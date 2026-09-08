#!/bin/sh
# =====================================================================
# openlist-sync.sh — 把 OpenList 掛載的網盤資料夾同步下載到本機目錄
#
# 用法:
#   openlist-sync.sh                      # 用預設遠端/本地路徑
#   openlist-sync.sh "/夸克網盤/影片" "/srv/share/USB/xxx/Video"
#   openlist-sync.sh --dry-run            # 只列出要抓什麼, 不真的抓
#
# 設計取捨(眉角):
# ⚠️ 這台對外只有 ~200KB/s, 28GB 的資料夾要跑好幾天。所以:
#    1. 一定要斷點續傳(curl -C -), 中斷不能從頭來。
#    2. 一定要有鎖, 否則 cron 每次都疊一個新的下載行程把頻寬吃光。
#    3. 每輪只抓「一個」檔案就結束, 讓 cron 自然接力 —— 不在單次執行裡
#       跑迴圈抓完整個資料夾(那會讓一個 cron instance 活好幾天, 鎖也難管)。
# ⚠️ OpenList 的 /d/ 端點沒帶 sign 一律回 401(實測), 每個檔都要先用
#    fs/get 取得自己的 sign。
# ⚠️ 用 .part 暫存檔, 抓完才 mv 成正式檔名 —— 避免半截檔被誤認為已完成。
# ⚠️ busybox 沒有 `stat`(實測 2026-09-08 .4: "stat: not found")! 取檔案大小
#    一律用 `wc -c < 檔案`。原本寫 stat -c %s 會靜默回空字串 → 判定永遠是
#    「沒有進展」, 明明檔案已經抓下來了還一直重抓。同理 busybox 的 cat 沒有
#    -A、也沒有 od, debug 時別用。
# =====================================================================

SCRIPT_DIR="$(dirname "$0")"
. "$SCRIPT_DIR/push-notify.inc" 2>/dev/null
PUSH_NAMES="${PUSH_NAMES:-admin}"

# ---- 設定 ----
OL_HOST="${OL_HOST:-http://192.168.1.4:5244}"
OL_USER="${OL_USER:-admin}"
OL_PASSFILE="/etc/myscript/.secrets/openlist.pass"

REMOTE_DIR="${1:-/夸克網盤}"
LOCAL_DIR="${2:-/srv/share/USB/1_42_6-25556/Video}"

DRY_RUN=0
[ "$1" = "--dry-run" ] && { DRY_RUN=1; REMOTE_DIR="${2:-/夸克網盤}"; LOCAL_DIR="${3:-/srv/share/USB/1_42_6-25556/Video}"; }

LOCKFILE="/tmp/openlist-sync.lock"
STATEDIR="/etc/myscript/.openlist-sync"
LOGTAG="openlist-sync"

log() { logger -t "$LOGTAG" "$1"; echo "$1"; }

# ---- 併發鎖 ----
# ⚠️ 不能只用 [ -f ] 判斷: 上次被 kill 掉會留下死鎖檔。存 PID 並驗證行程還在。
if [ -f "$LOCKFILE" ]; then
    _oldpid=$(cat "$LOCKFILE" 2>/dev/null)
    if [ -n "$_oldpid" ] && kill -0 "$_oldpid" 2>/dev/null; then
        # 正在跑就安靜結束, 不洗 log(cron 每 10 分鐘跑一次)
        exit 0
    fi
    log "清除死鎖檔 (舊 PID $_oldpid 已不存在)"
    rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT INT TERM

mkdir -p "$LOCAL_DIR" "$STATEDIR" 2>/dev/null

# ---- 取得密碼 ----
if [ ! -f "$OL_PASSFILE" ]; then
    log "錯誤: 找不到密碼檔 $OL_PASSFILE"
    exit 1
fi
OL_PASS=$(cat "$OL_PASSFILE")

# ---- 登入 ----
TOKEN=$(curl -s --max-time 20 -X POST "$OL_HOST/api/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$OL_USER\",\"password\":\"$OL_PASS\"}" \
    | jq -r '.data.token // empty' 2>/dev/null)

if [ -z "$TOKEN" ]; then
    log "登入失敗 — OpenList 沒回應或密碼錯誤"
    push_notify "OpenList同步: 登入失敗, 請檢查 $OL_PASSFILE"
    exit 1
fi

# ---- 列出遠端檔案 ----
# ⚠️ refresh:true 才會跟網盤要最新清單, 否則吃 OpenList 的 30 分鐘快取
LIST=$(curl -s --max-time 60 -X POST "$OL_HOST/api/fs/list" \
    -H "Authorization: $TOKEN" -H "Content-Type: application/json" \
    -d "{\"path\":\"$REMOTE_DIR\",\"page\":1,\"per_page\":500,\"refresh\":true}")

CODE=$(echo "$LIST" | jq -r '.code // 0' 2>/dev/null)
if [ "$CODE" != "200" ]; then
    _msg=$(echo "$LIST" | jq -r '.message // "未知錯誤"' 2>/dev/null)
    log "列目錄失敗: $_msg"
    # ⚠️ Cookie 過期是這套最常見的故障, 要能明確辨識並通知, 否則會靜默停擺
    case "$_msg" in
        *cookie*|*Cookie*|*login*|*auth*|*401*)
            push_notify "OpenList同步: 網盤認證失效(Cookie 可能過期), 需重新設定" ;;
        *)
            push_notify "OpenList同步: 列目錄失敗 — $_msg" ;;
    esac
    exit 1
fi

