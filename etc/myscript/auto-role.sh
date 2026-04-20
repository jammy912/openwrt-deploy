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
. /etc/myscript/lock_handler.sh
# auto-role 不受 agh_startup lock 限制 (它自己要判斷角色+停 AGH)

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
trap 'rm -f "$LOCKFILE" /tmp/cron_global.lock' EXIT

# 全域 cron 排隊鎖
cron_global_lock 60 || exit 0

# --debug 模式: 每步推播 / --dry-run 模式: 只偵測不執行
DEBUG=0; DRY_RUN=0
for _arg in "$@"; do
    case "$_arg" in
        --debug)  DEBUG=1 ;;
        --dry-run) DRY_RUN=1 ;;
    esac
done
dbg() { [ "$DEBUG" = "1" ] && push_notify "AutoRole-DBG: $1"; }

# radio 下排除指定 iface 後，是否還有其他啟用中 (disabled!=1) 的 wifi-iface
# $1=radio  $2=要排除的 iface
radio_has_other_active_iface() {
    local _radio="$1" _skip="$2" _has=0 _sec _dev _dis
    for _sec in $(uci show wireless 2>/dev/null | awk -F'[.=]' '/=wifi-iface$/{print $2}'); do
        [ "$_sec" = "$_skip" ] && continue
        _dev=$(uci -q get wireless.$_sec.device)
        [ "$_dev" = "$_radio" ] || continue
        _dis=$(uci -q get wireless.$_sec.disabled)
        [ "$_dis" = "1" ] && continue
        _has=1; break
    done
    return $((1 - _has))
}

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
MY_MAC=$(cat /sys/class/net/br-lan/address 2>/dev/null)
[ -z "$MY_MAC" ] && MY_MAC=$(cat /sys/class/net/eth0/address 2>/dev/null)

# 連外健康檢查: WAN 不通時暫時降 priority=0 讓出主 gw。
# ping IP 避免 DNS 未就緒誤判；失敗後重試 3 次 (間隔 10s)。
if [ "$NEW_ROLE" = "gateway" ]; then
    _wan_ok=0
    for _try in 1 2 3; do
        if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
            _wan_ok=1; break
        fi
        [ "$_try" -lt 3 ] && sleep 10
    done
    if [ "$_wan_ok" = "0" ]; then
        log "⚠️ 連外異常 (ping 8.8.8.8 重試 3 次失敗)，暫時降 priority 0"
        MY_PRI=0
    fi
fi

# 開機延遲: priority 越低等越久，讓高 priority 的先搶主 gw
BOOT_DELAY=$(( (600 - MY_PRI) / 10 ))
[ "$BOOT_DELAY" -lt 0 ] && BOOT_DELAY=0
UPTIME=$(awk -F. '{print $1}' /proc/uptime)
if [ "$UPTIME" -lt 120 ] && [ "$BOOT_DELAY" -gt 0 ]; then
    log "開機延遲 ${BOOT_DELAY}s (pri=${MY_PRI}, uptime=${UPTIME}s)"
    sleep "$BOOT_DELAY"
fi

# 設定自己的 gw_bandwidth = priority (讓 batctl gwl 看到，保留相容)
[ "$NEW_ROLE" = "gateway" ] && batctl gw server ${MY_PRI}MBit 2>/dev/null

# 先廣播自己的狀態到 alfred，讓其他 mesh 節點能讀到
_HAS_WAN_FOR_ALFRED="${HAS_WAN:-0}"
if command -v alfred >/dev/null 2>&1; then
    _WAN_STATUS="down"
    [ "$_HAS_WAN_FOR_ALFRED" = "1" ] && _WAN_STATUS="up"
    _AGH_STATUS="down"
    if pgrep -f '/usr/bin/AdGuardHome' >/dev/null 2>&1; then
        nslookup -port=53535 -timeout=2 www.twse.com.tw 127.0.0.1 >/dev/null 2>&1 && _AGH_STATUS="up"
    fi
    _LAN_IP=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    _ALFRED_DATA="{\"mac\":\"${MY_MAC}\", \"ip\":\"${_LAN_IP}\", \"wan_status\":\"${_WAN_STATUS}\", \"priority\":${MY_PRI}, \"agh_status\":\"${_AGH_STATUS}\"}"
    alfred_try() {
        alfred -r 64 >/dev/null 2>&1 || return 1
        printf '%s' "$_ALFRED_DATA" | alfred -s 64 2>/dev/null || return 1
        return 0
    }
    for _try in 1 2 3; do
        alfred_try && break
        log "alfred 異常 (try $_try)，重啟 alfred"
        /etc/init.d/alfred restart 2>/dev/null
        sleep 2
    done
fi

