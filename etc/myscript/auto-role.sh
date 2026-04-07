#!/bin/sh
# auto-role.sh - 自動偵測 WAN/DHCP 狀態，切換 gateway/client 角色
# 觸發時機: rc.local 開機、hotplug WAN 變化、cron 定時
#
# 邏輯:
#   1. 有 WAN + 沒其他 DHCP → gateway (IP=.1, 開 DHCP server, gw_mode=server)
#   2. 有 WAN + 有其他 DHCP → gateway (保持 IP, DHCP relay→.1, gw_mode=server)
#   3. 沒 WAN → client (保持 IP, DHCP relay→.1, gw_mode=client)
#
# mesh 設定由 Google Sheet 同步到:
#   .mesh_priority  - 優先權 (數字大=優先當主 gateway)
#   .mesh_wireless  - 無線 mesh (Y/N)
#   .mesh_wired     - 有線 mesh (Y/N)

. /etc/myscript/push_notify.inc 2>/dev/null
PUSH_NAMES="jammy"

LOG_TAG="auto-role"
log() { logger -t "$LOG_TAG" "$1"; echo "[$LOG_TAG] $1"; }

ROLE_FILE="/etc/myscript/.mesh_role"
ACTIVE_FILE="/etc/myscript/.mesh_role_active"
CURRENT_ROLE=$(cat "$ACTIVE_FILE" 2>/dev/null)

# =====================
# 0. 等待網路就緒 (WAN 有 IP 或 mesh 有鄰居)
# =====================
i=0
while [ $i -lt 120 ]; do
    # WAN 已拿到 IP → 單機 gateway
    ifstatus wan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null | grep -q '.' && break
    # mesh 有鄰居 → 多機模式
    batctl n 2>/dev/null | grep -q ':' && break
    [ $i -eq 0 ] && log "等待網路就緒..."
    sleep 5
    i=$((i + 5))
done
[ $i -ge 120 ] && log "⚠️ 等待超時 (120s)，繼續偵測"

# =====================
# 1. 檢查 WAN 狀態
# =====================
WAN_IF=$(uci get network.wan.device 2>/dev/null || echo "wan")
WAN_IP=$(uci get network.wan.ipaddr 2>/dev/null)
# 動態取得 WAN IP（DHCP 模式）
[ -z "$WAN_IP" ] && WAN_IP=$(ifstatus wan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)

HAS_WAN=0
if [ -n "$WAN_IP" ] && [ "$WAN_IP" != "0.0.0.0" ]; then
    # 確認能上網
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        HAS_WAN=1
    fi
fi

# =====================
# 2. 決定角色
# =====================
if [ "$HAS_WAN" = "1" ]; then
    NEW_ROLE="gateway"
else
    NEW_ROLE="client"
fi

# =====================
# 3. 判斷主 gateway (priority + MAC)
# =====================
# 邏輯: priority 大的優先，相同時 MAC 小的優先
MY_PRI=$(cat /etc/myscript/.mesh_priority 2>/dev/null)
[ -z "$MY_PRI" ] && MY_PRI=50
MY_MAC=$(cat /sys/class/net/bat0/address 2>/dev/null)

# 設定自己的 gw_bandwidth = priority (讓 batctl gwl 看到)
[ "$NEW_ROLE" = "gateway" ] && batctl gw server ${MY_PRI}MBit 2>/dev/null

