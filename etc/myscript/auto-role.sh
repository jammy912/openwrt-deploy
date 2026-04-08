#!/bin/sh
# auto-role.sh - 自動偵測 WAN/DHCP 狀態，切換 gateway/client 角色
# 觸發時機: rc.local 開機、hotplug WAN 變化、cron 定時
#
# 邏輯:
#   1. 有 WAN + 最高優先 → 主 gateway (IP=.1, 開 DHCP server, gw_mode=server)
#   2. 有 WAN + 非最高優先 → 副 gateway (靜態 IP, 關 DHCP, gw_mode=server)
#   3. 沒 WAN → client (靜態 IP from MAC/DHCP lease, 關 DHCP server, gw_mode=client)
#
# mesh 設定由 Google Sheet 同步到:
#   .mesh_priority  - 優先權 (數字大=優先當主 gateway)
#   .mesh_wireless  - 無線 mesh (Y/N)
#   .mesh_wired     - 有線 mesh (Y/N)

. /etc/myscript/push_notify.inc 2>/dev/null
PUSH_NAMES="jammy"

LOG_TAG="auto-role"
log() { logger -t "$LOG_TAG" "$1"; echo "[$LOG_TAG] $1"; }

# 併發鎖 (防止 cron 重疊執行)
LOCKFILE="/tmp/auto-role.lock"
if [ -f "$LOCKFILE" ]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null)
    if kill -0 "$LOCK_PID" 2>/dev/null; then
        log "另一個 auto-role (PID=$LOCK_PID) 正在執行，跳過"
        exit 0
    fi
    rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

# --debug 模式: 每步推播
DEBUG=0
[ "$1" = "--debug" ] && DEBUG=1
dbg() { [ "$DEBUG" = "1" ] && push_notify "AutoRole-DBG: $1"; }

# =====================
# 一次性 fw3→fw4 遷移
# =====================
if apk list -I 2>/dev/null | grep -q "^firewall-[0-9]"; then
    log "偵測到 fw3，開始遷移至 fw4..."
    apk del firewall 2>/dev/null
    apk add firewall4 uhttpd uhttpd-mod-ubus luci luci-ssl 2>/dev/null
    # 移除不存在的 firewall.user include
    uci show firewall 2>/dev/null | grep -q "@include\[0\].path='/etc/firewall.user'" && \
        uci delete firewall.@include[0] 2>/dev/null
    # dbroute include 標記 fw4 相容
    uci set firewall.dbroute.fw4_compatible='1' 2>/dev/null
    uci commit firewall 2>/dev/null
    /etc/init.d/firewall restart 2>/dev/null
    log "fw3 → fw4 遷移完成"
fi

ROLE_FILE="/etc/myscript/.mesh_role"
ACTIVE_FILE="/etc/myscript/.mesh_role_active"
CURRENT_ROLE=$(cat "$ACTIVE_FILE" 2>/dev/null)
GWTYPE_FILE="/etc/myscript/.mesh_gw_type"
PREV_GWTYPE=$(cat "$GWTYPE_FILE" 2>/dev/null)

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
dbg "0.網路就緒 (等待${i}s)"

# =====================
# 1. 檢查 override (Google Sheet GW Mode)
# =====================
OVERRIDE=$(cat /etc/myscript/.mesh_role_override 2>/dev/null)
OVERRIDE_LOWER=$(echo "$OVERRIDE" | tr 'A-Z' 'a-z')

if [ "$OVERRIDE_LOWER" = "gateway" ] || [ "$OVERRIDE_LOWER" = "client" ]; then
    NEW_ROLE="$OVERRIDE_LOWER"
    log "override 強制角色: $NEW_ROLE (來自 .mesh_role_override)"
    dbg "1.override=$NEW_ROLE"
