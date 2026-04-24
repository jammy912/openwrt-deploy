#!/bin/sh
# kick-wifi-client.sh - 依 hostname 踢 wifi client 重連
# 用法:
#   kick-wifi-client.sh <hostname_pattern> [ssid_filter]
# 範例:
#   kick-wifi-client.sh HomePod             # 踢所有 name 含 HomePod 的,所有 AP
#   kick-wifi-client.sh HomePod Portkey     # 只踢 Portkey AP 上的 HomePod
#   kick-wifi-client.sh HomePodR Portkey    # 只踢 HomePodR (Portkey AP)
#
# 原理: 從 /etc/config/dhcp static host 依 name 查 MAC,
#      用 ubus hostapd del_client 對該 MAC 發 deauth。
#      client 幾秒內自動回連,藉此刷新 wifi state / mDNS 廣播。

PATTERN="$1"
SSID_FILTER="$2"
[ -z "$PATTERN" ] && { echo "用法: $0 <hostname_pattern> [ssid_filter]"; exit 1; }

# 從 uci dhcp 抓符合 pattern 的 MAC (name → mac)
MACS=$(uci show dhcp 2>/dev/null | awk -v pat="$PATTERN" '
    function strip(s) { sub(/^.*=./, "", s); sub(/.$/, "", s); return s }
    /\.name=/ { name = strip($0); next }
    /\.mac=/  { mac = tolower(strip($0)); if (name ~ pat) print mac, name; name = "" }
')

if [ -z "$MACS" ]; then
    echo "沒有符合 '$PATTERN' 的 DHCP static host"
    exit 1
fi

# 列出 hostapd AP interface,若指定 SSID 則過濾
IFACES=""
for obj in $(ubus list 2>/dev/null | grep '^hostapd\.phy'); do
    iface="${obj#hostapd.}"
    if [ -n "$SSID_FILTER" ]; then
        this_ssid=$(ubus call "$obj" get_status 2>/dev/null | awk -F'"' '/"ssid"/{print $4; exit}')
        [ "$this_ssid" = "$SSID_FILTER" ] || continue
    fi
    IFACES="$IFACES $iface"
done

if [ -z "$IFACES" ]; then
    echo "找不到符合的 hostapd interface${SSID_FILTER:+ (SSID=$SSID_FILTER)}"
    exit 1
fi

echo "目標 AP:$IFACES"

echo "$MACS" | while read mac name; do
    [ -z "$mac" ] && continue
    echo "踢 $name ($mac)"
    for iface in $IFACES; do
        ubus call "hostapd.$iface" del_client \
            "{\"addr\":\"$mac\",\"deauth\":true,\"reason\":5}" 2>/dev/null
    done
done

logger -t kick-wifi "pattern=$PATTERN ssid=${SSID_FILTER:-ANY} macs=$(echo "$MACS" | wc -l)"