# ---- 挑出第一個「還沒抓完」的檔案 ----
# 逐筆比對: 遠端是檔案(is_dir=false) 且 本地不存在或大小不符
TOTAL=0; DONE=0; PICK=""; PICK_SIZE=0
_tmp="/tmp/.olsync.$$"
echo "$LIST" | jq -r '.data.content[]? | select(.is_dir==false) | "\(.size)\t\(.name)"' > "$_tmp" 2>/dev/null

while IFS="$(printf '\t')" read -r rsize rname; do
    [ -z "$rname" ] && continue
    TOTAL=$((TOTAL + 1))
    _local="$LOCAL_DIR/$rname"
    if [ -f "$_local" ]; then
        _lsize=$(wc -c < "$_local" 2>/dev/null | tr -d " " || echo 0)
        if [ "$_lsize" = "$rsize" ]; then
            DONE=$((DONE + 1))
            continue
        fi
        # ⚠️ 同名但大小不符 = 使用者自己放的檔 or 別處來的檔。
        #    絕對不能當成「沒下載完」去續傳 —— curl -C - 會從尾端接著寫,
        #    等於把使用者原有的檔案寫壞。★ 一律跳過並留紀錄, 由人決定。
        log "略過(同名但大小不符, 不覆寫): $rname 本地 ${_lsize} vs 遠端 ${rsize}"
        continue
    fi
    # 找到第一個沒完成的就記下來(只記第一個)
    [ -z "$PICK" ] && { PICK="$rname"; PICK_SIZE="$rsize"; }
done < "$_tmp"
rm -f "$_tmp"

if [ -z "$PICK" ]; then
    log "全部同步完成 ($DONE/$TOTAL 個檔案)"
    # ⚠️ 只在「剛完成」那次推播, 之後每 10 分鐘跑都安靜, 否則會被轟炸
    if [ ! -f "$STATEDIR/.allsynced" ] && [ "$TOTAL" -gt 0 ]; then
        push_notify "OpenList同步完成: $REMOTE_DIR 共 $TOTAL 個檔案已全部下載"
        touch "$STATEDIR/.allsynced"
    fi
    exit 0
fi
rm -f "$STATEDIR/.allsynced"

if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] 待下載: $PICK ($(( PICK_SIZE / 1048576 ))MB), 已完成 $DONE/$TOTAL"
    exit 0
fi

# ---- 取得該檔的 sign ----
SIGN=$(curl -s --max-time 30 -X POST "$OL_HOST/api/fs/get" \
    -H "Authorization: $TOKEN" -H "Content-Type: application/json" \
    -d "{\"path\":\"$REMOTE_DIR/$PICK\"}" \
    | jq -r '.data.sign // empty' 2>/dev/null)

if [ -z "$SIGN" ]; then
    log "取不到 sign: $PICK"
    push_notify "OpenList同步: 取不到下載簽章 ($PICK), 可能是網盤端拒絕"
    exit 1
fi

# ---- 下載(續傳) ----
PART="$LOCAL_DIR/.$PICK.part"
_have=0
[ -f "$PART" ] && _have=$(wc -c < "$PART" 2>/dev/null | tr -d " " || echo 0)
log "開始下載: $PICK ($(( PICK_SIZE / 1048576 ))MB), 已有 $(( _have / 1048576 ))MB, 進度 $DONE/$TOTAL"

# ⚠️ 路徑一定要 URL encode! 實測 2026-09-08: 檔名含空格或單引號(例如
#    "Sorcerer's Stone" 這種)直接塞進 URL, curl 8.19 會回 rc=3 (URL malformed)
#    或 HTTP 000, 完全抓不到。★ 用 jq 的 @uri 編碼整段路徑(連 / 也編成 %2F,
#    OpenList 收得下)。sign 不要編碼, 它本來就是 URL-safe base64。
_EPATH=$(jq -rn --arg s "$REMOTE_DIR/$PICK" '$s|@uri')

# ⚠️ --max-time 3000 (50分): 配合 cron */10 不會無限堆疊, 又能一次推進一大段。
#    -C - 讓下次接著抓, 慢速大檔靠多輪 cron 累積完成。
curl -sL -C - --max-time 3000 --retry 3 --retry-delay 10 \
    -o "$PART" \
    -H "Authorization: $TOKEN" \
    "$OL_HOST/d${_EPATH}?sign=$SIGN"
_rc=$?

_now=0
[ -f "$PART" ] && _now=$(wc -c < "$PART" 2>/dev/null | tr -d " " || echo 0)

if [ "$_now" = "$PICK_SIZE" ]; then
    # ⚠️ 最後一道保險: 就算跑到這裡, 目標若已存在也絕不覆寫(留 .part 讓人處理)
    if [ -e "$LOCAL_DIR/$PICK" ]; then
        log "警告: $PICK 已存在, 不覆寫; 新檔留在 $PART"
        push_notify "OpenList: $PICK 已存在未覆寫, 新檔暫存為 .part"
        exit 0
    fi
    mv "$PART" "$LOCAL_DIR/$PICK"
    log "完成: $PICK ($(( PICK_SIZE / 1048576 ))MB)"
    push_notify "OpenList: $PICK 下載完成 ($(( PICK_SIZE / 1048576 ))MB), 進度 $((DONE + 1))/$TOTAL"
elif [ "$_now" -gt "$_have" ]; then
    log "部分完成: $PICK $(( _now / 1048576 ))/$(( PICK_SIZE / 1048576 ))MB (curl rc=$_rc), 下輪續傳"
else
    log "沒有進展: $PICK (curl rc=$_rc)"
    # ⚠️ 完全沒進展才推播, 避免慢速正常續傳也一直通知
    push_notify "OpenList同步: $PICK 下載無進展 (rc=$_rc), 請檢查"
fi

exit 0
