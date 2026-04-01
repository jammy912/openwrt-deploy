#!/bin/sh
# Wi-Fi 啟用/停用 by RADIO + SSID (for OpenWrt)
# 用法:
#   wifi_set.sh <radio> <ssid> <1=啟用|0=停用>

LOG_FILE="/tmp/wifi-set.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

if [ $# -ne 3 ]; then
    echo "用法: $0 <radio> <ssid> <1=啟用|0=停用>"
    exit 1
fi

RADIO="$1"
SSID="$2"
ENABLE="$3"

# ENABLE=1 → disabled=0, ENABLE=0 → disabled=1
if [ "$ENABLE" -eq 1 ]; then
    DISABLED=0
else
    DISABLED=1
fi

# 找出對應的 iface 名稱 (同時匹配 radio 和 ssid 的 wifi-iface section)
IFACE=$(uci show wireless | awk -F'[.=]' -v r="$RADIO" -v s="$SSID" '
    /\.device=/ { gsub(/'"'"'/, "", $4); device[$2]=$4 }
    /\.ssid=/   { gsub(/'"'"'/, "", $4); ssid[$2]=$4 }
    END {
        for (sec in device) {
            if (device[sec]==r && ssid[sec]==s) { print sec; exit }
        }
    }
')


if [ -z "$IFACE" ]; then
    echo "找不到符合的介面 (radio=$RADIO, ssid=$SSID)"
    exit 1
fi

CURRENT=$(uci get wireless.${IFACE}.disabled 2>/dev/null || echo 0)
if [ "$CURRENT" -eq "$DISABLED" ]; then
    echo "[$RADIO/$SSID] 狀態未變更 (disabled=$DISABLED)"
    log "[$RADIO/$SSID] 狀態未變更 (disabled=$DISABLED)"
    exit 0
fi

echo "設定 $RADIO / $SSID ($IFACE) → disabled=$DISABLED"
log "設定 $RADIO / $SSID ($IFACE) → disabled=$DISABLED"

uci set wireless.${IFACE}.disabled="${DISABLED}"
uci commit wireless
wifi reload

if [ "$ENABLE" -eq 1 ]; then
    echo "[$RADIO/$SSID] Wi-Fi 已啟用"
    log "[$RADIO/$SSID] Wi-Fi 已啟用"
else
    echo "[$RADIO/$SSID] Wi-Fi 已停用"
    log "[$RADIO/$SSID] Wi-Fi 已停用"
fi
