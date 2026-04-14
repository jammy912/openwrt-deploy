#!/bin/sh
# check-wg-peers.sh - WireGuard peer 連入/斷線通知
# 用法: check-wg-peers.sh <interface> [timeout_seconds]
#   $1  WG_IFACE    WireGuard 介面名稱，如 wg1
#   $2  TIMEOUT     判斷斷線的秒數，預設 180 (3分鐘)
#
# 範例:
#   check-wg-peers.sh wg1          # 檢查 wg1，3 分鐘無 handshake 視為斷線
#   check-wg-peers.sh wg1 300      # 5 分鐘無 handshake 視為斷線
#
# 建議 cron: */1 * * * * /etc/myscript/check-wg-peers.sh wg1

. /etc/myscript/push_notify.inc
PUSH_NAMES="${PUSH_NAMES:-admin}"
HOSTNAME=$(uci get system.@system[0].hostname 2>/dev/null)
[ -z "$HOSTNAME" ] && HOSTNAME=$(cat /proc/sys/kernel/hostname 2>/dev/null)

WG_IFACE="${1:-wg1}"
TIMEOUT="${2:-180}"
STATE_DIR="/tmp"
STATE_FILE="$STATE_DIR/wg_peers_${WG_IFACE}.state"

# 從 uci 讀取 peer public_key → description 對照表
# 格式: pubkey|description
get_peer_name() {
    local pubkey="$1"
    local idx=0
    while true; do
        local pk=$(uci get "network.@wireguard_${WG_IFACE}[$idx].public_key" 2>/dev/null)
        [ -z "$pk" ] && break
        if [ "$pk" = "$pubkey" ]; then
            local desc=$(uci get "network.@wireguard_${WG_IFACE}[$idx].description" 2>/dev/null)
            echo "${desc:-$pubkey}"
            return
        fi
        idx=$((idx + 1))
    done
    # 找不到就顯示 pubkey 前 8 碼
    echo "${pubkey:0:8}..."
}

NOW=$(date +%s)

# 讀取上次狀態 (格式: pubkey|online/offline)
[ -f "$STATE_FILE" ] || touch "$STATE_FILE"

NEW_STATE_FILE="${STATE_FILE}.tmp"
: > "$NEW_STATE_FILE"

# 取得目前所有 peer 的 handshake
wg show "$WG_IFACE" latest-handshakes 2>/dev/null | while read pubkey hs_time; do
    [ -z "$pubkey" ] && continue

    peer_name=$(get_peer_name "$pubkey")
    prev_state=$(grep "^${pubkey}|" "$STATE_FILE" 2>/dev/null | cut -d'|' -f2)

    if [ "$hs_time" -gt 0 ] 2>/dev/null; then
        age=$((NOW - hs_time))
        if [ "$age" -le "$TIMEOUT" ]; then
            # 有效 handshake → 在線
            if [ "$prev_state" != "online" ]; then
                logger -t "check-wg" "[$HOSTNAME] $WG_IFACE: $peer_name 已連入"
                push_notify "$WG_IFACE: $peer_name 已連入"
            fi
            echo "${pubkey}|online" >> "$NEW_STATE_FILE"
        else
            # handshake 過期 → 離線
            if [ "$prev_state" = "online" ]; then
                logger -t "check-wg" "[$HOSTNAME] $WG_IFACE: $peer_name 已斷線 (${age}s)"
                push_notify "$WG_IFACE: $peer_name 已斷線"
            fi
            echo "${pubkey}|offline" >> "$NEW_STATE_FILE"
        fi
    else
        # 從未握手
        if [ "$prev_state" = "online" ]; then
            logger -t "check-wg" "[$HOSTNAME] $WG_IFACE: $peer_name 已斷線"
            push_notify "$WG_IFACE: $peer_name 已斷線"
        fi
        echo "${pubkey}|offline" >> "$NEW_STATE_FILE"
    fi
done

mv "$NEW_STATE_FILE" "$STATE_FILE"
