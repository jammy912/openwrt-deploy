#!/bin/sh
# =====================================================================
# openlist-sync.sh — 把 OpenList 掛載的網盤資料夾同步下載到本機目錄
#
# 用法:
#   openlist-sync.sh                      # 預設: /夸克網盤/来自：分享 → Video
#   openlist-sync.sh "<遠端目錄>" "<本地目錄>" "<暫存目錄>"
#   STAGE_DIR="" openlist-sync.sh ...     # 不用暫存, 直接寫本地目錄
#
# 流程: 下載寫 SSD 暫存 → 完成搬到 8TB → 記 .ok。8TB 離線時檔案留在 SSD,
#       下一輪自動補搬; .ok 讓「已抓過」的判定不依賴 8TB 在不在。
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
# ⚠️ busybox 沒有 `stat`(實測 2026-09-08 .4: "stat: not found")! 但取大小
#    也 **不能用 `wc -c`** —— 它為了算位元組數會把整個檔案讀過一遍, 對這裡
#    動輒 13GB 的 .part 等於每次執行都從碟上讀 13GB(實測會燒滿 CPU、拖垮
#    整台, 且大檔讀到一半被打斷還會回錯的數字, 顯示「已有 742MB」而實際是
#    13030MB)。★ 一律用 `ls -l <檔> | awk '{print $5}'`, 只讀 inode
#    metadata, 實測 0ms。2026-09-09 已把本檔六處 wc -c 全部換掉。
#    同理 busybox 的 cat 沒有 -A、也沒有 od 與 timeout/nohup, debug 時別用。
# =====================================================================

# ⚠️ 固定用絕對路徑, 不用 dirname $0: 從別的目錄執行(例如 debug 時複製到 /tmp)
#    會找不到 push-notify.inc 而整個腳本靜默中斷(source 失敗即 exit)。
. /etc/myscript/push-notify.inc 2>/dev/null
PUSH_NAMES="${PUSH_NAMES:-admin}"

# ---- 設定 ----
# ⚠️ 一律用 127.0.0.1, 不要寫本機的 LAN IP。
#    2026-09-09 實測: .4 接手主 gw 後 LAN IP 從 192.168.1.4 變成 192.168.1.1,
#    而容器 -p 綁死在 192.168.1.4 -> DNAT 與 docker-proxy 都指向一個已經不
#    存在的位址 -> 腳本每輪都「登入失敗 — OpenList 沒回應或密碼錯誤」,
#    下載整整停了一小時(容器本身完全正常, 直連 172.17.0.2:5244 回 200)。
#    ★ 配套: 容器要用 `-p 5244:5244`(綁 0.0.0.0)而不是 `-p <LAN IP>:5244`。
OL_HOST="${OL_HOST:-http://127.0.0.1:5244}"
OL_USER="${OL_USER:-admin}"
OL_PASSFILE="/etc/myscript/.secrets/openlist.pass"

# 來源目錄(第 1 參數)。預設監看「来自：分享」——夸克把別人分享、你存進網盤的
# 東西都放這層, 新片會自動落在這裡, 遞迴掃下去就會被抓到。
REMOTE_DIR="${1:-/夸克網盤/来自：分享}"
LOCAL_DIR="${2:-/srv/share/USB/8TB/Video}"

# 暫存區(第 3 參數): 下載寫這裡, 完成才搬到 LOCAL_DIR。
# ⚠️ 為什麼要暫存: (1) 8TB 機械碟已通電 4.1 年 + 72 壞軌, 少讓它做長時間零碎
#    追加寫入 (2) 未完成的 .part 不會混進正式媒體目錄 (3) 8TB 拔掉時仍能續傳。
#    設成空字串 STAGE_DIR="" 即退回「直接下載到 LOCAL_DIR」的舊行為。
STAGE_DIR="${3:-/srv/share/USB/SSD/Video}"

# 完成記錄目錄。★ 關鍵: 8TB 離線時, 光看 LOCAL_DIR 會誤判「這檔還沒下載」而
# 重抓 29GB。故每個搬移完成的檔案留一個 <相對路徑>.ok(內容是檔案大小),
# 判定「已完成」時先認 .ok, 認不到才看實際檔案。
# ★ 放在 SSD 暫存區同一層(路徑對應), 記錄跟著碟走 —— 換台機器接上這顆 SSD
#   也認得哪些抓過; 沒有暫存區時才退回 flash。
if [ -n "$STAGE_DIR" ]; then
    DONEDIR="${DONEDIR:-$STAGE_DIR/.done}"
