#!/bin/sh
# 推播外接硬碟 SMART 健康狀態: 溫度 / 壞軌 / 通電時數 / 傳輸錯誤
#
# 用法:
#   push-hddsmart.sh            # 正常執行(推播)
#   push-hddsmart.sh --show     # 只把推播內容印到 console, 不推播、不搶鎖
#
# ⚠️ 眉角一: 只在「碟有掛載成 share」時才推播。沒插碟或沒掛載時直接靜默退出,
#    否則每次 cron 都會推一則「查不到硬碟」的垃圾訊息。
# ⚠️ 眉角二: smartctl 讀取會喚醒休眠中的硬碟。本機碟由韌體 APM=128 管休眠,
#    每次讀 SMART 都吵醒它會讓 Start_Stop_Count 一直累加(機械磨損)。
#    ★ 故一律加 -n standby: 碟在睡就跳過本輪, 不打擾。
# ⚠️ 眉角三: USB 外接盒必須指定 -d 才讀得到 SMART。實測 Ugreen RTL9210
#    (0x0bda:0x9201) 用 -d auto 會回 "Unknown USB bridge ... Please specify
#    device type with the -d option", 一行屬性都拿不到; -d sat 才正常。
#    ★ 換不同外接盒可能要 sat,12 / usbjmicron / usbsunplus, 故改成候選清單
#      依序試, 第一個讀得到溫度(194)的就採用, 免得換盒子就得改 code。
# ⚠️ 眉角四: Reallocated_Sector_Ct 這類屬性要抓 RAW_VALUE(第10欄)而非 VALUE(第4欄)。
#    VALUE 是正規化後的分數(100=好), RAW_VALUE 才是實際壞軌數量。
# ⚠️ 眉角五: 碟「該休眠卻一直 active/idle」時, 元兇幾乎都是有程序開著碟上的檔案。
#    2026-09-07 實測踩過兩次: (1) Windows 檔案總管開著資料夾 -> smbd 持有 fd
#    並持續輪詢目錄變更 (2) minidlnad 初次索引 20 萬檔, 計數停了但仍在 D state
#    寫 files.db (60 秒寫 20MB)。兩次都得上機 for /proc/*/fd 才追得出來。
#    ★ 故推播直接帶上「誰開著碟上的檔案」, 省掉每次登入追查。
#    ⚠️ busybox 無 lsof, 只能掃 /proc/[0-9]*/fd/ 的 symlink。同程序常有多個 fd
#      指向同一目錄, 用 sort -u 收斂; 已刪除檔案的 symlink 會帶 " (deleted)" 尾綴。

# --show / --dry-run: 只把推播內容印到 console, 不真的推。
# ⚠️ 要在搶鎖「之前」判斷: cron 版每 5 分鐘跑一次, 手動執行常常搶不到全域鎖
#    而靜默 exit 0, 看起來像沒反應(本 repo 在 auto-role 踩過同樣的坑)。
#    ★ 故 --show 模式完全不碰鎖, 隨時可看。
SHOW_ONLY=0
case "$1" in
    --show|--dry-run) SHOW_ONLY=1 ;;
esac

# 全域 cron 排隊鎖 (--show 不搶鎖)
# ⚠️ DISK_ONLY 非空 = 這是父行程叫起來的逐碟子行程, 鎖已經由父行程持有。
#    子行程再搶會失敗而靜默 exit 0(一顆碟都不會報), 而且它的 trap 結束時
#    會把父行程的鎖刪掉。★ 子行程一律不碰鎖。
if [ "$SHOW_ONLY" = "0" ] && [ -z "$DISK_ONLY" ]; then
    . /etc/myscript/lock-handler.sh
    cron_global_lock 60 || exit 0
    trap 'rm -f /tmp/cron_global.lock' EXIT
fi

PUSH_NAMES="${PUSH_NAMES:-admin}"
. /etc/myscript/push-notify.inc

SHARE_BASE="/srv/share"

