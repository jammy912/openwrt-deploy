#!/bin/sh
# 推播外接硬碟 SMART 健康狀態: 溫度 / 壞軌 / 通電時數 / 傳輸錯誤
#
# ⚠️ 眉角一: 只在「碟有掛載成 share」時才推播。沒插碟或沒掛載時直接靜默退出,
#    否則每次 cron 都會推一則「查不到硬碟」的垃圾訊息。
# ⚠️ 眉角二: smartctl 讀取會喚醒休眠中的硬碟。本機碟由韌體 APM=128 管休眠,
#    每次讀 SMART 都吵醒它會讓 Start_Stop_Count 一直累加(機械磨損)。
#    ★ 故一律加 -n standby: 碟在睡就跳過本輪, 不打擾。
# ⚠️ 眉角三: 這顆 USB 外接盒(Ugreen RTL9210)必須用 -d sat 指定 SCSI-ATA 轉譯,
#    不加的話 smartctl 認不出是 ATA 裝置, 所有屬性都讀不到。
# ⚠️ 眉角四: Reallocated_Sector_Ct 這類屬性要抓 RAW_VALUE(第10欄)而非 VALUE(第4欄)。
#    VALUE 是正規化後的分數(100=好), RAW_VALUE 才是實際壞軌數量。
# ⚠️ 眉角五: 碟「該休眠卻一直 active/idle」時, 元兇幾乎都是有程序開著碟上的檔案。
#    2026-09-07 實測踩過兩次: (1) Windows 檔案總管開著資料夾 -> smbd 持有 fd
#    並持續輪詢目錄變更 (2) minidlnad 初次索引 20 萬檔, 計數停了但仍在 D state
#    寫 files.db (60 秒寫 20MB)。兩次都得上機 for /proc/*/fd 才追得出來。
#    ★ 故推播直接帶上「誰開著碟上的檔案」, 省掉每次登入追查。
#    ⚠️ busybox 無 lsof, 只能掃 /proc/[0-9]*/fd/ 的 symlink。同程序常有多個 fd
#      指向同一目錄, 用 sort -u 收斂; 已刪除檔案的 symlink 會帶 " (deleted)" 尾綴。

# 全域 cron 排隊鎖
. /etc/myscript/lock-handler.sh
cron_global_lock 60 || exit 0
trap 'rm -f /tmp/cron_global.lock' EXIT

PUSH_NAMES="${PUSH_NAMES:-admin}"
. /etc/myscript/push-notify.inc

SHARE_BASE="/srv/share/USB"

# --- 前置檢查: 沒掛載就靜默退出 ---
MOUNT_LINE=$(grep " ${SHARE_BASE}/" /proc/mounts 2>/dev/null | head -1)
[ -z "$MOUNT_LINE" ] && exit 0

DEV=$(echo "$MOUNT_LINE" | awk '{print $1}')          # /dev/sdb1
MNT=$(echo "$MOUNT_LINE" | awk '{print $2}')          # /srv/share/USB/xxx
# 分割 -> 整顆碟 (smartctl 要對整顆碟下, 不是分割)
DISK=$(echo "$DEV" | sed 's/[0-9]*$//')               # /dev/sdb
[ -b "$DISK" ] || exit 0

command -v smartctl >/dev/null 2>&1 || exit 0

# --- 讀 SMART (-n standby: 碟在休眠就跳過, 不吵醒它) ---
OUT=$(smartctl -A -H -n standby -d sat "$DISK" 2>/dev/null)

# 碟在休眠 -> 靜默退出 (exit code 2 且輸出含 STANDBY)
echo "$OUT" | grep -qi "Device is in STANDBY" && exit 0
[ -z "$OUT" ] && exit 0

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

# 通電時數 -> 年 (取一位小數, busybox 無 bc, 用 awk)
poh_y=""
[ -n "$poh" ] && poh_y=$(awk -v h="$poh" 'BEGIN{printf "%.1f", h/24/365}')

# 容量使用率
usage=$(df -h "$MNT" 2>/dev/null | awk 'NR==2{print $5" ("$4" free)"}')

# --- I/O 忙碌率 + 讀寫速率 (取樣 10 秒) ---
# /proc/diskstats 第 13 欄(io_ms)是「花在 I/O 上的毫秒數」, 兩次相減 / 取樣毫秒
# = 忙碌率, 等同 iostat 的 %util。第 6/10 欄是累計讀/寫磁區 (512 bytes/磁區)。
# ⚠️ busybox 無 iostat, 只能自己算; 碟休眠時本段不會執行(前面已 exit)。
_dname=$(echo "$DISK" | sed 's|^/dev/||')
_s1=$(awk -v d="$_dname" '$3==d {print $6, $10, $13; exit}' /proc/diskstats 2>/dev/null)
_iowait=10
sleep "$_iowait"
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

# --- 誰開著碟上的檔案 (碟不休眠時的元兇, 見眉角五) ---
holders=""
for _p in /proc/[0-9]*; do
    _pid=${_p#/proc/}
    case "$_pid" in *[!0-9]*) continue ;; esac
    _hit=$(ls -l "$_p/fd/" 2>/dev/null | grep -c "$MNT")
    [ "${_hit:-0}" -gt 0 ] 2>/dev/null || continue
    _cmd=$(cat "$_p/comm" 2>/dev/null)
    # 去掉掛載點前綴讓訊息短一點; 同程序多個 fd 指同目錄時去重, 最多列 3 個
    _files=$(ls -l "$_p/fd/" 2>/dev/null | sed -n "s|.*-> ${MNT}/*||p" \
             | sed 's/ (deleted)$//' | grep -v '^$' | sort -u | head -3 \
             | tr '\n' ',' | sed 's/,$//')
    [ -z "$_files" ] && _files="${_hit}個fd"
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
msg="HDD ${health} | ${tflag}${temp}°C"
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

push_notify "$msg"
