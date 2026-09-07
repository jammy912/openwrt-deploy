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
tmin_max=$(echo "$OUT" | sed -n 's/.*Min\/Max \([0-9]*\/[0-9]*\).*/\1/p' | head -1)

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
[ -n "$tmin_max" ] && msg="${msg}(${tmin_max})"
msg="${msg} | 通電:${poh}h"
[ -n "$poh_y" ] && msg="${msg}(${poh_y}年)"
msg="${msg} | 壞軌:${realloc} 待處理:${pending} 無法修復:${uncorr}"
msg="${msg} | CRC:${crc} 啟停:${ss}"
[ -n "$usage" ] && msg="${msg} | 用量:${usage}"
[ -n "$warn" ] && msg="${msg} |${warn}"

push_notify "$msg"
