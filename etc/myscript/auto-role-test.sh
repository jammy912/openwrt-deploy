#!/bin/sh
# auto-role-test.sh - 模擬角色切換壓力測試 (實際變更 + 詳細 LOG)
# 用法: sh /etc/myscript/auto-role-test.sh
# 前提: 先停掉 cron 裡的 auto-role.sh
#
# RAX3000Z(pri=1000): 主gw→副gw→client→主gw
# GW1(pri=500):       副gw→主gw→副gw→client→副gw

. /etc/myscript/push_notify.inc 2>/dev/null
PUSH_NAMES="jammy"

HOSTNAME=$(cat /proc/sys/kernel/hostname)
LOG="/etc/myscript/auto-role-test_${HOSTNAME}.log"
echo "" >> "$LOG"
echo "$(date '+%Y-%m-%d %H:%M:%S') ====== NEW RUN ======" >> "$LOG"

ts() { date "+%H:%M:%S"; }

log() {
    local msg="$(ts) [$HOSTNAME] $1"
    echo "$msg" >> "$LOG"
    echo "$msg"
}

# =====================
# 狀態快照
# =====================
snapshot() {
    local label="$1"
    log "===== SNAPSHOT: $label ====="
    log "LAN_IP: $(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}')"
    log "LAN_PROTO: $(uci get network.lan.proto 2>/dev/null)"
    log "LAN_IPADDR: $(uci get network.lan.ipaddr 2>/dev/null)"
    log "LAN_GW: $(uci get network.lan.gateway 2>/dev/null)"
    log "DHCP_IGNORE: $(uci get dhcp.lan.ignore 2>/dev/null)"
    log "DNSMASQ: $(pgrep -x dnsmasq >/dev/null 2>&1 && echo 'running' || echo 'stopped')"
    log "AGH: $(pgrep -x AdGuardHome >/dev/null 2>&1 && echo 'running' || echo 'stopped')"
    log "GW_MODE: $(batctl gw 2>/dev/null)"
    log "GW_TYPE_FILE: $(cat /etc/myscript/.mesh_gw_type 2>/dev/null)"
    log "ROLE_ACTIVE: $(cat /etc/myscript/.mesh_role_active 2>/dev/null)"
    log "WG_IFACES: $(wg show 2>/dev/null | grep 'interface:' | awk '{print $2}' | tr '\n' ' ')"
    log "PBR: $(/etc/init.d/pbr enabled 2>/dev/null && echo 'enabled' || echo 'disabled')"
    log "QOSIFY: $(pgrep -f qosify >/dev/null 2>&1 && echo 'running' || echo 'stopped')"
    # IOT WiFi
    local IOT_IF=$(uci show wireless 2>/dev/null | grep "ssid='IOT'" | cut -d. -f2)
    if [ -n "$IOT_IF" ]; then
        local IOT_DIS=$(uci get wireless.${IOT_IF}.disabled 2>/dev/null)
        local IOT_RADIO=$(uci get wireless.${IOT_IF}.device 2>/dev/null)
        local RADIO_DIS=$(uci get wireless.${IOT_RADIO}.disabled 2>/dev/null)
        local IOT_HOSTAPD=$(iw dev 2>/dev/null | grep -A1 "phy0-ap" | grep ssid | awk '{print $2}')
        log "IOT: iface_disabled=$IOT_DIS radio_disabled=$RADIO_DIS hostapd_ssid=$IOT_HOSTAPD"
    else
        log "IOT: (no IOT interface)"
    fi
    # batman
    log "BATCTL_N: $(batctl n 2>/dev/null | grep -c '[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]') neighbors"
    log "BATCTL_GWL: $(batctl gwl 2>/dev/null | grep 'MBit' | head -3)"
    # 連通性
    log "PING .1: $(ping -4 -c1 -W2 192.168.1.1 2>&1 | tail -1)"
    log "PING 8.8.8.8: $(ping -4 -c1 -W2 8.8.8.8 2>&1 | tail -1)"
    log "PING www.google.com: $(ping -4 -c1 -W3 www.google.com 2>&1 | tail -1)"
    log "DNS: $(nslookup google.com 127.0.0.1 2>&1 | grep -E 'Address|NXDOMAIN|timed out' | head -2)"
    # 路由
    log "DEFAULT_ROUTE: $(ip route | grep '^default' | head -1)"
    log "===== END SNAPSHOT ====="
}