# 檢查 mesh 裡有沒有比自己優先的 gateway (改用 alfred -r 64 取代 batctl gwl)
IS_PRIMARY=1
if [ "$NEW_ROLE" = "gateway" ]; then
    # alfred 輸出格式 (每行一筆):
    #   { "<src_mac>", "{\"mac\":\"...\", \"wan_status\":\"up\", \"priority\":50, ...}\x0a" },
    # 直接用正則抓 payload 裡的欄位 (不管外層 wrapper)
    ALFRED_RAW=$(alfred -r 64 2>/dev/null)
    dbg "3.alfred_raw_lines=$(echo "$ALFRED_RAW" | wc -l)"

    HIGHER=$(echo "$ALFRED_RAW" | awk -v me_pri="$MY_PRI" -v me_mac="$(echo "$MY_MAC" | tr 'A-Z' 'a-z')" '
        {
            line = tolower($0)
            mac = ""
            if (match(line, /\\"mac\\":\\"[0-9a-f:]+\\"/)) {
                s = substr(line, RSTART, RLENGTH); sub(/.*\\":\\"/, "", s); sub(/\\".*/, "", s); mac = s
            }
            pri = -1
            if (match(line, /\\"priority\\":-?[0-9]+/)) {
                s = substr(line, RSTART, RLENGTH); sub(/.*:/, "", s); pri = s + 0
            }
            wan = "down"
            if (match(line, /\\"wan_status\\":\\"[a-z]+\\"/)) {
                s = substr(line, RSTART, RLENGTH); sub(/.*\\":\\"/, "", s); sub(/\\".*/, "", s); wan = s
            }
            if (mac == "" || mac == me_mac) next
            if (wan != "up") next
            if (pri < 0) next
            if (pri > me_pri) { found=1; exit }
            if (pri == me_pri && mac < me_mac) { found=1; exit }
        }
        END { if (found) print "yes" }
    ')

    # 沒有 alfred 資料時 fallback 回 batctl gwl
    if [ -z "$ALFRED_RAW" ]; then
        GWL_RAW=$(batctl gwl 2>/dev/null)
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
        dbg "3.alfred empty, fallback to batctl gwl"
    fi

    if [ "$HIGHER" = "yes" ]; then
        IS_PRIMARY=0
        log "mesh 有更高優先的 gateway (my_pri=$MY_PRI, my_mac=$MY_MAC)"
    fi
fi

# ARP DAD 防撞: 判定為主但自己還沒是 .1 → 用 arping -D (source 0.0.0.0) 探測
# 若有別台 reply 且 MAC 不是自己 → 讓位為副，避免雙主
if [ "$NEW_ROLE" = "gateway" ] && [ "$IS_PRIMARY" = "1" ] && command -v arping >/dev/null 2>&1; then
    CUR_IP=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    if [ "$CUR_IP" != "192.168.1.1" ]; then
        ARP_OUT=$(arping -c 2 -w 2 -D -I br-lan 192.168.1.1 2>&1)
        MY_BRLAN_MAC=$(cat /sys/class/net/br-lan/address 2>/dev/null | tr 'A-Z' 'a-z')
        REMOTE_MAC=$(echo "$ARP_OUT" | grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | tr 'A-Z' 'a-z' | grep -v "^${MY_BRLAN_MAC}$" | head -1)
        if [ -n "$REMOTE_MAC" ]; then
            IS_PRIMARY=0
            log "ARP DAD: 192.168.1.1 已被 $REMOTE_MAC 佔用 (我 br-lan MAC=$MY_BRLAN_MAC)，讓位為副 gw"
        fi
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
    # 將 Hitron port forward wg* 規則指向本機 WAN IP
    # 優先用 Google 拉下來的快照整包覆蓋 (含 58U-wg1 等所有規則)
    if [ -x /etc/myscript/hitron-pf.sh ]; then
        if [ -f /etc/myscript/.hitron-pf.json ]; then
            /etc/myscript/hitron-pf.sh --apply-from /etc/myscript/.hitron-pf.json >/dev/null 2>&1 &
        else
            /etc/myscript/hitron-pf.sh >/dev/null 2>&1 &
        fi
    fi
elif [ "$NEW_ROLE" = "gateway" ]; then
    # 非主 gateway: 關閉 DHCP (client 透過 bat0/br-lan 直接拿主 gw 的 DHCP)
    DHCP_ACTION="off"
    LAN_MODE="keep"
else
    # client: 開 DHCP (靜態對應，gateway/DNS 指向主 GW)
    DHCP_ACTION="server"
    LAN_MODE="keep"
fi

# =====================
# dry-run: 輸出偵測結果後退出
# =====================
if [ "$DRY_RUN" = "1" ]; then
    # 決定 GW_TYPE 標籤
    if [ "$NEW_ROLE" = "gateway" ] && [ "$IS_PRIMARY" = "1" ]; then
        _GW_TYPE="主gw"
    elif [ "$NEW_ROLE" = "gateway" ]; then
        _GW_TYPE="副gw"
    else
        _GW_TYPE="client"
    fi
    echo "========== dry-run 偵測結果 =========="
    echo "HOSTNAME:    $(cat /proc/sys/kernel/hostname)"
    echo "UPTIME:      $(awk -F. '{print $1}' /proc/uptime)s"
    echo "CURRENT_ROLE: $CURRENT_ROLE"
    echo "PREV_GWTYPE:  $PREV_GWTYPE"
    echo "---"
    echo "OVERRIDE:     ${OVERRIDE:-none}"
    echo "WAN_IP:       ${WAN_IP:-none}"
    echo "HAS_WAN:      ${HAS_WAN:-N/A}"
    echo "PING_8.8.8.8: $(ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && echo OK || echo FAIL)"
    echo "NEW_ROLE:     $NEW_ROLE"
    echo "---"
    echo "MY_PRI:       $MY_PRI"
    echo "MY_MAC:       $MY_MAC"
    echo "BOOT_DELAY:   ${BOOT_DELAY}s (skipped in dry-run)"
    echo "IS_PRIMARY:   $IS_PRIMARY"
    echo "HIGHER_FOUND: ${HIGHER:-no}"
    echo "---"
    echo "結論: $_GW_TYPE (role=$NEW_ROLE, primary=$IS_PRIMARY)"
    echo "DHCP_ACTION:  $DHCP_ACTION"
    echo "LAN_MODE:     $LAN_MODE"
    echo "---"
    echo "batctl gw:    $(batctl gw 2>/dev/null)"
    echo "batctl gwl:"
    batctl gwl 2>/dev/null | head -10
    echo "batctl n:"
    batctl n 2>/dev/null | head -10
    echo "======================================="
    rm -f "$LOCKFILE"
    exit 0
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
# 啟用 bridge loop avoidance (防止 lan3+hub+lan2 mesh 造成 L2 迴圈)
CUR_BLA=$(uci get network.bat0.bridge_loop_avoidance 2>/dev/null)
if [ "$CUR_BLA" != "1" ]; then
    uci set network.bat0.bridge_loop_avoidance='1'
    log "bat0 BLA: 已啟用"
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
    # 非主 gateway / client: 用 hostname 查 DHCP 靜態對應
    MY_HOSTNAME=$(cat /proc/sys/kernel/hostname 2>/dev/null)
    SELF_IP=""
    if [ -n "$MY_HOSTNAME" ]; then
        MATCH_IDX=$(uci show dhcp 2>/dev/null | grep -i "name='$MY_HOSTNAME'" | head -1 | sed "s/\.name=.*//")
        [ -n "$MATCH_IDX" ] && SELF_IP=$(uci get "${MATCH_IDX}.ip" 2>/dev/null)
    fi
    # 沒找到，用 br-lan MAC 最後字節算
    if [ -z "$SELF_IP" ]; then
        MY_BR_MAC=$(cat /sys/class/net/br-lan/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null)
        MY_BR_MAC=$(echo "$MY_BR_MAC" | tr 'A-Z' 'a-z')
        MAC_LAST=$(echo "$MY_BR_MAC" | awk -F: '{print $NF}')
        SELF_IP="192.168.1.$((0x${MAC_LAST:-c8} % 53 + 200))"
    fi
    if [ "$CUR_LAN_IP" = "192.168.1.1" ] || [ "$CUR_LAN_IP" != "$SELF_IP" ]; then
        uci set network.lan.proto='static'
        uci set network.lan.ipaddr="$SELF_IP"
        uci set network.lan.netmask='255.255.255.0'
        if [ "$NEW_ROLE" = "client" ]; then
            # client 沒 WAN，走 .1
            uci set network.lan.gateway='192.168.1.1'
            uci set network.lan.dns='192.168.1.1'
        else
            # 副gw 有 WAN，不設 gateway（走自己的 WAN）
            uci delete network.lan.gateway 2>/dev/null
            uci delete network.lan.dns 2>/dev/null
        fi
        log "LAN IP: $SELF_IP (非主, role=$NEW_ROLE)"
        NEED_RESTART_NET=1
        CHANGED=1
    fi
fi
uci commit network

if [ "$NEED_FULL_RESTART_NET" = "1" ]; then
    log "重啟網路 (batmesh_wire 變更)..."
    /etc/init.d/network restart
    NEED_RESTART_NET=0
    for i in 1 2 3 4 5; do
        ping -c1 -W2 192.168.1.1 >/dev/null 2>&1 && break
        sleep 2
    done
fi

if [ "$NEED_RESTART_NET" = "1" ]; then
    # 用 ip addr 熱切換 LAN IP，避免 network restart 導致 WiFi 長時間斷線
    OLD_IP=$(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}')
    NEW_IP=$(uci get network.lan.ipaddr 2>/dev/null)
    NEW_MASK=$(uci get network.lan.netmask 2>/dev/null)
    NEW_GW=$(uci get network.lan.gateway 2>/dev/null)
    if [ -n "$OLD_IP" ] && [ -n "$NEW_IP" ]; then
        # 用 ifconfig 原子替換 IP（一步到位，不會有空窗期）
        ifconfig br-lan "$NEW_IP" netmask "${NEW_MASK:-255.255.255.0}" 2>/dev/null
        if [ -n "$NEW_GW" ]; then
            ip route replace default via "$NEW_GW" dev br-lan 2>/dev/null
        else
            # 主gw: 移除 br-lan default route，恢復 WAN route
            ip route del default via 192.168.1.1 dev br-lan 2>/dev/null
            WAN_GW=$(ifstatus wan 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
            WAN_DEV=$(ifstatus wan 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
            [ -n "$WAN_GW" ] && [ -n "$WAN_DEV" ] && ip route replace default via "$WAN_GW" dev "$WAN_DEV" 2>/dev/null
        fi
        log "LAN IP 熱切換: $OLD_IP → ${NEW_IP}/${NEW_MASK:-255.255.255.0}"
    else
        log "重啟網路 (無法熱切換)..."
        /etc/init.d/network restart
    fi
    NEED_RESTART_NET=0
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
    # 只有主 gw 發 IPv6 RA/DHCPv6 (有 public prefix from wan6)
    # client 模式 br-lan 沒有 public prefix, 一樣應該靠 bat0 bridge 轉發主 gw RA
    # 注意: IS_PRIMARY=1 只代表 mesh 內最高優先, client 也可能是 primary,
    #      所以必須同時是 gateway 才算主 gw
    CUR_DHCPV6=$(uci -q get dhcp.lan.dhcpv6)
    CUR_RA=$(uci -q get dhcp.lan.ra)
    if [ "$NEW_ROLE" = "gateway" ] && [ "$IS_PRIMARY" = "1" ]; then
        _want_v6="server"
    else
        _want_v6="disabled"
    fi
    if [ "$CUR_DHCPV6" != "$_want_v6" ] || [ "$CUR_RA" != "$_want_v6" ]; then
        uci set dhcp.lan.dhcpv6="$_want_v6"
        uci set dhcp.lan.ra="$_want_v6"
        uci commit dhcp
        /etc/init.d/odhcpd restart 2>/dev/null
        log "IPv6: odhcpd dhcpv6/ra=$_want_v6"
        CHANGED=1
    fi
    # client: DHCP 發出的 gateway/DNS 指向主 GW
    if [ "$NEW_ROLE" = "client" ]; then
        CUR_GW_OPT=$(uci get dhcp.lan.dhcp_option 2>/dev/null)
        if ! echo "$CUR_GW_OPT" | grep -q '3,192.168.1.1'; then
            uci delete dhcp.lan.dhcp_option 2>/dev/null
            uci add_list dhcp.lan.dhcp_option='3,192.168.1.1'
            uci add_list dhcp.lan.dhcp_option='6,192.168.1.1'
            uci commit dhcp
            /etc/init.d/dnsmasq restart
            log "DHCP: gateway/DNS 指向 192.168.1.1 (client)"
            CHANGED=1
        fi
    elif [ "$IS_PRIMARY" = "1" ]; then
        # 主 gw: 清除 dhcp_option 覆蓋 (從 client 切回時)
        if uci get dhcp.lan.dhcp_option >/dev/null 2>&1; then
            uci delete dhcp.lan.dhcp_option 2>/dev/null
            uci commit dhcp
            /etc/init.d/dnsmasq restart
            log "DHCP: 清除 gateway/DNS 覆蓋 (主 gw)"
            CHANGED=1
        fi
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
    # 副 gw 沒有 public IPv6 prefix,odhcpd 不該發 RA/DHCPv6,
    # 主 gw 的 RA 會透過 bat0 bridge 直接穿到下游
    # 留著 server 會導致 odhcpd 每次發 RA 都噴 "no public prefix" warning
    CUR_DHCPV6=$(uci -q get dhcp.lan.dhcpv6)
    CUR_RA=$(uci -q get dhcp.lan.ra)
    if [ "$CUR_DHCPV6" != "disabled" ] || [ "$CUR_RA" != "disabled" ]; then
        uci set dhcp.lan.dhcpv6='disabled'
        uci set dhcp.lan.ra='disabled'
        uci commit dhcp
        /etc/init.d/odhcpd restart 2>/dev/null
        log "IPv6: odhcpd dhcpv6/ra 已關閉 (副 gw 透過 mesh 轉發主 gw RA)"
        CHANGED=1
    fi
fi

# =====================
# 5. 服務啟停
# =====================
svc_enable()  { /etc/init.d/$1 enable 2>/dev/null; /etc/init.d/$1 start 2>/dev/null; }
svc_disable() {
    # 已經停了就不再跑（避免每次 cron 重複輸出 stop 訊息）
    /etc/init.d/$1 enabled 2>/dev/null || return 0
    /etc/init.d/$1 stop 2>/dev/null; /etc/init.d/$1 disable 2>/dev/null
}
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
        # 開機早期不啟動 AGH，由 rc.local 延遲 120 秒後統一啟動
        _UPTIME_SEC=$(awk -F. '{print $1}' /proc/uptime)
        if [ "$_UPTIME_SEC" -gt 180 ]; then
            lock_check_and_create "agh_startup" 300 >/dev/null 2>&1
            svc_enable adguardhome
        else
            log "開機早期 (${_UPTIME_SEC}s)，跳過 AGH 啟動 (由 rc.local 延遲處理)"
        fi
        svc_enable pbr
        svc_enable qosify
        NEED_WG_START=1
        # 恢復 dnsmasq 指向 AGH (從 client 切回時需要)
        if [ "$(uci get dhcp.@dnsmasq[0].noresolv 2>/dev/null)" != "1" ]; then
            uci set dhcp.@dnsmasq[0].noresolv='1'
            # server 是 list 不是 option，必須用 add_list (否則 dnsmasq.conf 不帶 upstream)
            uci -q delete dhcp.@dnsmasq[0].server
            uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#53535'
            uci commit dhcp
            # 等 AGH listen 53535 再 restart dnsmasq，避免 dnsmasq 標記 upstream dead → REFUSED
            for _i in 1 2 3 4 5 6 7 8 9 10; do
                netstat -lnu 2>/dev/null | grep -q ":53535 " && break
                sleep 1
            done
            /etc/init.d/dnsmasq restart
            log "dnsmasq: 恢復 AGH 轉發 (主 gateway, 等 AGH ready ${_i}s)"
        fi
        # 開啟 IOT WiFi
        IOT_IF=$(uci show wireless 2>/dev/null | grep "ssid='IOT'" | cut -d. -f2)
        if [ -n "$IOT_IF" ]; then
            CUR_IOT_DIS=$(uci get wireless.${IOT_IF}.disabled 2>/dev/null)
            if [ "$CUR_IOT_DIS" = "1" ]; then
                uci delete wireless.${IOT_IF}.disabled
                _IOT_RADIO=$(uci -q get wireless.${IOT_IF}.device)
                [ -n "$_IOT_RADIO" ] && uci delete wireless.${_IOT_RADIO}.disabled 2>/dev/null
                uci commit wireless
                wifi reload
                log "IOT WiFi ($IOT_IF+$_IOT_RADIO) 已啟用 (主 gateway)"
            fi
        fi
        [ "$PROMOTED" = "1" ] && log "服務: 全開 (副gw→主gw 升級)"
        [ "$PROMOTED" = "0" ] && log "服務: 全開 (主 gateway)"
        CHANGED=1
    fi
    dbg "5.主gateway (changed=$CHANGED promoted=$PROMOTED)"
elif [ "$NEW_ROLE" = "gateway" ]; then
    # 非主 gateway: 停全部服務 + IOT WiFi + AGH
    svc_disable ddns
    svc_disable adguardhome
    lock_remove "agh_startup" >/dev/null 2>&1
    # 副gw 不需 PBR 路由分流，但 /etc/dnsmasq.d/pbr -> /var/run/pbr.dnsmasq
    # 若 symlink target 不存在 dnsmasq 會 crash，touch 空檔即可
    [ -L /etc/dnsmasq.d/pbr ] && touch /var/run/pbr.dnsmasq 2>/dev/null
    svc_disable qosify
    wg_stop
    # 停 IOT WiFi (只有主 gw 需要)
    IOT_IF=$(uci show wireless 2>/dev/null | grep "ssid='IOT'" | cut -d. -f2)
    if [ -n "$IOT_IF" ]; then
        CUR_IOT_DIS=$(uci get wireless.${IOT_IF}.disabled 2>/dev/null)
        if [ "$CUR_IOT_DIS" != "1" ]; then
            uci set wireless.${IOT_IF}.disabled='1'
            _IOT_RADIO=$(uci -q get wireless.${IOT_IF}.device)
            if [ -n "$_IOT_RADIO" ]; then
                if radio_has_other_active_iface "$_IOT_RADIO" "$IOT_IF"; then
                    log "[$_IOT_RADIO] 尚有其他啟用 SSID，保留 radio"
                else
                    uci set wireless.${_IOT_RADIO}.disabled='1'
                fi
            fi
            uci commit wireless
            wifi reload
            log "IOT WiFi ($IOT_IF+$_IOT_RADIO) 已停用 (非主 gateway)"
        fi
    fi
    dbg "5.非主gateway: 停全部服務+IOT"
else
    # client: 停全部服務 + IOT WiFi + AGH (DNS 直接走主 GW)
    svc_disable ddns
    # client 不需 PBR，touch 空檔防 dnsmasq crash
    [ -L /etc/dnsmasq.d/pbr ] && touch /var/run/pbr.dnsmasq 2>/dev/null
    svc_disable qosify
    svc_disable adguardhome
    lock_remove "agh_startup" >/dev/null 2>&1
    wg_stop
    # dnsmasq 直接用主 GW 的 DNS，不經 AGH
    if [ "$(uci get dhcp.@dnsmasq[0].noresolv 2>/dev/null)" = "1" ]; then
        uci delete dhcp.@dnsmasq[0].noresolv 2>/dev/null
        uci delete dhcp.@dnsmasq[0].server 2>/dev/null
        uci commit dhcp
        /etc/init.d/dnsmasq restart
        log "dnsmasq: 移除 AGH 轉發，改用 resolv (client)"
    fi
    IOT_IF=$(uci show wireless 2>/dev/null | grep "ssid='IOT'" | cut -d. -f2)
    if [ -n "$IOT_IF" ]; then
        CUR_IOT_DIS=$(uci get wireless.${IOT_IF}.disabled 2>/dev/null)
        if [ "$CUR_IOT_DIS" != "1" ]; then
            uci set wireless.${IOT_IF}.disabled='1'
            _IOT_RADIO=$(uci -q get wireless.${IOT_IF}.device)
            if [ -n "$_IOT_RADIO" ]; then
                if radio_has_other_active_iface "$_IOT_RADIO" "$IOT_IF"; then
                    log "[$_IOT_RADIO] 尚有其他啟用 SSID，保留 radio"
                else
                    uci set wireless.${_IOT_RADIO}.disabled='1'
                fi
            fi
            uci commit wireless
            wifi reload
            log "IOT WiFi ($IOT_IF+$_IOT_RADIO) 已停用 (client)"
        fi
    fi
    dbg "5.client: 停全部服務+IOT"
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
        CUR_PORTS=$(uci get network.@device[0].ports 2>/dev/null)
        if echo " $CUR_PORTS " | grep -q " ${WIRE_DEV} "; then
            uci delete network.@device[0].ports 2>/dev/null
            for p in $CUR_PORTS; do
                [ "$p" = "$WIRE_DEV" ] && continue
                uci add_list network.@device[0].ports="$p"
            done
            log "br-lan 移除 $WIRE_DEV (原: $CUR_PORTS)"
        fi
        # 為 $WIRE_DEV 隨機生成 locally-administered MAC，避免與 br-lan MAC 同源
        # 造成 batman 廣播繞回警告 (受 hostname 影響的穩定隨機，重開也不變)
        NEW_MAC=$(hexdump -n5 -e '"02:" 4/1 "%02x:" 1/1 "%02x"' /dev/urandom)
        # 建一個獨立 device section 設 macaddr
        WIRE_DEV_IDX=""
        _idx=0
        while _name=$(uci -q get "network.@device[$_idx].name" 2>/dev/null); do
            [ "$_name" = "$WIRE_DEV" ] && { WIRE_DEV_IDX=$_idx; break; }
            _idx=$((_idx + 1))
        done
        if [ -z "$WIRE_DEV_IDX" ]; then
            uci add network device >/dev/null
            uci set "network.@device[-1].name=$WIRE_DEV"
        fi
        uci set "network.@device[${WIRE_DEV_IDX:--1}].macaddr=$NEW_MAC"
        log "$WIRE_DEV 設定隨機 MAC: $NEW_MAC (防 batman 廣播繞回)"
        uci commit network
        NEED_RESTART_NET=1
        push_notify "有線mesh啟用: $WIRE_DEV (MAC=$NEW_MAC)"
        log "自動建立 batmesh_wire ($WIRE_DEV)"
        CHANGED=1
    fi
fi
if [ -n "$WANT_WIRED" ] && [ -n "$WIRE_DEV" ]; then
    CUR_WIRE_DISABLED=$(uci get network.batmesh_wire.disabled 2>/dev/null)
    if [ "$WANT_WIRED" = "N" ] && [ "$CUR_WIRE_DISABLED" != "1" ]; then
        uci set network.batmesh_wire.disabled='1'
        uci commit network
        NEED_FULL_RESTART_NET=1
        log "有線 mesh ($WIRE_DEV) 已停用 (設定=N)"
        CHANGED=1
    elif [ "$WANT_WIRED" = "Y" ] && [ "$CUR_WIRE_DISABLED" = "1" ]; then
        uci delete network.batmesh_wire.disabled
        uci commit network
        NEED_FULL_RESTART_NET=1
        log "有線 mesh ($WIRE_DEV) 已啟用 (設定=Y)"
        CHANGED=1
    fi
    # batmesh_wire 設定存在但 netifd 沒載入 → 直接 restart
    if [ "$WANT_WIRED" = "Y" ] && [ "$CUR_WIRE_DISABLED" != "1" ]; then
        if ! ifstatus batmesh_wire >/dev/null 2>&1; then
            log "batmesh_wire 未被 netifd 載入，強制 network restart"
            /etc/init.d/network restart
            for i in 1 2 3 4 5; do
                ping -c1 -W2 192.168.1.1 >/dev/null 2>&1 && break
                sleep 2
            done
        fi
    fi
fi

# br-lan 啟用 STP (避免 HUB/多條線造成 L2 迴圈)
BRLAN_IDX=$(uci show network 2>/dev/null | awk -F'[][]' '/\.name=.br-lan./{print $2; exit}')
if [ -n "$BRLAN_IDX" ]; then
    CUR_STP=$(uci get "network.@device[$BRLAN_IDX].stp" 2>/dev/null)
    if [ "$CUR_STP" != "1" ]; then
        uci set "network.@device[$BRLAN_IDX].stp"='1'
        uci commit network
        NEED_RESTART_NET=1
        log "br-lan STP 已啟用"
        CHANGED=1
    fi
fi

# =====================
# 7.5 5G 頻道政策
#   - mesh radio (同 radio 下有 mode=mesh 介面) 且 mesh_wireless=Y → 固定 149
#   - 其他 5G radio (client AP):
#       主gw / client → channel=auto, channels='36 40 48'       (低頻段)
#       副gw          → channel=auto, channels='149 153 157 161 165' (高頻段)
# =====================
apply_5g_channel_policy() {
    local gw_type="$1"          # 主gw / 副gw / client
    local mesh_wireless="$2"    # Y / N
    local ap_channel="auto" ap_channels
    # 非 DFS 頻段 (台灣): 低頻 36/40/44/48、高頻 149/153/157/161/165
    case "$gw_type" in
        副gw) ap_channels="149 153 157 161 165" ;;
        *)    ap_channels="36 40 44 48" ;;
    esac

    local radio band has_mesh mesh_disabled tgt_ch tgt_chs cur_ch cur_chs
    for radio in radio0 radio1 radio2 radio3; do
        band=$(uci get wireless.$radio.band 2>/dev/null)
        [ "$band" != "5g" ] && continue

        # 該 radio 是否為 mesh radio (有 mode=mesh 的介面綁在上面)
        has_mesh=0
        mesh_disabled=1
        for iface in $(uci show wireless 2>/dev/null | awk -F'[.=]' '/=wifi-iface/ {print $2}'); do
            [ "$(uci get wireless.$iface.device 2>/dev/null)" = "$radio" ] || continue
            [ "$(uci get wireless.$iface.mode 2>/dev/null)" = "mesh" ] || continue
            has_mesh=1
            [ "$(uci get wireless.$iface.disabled 2>/dev/null)" = "1" ] || mesh_disabled=0
        done

        if [ "$has_mesh" = "1" ] && [ "$mesh_wireless" = "Y" ] && [ "$mesh_disabled" = "0" ]; then
            tgt_ch="149"; tgt_chs=""
        else
            tgt_ch="$ap_channel"
            # 過濾掉該 radio 硬體不支援的頻道 (三頻機 phy 各有不同頻段)
            _phy=$(echo "$radio" | sed 's/radio/phy/')
            _avail=$(iw phy "$_phy" channels 2>/dev/null | grep -v disabled | grep -oE '\[([0-9]+)\]' | tr -d '[]')
            tgt_chs=""
            for _ch in $ap_channels; do
                echo "$_avail" | grep -qw "$_ch" && tgt_chs="$tgt_chs $_ch"
            done
            tgt_chs=$(echo "$tgt_chs" | sed 's/^ //')
            # 如果指定頻段全不支援，改用非 DFS 可用頻道 (36 40 44 48 149 153 157 161 165)
            if [ -z "$tgt_chs" ]; then
                for _ch in 36 40 44 48 149 153 157 161 165; do
                    echo "$_avail" | grep -qw "$_ch" && tgt_chs="$tgt_chs $_ch"
                done
                tgt_chs=$(echo "$tgt_chs" | sed 's/^ //')
                log "[channel-policy] $radio 指定頻段不可用，改用硬體可用: [$tgt_chs]"
            fi
        fi

        cur_ch=$(uci get wireless.$radio.channel 2>/dev/null)
        cur_chs=$(uci get wireless.$radio.channels 2>/dev/null)

        if [ "$cur_ch" != "$tgt_ch" ]; then
            uci set wireless.$radio.channel="$tgt_ch"
            NEED_WIFI_RELOAD=1
            log "[channel-policy] $radio channel: $cur_ch -> $tgt_ch"
        fi
        if [ "$cur_chs" != "$tgt_chs" ]; then
            if [ -n "$tgt_chs" ]; then
                uci set wireless.$radio.channels="$tgt_chs"
            else
                uci delete wireless.$radio.channels 2>/dev/null
            fi
            NEED_WIFI_RELOAD=1
            log "[channel-policy] $radio channels: [$cur_chs] -> [$tgt_chs]"
        fi
    done

    [ "$NEED_WIFI_RELOAD" = "1" ] && uci commit wireless
}

# 決定 GW_TYPE (line 677 才最終定，這裡用同邏輯提早算)
if [ "$NEW_ROLE" = "gateway" ] && [ "$IS_PRIMARY" = "1" ]; then
    _GW_TYPE_FOR_CH="主gw"
elif [ "$NEW_ROLE" = "gateway" ]; then
    _GW_TYPE_FOR_CH="副gw"
else
    _GW_TYPE_FOR_CH="client"
fi
apply_5g_channel_policy "$_GW_TYPE_FOR_CH" "$WANT_WIRELESS"

[ "$NEED_WIFI_RELOAD" = "1" ] && wifi reload

# 更新當前身份
if [ "$CURRENT_ROLE" != "$NEW_ROLE" ]; then
    echo "$NEW_ROLE" > "$ACTIVE_FILE"
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
    # network restart 後主 GW 需重啟 WG/PBR (否則 VPN 斷線)
    if [ "$IS_PRIMARY" = "1" ] && [ "$NEED_WG_START" != "1" ]; then
        WG_UP=$(wg show 2>/dev/null | grep -c 'interface:')
        if [ "$WG_UP" -gt 0 ] || /etc/init.d/pbr enabled 2>/dev/null; then
            log "network restart 後重啟 WG/PBR..."
            wg_start
            /etc/init.d/pbr restart >/dev/null 2>&1
        fi
    fi
fi

# 確保 gw_mode + bandwidth(=priority) 生效 (uci set 需要 network restart 才套用，直接用 batctl 即時生效)
if [ "$NEW_ROLE" = "gateway" ]; then
    batctl gw server ${MY_PRI}MBit 2>/dev/null
else
    batctl gw client 2>/dev/null
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
FINAL_IP=""
for _iw in 1 2 3 4 5; do
    FINAL_IP=$(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1)
    [ -n "$FINAL_IP" ] && break
    sleep 2
done
FINAL_IP="${FINAL_IP:-$(uci get network.lan.ipaddr 2>/dev/null)}"
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
    echo "$GW_TYPE" > "$GWTYPE_FILE"
else
    > "$GWTYPE_FILE"
fi

# =====================
# wan6 自動管理
# =====================
# 只有主gw需要自己拉 IPv6 上游;副gw/client透過 mesh 從主gw 拿 RA,
# 自己拉 wan6 在 rename device + MAC clone 架構下會引發 netifd flap
# (ubus error: Invalid argument, 10+/sec)
if [ -n "$(uci -q get network.wan6)" ]; then
    _wan6_disabled=$(uci -q get network.wan6.disabled)
    if [ "$GW_TYPE" = "主gw" ]; then
        _wan6_want="0"
    else
        _wan6_want="1"
    fi
    # 空字串視為 0 (uci 預設啟用)
    [ -z "$_wan6_disabled" ] && _wan6_disabled="0"
    if [ "$_wan6_disabled" != "$_wan6_want" ]; then
        if [ "$_wan6_want" = "1" ]; then
            uci set network.wan6.disabled='1'
            uci commit network
            ifdown wan6 2>/dev/null
            # 殺掉殘留的 odhcp6c (netifd flap 時常遺留)
            killall -q odhcp6c 2>/dev/null
            log "wan6: disabled (${GW_TYPE}不需獨立IPv6)"
        else
            uci -q delete network.wan6.disabled
            uci commit network
            ifup wan6 2>/dev/null
            log "wan6: enabled (主gw拉IPv6上游)"
        fi
    fi
fi

# 主 gw 確立時推播 mesh 架構圖 (延遲等 batman-adv 收集鄰居)
# 觸發條件: 角色變更、主/副切換、開機首次、或架構內容與上次不同
_BOOT_FIRST=0
[ ! -f /tmp/auto-role.boot ] && _BOOT_FIRST=1 && touch /tmp/auto-role.boot
if [ "$GW_TYPE" = "主gw" ]; then
    # 是否為觸發事件 (角色變更/開機) — 決定要不要等 batman-adv 鄰居恢復
    _MESH_TRIGGER=0
    if [ "$CURRENT_ROLE" != "$NEW_ROLE" ] || [ "$PREV_GWTYPE" != "$GW_TYPE" ] || [ "$_BOOT_FIRST" = "1" ]; then
        _MESH_TRIGGER=1
        # 等待 batman-adv 鄰居恢復（切 gw_mode / wifi up 後需要時間重新發現）
        for _wait in 1 2 3 4 5 6; do
            _nc=$(batctl n 2>/dev/null | grep -c '[0-9a-f][0-9a-f]:')
            [ "$_nc" -gt 0 ] && break
            sleep 5
        done
    fi
    MY_HOSTNAME=$(cat /proc/sys/kernel/hostname)
    GWL_CACHE=$(batctl gwl 2>/dev/null | grep 'MBit')
    N_RAW=$(batctl n 2>/dev/null)
    N_CACHE=$(echo "$N_RAW" | grep '[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]')
    # 取唯一鄰居 MAC 列表
    PEER_MACS=$(echo "$N_CACHE" | awk '{for(i=1;i<=NF;i++){if($i~/^[0-9a-f][0-9a-f]:/){print $i;break}}}' | sort -u)
    if [ "$_MESH_TRIGGER" = "1" ]; then
        log "mesh-map: batctl_n_raw_lines=$(echo "$N_RAW" | wc -l) filtered_lines=$(echo "$N_CACHE" | grep -c .) peer_macs=[${PEER_MACS}]"
        log "mesh-map: batctl_n_raw: $(echo "$N_RAW" | head -5)"
        log "mesh-map: gwl_cache: $(echo "$GWL_CACHE" | head -3)"
    fi
    MESH_TMP="/tmp/mesh_map.$$"
    echo "Mesh架構:" > "$MESH_TMP"
    echo "${MY_HOSTNAME}(${FINAL_IP}) ${GW_TYPE} pri=${MY_PRI}" >> "$MESH_TMP"
    NEIGH_CACHE=$(ip neigh show dev br-lan 2>/dev/null | grep -v FAILED)
    LEASE_CACHE=$(cat /tmp/dhcp.leases 2>/dev/null)
    STATIC_HOSTS=$(uci show dhcp 2>/dev/null | grep "=host$" | cut -d'.' -f2 | cut -d'=' -f1)
    if [ "$_MESH_TRIGGER" = "1" ]; then
        log "mesh-map: neigh_cache=$(echo "$NEIGH_CACHE" | head -5)"
        log "mesh-map: lease_cache=$(echo "$LEASE_CACHE" | head -5)"
    fi
    # 用後4字節合併同一台的有線/無線 MAC
    SEEN_TAILS=""
    for mac in $PEER_MACS; do
        MAC_TAIL=$(echo "$mac" | cut -d: -f3-5)
        echo "$SEEN_TAILS" | grep -q "$MAC_TAIL" && continue
        SEEN_TAILS="$SEEN_TAILS $MAC_TAIL"
        # 連線類型: 收集同 tail 的所有 MAC 的介面
        LINKS=$(echo "$N_CACHE" | grep -i "$MAC_TAIL" | awk '{print $1}' | while read iface; do
            echo "$iface" | grep -q '^lan' && echo "有線" || echo "無線"
        done | sort -u | tr '\n' '+' | sed 's/+$//')
        # gwl priority: 同 tail 的任一 MAC 在 gwl 裡找
        PEER_PRI=$(echo "$GWL_CACHE" | grep -i "$MAC_TAIL" | head -1 | awk '{for(i=1;i<=NF;i++){if($i~/\//){split($i,bw,"/");split(bw[1],d,".");print d[1];exit}}}')
        PEER_ROLE="client"
        [ -n "$PEER_PRI" ] && PEER_ROLE="gw pri=${PEER_PRI}"
        # 1. ARP 表查 IP
        PEER_IP=$(echo "$NEIGH_CACHE" | grep -i "$MAC_TAIL" | awk '/^192\.168\.1\./{print $1}' | head -1)
        PEER_NAME=""
        [ -n "$PEER_IP" ] && PEER_NAME=$(echo "$LEASE_CACHE" | awk -v ip="$PEER_IP" '$3==ip && $4!="*"{print $4}')
        # 2. fallback: DHCP 靜態設定 (uci show dhcp host) 用 MAC_TAIL 匹配，跳過 99.x
        if [ -z "$PEER_IP" ]; then
            for _host in $STATIC_HOSTS; do
                _hmac=$(uci get dhcp.${_host}.mac 2>/dev/null | tr 'A-Z' 'a-z')
                echo "$_hmac" | grep -qi "$MAC_TAIL" || continue
                _hip=$(uci get dhcp.${_host}.ip 2>/dev/null)
                echo "$_hip" | grep -q '^192\.168\.1\.' || continue
                PEER_IP="$_hip"
                PEER_NAME=$(uci get dhcp.${_host}.name 2>/dev/null)
                break
            done
        fi
        # 3. fallback: DHCP lease 檔用 MAC_TAIL 匹配
        if [ -z "$PEER_IP" ]; then
            PEER_IP=$(echo "$LEASE_CACHE" | awk -v tail="$MAC_TAIL" 'tolower($2) ~ tolower(tail) {print $3; exit}')
            [ -n "$PEER_IP" ] && PEER_NAME=$(echo "$LEASE_CACHE" | awk -v ip="$PEER_IP" '$3==ip && $4!="*"{print $4}')
        fi
        # 組合: hostname(IP) 或 IP 或 MAC
        if [ -n "$PEER_NAME" ]; then
            PEER_LABEL="${PEER_NAME}(${PEER_IP})"
        elif [ -n "$PEER_IP" ]; then
            PEER_LABEL="$PEER_IP"
        else
            PEER_LABEL="$mac"
        fi
        [ "$_MESH_TRIGGER" = "1" ] && log "mesh-map: peer mac=$mac tail=$MAC_TAIL links=$LINKS pri=$PEER_PRI ip=$PEER_IP name=$PEER_NAME"
        # gw 排前面(1)、client 排後面(2); 同 pri 合併 key 用 pri 值
        _sort_key="2"
        _merge_key="client_${mac}"
        if [ -n "$PEER_PRI" ]; then
            _sort_key="1"
            _merge_key="gw_pri${PEER_PRI}"
        fi
        # 格式: sort_key|merge_key|LINKS|LABEL|ROLE
        echo "${_sort_key}|${_merge_key}|${LINKS}|${PEER_LABEL}|${PEER_ROLE}" >> "${MESH_TMP}.unsorted"
    done
    if [ -z "$PEER_MACS" ]; then
        log "mesh-map: ⚠️ PEER_MACS 為空，無法組建架構圖"
        echo "├─(無鄰居)" >> "$MESH_TMP"
    elif [ -f "${MESH_TMP}.unsorted" ]; then
        # 合併同 merge_key: LINKS 聯集、LABEL 取有 IP 的那筆
        awk -F'|' '
            {
                k=$2
                if (!(k in seen)) { order[++n]=k; seen[k]=1; sort_key[k]=$1; role[k]=$5 }
                split($3, parts, "+")
                for (i in parts) if (parts[i]!="" && index(links[k], parts[i])==0) {
                    links[k] = (links[k]=="" ? parts[i] : links[k]"+"parts[i])
                }
                if (label[k]=="" || ($4 ~ /^192\./ || $4 ~ /\(/) && !(label[k] ~ /^192\./ || label[k] ~ /\(/)) {
                    label[k] = $4
                }
            }
            END {
                for (i=1; i<=n; i++) { k=order[i]; print sort_key[k]"├─"links[k]"─"label[k]" "role[k] }
            }
        ' "${MESH_TMP}.unsorted" | sort | sed 's/^[12]//' >> "$MESH_TMP"
        rm -f "${MESH_TMP}.unsorted"
    fi
    # 推播判斷: 角色變更/主副切換/開機首次 → 無條件推
    # 其餘時候 → 架構內容 hash 與上次不同才推 (偵測鄰居加入/離開/連線類型變動)
    MESH_HASH=$(md5sum "$MESH_TMP" 2>/dev/null | awk '{print $1}')
    LAST_HASH=$(cat /tmp/mesh_map.hash 2>/dev/null)
    if [ "$_MESH_TRIGGER" = "1" ] || [ "$MESH_HASH" != "$LAST_HASH" ]; then
        push_notify "$(cat "$MESH_TMP")"
        echo "$MESH_HASH" > /tmp/mesh_map.hash
        [ "$_MESH_TRIGGER" = "1" ] && log "mesh-map: 推播 (角色/開機觸發)" || log "mesh-map: 推播 (架構變動)"
    fi
    rm -f "$MESH_TMP"
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
    # 主 gw: default route 必須有 via 且 dev 為 WAN 的 l3_device，否則修正
    CUR_DEF_LINE=$(ip route show default 2>/dev/null | head -1)
    CUR_DEF_DEV=$(echo "$CUR_DEF_LINE" | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1);exit}}}')
    CUR_DEF_VIA=$(echo "$CUR_DEF_LINE" | awk '{for(i=1;i<=NF;i++){if($i=="via"){print $(i+1);exit}}}')
    WAN_GW=$(ifstatus wan 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
    WAN_DEV=$(ifstatus wan 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
    if [ -n "$WAN_GW" ] && [ -n "$WAN_DEV" ] && \
       { [ "$CUR_DEF_DEV" != "$WAN_DEV" ] || [ "$CUR_DEF_VIA" != "$WAN_GW" ]; }; then
        ip route replace default via "$WAN_GW" dev "$WAN_DEV"
        log "fixup: default route ($CUR_DEF_LINE) → via $WAN_GW dev $WAN_DEV"
        FIXUP=1
    fi
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
        _FIX_UPTIME=$(awk -F. '{print $1}' /proc/uptime)
        if [ "$_FIX_UPTIME" -le 180 ]; then
            log "fixup: AGH 未運行，但開機早期 (${_FIX_UPTIME}s)，由 rc.local 延遲處理"
        elif lock_is_active "agh_startup" 300; then
            # agh_startup lock 有效 → 正在啟動中或剛被 OOM kill，不搶啟動
            log "fixup: AdGuardHome 未運行，agh_startup lock 有效，跳過"
        else
            lock_check_and_create "agh_startup" 300 >/dev/null 2>&1
            /etc/init.d/adguardhome start 2>/dev/null; log "fixup: AdGuardHome 未運行，已啟動"; FIXUP=1
        fi
    fi
else
    # 副 gw / client: WG/pbr/qosify/IOT 不該跑
    WG_UP=$(wg show 2>/dev/null | grep -c 'interface:')
    if [ "$WG_UP" -gt 0 ]; then
        wg_stop; log "fixup: WG 不應運行，已停止"; FIXUP=1
    fi
    # 確保 /var/run/pbr.dnsmasq 存在 (防 dangling symlink → dnsmasq crash)
    if [ -L /etc/dnsmasq.d/pbr ] && [ ! -f /var/run/pbr.dnsmasq ]; then
        touch /var/run/pbr.dnsmasq 2>/dev/null
        log "fixup: touch /var/run/pbr.dnsmasq (防 dnsmasq crash)"
        FIXUP=1
    fi
    # 副 gw / client: AGH 不該跑 (DNS 直接走主 GW)
    if pgrep -f adguardhome >/dev/null 2>&1; then
        svc_disable adguardhome; lock_remove "agh_startup" >/dev/null 2>&1; log "fixup: AGH 不應運行 ($GW_TYPE)，已停止"; FIXUP=1
    fi
    if [ "$(uci get dhcp.@dnsmasq[0].noresolv 2>/dev/null)" = "1" ]; then
        uci delete dhcp.@dnsmasq[0].noresolv 2>/dev/null
        uci delete dhcp.@dnsmasq[0].server 2>/dev/null
        uci commit dhcp
        /etc/init.d/dnsmasq restart
        log "fixup: dnsmasq 移除 AGH 轉發 (client)"; FIXUP=1
    fi
    IOT_IF=$(uci show wireless 2>/dev/null | grep "ssid='IOT'" | cut -d. -f2)
    if [ -n "$IOT_IF" ] && [ "$(uci get wireless.${IOT_IF}.disabled 2>/dev/null)" != "1" ]; then
        uci set wireless.${IOT_IF}.disabled='1'
        _IOT_RADIO=$(uci -q get wireless.${IOT_IF}.device)
        if [ -n "$_IOT_RADIO" ]; then
            if radio_has_other_active_iface "$_IOT_RADIO" "$IOT_IF"; then
                log "[$_IOT_RADIO] 尚有其他啟用 SSID，保留 radio"
            else
                uci set wireless.${_IOT_RADIO}.disabled='1'
            fi
        fi
        uci commit wireless
        wifi reload
        log "fixup: IOT WiFi ($IOT_IF+$_IOT_RADIO) 不應開啟，已停用"; FIXUP=1
    fi
fi
[ "$FIXUP" = "1" ] && push_notify "AutoRole fixup: $GW_TYPE $FINAL_IP 服務狀態已修正"

# =====================
# 10. usteer 確保正確註冊 hostapd
# =====================
if [ "$CHANGED" = "1" ] || [ "$NEED_RESTART_NET" = "1" ]; then
    # 主副互換或角色變更: 直接 restart (hostapd socket 已更新)
    sleep 5
    /etc/init.d/usteer restart >/dev/null 2>&1
    log "usteer restart (角色/網路變更)"
elif ! pidof usteerd >/dev/null 2>&1; then
    # usteerd process 死掉 (crash/OOM/ubus 斷線後未恢復)
    # 注意: 不用 `pgrep -x usteerd` - BusyBox 的 pgrep -x 對純字串比對不會觸發，
    #       會永遠誤判為 DEAD，導致每分鐘 false-positive restart
    /etc/init.d/usteer restart >/dev/null 2>&1
    log "fixup: usteerd 未執行，已 restart"
else
    # 常態健康檢查: local_info 沒有 AP 就 restart
    # (usteerd 存活但已從 hostapd disconnect，自己不會重連)
    _ust_ap=$(ubus call usteer local_info 2>/dev/null | grep -c 'ssid')
    if [ "$_ust_ap" -eq 0 ]; then
        /etc/init.d/usteer restart >/dev/null 2>&1
        log "fixup: usteer 無本地 AP，已 restart"
    fi
fi