# =====================================================================
# 多碟支援
#
# ⚠️ 2026-09-08 (.4): 原本寫死 `grep " /srv/share/USB/" | head -1`, 只報第一顆。
#    接上第二顆碟(SSD 掛在 /srv/share/SSD)後完全被忽略 —— 兩個原因: head -1
#    只取一筆, 且 SHARE_BASE 寫死 USB 這層掃不到平行的 SSD 目錄。
#    ★ 改法: 底下整段單碟流程完全不動(它有 6 個提早 exit 0 的路徑, 拆成函式
#      會全部要改), 改成「外層挑出所有碟, 用 DISK_ONLY 環境變數逐顆重跑自己」。
#      單碟邏輯零改動 = 風險最低。
# ⚠️ 同一顆碟可能有多個分割都掛載, 要用整顆碟裝置名去重(sort -u), 否則會對
#    同一顆碟重複讀 SMART(每次都是一次喚醒風險)。
# =====================================================================
if [ -z "$DISK_ONLY" ]; then
    _disks=$(awk -v b="$SHARE_BASE/" '$2 ~ "^"b {print $1}' /proc/mounts 2>/dev/null \
             | sed 's/[0-9]*$//' | sort -u)
    if [ -z "$_disks" ]; then
        [ "$SHOW_ONLY" = "1" ] && echo "(沒有掛載在 ${SHARE_BASE}/ 下的碟, 正常執行時會靜默跳過不推播)"
        exit 0
    fi
    _n=0
    for _d in $_disks; do _n=$((_n + 1)); done
    # 只有一顆就直接往下跑(省一次 fork, 行為與改版前完全相同)
    if [ "$_n" -gt 1 ]; then
        for _d in $_disks; do
            DISK_ONLY="$_d" "$0" "$@"
        done
        exit 0
    fi
fi

# --- 前置檢查: 沒掛載就靜默退出 ---
if [ -n "$DISK_ONLY" ]; then
    # 逐顆模式: 找這顆碟的任一個掛載點
    MOUNT_LINE=$(awk -v d="$DISK_ONLY" '$1 ~ "^"d {print; exit}' /proc/mounts 2>/dev/null)
else
    MOUNT_LINE=$(grep " ${SHARE_BASE}/" /proc/mounts 2>/dev/null | head -1)
fi
if [ -z "$MOUNT_LINE" ]; then
    # --show 時要講清楚為什麼沒東西, 否則使用者看到空輸出會以為腳本壞了
    [ "$SHOW_ONLY" = "1" ] && echo "(沒有掛載在 ${SHARE_BASE}/ 下的碟, 正常執行時會靜默跳過不推播)"
    exit 0
fi

DEV=$(echo "$MOUNT_LINE" | awk '{print $1}')          # /dev/sdb1
MNT=$(echo "$MOUNT_LINE" | awk '{print $2}')          # /srv/share/USB/xxx
# 分割 -> 整顆碟 (smartctl 要對整顆碟下, 不是分割)
DISK=$(echo "$DEV" | sed 's/[0-9]*$//')               # /dev/sdb
if [ ! -b "$DISK" ]; then
    [ "$SHOW_ONLY" = "1" ] && echo "(找不到整顆碟裝置 $DISK, 正常執行時會靜默跳過)"
    exit 0
fi

if ! command -v smartctl >/dev/null 2>&1; then
    [ "$SHOW_ONLY" = "1" ] && echo "(未安裝 smartctl, 正常執行時會靜默跳過)"
    exit 0
fi

