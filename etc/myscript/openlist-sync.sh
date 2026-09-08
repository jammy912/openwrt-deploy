#!/bin/sh
# =====================================================================
# openlist-sync.sh — 把 OpenList 掛載的網盤資料夾同步下載到本機目錄
#
# 用法:
#   openlist-sync.sh                      # 預設: /夸克網盤/来自：分享 → Video
#   openlist-sync.sh "<遠端目錄>" "<本地目錄>"
#   openlist-sync.sh --dry-run            # 只列出要抓什麼, 不真的抓
#   openlist-sync.sh --dry-run "<遠端目錄>"
#   MAX_DEPTH=3 openlist-sync.sh ...      # 限制遞迴深度(預設 5)
#
# 行為: 遞迴掃描來源目錄樹, 只抓影片副檔名, 本地保留相同的子目錄結構。
#       新增的影片(含新子目錄裡的)下一輪就會被抓到, 不必改設定。
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

# ⚠️ 固定用絕對路徑, 不用 dirname $0: 從別的目錄執行(例如 debug 時複製到 /tmp)
#    會找不到 push-notify.inc 而整個腳本靜默中斷(source 失敗即 exit)。
. /etc/myscript/push-notify.inc 2>/dev/null
PUSH_NAMES="${PUSH_NAMES:-admin}"

# ---- 設定 ----
OL_HOST="${OL_HOST:-http://192.168.1.4:5244}"
OL_USER="${OL_USER:-admin}"
OL_PASSFILE="/etc/myscript/.secrets/openlist.pass"

# 來源目錄(第 1 參數)。預設監看「来自：分享」——夸克把別人分享、你存進網盤的
# 東西都放這層, 新片會自動落在這裡, 遞迴掃下去就會被抓到。
REMOTE_DIR="${1:-/夸克網盤/来自：分享}"
LOCAL_DIR="${2:-/srv/share/USB/1_42_6-25556/Video}"

DRY_RUN=0
[ "$1" = "--dry-run" ] && { DRY_RUN=1; REMOTE_DIR="${2:-/夸克網盤/来自：分享}"; LOCAL_DIR="${3:-/srv/share/USB/1_42_6-25556/Video}"; }

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

# ---- 遞迴展開整個目錄樹, 挑出第一個「還沒抓完」的影片 ----
# ⚠️ 用暫存檔+while, 不用管線右側的 while: 那會在子 shell 跑, TOTAL/PICK
#    這些變數改了傳不回父層(本 repo 在 auto-role.sh 踩過同樣的坑)。
# ⚠️ busybox 沒有 `find -maxdepth` 可用在遠端, 遞迴要自己走: 用一個待訪佇列
#    檔, 邊走邊往後追加子目錄, 直到佇列空。深度上限 MAX_DEPTH 防惡性巢狀。
TOTAL=0; DONE=0; SKIP=0; PICK=""; PICK_SIZE=0; PICK_REL=""
_tmp="/tmp/.olsync.$$"
_queue="/tmp/.olsync.q.$$"
: > "$_tmp"
echo "	$REMOTE_DIR" > "$_queue"      # 格式: <相對路徑>\t<絕對路徑>, 根的相對路徑為空
MAX_DEPTH="${MAX_DEPTH:-5}"
_qline=1

while :; do
    _cur=$(sed -n "${_qline}p" "$_queue")
    [ -z "$_cur" ] && break
    _qline=$((_qline + 1))
    _rel="${_cur%%	*}"
    _abs="${_cur#*	}"

    # 深度保護: 相對路徑的 / 數量
    _depth=$(echo "$_rel" | tr -cd '/' | wc -c | tr -d ' ')
    [ "$_depth" -ge "$MAX_DEPTH" ] && { log "略過(超過深度 $MAX_DEPTH): $_rel"; continue; }

    # 根目錄的清單已經抓過(上面的 $LIST), 不重抓
    if [ "$_abs" = "$REMOTE_DIR" ]; then
        _json="$LIST"
    else
        _json=$(curl -s --max-time 60 -X POST "$OL_HOST/api/fs/list" \
            -H "Authorization: $TOKEN" -H "Content-Type: application/json" \
            -d "$(jq -nc --arg p "$_abs" '{path:$p,page:1,per_page:500,refresh:true}')")
        [ "$(echo "$_json" | jq -r '.code // 0' 2>/dev/null)" != "200" ] && {
            log "略過(子目錄讀取失敗): $_rel"; continue; }
    fi

    # 子目錄 → 追加到佇列尾端(廣度優先)
    echo "$_json" | jq -r '.data.content[]? | select(.is_dir==true) | .name' 2>/dev/null \
        | while read -r _d; do
            [ -z "$_d" ] && continue
            printf '%s\t%s\n' "${_rel:+$_rel/}$_d" "$_abs/$_d" >> "$_queue"
        done

    # 檔案 → 寫進待比對清單(帶相對路徑)
    echo "$_json" | jq -r '.data.content[]? | select(.is_dir==false) | "\(.size)\t\(.name)"' 2>/dev/null \
        | while IFS="$(printf '\t')" read -r _s _n; do
            [ -z "$_n" ] && continue
            printf '%s\t%s\t%s\n' "$_s" "${_rel:+$_rel/}$_n" "$_abs/$_n" >> "$_tmp"
        done
done
rm -f "$_queue"

