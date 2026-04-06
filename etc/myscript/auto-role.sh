#!/bin/sh
# auto-role.sh - 自動偵測 WAN/DHCP 狀態，切換 gateway/client 角色
# 觸發時機: rc.local 開機、hotplug WAN 變化、cron 定時
#
# 邏輯:
#   1. 有 WAN + 沒其他 DHCP → gateway (IP=.1, 開 DHCP server, gw_mode=server)
#   2. 有 WAN + 有其他 DHCP → gateway (保持 IP, DHCP relay→.1, gw_mode=server)
#   3. 沒 WAN → client (保持 IP, DHCP relay→.1, gw_mode=client)

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
# 3. 檢查 DHCP
# =====================
# 用 udhcpc 測試 LAN 上有沒有其他 DHCP server
check_other_dhcp() {
    LAN_IF=$(uci get network.lan.device 2>/dev/null)
    [ -z "$LAN_IF" ] && LAN_IF="br-lan"
    # 嘗試取得 DHCP，timeout 5 秒
    DHCP_RESULT=$(udhcpc -i "$LAN_IF" -n -q -t 3 -T 2 -s /bin/true 2>&1)
    if echo "$DHCP_RESULT" | grep -q "obtained"; then
        return 0  # 有其他 DHCP server
    fi
    return 1  # 沒有
}

DHCP_ACTION=""  # server, relay, 或空
LAN_MODE=""     # static 或 keep
if [ "$NEW_ROLE" = "gateway" ]; then
    if check_other_dhcp; then
        # 有其他 DHCP server，用 relay 轉發
        DHCP_ACTION="relay"
        LAN_MODE="keep"
        log "已有其他 DHCP server，改用 DHCP relay"
    else
        # 唯一 gateway，固定 .1 開 DHCP server
        DHCP_ACTION="server"
        LAN_MODE="static"
    fi
else
    # client: DHCP relay 轉發給 gateway
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
# 6. 有線 mesh 時停用無線 mesh
# =====================
WIRE_DEV=$(uci get network.batmesh_wire.device 2>/dev/null)
if [ -n "$WIRE_DEV" ] && [ "$(cat /sys/class/net/$WIRE_DEV/carrier 2>/dev/null)" = "1" ]; then
    # 有線 mesh 連線中 → 停無線 mesh
    CUR_MESH_DISABLED=$(uci get wireless.mesh0.disabled 2>/dev/null)
    if [ "$CUR_MESH_DISABLED" != "1" ]; then
        uci set wireless.mesh0.disabled='1'
        uci commit wireless
        wifi reload
        log "有線 mesh ($WIRE_DEV) 連線中，停用無線 mesh"
        CHANGED=1
    fi
else
    # 無有線 mesh → 啟用無線 mesh
    CUR_MESH_DISABLED=$(uci get wireless.mesh0.disabled 2>/dev/null)
    if [ "$CUR_MESH_DISABLED" = "1" ]; then
        uci delete wireless.mesh0.disabled
        uci commit wireless
        wifi reload
        log "有線 mesh 未連線，啟用無線 mesh"
        CHANGED=1
    fi
fi

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

if [ "$CHANGED" = "0" ]; then
    log "角色: $NEW_ROLE, DHCP: $DHCP_ACTION, LAN: $LAN_MODE (無變更)"
fi