# 檢查 mesh 裡有沒有比自己優先的 gateway
IS_PRIMARY=1
if [ "$NEW_ROLE" = "gateway" ]; then
    # 從 batctl gwl 讀其他 gateway 的 bandwidth(=priority) 和 MAC
    # gwl 格式: [B.A.T.M.A.N...] 或 "  MAC (bandwidth) ..."
    HIGHER=$(batctl gwl 2>/dev/null | awk -v me_pri="$MY_PRI" -v me_mac="$MY_MAC" '
        /MBit/ {
            mac = $1; gsub(/[^0-9a-f:]/, "", mac)
            # 取得 bandwidth 數字
            for (i=1; i<=NF; i++) {
                if ($i ~ /MBit/) { pri = $i; gsub(/[^0-9]/, "", pri); break }
            }
            if (mac == me_mac) next
            if (pri+0 > me_pri+0) { found=1; exit }
            if (pri+0 == me_pri+0 && mac < me_mac) { found=1; exit }
        }
        END { if (found) print "yes" }
    ')
    if [ "$HIGHER" = "yes" ]; then
        IS_PRIMARY=0
        log "mesh 有更高優先的 gateway (my_pri=$MY_PRI, my_mac=$MY_MAC)"
    fi
fi

DHCP_ACTION=""  # server, relay, 或空
LAN_MODE=""     # static 或 keep
if [ "$NEW_ROLE" = "gateway" ] && [ "$IS_PRIMARY" = "1" ]; then
    # 主 gateway: 固定 .1 開 DHCP server
    DHCP_ACTION="server"
    LAN_MODE="static"
    log "主 gateway (priority=$MY_PRI)"
elif [ "$NEW_ROLE" = "gateway" ]; then
    # 非主 gateway: relay 轉發
    DHCP_ACTION="relay"
    LAN_MODE="keep"
else
    # client: relay 轉發
    DHCP_ACTION="relay"
    LAN_MODE="keep"
fi

# =====================
# 4. 套用變更
# =====================
CHANGED=0

# batman gw_mode
if [ "$NEW_ROLE" = "gateway" ]; then
    WANT_GW="server"
else
    WANT_GW="client"
fi
CUR_GW=$(uci get network.bat0.gw_mode 2>/dev/null)
if [ "$CUR_GW" != "$WANT_GW" ]; then
    uci set network.bat0.gw_mode="$WANT_GW"
    log "bat0 gw_mode: $CUR_GW -> $WANT_GW"
    CHANGED=1
fi

# LAN IP 模式
CUR_LAN_PROTO=$(uci get network.lan.proto 2>/dev/null)
CUR_LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null)
NEED_RESTART_NET=0
if [ "$LAN_MODE" = "static" ]; then
    if [ "$CUR_LAN_PROTO" != "static" ] || [ "$CUR_LAN_IP" != "192.168.1.1" ]; then
        uci set network.lan.proto='static'
        uci set network.lan.ipaddr='192.168.1.1'
        uci set network.lan.netmask='255.255.255.0'
        log "LAN 改為 static 192.168.1.1"
        NEED_RESTART_NET=1
        CHANGED=1
    fi
fi
# LAN_MODE=keep 時不動 IP
uci commit network

# DHCP server / relay
CUR_DHCP_IGNORE=$(uci get dhcp.lan.ignore 2>/dev/null)
HAS_RELAY=$(uci show dhcp 2>/dev/null | grep -c "=relay")

setup_relay() {
    # 取得 DHCP server 的 IP (從 udhcpc 結果取得，或預設 .1)
    RELAY_SERVER="192.168.1.1"
    MY_IP=$(uci get network.lan.ipaddr 2>/dev/null)
    [ -z "$MY_IP" ] && MY_IP=$(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1)
    # 清除舊 relay 設定
    while uci show dhcp 2>/dev/null | grep -q "=relay"; do
        uci delete dhcp.@relay[0] 2>/dev/null || break
    done
    # 建立 relay
    uci add dhcp relay >/dev/null
    uci set dhcp.@relay[-1].local_addr="$MY_IP"
    uci set dhcp.@relay[-1].server_addr="$RELAY_SERVER"
    uci set dhcp.@relay[-1].interface='lan'
    # 關閉 DHCP server
    uci set dhcp.lan.ignore='1'
    uci set dhcp.lan.dhcpv4='disabled'
    uci commit dhcp
    /etc/init.d/dnsmasq restart
    log "DHCP relay 已設定 ($MY_IP → $RELAY_SERVER)"
}

remove_relay() {
    while uci show dhcp 2>/dev/null | grep -q "=relay"; do
        uci delete dhcp.@relay[0] 2>/dev/null || break
    done
}

if [ "$DHCP_ACTION" = "server" ]; then
    if [ "$CUR_DHCP_IGNORE" = "1" ] || [ "$HAS_RELAY" -gt 0 ]; then
        remove_relay
        uci delete dhcp.lan.ignore 2>/dev/null
        uci set dhcp.lan.dhcpv4='server'
        uci commit dhcp
        /etc/init.d/dnsmasq restart
        log "DHCP server 已開啟"
        CHANGED=1
    fi
elif [ "$DHCP_ACTION" = "relay" ]; then
    if [ "$HAS_RELAY" -eq 0 ] || [ "$CUR_DHCP_IGNORE" != "1" ]; then
        setup_relay
        CHANGED=1
    fi
fi

# =====================
# 5. 服務啟停
# =====================
svc_enable()  { /etc/init.d/$1 enable 2>/dev/null; /etc/init.d/$1 start 2>/dev/null; }
svc_disable() { /etc/init.d/$1 stop 2>/dev/null; /etc/init.d/$1 disable 2>/dev/null; }

if [ "$NEW_ROLE" = "gateway" ] && [ "$LAN_MODE" = "static" ]; then
    # 唯一 gateway (.1): 全開
    svc_enable wireguard 2>/dev/null  # WG 由 network 管理，這裡確保 interface up
    svc_enable ddns
    svc_enable adguardhome
    svc_enable pbr
    svc_enable qosify
    log "服務: 全開 (唯一 gateway)"