else
    DONEDIR="${DONEDIR:-/etc/myscript/.openlist-sync/done}"
fi

DRY_RUN=0
[ "$1" = "--dry-run" ] && { DRY_RUN=1; REMOTE_DIR="${2:-/夸克網盤/来自：分享}"; LOCAL_DIR="${3:-/srv/share/USB/8TB/Video}"; STAGE_DIR="${4:-/srv/share/USB/SSD/Video}"; }

LOCKFILE="/tmp/openlist-sync.lock"
FLUSHLOCK="/tmp/openlist-sync-flush.lock"
STATEDIR="/etc/myscript/.openlist-sync"
LOGTAG="openlist-sync"

log() { logger -t "$LOGTAG" "$1"; echo "$1"; }

# 目的地(8TB)是否真的掛載可寫。
# ⚠️ 不能只看目錄在不在: 碟拔掉後掛載點目錄仍存在(空的), 寫進去會寫到根檔案
#    系統的 overlay 把 flash 塞爆。★ 必須確認它是「掛載點」。
dest_online() {
    [ -d "$LOCAL_DIR" ] || return 1
    # LOCAL_DIR 或其上層要出現在 /proc/mounts
    _chk="$LOCAL_DIR"
    while [ -n "$_chk" ] && [ "$_chk" != "/" ]; do
        grep -q " $_chk " /proc/mounts 2>/dev/null && return 0
        _chk="${_chk%/*}"
    done
    return 1
}