while IFS="$(printf '\t')" read -r rsize rrel rabs; do
    [ -z "$rrel" ] && continue

    # ⚠️ 只抓影片: 遞迴會掃到 .ipk/.txt/.7z/.jpg 這些, 全抓會浪費好幾天頻寬。
    #    副檔名比對要轉小寫(遠端常見 .MKV)。
    _ext=$(echo "${rrel##*.}" | tr 'A-Z' 'a-z')
    case "$_ext" in
        mkv|mp4|avi|ts|m2ts|mov|wmv|flv|webm|iso|rmvb|mpg|mpeg) ;;
        *) SKIP=$((SKIP + 1)); continue ;;
    esac

    TOTAL=$((TOTAL + 1))
    _local="$LOCAL_DIR/$rrel"
    if [ -f "$_local" ]; then
        _lsize=$(wc -c < "$_local" 2>/dev/null | tr -d " " || echo 0)
        if [ "$_lsize" = "$rsize" ]; then
            DONE=$((DONE + 1))
            continue
        fi
        # ⚠️ 同名但大小不符 = 使用者自己放的檔 or 別處來的檔。
        #    絕對不能當成「沒下載完」去續傳 —— curl -C - 會從尾端接著寫,
        #    等於把使用者原有的檔案寫壞。★ 一律跳過並留紀錄, 由人決定。
        log "略過(同名但大小不符, 不覆寫): $rrel 本地 ${_lsize} vs 遠端 ${rsize}"
        continue
    fi
    # 找到第一個沒完成的就記下來(只記第一個)
    [ -z "$PICK" ] && { PICK="$rabs"; PICK_SIZE="$rsize"; PICK_REL="$rrel"; }
done < "$_tmp"
rm -f "$_tmp"

# ---- 容量保護 ----
# ⚠️ 4K 一部就 30GB, 磁碟寫滿會連累 minidlna db 跟其他服務(都在同一顆碟)。
#    ★ 剩餘空間不足「這個檔 + 5GB 緩衝」就停手並通知, 不要抓到爆碟。
if [ -n "$PICK" ]; then
    _availkb=$(df -k "$LOCAL_DIR" 2>/dev/null | awk 'NR==2{print $4}')
    _needkb=$(( PICK_SIZE / 1024 + 5242880 ))
    if [ -n "$_availkb" ] && [ "$_availkb" -lt "$_needkb" ]; then
        log "空間不足: 剩 $(( _availkb / 1048576 ))GB, 需要 $(( _needkb / 1048576 ))GB"
        if [ ! -f "$STATEDIR/.diskfull" ]; then
            push_notify "OpenList同步: 磁碟空間不足, 已暫停下載 (剩 $(( _availkb / 1048576 ))GB)"
            touch "$STATEDIR/.diskfull"
        fi
        exit 1
    fi
    rm -f "$STATEDIR/.diskfull"
fi

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
    log "[dry-run] 待下載: $PICK_REL ($(( PICK_SIZE / 1048576 ))MB), 影片 $DONE/$TOTAL, 已略過非影片 $SKIP 個"
    exit 0
fi

# ---- 取得該檔的 sign ----
SIGN=$(curl -s --max-time 30 -X POST "$OL_HOST/api/fs/get" \
    -H "Authorization: $TOKEN" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg p "$PICK" '{path:$p}')" \
    | jq -r '.data.sign // empty' 2>/dev/null)

if [ -z "$SIGN" ]; then
    log "取不到 sign: $PICK_REL"
    push_notify "OpenList同步: 取不到下載簽章 ($PICK_REL), 可能是網盤端拒絕"
    exit 1
fi

# ---- 下載(續傳) ----
# ⚠️ 遞迴模式下要還原目錄結構, 子目錄可能還不存在
_destdir=$(dirname "$LOCAL_DIR/$PICK_REL")
mkdir -p "$_destdir" 2>/dev/null
PART="$_destdir/.$(basename "$PICK_REL").part"
_have=0
[ -f "$PART" ] && _have=$(wc -c < "$PART" 2>/dev/null | tr -d " " || echo 0)
log "開始下載: $PICK_REL ($(( PICK_SIZE / 1048576 ))MB), 已有 $(( _have / 1048576 ))MB, 進度 $DONE/$TOTAL"

# ⚠️ 路徑一定要 URL encode! 實測 2026-09-08: 檔名含空格或單引號(例如
#    "Sorcerer's Stone" 這種)直接塞進 URL, curl 8.19 會回 rc=3 (URL malformed)
#    或 HTTP 000, 完全抓不到。★ 用 jq 的 @uri 編碼整段路徑(連 / 也編成 %2F,
#    OpenList 收得下)。sign 不要編碼, 它本來就是 URL-safe base64。
_EPATH=$(jq -rn --arg s "$PICK" '$s|@uri')

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
    if [ -e "$LOCAL_DIR/$PICK_REL" ]; then
        log "警告: $PICK_REL 已存在, 不覆寫; 新檔留在 $PART"
        push_notify "OpenList: $PICK_REL 已存在未覆寫, 新檔暫存為 .part"
        exit 0
    fi
    mv "$PART" "$LOCAL_DIR/$PICK_REL"
    log "完成: $PICK_REL ($(( PICK_SIZE / 1048576 ))MB)"
    push_notify "OpenList: $(basename "$PICK_REL") 下載完成 ($(( PICK_SIZE / 1048576 ))MB), 進度 $((DONE + 1))/$TOTAL"
elif [ "$_now" -gt "$_have" ]; then
    log "部分完成: $PICK_REL $(( _now / 1048576 ))/$(( PICK_SIZE / 1048576 ))MB (curl rc=$_rc), 下輪續傳"
else
    log "沒有進展: $PICK_REL (curl rc=$_rc)"
    # ⚠️ 完全沒進展才推播, 避免慢速正常續傳也一直通知
    push_notify "OpenList同步: $(basename "$PICK_REL") 下載無進展 (rc=$_rc), 請檢查"
fi

exit 0
