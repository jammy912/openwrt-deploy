#!/bin/sh
# auto-role.sh - 自動偵測 WAN/DHCP 狀態，切換 gateway/client 角色
# 觸發時機: rc.local 開機、hotplug WAN 變化、cron 定時
#
# 邏輯:
#   1. 有 WAN + 沒其他 DHCP → gateway (IP=.1, 開 DHCP, gw_mode=server)
#   2. 有 WAN + 有其他 DHCP → gateway (LAN DHCP client, 不開 DHCP, gw_mode=server)
#   3. 沒 WAN → client (LAN DHCP client, 關 DHCP, gw_mode=client)

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

DHCP_ACTION=""
LAN_MODE=""  # static 或 dhcp
if [ "$NEW_ROLE" = "gateway" ]; then
    if check_other_dhcp; then
        # 有其他 DHCP server，自己不開，LAN 用 DHCP client
        DHCP_ACTION="disable"
        LAN_MODE="dhcp"
        log "已有其他 DHCP server，LAN 改為 DHCP client"
    else
        # 唯一 gateway，固定 .1 開 DHCP
        DHCP_ACTION="enable"
        LAN_MODE="static"
    fi
else
    # client: 關 DHCP，LAN 用 DHCP client
    DHCP_ACTION="disable"
    LAN_MODE="dhcp"
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
NEED_RESTART_NET=0
if [ "$LAN_MODE" = "static" ]; then
    if [ "$CUR_LAN_PROTO" != "static" ]; then
        uci set network.lan.proto='static'
        uci set network.lan.ipaddr='192.168.1.1'
        uci set network.lan.netmask='255.255.255.0'
        log "LAN 改為 static 192.168.1.1"
        NEED_RESTART_NET=1
        CHANGED=1
    fi
elif [ "$LAN_MODE" = "dhcp" ]; then
    if [ "$CUR_LAN_PROTO" != "dhcp" ]; then
        uci set network.lan.proto='dhcp'
        uci delete network.lan.ipaddr 2>/dev/null
        uci delete network.lan.netmask 2>/dev/null
        log "LAN 改為 DHCP client"
        NEED_RESTART_NET=1
        CHANGED=1
    fi
fi
uci commit network

# DHCP
CUR_DHCP_IGNORE=$(uci get dhcp.lan.ignore 2>/dev/null)
if [ "$DHCP_ACTION" = "enable" ]; then
    if [ "$CUR_DHCP_IGNORE" = "1" ]; then
        uci delete dhcp.lan.ignore
        uci commit dhcp
        /etc/init.d/dnsmasq restart
        log "DHCP server 已開啟"
        CHANGED=1
    fi
elif [ "$DHCP_ACTION" = "disable" ]; then
    if [ "$CUR_DHCP_IGNORE" != "1" ]; then
        uci set dhcp.lan.ignore='1'
        uci commit dhcp
        /etc/init.d/dnsmasq restart
        log "DHCP server 已關閉"
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