# =====================
# 實際切換函數 (從 auto-role.sh 提取核心邏輯)
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

switch_to() {
    local TARGET="$1"  # 主gw / 副gw / client
    local PRI="$2"
    log ""
    log "##############################"
    log "# 切換到: $TARGET (pri=$PRI)"
    log "##############################"

    snapshot "切換前 → $TARGET"

    # === gw_mode ===
    if [ "$TARGET" = "client" ]; then
        WANT_GW="client"
    else
        WANT_GW="server"
    fi
    CUR_GW=$(uci get network.bat0.gw_mode 2>/dev/null)
    if [ "$CUR_GW" != "$WANT_GW" ]; then
        uci set network.bat0.gw_mode="$WANT_GW"
        uci commit network
        log "ACTION: gw_mode $CUR_GW → $WANT_GW"
    else
        log "ACTION: gw_mode 不變 ($WANT_GW)"
    fi

    # === batctl gw_bandwidth ===
    if [ "$TARGET" != "client" ]; then
        batctl gw server ${PRI}MBit 2>/dev/null
        log "ACTION: batctl gw server ${PRI}MBit"
    else
        batctl gw client 2>/dev/null
        log "ACTION: batctl gw client"
    fi

    # === LAN IP ===
    if [ "$TARGET" = "主gw" ]; then
        NEW_IP="192.168.1.1"
        NEW_GW=""
    else
        # 非主: 用 DHCP lease 或 MAC 算
        MY_BR_MAC=$(cat /sys/class/net/eth0/address 2>/dev/null | tr 'A-Z' 'a-z')
        SELF_IP=""
        if [ -n "$MY_BR_MAC" ]; then
            MATCH_IDX=$(uci show dhcp 2>/dev/null | grep -i "mac='$MY_BR_MAC'" | head -1 | sed "s/\.mac=.*//")
            [ -n "$MATCH_IDX" ] && SELF_IP=$(uci get "${MATCH_IDX}.ip" 2>/dev/null)
        fi
        if [ -z "$SELF_IP" ]; then
            MAC_LAST=$(echo "$MY_BR_MAC" | awk -F: '{print $NF}')
            SELF_IP="192.168.1.$((0x${MAC_LAST:-c8} % 53 + 200))"
        fi
        NEW_IP="$SELF_IP"
        NEW_GW="192.168.1.1"
        log "ACTION: 計算非主IP: MAC=$MY_BR_MAC → $SELF_IP"
    fi

    CUR_LAN_IP=$(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1)
    if [ "$CUR_LAN_IP" != "$NEW_IP" ]; then
        OLD_CIDR=$(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}')

        # 用 ifconfig 原子替換 IP（一步到位，不會有空窗期）
        log "ACTION: ifconfig br-lan ${NEW_IP} netmask 255.255.255.0"
        ifconfig br-lan "$NEW_IP" netmask 255.255.255.0 2>/dev/null

        if [ "$TARGET" = "client" ]; then
            # client 沒 WAN，走 br-lan→.1
            ip route replace default via "$NEW_GW" dev br-lan 2>/dev/null
            log "ACTION: client default route → via $NEW_GW dev br-lan"
        else
            # 主gw / 副gw 都走 WAN
            ip route del default via 192.168.1.1 dev br-lan 2>/dev/null
            WAN_GW=$(ifstatus wan 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
            WAN_DEV=$(ifstatus wan 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
            if [ -n "$WAN_GW" ] && [ -n "$WAN_DEV" ]; then
                ip route replace default via "$WAN_GW" dev "$WAN_DEV" 2>/dev/null
                log "ACTION: WAN default route: via $WAN_GW dev $WAN_DEV"
            else
                log "ACTION: 警告 - 無法取得 WAN gateway ($WAN_GW / $WAN_DEV)"
            fi
        fi

        # 驗證
        sleep 1
        VERIFY_IP=$(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}')
        log "ACTION: IP 切換結果: $OLD_CIDR → $VERIFY_IP"

        # UCI 更新
        uci set network.lan.ipaddr="$NEW_IP"
        if [ "$TARGET" = "client" ]; then
            # client 沒 WAN，gateway 指向 .1
            uci set network.lan.gateway="$NEW_GW"
            uci set network.lan.dns='192.168.1.1'
        else
            # 主gw / 副gw 走 WAN，不需要 LAN gateway
            uci delete network.lan.gateway 2>/dev/null
            uci delete network.lan.dns 2>/dev/null
        fi
        uci commit network

        sleep 2
        log "ACTION: IP 切換後確認: $(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}')"
    else
        log "ACTION: IP 不變 ($NEW_IP)"
    fi

    # === DHCP ===
    if [ "$TARGET" = "主gw" ]; then
        CUR_IGN=$(uci get dhcp.lan.ignore 2>/dev/null)
        if [ "$CUR_IGN" = "1" ]; then
            uci delete dhcp.lan.ignore 2>/dev/null
            uci set dhcp.lan.dhcpv4='server'
            uci commit dhcp
            /etc/init.d/dnsmasq restart
            log "ACTION: DHCP server 開啟"
        else
            log "ACTION: DHCP server 已開 (不變)"
        fi
    else
        CUR_IGN=$(uci get dhcp.lan.ignore 2>/dev/null)
        if [ "$CUR_IGN" != "1" ]; then
            uci set dhcp.lan.ignore='1'
            uci set dhcp.lan.dhcpv4='disabled'
            uci commit dhcp
            /etc/init.d/dnsmasq restart
            sleep 2
            # 確保 dnsmasq 還在跑（DNS 轉發需要它）
            if ! pgrep -x dnsmasq >/dev/null 2>&1; then
                log "ACTION: dnsmasq 未啟動，重試..."
                /etc/init.d/dnsmasq start
            fi
            log "ACTION: DHCP server 關閉"
        else
            log "ACTION: DHCP 已關 (不變)"
        fi
    fi

    # === 服務 ===
    if [ "$TARGET" = "主gw" ]; then
        log "ACTION: 啟動服務 ddns/adguardhome/pbr/qosify"
        svc_enable ddns
        svc_enable adguardhome
        svc_enable pbr
        svc_enable qosify
        # WG
        log "ACTION: 等 WAN 就緒再啟動 WG..."
        for i in 1 2 3 4 5 6; do
            WAN_OK=$(ifstatus wan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
            [ -n "$WAN_OK" ] && ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && break
            sleep 3
        done
        wg_start
        log "ACTION: WG 已啟動 (WAN=$WAN_OK)"
        # IOT WiFi
        IOT_IF=$(uci show wireless 2>/dev/null | grep "ssid='IOT'" | cut -d. -f2)
        if [ -n "$IOT_IF" ]; then
            uci delete wireless.${IOT_IF}.disabled 2>/dev/null
            IOT_RADIO=$(uci get wireless.${IOT_IF}.device 2>/dev/null)
            [ -n "$IOT_RADIO" ] && uci delete wireless.${IOT_RADIO}.disabled 2>/dev/null
            uci commit wireless
            [ -n "$IOT_RADIO" ] && wifi up "$IOT_RADIO"
            log "ACTION: IOT WiFi+${IOT_RADIO} 啟用"
        fi
    else
        log "ACTION: 停止服務 ddns/pbr/qosify/WG"
        svc_disable ddns
        svc_disable pbr
        svc_disable qosify
        wg_stop
        # IOT WiFi
        IOT_IF=$(uci show wireless 2>/dev/null | grep "ssid='IOT'" | cut -d. -f2)
        if [ -n "$IOT_IF" ]; then
            CUR_IOT_DIS=$(uci get wireless.${IOT_IF}.disabled 2>/dev/null)
            if [ "$CUR_IOT_DIS" != "1" ]; then
                uci set wireless.${IOT_IF}.disabled='1'
                IOT_RADIO=$(uci get wireless.${IOT_IF}.device 2>/dev/null)
                [ -n "$IOT_RADIO" ] && uci set wireless.${IOT_RADIO}.disabled='1'
                uci commit wireless
                [ -n "$IOT_RADIO" ] && wifi down "$IOT_RADIO"
                log "ACTION: IOT WiFi+${IOT_RADIO} 停用"
            else
                log "ACTION: IOT 已停用 (不變)"
            fi
        fi
    fi

    # === 更新狀態檔 ===
    echo "gateway" > /etc/myscript/.mesh_role_active
    [ "$TARGET" = "client" ] && echo "client" > /etc/myscript/.mesh_role_active
    echo "$TARGET" > /etc/myscript/.mesh_gw_type
    [ "$TARGET" = "client" ] && > /etc/myscript/.mesh_gw_type
    echo "$PRI" > /etc/myscript/.mesh_priority
    log "ACTION: 狀態檔更新: role_active=$(cat /etc/myscript/.mesh_role_active) gw_type=$(cat /etc/myscript/.mesh_gw_type) pri=$PRI"

    # === 等待穩定 ===
    log "等待 5 秒穩定..."
    sleep 5

    snapshot "切換後 → $TARGET"

    # === 連通性深度檢查 ===
    ACTUAL_IP=$(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1)
    log "--- 連通性檢查 (IP=$ACTUAL_IP) ---"
    log "ping 自己 ($ACTUAL_IP): $(ping -c1 -W2 $ACTUAL_IP 2>&1 | tail -1)"
    if [ "$TARGET" != "主gw" ]; then
        log "ping 主gw (.1): $(ping -c2 -W3 192.168.1.1 2>&1 | tail -1)"
    fi
    log "ping 8.8.8.8: $(ping -4 -c2 -W3 8.8.8.8 2>&1 | tail -1)"
    log "ping www.google.com: $(ping -4 -c2 -W3 www.google.com 2>&1 | tail -1)"
    log "nslookup google.com: $(nslookup google.com 127.0.0.1 2>&1 | grep -E 'Address|NXDOMAIN|timed out' | head -3)"
    # mesh
    log "batctl neighbors:"
    batctl n 2>/dev/null | grep '[0-9a-f][0-9a-f]:' >> "$LOG"
    log "batctl gwl:"
    batctl gwl 2>/dev/null | grep 'MBit' >> "$LOG"
    log "--- 檢查結束 ---"
    log ""
}

# =====================
# 主流程: 依 hostname 排程
# =====================
log "============================================"
log "AUTO-ROLE 壓力測試開始"
log "HOSTNAME=$HOSTNAME"
log "============================================"

snapshot "初始狀態"

if [ "$HOSTNAME" = "RAX3000Z" ]; then
    # RAX3000Z: 主gw(1000) → 副gw(400) → client → 主gw(1000)
    WAIT=0
    log "排程: RAX3000Z → 主gw(1000) → [60s] → 副gw(400) → [60s] → client → [60s] → 主gw(1000)"

    log "=== Phase 1: 主gw (pri=1000) ==="
    switch_to "主gw" 1000

    log "等待 60 秒 (讓 GW1 先準備好)..."
    sleep 60

    log "=== Phase 2: 副gw (pri=400) ==="
    switch_to "副gw" 400

    log "等待 60 秒..."
    sleep 60

    log "=== Phase 3: client ==="
    switch_to "client" 400

    log "等待 60 秒..."
    sleep 60

    log "=== Phase 4: 回到主gw (pri=1000) ==="
    switch_to "主gw" 1000

elif [ "$HOSTNAME" = "GW1" ]; then
    # GW1: 副gw(500) → [等30s讓RAX先當主] → 主gw(600) → 副gw(400) → client → 副gw(500)
    log "排程: GW1 → 副gw(500) → [90s] → 主gw(600) → [60s] → 副gw(400) → [60s] → client → [60s] → 副gw(500)"

    log "=== Phase 1: 副gw (pri=500) ==="
    switch_to "副gw" 500

    log "等待 90 秒 (讓 RAX3000Z 先切副gw)..."
    sleep 90

    log "=== Phase 2: 主gw (pri=600) ==="
    switch_to "主gw" 600

    log "等待 60 秒..."
    sleep 60

    log "=== Phase 3: 副gw (pri=400) ==="
    switch_to "副gw" 400

    log "等待 60 秒..."
    sleep 60

    log "=== Phase 4: client ==="
    switch_to "client" 400

    log "等待 60 秒..."
    sleep 60

    log "=== Phase 5: 回到副gw (pri=500) ==="
    switch_to "副gw" 500

else
    log "未知 hostname: $HOSTNAME，跳過"
    exit 1
fi

log ""
log "============================================"
log "測試完成！LOG: $LOG"
log "============================================"

# === Mesh 架構圖推播 (debug) ===
MY_PRI=$(cat /etc/myscript/.mesh_priority 2>/dev/null)
FINAL_IP=$(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1)
GW_TYPE=$(cat /etc/myscript/.mesh_gw_type 2>/dev/null || echo "?")
GWL_CACHE=$(batctl gwl 2>/dev/null | grep 'MBit')
N_RAW=$(batctl n 2>/dev/null)
N_CACHE=$(echo "$N_RAW" | grep '[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]')
PEER_MACS=$(echo "$N_CACHE" | awk '{for(i=1;i<=NF;i++){if($i~/^[0-9a-f][0-9a-f]:/){print $i;break}}}' | sort -u)
log "mesh-map: batctl_n_raw_lines=$(echo "$N_RAW" | wc -l) filtered=$(echo "$N_CACHE" | grep -c .) peer_macs=[${PEER_MACS}]"
log "mesh-map: batctl_n_raw: $(echo "$N_RAW" | head -5)"
log "mesh-map: gwl_cache: $(echo "$GWL_CACHE" | head -3)"
MESH_TMP="/tmp/mesh_map.$$"
echo "Mesh架構:" > "$MESH_TMP"
echo "${HOSTNAME}(${FINAL_IP}) ${GW_TYPE} pri=${MY_PRI}" >> "$MESH_TMP"
NEIGH_CACHE=$(ip neigh show dev br-lan 2>/dev/null | grep -v FAILED)
LEASE_CACHE=$(cat /tmp/dhcp.leases 2>/dev/null)
log "mesh-map: neigh=$(echo "$NEIGH_CACHE" | head -5)"
log "mesh-map: lease=$(echo "$LEASE_CACHE" | head -5)"
SEEN_TAILS=""
for mac in $PEER_MACS; do
    MAC_TAIL=$(echo "$mac" | cut -d: -f3-5)
    echo "$SEEN_TAILS" | grep -q "$MAC_TAIL" && continue
    SEEN_TAILS="$SEEN_TAILS $MAC_TAIL"
    LINKS=$(echo "$N_CACHE" | grep -i "$MAC_TAIL" | awk '{print $1}' | while read iface; do
        echo "$iface" | grep -q '^lan' && echo "有線" || echo "無線"
    done | sort -u | tr '\n' '+' | sed 's/+$//')
    PEER_PRI=$(echo "$GWL_CACHE" | grep -i "$MAC_TAIL" | head -1 | awk '{for(i=1;i<=NF;i++){if($i~/\//){split($i,bw,"/");split(bw[1],d,".");print d[1];exit}}}')
    PEER_ROLE="client"
    [ -n "$PEER_PRI" ] && PEER_ROLE="gw pri=${PEER_PRI}"
    PEER_IP=$(echo "$NEIGH_CACHE" | grep -i "$MAC_TAIL" | awk '/^192\.168\.1\./{print $1}' | head -1)
    PEER_NAME=""
    [ -n "$PEER_IP" ] && PEER_NAME=$(echo "$LEASE_CACHE" | awk -v ip="$PEER_IP" '$3==ip && $4!="*"{print $4}')
    if [ -n "$PEER_NAME" ]; then
        PEER_LABEL="${PEER_NAME}(${PEER_IP})"
    elif [ -n "$PEER_IP" ]; then
        PEER_LABEL="$PEER_IP"
    else
        PEER_LABEL="$mac"
    fi
    log "mesh-map: peer mac=$mac tail=$MAC_TAIL links=$LINKS pri=$PEER_PRI ip=$PEER_IP name=$PEER_NAME"
    echo "├─${LINKS}─${PEER_LABEL} ${PEER_ROLE}" >> "$MESH_TMP"
done
if [ -z "$PEER_MACS" ]; then
    log "mesh-map: ⚠️ PEER_MACS 為空，無鄰居"
    echo "├─(無鄰居)" >> "$MESH_TMP"
fi
log "mesh-map: 推播內容: $(cat "$MESH_TMP")"
push_notify "$(cat "$MESH_TMP")"
rm -f "$MESH_TMP"

push_notify "AutoRole測試完成($HOSTNAME) 30秒後重開機"

log "30 秒後重開機..."
sleep 30
reboot