# --- 前置: 碟閒置就靜默跳過, 連 smartctl 都不要跑 ---
#
# ⚠️ 眉角八: 這是為了「高頻排程」而存在的。實測踩過: 本腳本掛 */10 而
#   hd-idle 門檻是 20 分鐘 -> 每次 SMART 讀取都重置 hd-idle 計時器,
#   碟永遠等不到 20 分鐘安靜期, 一輩子不休眠。 (真兇是 cron 間隔 < 休眠門檻)
#   ★ smartctl -n standby 本來就該避免喚醒, 但它必須先「碰」裝置才知道
#     狀態, 對這個 USB 外接盒仍可能觸發喚醒(眉角七已證實其電源狀態回報
#     不可信)。唯一零風險的做法是「完全不碰碟」——
#     改讀 /proc/diskstats 的累計 I/O, 純 kernel 計數器, 不產生任何裝置存取。
#   ⚠️ 眉角九: 不能只看「這 10 秒有沒有 I/O」—— 那只證明取樣窗內是靜的,
#     不代表碟真的已經 spin down。SMB 傳檔、minidlna 增量索引都是一陣一陣
#     的存取, 探測窗剛好落在兩批之間的空檔就會誤判成閒置而漏推(碟其實醒著)。
#     ★ 正確判準是「距離上次 I/O 過了多久」, 要比 hd-idle 的門檻久才算真閒置。
#       diskstats 沒有 last-I/O 時間欄位(實測 20 欄都沒有), 只能自己記:
#       用狀態檔存下「上次看到 I/O 變動時的計數器值 + 當時的 uptime」,
#       每輪比對計數器有沒有變, 沒變才累積閒置時間。
#     ⚠️ 狀態檔放 /tmp(tmpfs) —— 絕不能放碟上, 否則每輪寫檔自己就把碟叫醒了。
#     ⚠️ 用 /proc/uptime 而非 date +%s 當時鐘: 免受 NTP 校時跳動影響。
#   ⚠️ 注意 diskstats 要抓「整顆碟」的列(sda)而非分割(sda1), 且欄位是
#     第6欄=讀磁區 第10欄=寫磁區 —— 不是第3/7欄(那是完成次數, 曾誤用過)。
IDLE_PROBE=10
# 需要連續安靜多久才算真閒置。取 hd-idle 門檻(-i 1200)再加緩衝,
# 確保「腳本認定閒置」永遠發生在「碟已 spin down」之後。
IDLE_THRESHOLD=$(uci -q get hd-idle.@hd-idle[0].idle_time_interval 2>/dev/null)
case "$IDLE_THRESHOLD" in
    ''|*[!0-9]*) IDLE_THRESHOLD=1320 ;;                 # 查不到就用 22 分鐘
    *) IDLE_THRESHOLD=$(( IDLE_THRESHOLD * 60 + 120 )) ;;  # 分鐘 -> 秒, +2分緩衝
esac
# ⚠️ 多碟必須各自一份: 共用一個檔會讓兩顆碟互相覆寫 I/O 閒置計時,
#    結果不是誤判「碟在睡」而跳過健檢, 就是反過來吵醒本該休眠的碟。
STATE_FILE="/tmp/.push-hddsmart.iostate$(echo "${DISK_ONLY:-single}" | tr '/' '_')"

_dname=$(echo "$DISK" | sed 's|^/dev/||')
# 存三欄位快照(讀磁區/寫磁區/io_ms), 後面算忙碌率時直接沿用這個起點
_iostat1=$(awk -v d="$_dname" '$3==d {print $6, $10, $13; exit}' /proc/diskstats 2>/dev/null)
_i1=$(echo "$_iostat1" | awk '{print $1+$2}')
sleep "$IDLE_PROBE"
_i2=$(awk -v d="$_dname" '$3==d {print $6+$10; exit}' /proc/diskstats 2>/dev/null)
_now=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)

# 讀上輪狀態: "<計數器值> <當時 uptime>"
_prev_io=""; _prev_t=""
if [ -f "$STATE_FILE" ]; then
    read -r _prev_io _prev_t < "$STATE_FILE" 2>/dev/null
fi

if [ -z "$_i2" ] || [ -z "$_now" ]; then
    :                                    # 讀不到 diskstats, 不做閒置判斷
elif [ "$_i1" != "$_i2" ] || [ "$_i2" != "$_prev_io" ]; then
    # 探測窗內有 I/O, 或與上輪相比計數器有變 -> 碟是活的, 重設閒置起點
    echo "$_i2 $_now" > "$STATE_FILE"
else
    # 計數器與上輪完全相同 -> 從 _prev_t 起一直是靜的
    case "$_prev_t" in
        ''|*[!0-9]*) echo "$_i2 $_now" > "$STATE_FILE" ;;   # 狀態檔壞了, 重來
        *)
            if [ "$(( _now - _prev_t ))" -ge "$IDLE_THRESHOLD" ]; then
                # 靜夠久了, 碟應已 spin down -> 別碰它
                [ "$SHOW_ONLY" = "1" ] && echo "(碟閒置已達門檻, 判定已休眠; 為免吵醒它本輪不讀 SMART)"
                exit 0
            fi
            ;;
    esac
fi