else
    # =====================
    # 1b. 檢查 WAN 狀態 (自動偵測)
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
    dbg "1.自動偵測 WAN_IP=$WAN_IP HAS_WAN=$HAS_WAN → $NEW_ROLE"
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
    GWL_RAW=$(batctl gwl 2>/dev/null)
    GWL_COUNT=$(echo "$GWL_RAW" | grep -c 'MBit')
    MY_GWMODE=$(batctl gw 2>/dev/null)
    NEIGHBOR_COUNT=$(batctl n 2>/dev/null | grep -c ':')
    dbg "3.gwl_raw: count=$GWL_COUNT my_gw=$MY_GWMODE neighbors=$NEIGHBOR_COUNT"
    [ "$DEBUG" = "1" ] && {
        GWL_LINES=$(echo "$GWL_RAW" | grep 'MBit' | head -5)
        [ -n "$GWL_LINES" ] && dbg "3.gwl_entries: $GWL_LINES"
        [ -z "$GWL_LINES" ] && dbg "3.gwl_entries: (empty)"
    }

    # 格式: "95.0/2.0 MBit" → 取 "/" 前的整數部分
    HIGHER=$(echo "$GWL_RAW" | awk -v me_pri="$MY_PRI" -v me_mac="$MY_MAC" '
        /MBit/ {
            mac = $1; gsub(/[^0-9a-f:]/, "", mac)
            for (i=1; i<=NF; i++) {
                if ($i ~ /\/.*MBit/ || (i<NF && $(i+1)=="MBit")) {
                    split($i, bw, "/"); split(bw[1], dec, "."); pri=dec[1]; break
                }
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

dbg "3.priority=$MY_PRI MAC=$MY_MAC IS_PRIMARY=$IS_PRIMARY"

DHCP_ACTION=""  # server 或 off
LAN_MODE=""     # static 或 keep
if [ "$NEW_ROLE" = "gateway" ] && [ "$IS_PRIMARY" = "1" ]; then
    # 主 gateway: 固定 .1 開 DHCP server
    DHCP_ACTION="server"
    LAN_MODE="static"
    log "主 gateway (priority=$MY_PRI)"
elif [ "$NEW_ROLE" = "gateway" ]; then
    # 非主 gateway: 關閉 DHCP (client 透過 bat0/br-lan 直接拿主 gw 的 DHCP)
    DHCP_ACTION="off"
    LAN_MODE="keep"
else
    # client: 關閉 DHCP
    DHCP_ACTION="off"
    LAN_MODE="keep"
fi

# =====================
# 4. 套用變更
# =====================
CHANGED=0
NEED_WG_START=0

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
CUR_LAN_PROTO=$(uci get network.lan.proto 2>/dev/null)
CUR_LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null)
[ -z "$CUR_LAN_IP" ] && CUR_LAN_IP=$(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1)
dbg "4.gw_mode=$WANT_GW DHCP=$DHCP_ACTION LAN=$LAN_MODE IP=$CUR_LAN_IP proto=$CUR_LAN_PROTO"

# LAN IP 模式
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
else
    # 非主 gateway / client: 查 DHCP 靜態對應，沒有則用 MAC 算 IP
    MY_BR_MAC=$(cat /sys/class/net/br-lan/address 2>/dev/null | tr 'A-Z' 'a-z')
    # 從本地 /etc/config/dhcp 找自己 MAC 的靜態 IP
    SELF_IP=""
    if [ -n "$MY_BR_MAC" ]; then
        MATCH_IDX=$(uci show dhcp 2>/dev/null | grep -i "mac='$MY_BR_MAC'" | head -1 | sed "s/\.mac=.*//")
        [ -n "$MATCH_IDX" ] && SELF_IP=$(uci get "${MATCH_IDX}.ip" 2>/dev/null)
    fi
    # 沒找到靜態對應，用 MAC 最後字節算
    if [ -z "$SELF_IP" ]; then
        MAC_LAST=$(echo "$MY_BR_MAC" | awk -F: '{print $NF}')
        SELF_IP="192.168.1.$((0x${MAC_LAST:-c8} % 53 + 200))"
    fi
    if [ "$CUR_LAN_IP" = "192.168.1.1" ] || [ "$CUR_LAN_IP" != "$SELF_IP" ]; then
        uci set network.lan.proto='static'
        uci set network.lan.ipaddr="$SELF_IP"
        uci set network.lan.netmask='255.255.255.0'
        uci set network.lan.gateway='192.168.1.1'
        uci set network.lan.dns='192.168.1.1'
        log "LAN IP: $SELF_IP (非主 gateway)"
        NEED_RESTART_NET=1
        CHANGED=1
    fi
fi
uci commit network

if [ "$NEED_RESTART_NET" = "1" ]; then
    log "重啟網路..."
    /etc/init.d/network restart
    NEED_RESTART_NET=0
    # 等待網路恢復，確保後續推播能送出
    for i in 1 2 3 4 5; do
        ping -c1 -W2 192.168.1.1 >/dev/null 2>&1 && break
        sleep 2
    done
fi

# DHCP server / off
CUR_DHCP_IGNORE=$(uci get dhcp.lan.ignore 2>/dev/null)
HAS_RELAY=$(uci show dhcp 2>/dev/null | grep -c "=relay")

# 清除歷史遺留的 relay 設定
if [ "$HAS_RELAY" -gt 0 ]; then
    while uci show dhcp 2>/dev/null | grep -q "=relay"; do
        uci delete dhcp.@relay[0] 2>/dev/null || break
    done
    uci commit dhcp
    log "清除舊 DHCP relay 設定"
fi

if [ "$DHCP_ACTION" = "server" ]; then
    # 確保 dnsmasq 在跑
    DNSMASQ_OK=1
    [ "$CUR_DHCP_IGNORE" = "1" ] && DNSMASQ_OK=0
    pgrep -x dnsmasq >/dev/null 2>&1 || DNSMASQ_OK=0
    if [ "$DNSMASQ_OK" = "0" ]; then
        uci delete dhcp.lan.ignore 2>/dev/null
        uci set dhcp.lan.dhcpv4='server'
        uci commit dhcp
        /etc/init.d/dnsmasq restart
        log "DHCP server 已開啟"
        CHANGED=1
    fi
elif [ "$DHCP_ACTION" = "off" ]; then
    if [ "$CUR_DHCP_IGNORE" != "1" ]; then
        uci set dhcp.lan.ignore='1'
        uci set dhcp.lan.dhcpv4='disabled'
        uci commit dhcp
        /etc/init.d/dnsmasq restart
        log "DHCP server 已關閉 (非主 gateway)"
        CHANGED=1
    fi
fi

# =====================
# 5. 服務啟停
# =====================
svc_enable()  { /etc/init.d/$1 enable 2>/dev/null; /etc/init.d/$1 start 2>/dev/null; }
svc_disable() { /etc/init.d/$1 stop 2>/dev/null; /etc/init.d/$1 disable 2>/dev/null; }
wg_stop() {
    for wg_if in $(uci show network | grep "=interface" | cut -d. -f2 | cut -d= -f1 | grep '^wg'); do
        ifdown "$wg_if" 2>/dev/null
    done
}
wg_start() {
    for wg_if in $(uci show network | grep "=interface" | cut -d. -f2 | cut -d= -f1 | grep '^wg'); do
        ifup "$wg_if" 2>/dev/null
    done
}

if [ "$NEW_ROLE" = "gateway" ] && [ "$LAN_MODE" = "static" ]; then
    # 主 gateway: 有變更或主/副切換時啟動服務
    PROMOTED=0
    [ "$PREV_GWTYPE" != "主gw" ] && PROMOTED=1
    if [ "$CHANGED" = "1" ] || [ "$PROMOTED" = "1" ]; then
        svc_enable ddns
        svc_enable adguardhome
        svc_enable pbr
        svc_enable qosify
        NEED_WG_START=1
        [ "$PROMOTED" = "1" ] && log "服務: 全開 (副gw→主gw 升級)"
        [ "$PROMOTED" = "0" ] && log "服務: 全開 (主 gateway)"
        CHANGED=1
    fi
    dbg "5.主gateway (changed=$CHANGED promoted=$PROMOTED)"
elif [ "$NEW_ROLE" = "gateway" ]; then
    # 非主 gateway: 每次確保 WG/DDNS 停掉
    svc_disable ddns
    wg_stop
    dbg "5.非主gateway: 停WG/DDNS"
else
    # client: 每次確保全停
    svc_disable ddns
    svc_disable adguardhome
    svc_disable pbr
    svc_disable qosify
    wg_stop
    dbg "5.client: 停全部服務"
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
[ -z "$WANT_WIRELESS" ] && WANT_WIRELESS=Y
[ -z "$WANT_WIRED" ] && WANT_WIRED=Y
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

# 有線 mesh — 自動建立 batmesh_wire (預設 lan2)
WIRE_DEV=$(uci get network.batmesh_wire.device 2>/dev/null)
if [ "$WANT_WIRED" = "Y" ] && [ -z "$WIRE_DEV" ]; then
    # 偵測可用的 lan port (優先 lan2)
    if [ -e /sys/class/net/lan2 ]; then
        WIRE_DEV="lan2"
    else
        WIRE_DEV=$(ls /sys/class/net/ | grep '^lan' | sort | tail -1)
    fi
    if [ -n "$WIRE_DEV" ]; then
        uci set network.batmesh_wire=interface
        uci set network.batmesh_wire.proto='batadv_hardif'
        uci set network.batmesh_wire.master='bat0'
        uci set network.batmesh_wire.mtu='1536'
        uci set network.batmesh_wire.device="$WIRE_DEV"
        # 從 br-lan 移除該 port (避免衝突)
        uci show network | grep -q "br-lan.*ports.*$WIRE_DEV" && {
            CUR_PORTS=$(uci get network.@device[0].ports 2>/dev/null)
            NEW_PORTS=$(echo "$CUR_PORTS" | tr ' ' '\n' | grep -v "^${WIRE_DEV}$" | tr '\n' ' ')
            uci delete network.@device[0].ports 2>/dev/null
            for p in $NEW_PORTS; do uci add_list network.@device[0].ports="$p"; done
        }
        uci commit network
        NEED_RESTART_NET=1
        push_notify "有線mesh啟用: $WIRE_DEV"
        log "自動建立 batmesh_wire ($WIRE_DEV)"
        CHANGED=1
    fi
fi
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
    CHANGED=1
fi

if [ "$NEED_RESTART_NET" = "1" ]; then
    log "重啟網路 (mesh 介面變更)..."
    /etc/init.d/network restart
    for i in 1 2 3 4 5; do
        ping -c1 -W2 192.168.1.1 >/dev/null 2>&1 && break
        sleep 2
    done
fi

# 確保 gw_mode + bandwidth(=priority) 在 network restart 後生效
if [ "$NEW_ROLE" = "gateway" ]; then
    batctl gw server ${MY_PRI}MBit 2>/dev/null
fi

# WG 延遲啟動 (等所有 network restart 完成 + WAN 就緒)
if [ "$NEED_WG_START" = "1" ]; then
    # 等 WAN 拿到 IP 且能上網
    for i in 1 2 3 4 5 6; do
        WAN_OK=$(ifstatus wan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
        [ -n "$WAN_OK" ] && ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && break
        sleep 3
    done
    wg_start
    log "WG 已啟動 (WAN=$WAN_OK)"
fi

# 取得最新 IP (network restart 後可能改變)
FINAL_IP=$(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1)
if [ "$IS_PRIMARY" = "1" ] && [ "$NEW_ROLE" = "gateway" ]; then
    GW_TYPE="主gw"
elif [ "$NEW_ROLE" = "gateway" ]; then
    GW_TYPE="副gw"
else
    GW_TYPE="client"
fi

# 角色或主/副變更時推播
if [ "$CURRENT_ROLE" != "$NEW_ROLE" ]; then
    push_notify "AutoRole: ${CURRENT_ROLE:-none}→${GW_TYPE} ${FINAL_IP}"
elif [ "$NEW_ROLE" = "gateway" ] && [ "$PREV_GWTYPE" != "$GW_TYPE" ]; then
    push_notify "AutoRole: ${PREV_GWTYPE:-?}→${GW_TYPE} ${FINAL_IP}"
fi
if [ "$NEW_ROLE" = "gateway" ]; then
    echo -n "$GW_TYPE" > "$GWTYPE_FILE"
else
    > "$GWTYPE_FILE"
fi

if [ "$CHANGED" = "0" ]; then
    log "角色: $NEW_ROLE ($GW_TYPE), IP=$FINAL_IP, DHCP=$DHCP_ACTION (無變更)"
fi
# debug 網路診斷
if [ "$DEBUG" = "1" ]; then
    BAT0_MASTER=$(ip link show bat0 2>/dev/null | grep -o 'master [^ ]*')
    BR_BAT0=$(brctl show br-lan 2>/dev/null | grep bat0 | head -1)
    MESH_NEIGHBORS=$(batctl n 2>/dev/null | grep -c ':')
    TL_COUNT=$(batctl tl 2>/dev/null | grep -c ':')
    dbg "diag: bat0=${BAT0_MASTER:-NONE} br-lan_has_bat0=${BR_BAT0:+YES} LAN_IP=$FINAL_IP neighbors=$MESH_NEIGHBORS tl_entries=$TL_COUNT"
fi
dbg "完成: role=$NEW_ROLE $GW_TYPE IP=$FINAL_IP DHCP=$DHCP_ACTION changed=$CHANGED"

# =====================
# 9. 最終狀態一致性檢查
# =====================
FIXUP=0
if [ "$GW_TYPE" = "主gw" ]; then
    # 主 gw: WG/dnsmasq/adguardhome 必須在跑
    WG_UP=$(wg show 2>/dev/null | grep -c 'interface:')
    if [ "$WG_UP" -eq 0 ]; then
        for i in 1 2 3 4 5; do
            WAN_OK=$(ifstatus wan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
            [ -n "$WAN_OK" ] && break
            sleep 2
        done
        wg_start; log "fixup: WG 未運行，已啟動 (WAN=$WAN_OK)"; FIXUP=1
    fi
    if ! pgrep -x dnsmasq >/dev/null 2>&1; then
        /etc/init.d/dnsmasq restart; log "fixup: dnsmasq 未運行，已重啟"; FIXUP=1
    fi
    if ! pgrep -f adguardhome >/dev/null 2>&1; then
        /etc/init.d/adguardhome start 2>/dev/null; log "fixup: AdGuardHome 未運行，已啟動"; FIXUP=1
    fi
else
    # 副 gw / client: WG 不該跑
    WG_UP=$(wg show 2>/dev/null | grep -c 'interface:')
    if [ "$WG_UP" -gt 0 ]; then
        wg_stop; log "fixup: WG 不應運行，已停止"; FIXUP=1
    fi
fi
[ "$FIXUP" = "1" ] && push_notify "AutoRole fixup: $GW_TYPE $FINAL_IP 服務狀態已修正"