# 驗證 MKV 結構完整性。回傳 0=通過(或非 mkv 不驗), 1=結構異常。
# ⚠️ 夸克 API 不回 hash(實測 2026-09-09: fs/get 的 hash_info 恆為 null),
#    無法跟遠端比對 checksum。但 MKV 檔頭自己就宣告了總長度, 可自我驗證:
#      1a 45 df a3            = EBML magic(不符 = 根本不是 mkv, 例如抓到錯誤頁)
#      18 53 80 67 + VINT     = Segment ID 與其 payload 長度
#    Segment 長度 + 檔頭偏移 ≈ 檔案總大小, 對不上就是被截斷。
# ★ 只讀 64 bytes, 對 30GB 檔案成本等於零 —— 不要用會讀完整顆檔的做法
#   (參見 wc -c 的教訓: busybox wc -c 會把整個檔案讀過一遍)。
# ⚠️ 副檔名要用「最終檔名」判斷, 不能用被讀的那個檔:下載中的檔叫 xxx.mkv.part,
#    拿它比對 *.mkv 永遠不中 → 整個檢查靜默跳過(實測 2026-09-09 踩到)。
#    故 $1=要讀的檔, $3=最終檔名(省略時才退回用 $1 判斷)。
verify_mkv() {
    _vf="$1"; _vsz="$2"; _vname="${3:-$1}"
    case "$_vname" in *.mkv|*.MKV) ;; *) return 0 ;; esac   # 非 mkv 不驗
    command -v hexdump >/dev/null 2>&1 || return 0        # 沒 hexdump 就跳過

    _hx=$(hexdump -v -e '1/1 "%02x "' -n 64 "$_vf" 2>/dev/null)
    [ -n "$_hx" ] || return 0

    # 1) EBML magic
    case "$_hx" in
        "1a 45 df a3 "*) ;;
        *) log "結構異常: $(basename "$_vname") 不是 MKV(檔頭 $(echo "$_hx" | cut -c1-11))"
           return 1 ;;
    esac

    # 2) 找 Segment ID (18 53 80 67), 取其後的 VINT 長度
    _pre="${_hx%%18 53 80 67 *}"
    [ "$_pre" = "$_hx" ] && return 0          # 64 bytes 內沒看到 Segment, 不判定
    _off=$(( ${#_pre} / 3 ))                  # 每 byte 佔 "xx " 三字元
    _rest="${_hx#*18 53 80 67 }"
    set -- $_rest
    _first="$1"
    # VINT: 首 byte 的最高位標示長度。只處理最常見的 01(8-byte)與 ff(未知長度)
    [ "$_first" = "ff" ] && return 0          # 未知長度(串流式寫入), 無從比對
    [ "$_first" = "01" ] || return 0          # 其他編碼不判定, 避免誤殺

    _val=0
    for _b in "$2" "$3" "$4" "$5" "$6" "$7" "$8"; do
        _val=$(( _val * 256 + 0x$_b ))
    done
    _hdr=$(( _off + 4 + 8 ))                  # Segment ID(4) + 長度欄(8)
    _exp=$(( _val + _hdr ))
    _diff=$(( _vsz - _exp ))
    [ "$_diff" -lt 0 ] && _diff=$(( - _diff ))
    # 容差 1KB: 檔尾可能有 EBML void/padding(實測某片差 22 bytes)
    if [ "$_diff" -gt 1024 ]; then
        log "結構異常: $(basename "$_vname") 宣告 $_exp bytes 實際 $_vsz bytes(差 $_diff)"
        return 1
    fi
    return 0
}

# 把暫存區的一個完成檔搬到目的地並記 .ok。
# 回傳 0=已搬(或本來就沒暫存區), 1=目的地離線(留在暫存區)
stage_move() {
    _rel="$1"; _sz="$2"
    _okf="$DONEDIR/$_rel.ok"
    # 沒有暫存區 = 本來就直接寫目的地, 只要記 .ok
    if [ -z "$STAGE_DIR" ]; then
        mkdir -p "$(dirname "$_okf")" 2>/dev/null; echo "$_sz" > "$_okf"; return 0
    fi
    _src="$STAGE_DIR/$_rel"
    [ -f "$_src" ] || return 0
    if ! dest_online; then
        log "8TB 未掛載, $_rel 暫留 SSD(下輪自動補搬)"
        return 1
    fi
    mkdir -p "$(dirname "$LOCAL_DIR/$_rel")" 2>/dev/null
    if [ -e "$LOCAL_DIR/$_rel" ]; then
        log "目的地已有同名檔, 不覆寫; $_rel 留在 SSD"
        return 1
    fi
    # ⚠️ 跨檔案系統 mv = 複製後刪除, 中途斷電會留半截檔。先搬成 .moving 再改名,
    #    這樣目的地不會出現看似完整的半截檔。
    if mv "$_src" "$LOCAL_DIR/$_rel.moving" 2>/dev/null; then
        _msz=$(ls -l "$LOCAL_DIR/$_rel.moving" 2>/dev/null | awk '{print $5}')
        [ -z "$_msz" ] && _msz=0
        if [ "$_msz" = "$_sz" ]; then
            mv "$LOCAL_DIR/$_rel.moving" "$LOCAL_DIR/$_rel"
            mkdir -p "$(dirname "$_okf")" 2>/dev/null; echo "$_sz" > "$_okf"
            log "已歸檔到 8TB: $_rel"
            return 0
        fi
        log "搬移後大小不符($_msz vs $_sz), 保留 .moving 供檢查"
        return 1
    fi
    # 搬移失敗最常見的原因就是 8TB 滿了, 明講出來免得使用者以為是壞掉
    _free=$(df -k "$LOCAL_DIR" 2>/dev/null | awk 'NR==2{print $4}')
    log "搬移失敗: $_rel (8TB 剩餘 $(( ${_free:-0} / 1048576 ))GB)"
    push_notify "OpenList: $(basename "$_rel") 歸檔失敗, 8TB 剩 $(( ${_free:-0} / 1048576 ))GB, 檔案留在 SSD"
    return 1
}

# 開場先把暫存區裡「已完成但還沒搬」的檔補搬(上次 8TB 離線時留下的)
stage_flush() {
    [ -n "$STAGE_DIR" ] || return 0
    [ -d "$STAGE_DIR" ] || return 0
    dest_online || return 0
    # ⚠️ while 由管線餵食 = 跑在子 shell, 迴圈內的變數出不來。改用暫存檔累計,
    #    否則補搬幾個、總共多大這些數字在迴圈結束後全部歸零。
    _fl="/tmp/olsync.flush.$$"; : > "$_fl"
    # ⚠️ 要排除 .done 目錄本身(裡面是 .ok 記錄, 不是待搬的影片)
    find "$STAGE_DIR" -type f ! -name ".*.part" ! -name "*.moving" ! -name "*.ok" 2>/dev/null | while read -r _f; do
        _r="${_f#$STAGE_DIR/}"
        case "$_r" in .done/*) continue ;; esac
        _s=$(ls -l "$_f" 2>/dev/null | awk '{print $5}')
        [ -n "$_s" ] && [ "$_s" -gt 0 ] || continue
        stage_move "$_r" "$_s" && echo "$_s $(basename "$_r")" >> "$_fl"
    done
    # 補搬完成才推播。★ 彙總成一則: 8TB 接回來時可能一次搬好幾個檔,
    #   每個檔推一則會連環轟炸。
    if [ -s "$_fl" ]; then
        _n=$(wc -l < "$_fl")
        _mb=$(awk '{t+=$1} END{printf "%d", t/1048576}' "$_fl")
        _names=$(awk '{$1=""; sub(/^ /,""); print}' "$_fl" | head -3 | tr '\n' ' ')
        [ "$_n" -gt 3 ] && _names="$_names..."
        push_notify "OpenList: 8TB 已接回, 補搬 $_n 個檔案完成 (${_mb}MB): $_names"
    fi
    rm -f "$_fl"
}

# 取鎖: $1=鎖檔路徑。回傳 0=取到, 1=別人正在跑。
# ⚠️ 不能只用 [ -f ] 判斷: 上次被 kill 掉會留下死鎖檔。存 PID 並驗證行程還在。
# 殺掉某個行程的所有子行程。⚠️ busybox 的 ps 沒有 -o 選項(實測
# "ps: unrecognized option: o"), 只能從 /proc/<pid>/stat 第 4 欄讀 PPID。
kill_children() {
    _pp="$1"; _sig="$2"
    for _d in /proc/[0-9]*; do
        _cp="${_d#/proc/}"
        [ "$(awk '{print $4}' "$_d/stat" 2>/dev/null)" = "$_pp" ] || continue
        kill $_sig "$_cp" 2>/dev/null
    done
}

take_lock() {
    _lk="$1"
    if [ -f "$_lk" ]; then
        _oldpid=$(cat "$_lk" 2>/dev/null)
        if [ -n "$_oldpid" ] && kill -0 "$_oldpid" 2>/dev/null; then
            return 1
        fi
        log "清除死鎖檔 $_lk (舊 PID $_oldpid 已不存在)"
        rm -f "$_lk"
    fi
    echo $$ > "$_lk"
    return 0
}

# ---- 沒裝 OpenList 的機器安靜跳過(要在建目錄之前!) ----
# ⚠️ 2026-09-08: 這支 cron 由 Google Sheet 下發給整個機隊, 但只有 .4 跑
#    OpenList。其他機器(實查 .1)每 10 分鐘寫一筆「找不到密碼檔」到 log,
#    一天 144 筆純噪音, 而 log buffer 只有 128KB 很快被洗光。
#    ★ 更糟的是原本判斷寫在下面, 上面的 mkdir 已經先跑過 —— 在沒有那些碟的
#      機器上會把 /srv/share/USB/... 建在根檔案系統的 overlay 慢慢吃 flash。
#      故判斷必須提到「所有 mkdir 與 stage_flush 之前」。
#    ★ 沒有密碼檔 = 這台沒有 OpenList -> 安靜 exit 0, 不 log 不推播。
#      真正「有裝但設定壞掉」由後面的登入失敗那段負責告警。
if [ ! -f "$OL_PASSFILE" ]; then
    [ "$DRY_RUN" = "1" ] && echo "(本機無 $OL_PASSFILE, 判定未安裝 OpenList, 正常執行時會安靜跳過)"
    exit 0
fi

# ⚠️ 不要無條件 mkdir -p "$LOCAL_DIR": 8TB 拔掉時掛載點目錄還在(空的),
#    建目錄+寫檔會落到根檔案系統的 overlay, 把 flash 塞爆。只在它真的掛著時建。
dest_online && mkdir -p "$LOCAL_DIR" 2>/dev/null
mkdir -p "$STATEDIR" 2>/dev/null
[ -n "$STAGE_DIR" ] && mkdir -p "$STAGE_DIR" "$DONEDIR" 2>/dev/null

# ---- 補搬上次因 8TB 離線而留在 SSD 的完成檔 ----
# ★ 必須在「下載鎖」之前, 而且用自己獨立的鎖。
#   ⚠️ 2026-09-09 實測的坑: 原本 stage_flush 在下載鎖「之後」, 而 curl 帶
#      舊設定 --max-time 3000(50分) = 下載幾乎永遠在跑 -> 每輪
#      都在鎖那裡 exit 0 -> 走不到補搬。結果「8TB 接回來了, 但因為正在抓別的
#      檔, 已完成的檔就一直躺在 SSD」, 要等整個下載結束才會搬。
#   搬檔(本地 mv)與下載(網路 I/O)沒有共用資源, 可以並行。同時搬同一個檔也
#   安全: mv 對同一來源只有一個會成功, 另一個 [ -f "$_src" ] 就 return 了。
if take_lock "$FLUSHLOCK"; then
    trap 'rm -f "$FLUSHLOCK"' EXIT INT TERM
    stage_flush
    rm -f "$FLUSHLOCK"
    trap - EXIT INT TERM
fi

# ---- 下載併發鎖 ----
# ⚠️ 這把鎖只管下載: 一個 cron instance 可能活很久, 不能讓下一輪再疊一個
#    curl 上來把頻寬吃光。
# ★ 但「行程還活著」不等於「還在做事」: 實測 2026-09-09 有個 curl 卡了 116
#   分鐘、.part 完全沒長, 卻因為 PID 還在而一直佔著鎖 —— 每輪 cron 都被它擋
#   掉, 等於整個同步停擺。故取不到鎖時再檢查「上一輪是不是卡死了」。
if ! take_lock "$LOCKFILE"; then
    _stall="$STATEDIR/.stall"
    _cur=0
    _pf=$(find "$STAGE_DIR" -name "*.part" 2>/dev/null | head -1)
    [ -n "$_pf" ] && _cur=$(ls -l "$_pf" 2>/dev/null | awk '{print $5}')
    _prev=$(cat "$_stall" 2>/dev/null | awk '{print $1}')
    _cnt=$(cat "$_stall" 2>/dev/null | awk '{print $2+0}')
    if [ -n "$_prev" ] && [ "$_cur" = "$_prev" ]; then
        _cnt=$(( _cnt + 1 ))
    else
        _cnt=0
    fi
    echo "$_cur $_cnt" > "$_stall"
    # 連續 3 輪(整點 cron = 3 小時)完全沒進展才動手, 避免誤殺慢速但正常的下載
    if [ "$_cnt" -ge 3 ]; then
        _oldpid=$(cat "$LOCKFILE" 2>/dev/null)
        log "上一輪卡死 (PID $_oldpid, 連續 $_cnt 輪停在 $_cur bytes), 終止它"
        # 先殺 curl 子行程再殺主行程, 否則 curl 會被 init 收養繼續佔頻寬
        kill_children "$_oldpid"
        [ -n "$_oldpid" ] && kill "$_oldpid" 2>/dev/null
        sleep 2
        kill_children "$_oldpid" -9
        [ -n "$_oldpid" ] && kill -9 "$_oldpid" 2>/dev/null
        rm -f "$LOCKFILE" "$_stall"
        push_notify "OpenList: 下載卡死 $_cnt 輪(停在 $(( _cur / 1048576 ))MB)已重啟, 續傳不會損失進度"
        take_lock "$LOCKFILE" || exit 0
    else
        exit 0
    fi
fi
trap 'rm -f "$LOCKFILE"' EXIT INT TERM
rm -f "$STATEDIR/.stall"

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

    # ★ 先認 .ok 記錄: 8TB 離線時 $_local 根本不存在, 沒有這關會誤判成「還沒
    #   下載」而重抓 29GB。.ok 存在 flash, 不受外接碟插拔影響。
    #   內容存遠端大小, 遠端換了新版(大小不同)時 .ok 自動失效會重抓。
    _okf="$DONEDIR/$rrel.ok"
    if [ -f "$_okf" ] && [ "$(cat "$_okf" 2>/dev/null)" = "$rsize" ]; then
        DONE=$((DONE + 1))
        continue
    fi

    # 暫存區已有完整檔(等著搬) 也算完成, 避免重抓
    if [ -n "$STAGE_DIR" ] && [ -f "$STAGE_DIR/$rrel" ]; then
        _ssize=$(ls -l "$STAGE_DIR/$rrel" 2>/dev/null | awk '{print $5}')
        [ -z "$_ssize" ] && _ssize=0
        [ "$_ssize" = "$rsize" ] && { DONE=$((DONE + 1)); continue; }
    fi

    _local="$LOCAL_DIR/$rrel"
    if [ -f "$_local" ]; then
        _lsize=$(ls -l "$_local" 2>/dev/null | awk '{print $5}')
        [ -z "$_lsize" ] && _lsize=0
        if [ "$_lsize" = "$rsize" ]; then
            DONE=$((DONE + 1))
            # 補記 .ok(舊檔或手動放的檔第一次掃到時建立)
            mkdir -p "$(dirname "$_okf")" 2>/dev/null
            echo "$rsize" > "$_okf"
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
    # ★ 要查「實際寫入的那顆碟」= 暫存區(SSD), 不是最終的 8TB。SSD 只有 440GB,
    #   放不下 4K 大檔就會寫爆; 查錯碟會以為 6.2T 很夠而一路寫到滿。
    _spacedir="${STAGE_DIR:-$LOCAL_DIR}"
    _availkb=$(df -k "$_spacedir" 2>/dev/null | awk 'NR==2{print $4}')
    _needkb=$(( PICK_SIZE / 1024 + 5242880 ))
    if [ -n "$_availkb" ] && [ "$_availkb" -lt "$_needkb" ]; then
        log "空間不足($_spacedir): 剩 $(( _availkb / 1048576 ))GB, 需要 $(( _needkb / 1048576 ))GB"
        if [ ! -f "$STATEDIR/.diskfull" ]; then
            push_notify "OpenList同步: 暫存區空間不足已暫停 (剩 $(( _availkb / 1048576 ))GB, 需 $(( _needkb / 1048576 ))GB); 8TB 若離線請接回讓檔案歸檔"
            touch "$STATEDIR/.diskfull"
        fi
        exit 1
    fi
    rm -f "$STATEDIR/.diskfull"

    # ★ 最終目的地(8TB)也要檢查: 暫存區夠不代表歸檔得下。8TB 滿了會讓檔案
    #   全部卡在 440GB 的 SSD, 很快連暫存都寫不下 —— 要提早警告而不是等到卡死。
    #   ⚠️ 只警告不中斷: 下載到 SSD 仍有意義(8TB 清出空間後會自動補搬)。
    if [ -n "$STAGE_DIR" ] && dest_online; then
        _dstkb=$(df -k "$LOCAL_DIR" 2>/dev/null | awk 'NR==2{print $4}')
        if [ -n "$_dstkb" ] && [ "$_dstkb" -lt "$_needkb" ]; then
            log "8TB 空間不足: 剩 $(( _dstkb / 1048576 ))GB, 需要 $(( _needkb / 1048576 ))GB"
            if [ ! -f "$STATEDIR/.destfull" ]; then
                push_notify "OpenList同步: ⚠️8TB 空間不足 (剩 $(( _dstkb / 1048576 ))GB, 需 $(( _needkb / 1048576 ))GB), 檔案將卡在 SSD 暫存區, 請清理"
                touch "$STATEDIR/.destfull"
            fi
        else
            rm -f "$STATEDIR/.destfull"
        fi
    fi
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
# 有暫存區就寫暫存區, 否則直接寫目的地(舊行為)
if [ -n "$STAGE_DIR" ]; then
    _workdir=$(dirname "$STAGE_DIR/$PICK_REL")
else
    _workdir=$(dirname "$LOCAL_DIR/$PICK_REL")
fi
_destdir=$(dirname "$LOCAL_DIR/$PICK_REL")
mkdir -p "$_workdir" 2>/dev/null
PART="$_workdir/.$(basename "$PICK_REL").part"
_have=0
[ -f "$PART" ] && _have=$(ls -l "$PART" 2>/dev/null | awk '{print $5}')
[ -z "$_have" ] && _have=0
log "開始下載: $PICK_REL ($(( PICK_SIZE / 1048576 ))MB), 已有 $(( _have / 1048576 ))MB, 進度 $DONE/$TOTAL"

# ⚠️ 路徑一定要 URL encode! 實測 2026-09-08: 檔名含空格或單引號(例如
#    "Sorcerer's Stone" 這種)直接塞進 URL, curl 8.19 會回 rc=3 (URL malformed)
#    或 HTTP 000, 完全抓不到。★ 用 jq 的 @uri 編碼整段路徑(連 / 也編成 %2F,
#    OpenList 收得下)。sign 不要編碼, 它本來就是 URL-safe base64。
_EPATH=$(jq -rn --arg s "$PICK" '$s|@uri')

# ⚠️ --max-time 是「單次嘗試」的上限, 不是整條指令的上限!
#    實測 2026-09-09: --max-time 3000 --retry 3 的 curl 活了 116 分鐘還沒被砍,
#    因為 retry 3 次 = 最多 4 次嘗試 -> 上限其實是 3000 x 4 = 12000 秒(200分)。
#    ⚠️ --speed-limit/--speed-time 也擋不住這種卡法! 實測 2026-09-09: 帶了
#      --speed-time 120 的 curl 照樣跑 663 秒不放棄。原因是 speed 計量要等
#      「回應主體開始傳輸」才啟動, 而夸克限速時是 TCP 連線 ESTABLISHED、
#      卻遲遲不回 header -> 速度計根本沒開始算 -> 這道防護形同虛設。
#      (驗證法: /proc/<pid>/net/tcp 看到狀態 01=ESTABLISHED 但 -o 目標 0 bytes)
#    ★ 真正有效的是 --max-time 壓低 + 少 retry: 讓「單輪」有絕對上限。
#      10 分鐘一輪的 cron 配 max-time 540(9分) + retry 1, 最壞約 9 分鐘結束,
#      不會跨到下一輪。卡住就早點放手, 下輪帶新 sign 重來。
#    -C - 讓下次接著抓, 慢速大檔靠多輪 cron 累積完成 —— 放棄不會損失進度。
curl -sL -C - --max-time 540 --retry 1 --retry-delay 5 \
    --connect-timeout 30 --speed-limit 1024 --speed-time 120 \
    -o "$PART" \
    -H "Authorization: $TOKEN" \
    "$OL_HOST/d${_EPATH}?sign=$SIGN"
_rc=$?

_now=0
[ -f "$PART" ] && _now=$(ls -l "$PART" 2>/dev/null | awk '{print $5}')
[ -z "$_now" ] && _now=0

if [ "$_now" = "$PICK_SIZE" ]; then
    # ⚠️ 最後一道保險: 就算跑到這裡, 目標若已存在也絕不覆寫(留 .part 讓人處理)
    if [ -e "$LOCAL_DIR/$PICK_REL" ]; then
        log "警告: $PICK_REL 已存在, 不覆寫; 新檔留在 $PART"
        push_notify "OpenList: $PICK_REL 已存在未覆寫, 新檔暫存為 .part"
        exit 0
    fi
    # ★ 結構檢查: 大小對不代表內容完整。不通過就留著 .part 不改名, 讓下一輪
    #   不會把壞檔當成完成品搬進 8TB(改名後 .ok 一記就再也不會重抓)。
    if ! verify_mkv "$PART" "$PICK_SIZE" "$PICK_REL"; then
        push_notify "OpenList: ⚠️$(basename "$PICK_REL") 大小正確但 MKV 結構異常, 未歸檔; 檔案留在 .part 待檢查"
        exit 0
    fi

    # .part → 暫存區的正式檔名(先落地, 再談搬不搬)
    _staged="$_workdir/$(basename "$PICK_REL")"
    mv "$PART" "$_staged"
    log "下載完成: $PICK_REL ($(( PICK_SIZE / 1048576 ))MB)"

    # 搬到 8TB。⚠️ 8TB 可能離線(拔碟/沒掛載), 這時「留在 SSD」不要搬、不要
    #    報錯、更不要重下 —— 下一輪由 stage_flush 補搬。
    if stage_move "$PICK_REL" "$PICK_SIZE"; then
        push_notify "OpenList: $(basename "$PICK_REL") 完成並歸檔 ($(( PICK_SIZE / 1048576 ))MB), 進度 $((DONE + 1))/$TOTAL"
    else
        push_notify "OpenList: $(basename "$PICK_REL") 下載完成但 8TB 未掛載, 暫留 SSD ($(( PICK_SIZE / 1048576 ))MB)"
    fi
elif [ "$_now" -gt "$_have" ]; then
    log "部分完成: $PICK_REL $(( _now / 1048576 ))/$(( PICK_SIZE / 1048576 ))MB (curl rc=$_rc), 下輪續傳"
else
    log "沒有進展: $PICK_REL (curl rc=$_rc)"
    # ⚠️ 完全沒進展才推播, 避免慢速正常續傳也一直通知
    push_notify "OpenList同步: $(basename "$PICK_REL") 下載無進展 (rc=$_rc), 請檢查"
fi

exit 0