# --- 讀 SMART (-n standby: 碟在休眠就跳過, 不吵醒它) ---
#
# ⚠️ 眉角六: 開機/重新插拔的空窗期會推出一整排空值。2026-09-07 實際收到:
#   「HDD PASSED | °C | 通電:h | 壞軌: 待處理: ...」— 溫度/時數/壞軌全空,
#   只有 df 和開檔清單有值。真兇: 路由器重開後碟從 sdb 變 sda, 舊的 /dev/sdb
#   裝置節點還沒被清掉([ -b ] 過得了), 但 USB 已斷 -> smartctl 回
#   "Smartctl open device: /dev/sdX [SAT] failed: No such device", 沒有任何屬性行。
#   ★ 故要驗「真的讀到屬性了」而非只驗指令有輸出 — 用溫度(194)是否為純數字
#     當哨兵; 讀不到就代表整批屬性都沒讀到, 推出去只會是一排冒號。
#   ★ 這個哨兵同時兼任「試出正確 -d 值」的判準(見眉角三)。
# ⚠️ 眉角七: 判斷休眠不能靠輸出字串, 也不能靠 hdparm -C。兩條死路都實測過:
#   (1) grep "Device is in STANDBY": 同一顆碟在 standby 下 smartctl 有時回
#       "Device is in STANDBY mode, exit(2)", 有時回 exit 4 +
#       "overall-health: UNKNOWN!" 完全沒提 STANDBY -> 會漏判。
#   (2) hdparm -C: 對這個 USB 外接盒(RTL9210)回報不準 —— 實測用
#       iflag=direct 確實讀了 20MB(diskstats 佐證 40960 磁區), hdparm -C
#       仍固執回報 standby。橋接晶片沒正確轉譯 ATA 電源狀態查詢。
#       若拿它當判準, 碟醒著也會被誤判成休眠而永遠不推播。
#   ★ 唯一可靠的是 smartctl 自己: -n standby 命中休眠時 exit code 為 2 或 4
#     且不會有任何屬性行; 讀得到溫度(194)就代表碟是醒的、-d 也對。
#     這個判準同時兼任「試出正確 -d 值」(見眉角三)與「擋開機空窗期空值」。
OUT=""
_sawstandby=0
for _dt in sat sat,12 usbjmicron usbsunplus auto; do
    _try=$(smartctl -A -H -n standby -d "$_dt" "$DISK" 2>/dev/null)
    _rc=$?
    _probe=$(echo "$_try" | awk '$1==194 {print $10; exit}')
    case "$_probe" in
        [0-9]*)
            OUT="$_try"
            break
            ;;
    esac
    # 讀不到屬性 + exit 2/4 = 碟在休眠(不是 -d 選錯), 記下來別再試其他 -d,
    # 每多試一次都是一次喚醒風險
    { [ "$_rc" = "2" ] || [ "$_rc" = "4" ]; } && { _sawstandby=1; break; }
done
if [ "$_sawstandby" = "1" ]; then
    [ "$SHOW_ONLY" = "1" ] && echo "(碟目前在 standby 休眠中, 不喚醒它讀 SMART; 正常執行時會靜默跳過)"
    exit 0
fi
# 全部候選都讀不到 -> 靜默退出(裝置消失、或這個外接盒不支援任何已知轉譯)
if [ -z "$OUT" ]; then
    [ "$SHOW_ONLY" = "1" ] && echo "(所有 -d 候選都讀不到 SMART 屬性: 裝置消失或外接盒不支援)"
    exit 0
fi

# --- 取值: RAW_VALUE 是第 10 欄 ---
smart_raw() {
    echo "$OUT" | awk -v id="$1" '$1==id {print $10; exit}'
}

health=$(echo "$OUT" | sed -n 's/^SMART overall-health self-assessment test result: *//p')
[ -z "$health" ] && health="UNKNOWN"

# 194 溫度: RAW 可能是 "50 (Min/Max 17/59)", 只取第一個數字
temp=$(echo "$OUT" | awk '$1==194 {print $10; exit}')

poh=$(smart_raw 9)      # Power_On_Hours
realloc=$(smart_raw 5)  # Reallocated_Sector_Ct
pending=$(smart_raw 197) # Current_Pending_Sector
uncorr=$(smart_raw 198) # Offline_Uncorrectable
crc=$(smart_raw 199)    # UDMA_CRC_Error_Count
ss=$(smart_raw 4)       # Start_Stop_Count