elif [ "$NEW_ROLE" = "gateway" ]; then
    # 非唯一 gateway: 停 WireGuard、DDNS
    svc_disable ddns
    log "服務: 停 DDNS (非唯一 gateway)"
    # 停 WireGuard interfaces
    for wg_if in $(uci show network | grep "=interface" | cut -d. -f2 | cut -d= -f1 | grep '^wg'); do
        ifdown "$wg_if" 2>/dev/null
    done
    log "服務: 停 WireGuard (非唯一 gateway)"
else
    # client: 停所有 gateway 專屬服務
    svc_disable ddns
    svc_disable adguardhome
    svc_disable pbr
    svc_disable qosify
    for wg_if in $(uci show network | grep "=interface" | cut -d. -f2 | cut -d= -f1 | grep '^wg'); do
        ifdown "$wg_if" 2>/dev/null
    done
    log "服務: 停 WireGuard/DDNS/AdGuard/PBR/qosify (client)"
fi

# =====================
# 6. VPN 子網路由 (非唯一 gateway/client → 路由到 .1)
# =====================
if [ "$LAN_MODE" != "static" ]; then
    # 從自己的 WG 設定取得所有 VPN 子網，路由到 .1
    for addr in $(uci show network | grep 'wg.*\.addresses=' | cut -d"'" -f2); do
        subnet=$(echo "$addr" | cut -d/ -f1 | sed 's/\.[0-9]*$/.0/')
        ip route add "$subnet/24" via 192.168.1.1 2>/dev/null && \
            log "VPN 路由: $subnet/24 via 192.168.1.1"
    done
fi

# =====================
# 7. Mesh 介面啟停 (由 .mesh_wireless / .mesh_wired 控制)
# =====================
WANT_WIRELESS=$(cat /etc/myscript/.mesh_wireless 2>/dev/null)
WANT_WIRED=$(cat /etc/myscript/.mesh_wired 2>/dev/null)
NEED_WIFI_RELOAD=0

# 無線 mesh
if [ -n "$WANT_WIRELESS" ]; then
    CUR_MESH_DISABLED=$(uci get wireless.mesh0.disabled 2>/dev/null)
    if [ "$WANT_WIRELESS" = "N" ] && [ "$CUR_MESH_DISABLED" != "1" ]; then
        uci set wireless.mesh0.disabled='1'
        uci commit wireless
        NEED_WIFI_RELOAD=1
        log "無線 mesh 已停用 (設定=N)"
        CHANGED=1
    elif [ "$WANT_WIRELESS" = "Y" ] && [ "$CUR_MESH_DISABLED" = "1" ]; then
        uci delete wireless.mesh0.disabled
        uci commit wireless
        NEED_WIFI_RELOAD=1
        log "無線 mesh 已啟用 (設定=Y)"
        CHANGED=1
    fi
fi

# 有線 mesh
WIRE_DEV=$(uci get network.batmesh_wire.device 2>/dev/null)
if [ -n "$WANT_WIRED" ] && [ -n "$WIRE_DEV" ]; then
    CUR_WIRE_DISABLED=$(uci get network.batmesh_wire.disabled 2>/dev/null)
    if [ "$WANT_WIRED" = "N" ] && [ "$CUR_WIRE_DISABLED" != "1" ]; then
        uci set network.batmesh_wire.disabled='1'
        uci commit network
        NEED_RESTART_NET=1
        log "有線 mesh ($WIRE_DEV) 已停用 (設定=N)"
        CHANGED=1
    elif [ "$WANT_WIRED" = "Y" ] && [ "$CUR_WIRE_DISABLED" = "1" ]; then
        uci delete network.batmesh_wire.disabled
        uci commit network
        NEED_RESTART_NET=1
        log "有線 mesh ($WIRE_DEV) 已啟用 (設定=Y)"
        CHANGED=1
    fi
fi

[ "$NEED_WIFI_RELOAD" = "1" ] && wifi reload

# 更新當前身份
if [ "$CURRENT_ROLE" != "$NEW_ROLE" ]; then
    echo -n "$NEW_ROLE" > "$ACTIVE_FILE"
    log "角色切換: $CURRENT_ROLE -> $NEW_ROLE"
    push_notify "AutoRole: $CURRENT_ROLE -> $NEW_ROLE"
    CHANGED=1
fi

if [ "$NEED_RESTART_NET" = "1" ]; then
    log "重啟網路..."
    /etc/init.d/network restart
fi

# 確保 gw_mode + bandwidth(=priority) 在 network restart 後生效
if [ "$NEW_ROLE" = "gateway" ]; then
    batctl gw server ${MY_PRI}MBit 2>/dev/null
fi

if [ "$CHANGED" = "0" ]; then
    log "角色: $NEW_ROLE, DHCP: $DHCP_ACTION, LAN: $LAN_MODE (無變更)"
fi