# ⚠️ SSD 沒有機械碟專屬的屬性(197 待處理/198 無法修復/4 啟停次數), 取不到會
#    印成 "待處理: 無法修復: 啟停:" 這種空欄位, 看起來像壞掉。★ 補成 "-"。
[ -z "$pending" ] && pending="-"
[ -z "$uncorr" ]  && uncorr="-"
[ -z "$ss" ]      && ss="-"
[ -z "$crc" ]     && crc="-"
[ -z "$realloc" ] && realloc="-"

# 通電時數 -> 年 (取一位小數, busybox 無 bc, 用 awk)
poh_y=""
[ -n "$poh" ] && poh_y=$(awk -v h="$poh" 'BEGIN{printf "%.1f", h/24/365}')

# 容量使用率
usage=$(df -h "$MNT" 2>/dev/null | awk 'NR==2{print $5" ("$4" free)"}')

# --- I/O 忙碌率 + 讀寫速率 ---
# /proc/diskstats 第 13 欄(io_ms)是「花在 I/O 上的毫秒數」, 兩次相減 / 取樣毫秒
# = 忙碌率, 等同 iostat 的 %util。第 6/10 欄是累計讀/寫磁區 (512 bytes/磁區)。
# ⚠️ busybox 無 iostat, 只能自己算; 碟休眠時本段不會執行(前面已 exit)。
# ★ 起點沿用眉角八那次閒置探測的第一筆($_iostat1), 不再另外 sleep ——
#   否則腳本要睡 5+10 秒, 白白多佔全域鎖 10 秒。
_iowait="$IDLE_PROBE"
_s1="$_iostat1"
_s2=$(awk -v d="$_dname" '$3==d {print $6, $10, $13; exit}' /proc/diskstats 2>/dev/null)
io_stat=""
if [ -n "$_s1" ] && [ -n "$_s2" ]; then
    io_stat=$(echo "$_s1|$_s2" | awk -v secs="$_iowait" -F'|' '{
        split($1, a, " "); split($2, b, " ")
        util = (b[3] - a[3]) / (secs * 1000) * 100
        if (util > 100) util = 100
        rd = (b[1] - a[1]) * 512 / 1024 / secs
        wr = (b[2] - a[2]) * 512 / 1024 / secs
        printf "%.0f%%", util
        if (rd >= 1024 || wr >= 1024)
            printf "(R%.1f/W%.1f MB/s)", rd/1024, wr/1024
        else if (rd >= 1 || wr >= 1)
            printf "(R%.0f/W%.0f KB/s)", rd, wr
    }')
fi

# 人類可讀的大小。TB 保留 2 位小數(3.14TB), 其餘 1 位(20.5MB)。
# ⚠️ TB 級距太粗: 1 位小數時 3.1TB 涵蓋 110GB 的範圍, 看不出碟到底長多少,
#    所以 TB 特別給 2 位。
# ⚠️ busybox ash 只有整數運算, 沒有 bc, printf 也沒有 %f —— 自己乘 10/100
#    取餘數湊小數。餘數要補前導零, 否則 3.04TB 會印成 3.4TB。
fmt_size() {
    _n="$1"
    if   [ "$_n" -ge 1099511627776 ]; then _d=1099511627776; _u=TB; _s=100
    elif [ "$_n" -ge 1073741824 ];    then _d=1073741824;    _u=GB; _s=10
    elif [ "$_n" -ge 1048576 ];       then _d=1048576;       _u=MB; _s=10
    elif [ "$_n" -ge 1024 ];          then _d=1024;          _u=KB; _s=10
    else echo "${_n}B"; return; fi
    _int=$(( _n / _d ))
    _frac=$(( _n * _s / _d % _s ))
    [ "$_s" = "100" ] && [ "$_frac" -lt 10 ] && _frac="0$_frac"
    echo "${_int}.${_frac}$_u"
}

# --- 誰開著碟上的檔案 (碟不休眠時的元兇, 見眉角五) ---
holders=""
for _p in /proc/[0-9]*; do
    _pid=${_p#/proc/}
    case "$_pid" in *[!0-9]*) continue ;; esac
    _hit=$(ls -l "$_p/fd/" 2>/dev/null | grep -c "$MNT")
    [ "${_hit:-0}" -gt 0 ] 2>/dev/null || continue
    _cmd=$(cat "$_p/comm" 2>/dev/null)
    # 去掉掛載點前綴讓訊息短一點; 同程序多個 fd 指同目錄時去重, 最多列 3 個
    _flist=$(ls -l "$_p/fd/" 2>/dev/null | sed -n "s|.*-> ${MNT}/*||p" \
             | sed 's/ (deleted)$//' | grep -v '^$' | sort -u | head -3)
    if [ -z "$_flist" ]; then
        _files="${_hit}個fd"
    else
        # ⚠️ 附上檔案大小: 看到「誰開著碟」還不夠, 知道多大才判斷得出是
        #    大檔傳輸(正常會佔久)還是小檔輪詢(異常)。2026-09-08 加。
        # ⚠️⚠️ 取大小絕對不能用 `wc -c`! 它會把整個檔案讀完才算出位元組數,
        #    對 12GB 的 .part 等於從碟上讀 12GB。實測兩個 wc -c 各吃 47% CPU,
        #    把整台 RAX3000M 拖到 0% idle / load 2.2, 且 cron 前一輪沒跑完
        #    下一輪又進來疊上去(2026-09-09 實測, 就是本腳本自己造成的)。
        #    ★ 改用 `ls -l` 取第 5 欄: 只讀 inode metadata, 實測 0ms。
        #    ⚠️ memory 記的「busybox 沒 stat 就用 wc -c」只適用小檔, 大檔會炸。
        #    目錄沒有意義的大小, 跳過不標。
        _files=""
        _oldifs="$IFS"; IFS='
'
        for _f in $_flist; do
            _full="$MNT/$_f"
            if [ -f "$_full" ]; then
                _sz=$(ls -l "$_full" 2>/dev/null | awk '{print $5}')
                case "$_sz" in
                    ''|*[!0-9]*) _tag="" ;;
                    *) _tag=" $(fmt_size "$_sz")" ;;
                esac
            else
                _tag=""          # 目錄或已消失的檔
            fi
            _files="${_files:+$_files,}${_f}${_tag}"
        done
        IFS="$_oldifs"
    fi
    holders="${holders} ${_cmd}[${_files}]"
done

# --- 組警示標記 ---
# 溫度 >=50 提醒, >=55 警告 (MG05ACA800E 規格上限 55)
tflag=""
if [ -n "$temp" ]; then
    [ "$temp" -ge 50 ] 2>/dev/null && tflag="⚠️"
    [ "$temp" -ge 55 ] 2>/dev/null && tflag="🔥"
fi
# 有待處理/無法修復扇區 = 真的要注意
warn=""
[ "${pending:-0}" -gt 0 ] 2>/dev/null && warn="${warn} ⚠️Pending:${pending}"
[ "${uncorr:-0}" -gt 0 ] 2>/dev/null && warn="${warn} ⚠️Uncorr:${uncorr}"
[ "${crc:-0}" -gt 0 ] 2>/dev/null && warn="${warn} ⚠️CRC:${crc}"
[ "$health" != "PASSED" ] && warn="${warn} ❗健康:${health}"

# --- 推播 ---
# ⚠️ 多碟時每顆各推一則, 開頭要標明是哪顆碟否則分不出來。
#    用掛載點最後一段當名字(8TB→"8TB", SSD→"SSD"), 比 /dev/sdX 好認
#    且不隨列舉順序變動。單碟時維持原本的 "HDD" 開頭不變。
if [ -n "$DISK_ONLY" ]; then
    msg="HDD[${MNT##*/}] ${health} | ${tflag}${temp}°C"
else
    msg="HDD ${health} | ${tflag}${temp}°C"
fi
msg="${msg} | 通電:${poh}h"
[ -n "$poh_y" ] && msg="${msg}(${poh_y}年)"
msg="${msg} | 壞軌:${realloc} 待處理:${pending} 無法修復:${uncorr}"
msg="${msg} | CRC:${crc} 啟停:${ss}"
[ -n "$usage" ] && msg="${msg} | 用量:${usage}"
[ -n "$io_stat" ] && msg="${msg} | 忙碌:${io_stat}"
if [ -n "$holders" ]; then
    msg="${msg} | 開檔:${holders}"
else
    msg="${msg} | 開檔:無"
fi
[ -n "$warn" ] && msg="${msg} |${warn}"

if [ "$SHOW_ONLY" = "1" ]; then
    echo "$msg"
else
    push_notify "$msg"
fi
