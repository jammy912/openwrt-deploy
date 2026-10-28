#!/bin/sh
# =====================================================================
# tv-status.sh — 唯讀狀態 JSON (給 LG webOS 電視 App 輪詢)
#
# 掛法: /www/cgi-bin/tv-status -> /etc/myscript/tv-status.sh (deploy.sh 建 symlink)
#       URL = http://192.168.1.1/cgi-bin/tv-status, 電視端每 5 秒 GET 一次
#       命令列直接跑也可以 (REQUEST_METHOD 空 = 當 GET 處理), 方便除錯
#
# ★ 無認證, LAN 上任何人都讀得到 -> 只回不敏感的欄位:
#   - 不回 wg 公鑰/endpoint (wg dump 第一行含私鑰, 只取 peer 行的數字欄)
#   - WAN IP 只回前兩段 (180.218.x.x), IPv6 只回前 2 個 hextet
# ★ 任一項讀不到只把該欄回 null, 整體仍是 200 + 合法 JSON
# ★ schema 版本 v=1; 改欄位語意要升版, 電視端靠它判斷
#
# 欄位單位: 時間一律秒/epoch, 流量一律 bytes, 記憶體 bytes, 溫度 °C
# =====================================================================

hdr() {
    printf 'Access-Control-Allow-Origin: *\r\n'
    printf 'Access-Control-Allow-Methods: GET, OPTIONS\r\n'
    printf 'Cache-Control: no-store\r\n'
}

case "$REQUEST_METHOD" in
    ""|GET|HEAD) ;;
    OPTIONS)
        printf 'Status: 204 No Content\r\n'; hdr; printf '\r\n'; exit 0 ;;
    *)
        printf 'Status: 405 Method Not Allowed\r\n'; hdr; printf '\r\n'; exit 0 ;;
esac

# ---- JSON 小工具: 空值/非數字一律 null, 字串剝掉引號反斜線 ----
num() {
    case "$1" in
        ''|-|*[!0-9.-]*) echo null ;;
        *) echo "$1" ;;
    esac
}
str() {
    _s=$(printf '%s' "$1" | tr -d '"\\\r\n')
    [ -n "$_s" ] && printf '"%s"' "$_s" || echo null
}
bool() {
    case "$1" in
        true|1) echo true ;;
        false|0) echo false ;;
        *) echo null ;;
    esac
}
readf() { cat "$1" 2>/dev/null; }

# 跑有可能卡住的外部指令, 超過 $1 秒就砍掉回空 (busybox 沒有 timeout)
TMPF="/tmp/tv-status.$$"
run_limited() {
    _t=$1; shift
    "$@" > "$TMPF" 2>/dev/null &
    _p=$!
    # ⚠️ 看門狗必須斷開 stdout: 否則 sleep 繼承 $( ) 的 pipe,
    #    命令替換要等 sleep 結束才拿到 EOF -> 每次固定多卡 $_t 秒 (實測 3.2s/次)
    ( sleep "$_t"; kill "$_p" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
    _k=$!
    wait "$_p" 2>/dev/null
    kill "$_k" 2>/dev/null
    cat "$TMPF" 2>/dev/null
    rm -f "$TMPF"
}

NOW=$(date +%s)

# ---- 系統 ----
HOST=$(readf /proc/sys/kernel/hostname)
case "$(readf /etc/myscript/.mesh_gw_type)" in
    主gw*) ROLE=main ;;
    副gw*) ROLE=sub ;;
    *) ROLE="" ;;
esac
UPTIME=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)
set -- $(readf /proc/loadavg)
LOAD="[$(num "$1"),$(num "$2"),$(num "$3")]"
MEM_TOTAL=$(awk '/^MemTotal:/ {printf "%d", $2*1024}' /proc/meminfo 2>/dev/null)
MEM_AVAIL=$(awk '/^MemAvailable:/ {printf "%d", $2*1024}' /proc/meminfo 2>/dev/null)
CPU_TEMP=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
CT_COUNT=$(readf /proc/sys/net/netfilter/nf_conntrack_count)
CT_MAX=$(readf /proc/sys/net/netfilter/nf_conntrack_max)
# ⚠️ 副gw 是 dhcp.lan.ignore=1 不發 DHCP, 但 /tmp/dhcp.leases 會留著當主gw 時的舊檔
#    (實測 .4 舊檔 6 筆) -> 不發 DHCP 時回 null, 免得電視端看到假數字
DHCP_CLIENTS=""
[ "$(uci -q get dhcp.lan.ignore)" != 1 ] && [ -f /tmp/dhcp.leases ] && \
    DHCP_CLIENTS=$(grep -c . /tmp/dhcp.leases)

# ---- WAN / WAN6 (ubus network.interface.*) ----
# 回傳: {"up":..,"uptime":..,"has_ipv4|6":..,"ipv4|6_masked":..}
iface_json() {
    _st=$(ubus call "network.interface.$1" status 2>/dev/null)
    if [ -z "$_st" ]; then echo null; return; fi
    _up= _upt= _a4= _a6= _p6=
    eval "$(echo "$_st" | jsonfilter \
        -e '_up=@.up' -e '_upt=@.uptime' \
        -e '_a4=@["ipv4-address"][0].address' \
        -e '_a6=@["ipv6-address"][0].address' \
        -e '_p6=@["ipv6-prefix"][0].address' 2>/dev/null)"
    if [ "$2" = 4 ]; then
        _m=""
        [ -n "$_a4" ] && _m=$(echo "$_a4" | awk -F. '{print $1"."$2".x.x"}')
        _has=false; [ -n "$_a4" ] && _has=true
        printf '{"up":%s,"uptime":%s,"has_ipv4":%s,"ipv4_masked":%s}' \
            "$(bool "$_up")" "$(num "$_upt")" "$_has" "$(str "$_m")"
    else
        _v6=${_p6:-$_a6}
        _m=""
        [ -n "$_v6" ] && _m=$(echo "$_v6" | awk -F: '{print $1":"$2":x:x"}')
        _has=false; [ -n "$_v6" ] && _has=true
        printf '{"up":%s,"uptime":%s,"has_ipv6":%s,"ipv6_masked":%s}' \
            "$(bool "$_up")" "$(num "$_upt")" "$_has" "$(str "$_m")"
    fi
}
WAN_JSON=$(iface_json wan 4)
WAN_DEV=$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
WAN6_JSON=$(iface_json wan6 6)

WAN_RX="" WAN_TX=""
if [ -n "$WAN_DEV" ] && [ -d "/sys/class/net/$WAN_DEV" ]; then
    WAN_RX=$(readf "/sys/class/net/$WAN_DEV/statistics/rx_bytes")
    WAN_TX=$(readf "/sys/class/net/$WAN_DEV/statistics/tx_bytes")
fi

# ---- WireGuard ----
# ⚠️ 介面清單從 uci 的 proto=wireguard section 列舉, 不用 `wg show interfaces`
#    —— 後者只列現存介面, 掉線的隧道會整條消失, 電視端看不出它斷了
# handshake_age = 所有 peer 中最近一次 handshake 距今秒數, 從沒握手回 null
# peers_active = 180 秒內有 handshake 的 peer 數 (wg1 這類撥入伺服器常 0)
WG_JSON=""
for _i in $(uci -q show network | sed -n "s/^network\.\([^.]*\)\.proto='wireguard'$/\1/p"); do
    _up=false
    if [ -r "/sys/class/net/$_i/flags" ]; then
        [ $(( $(cat "/sys/class/net/$_i/flags") & 1 )) -eq 1 ] && _up=true
    fi
    _stat=""
    [ "$_up" = true ] && _stat=$(wg show "$_i" dump 2>/dev/null | awk -v now="$NOW" '
        NR > 1 {
            n++; rx += $6; tx += $7
            if ($5 > hs) hs = $5
            if ($5 > 0 && now - $5 < 180) act++
        }
        END {
            age = (hs > 0) ? now - hs : "null"
            printf "%d %s %d %.0f %.0f", n, age, act, rx, tx
        }')
    if [ -n "$_stat" ]; then
        set -- $_stat
        _o=$(printf '{"name":"%s","up":%s,"handshake_age":%s,"peers":%s,"peers_active":%s,"rx_bytes":%s,"tx_bytes":%s}' \
            "$_i" "$_up" "$(num "$2")" "$(num "$1")" "$(num "$3")" "$(num "$4")" "$(num "$5")")
    else
        _o=$(printf '{"name":"%s","up":%s,"handshake_age":null,"peers":null,"peers_active":null,"rx_bytes":null,"tx_bytes":null}' \
            "$_i" "$_up")
    fi
    WG_JSON="${WG_JSON:+$WG_JSON,}$_o"
done

# ---- Tailscale ----
TS_JSON=null
if command -v tailscale >/dev/null 2>&1; then
    _ts=$(run_limited 3 tailscale status --json)
    if [ -n "$_ts" ]; then
        _state=$(echo "$_ts" | jsonfilter -e '@.BackendState' 2>/dev/null)
        _online=$(echo "$_ts" | jsonfilter -e '@.Self.Online' 2>/dev/null)
        _peers=$(echo "$_ts" | jsonfilter -e '@.Peer[*].Online' 2>/dev/null)
        _ptot=$(echo "$_peers" | grep -c .)
        _pon=$(echo "$_peers" | grep -c '^true$')
        TS_JSON=$(printf '{"state":%s,"online":%s,"peers_online":%s,"peers_total":%s}' \
            "$(str "$_state")" "$(bool "$_online")" "$(num "$_pon")" "$(num "$_ptot")")
    fi
fi

# ---- 輸出 ----
printf 'Content-Type: application/json\r\n'; hdr; printf '\r\n'
[ "$REQUEST_METHOD" = HEAD ] && exit 0
printf '{"v":1,"ts":%s,"host":%s,"role":%s,"uptime":%s,"load":%s,' \
    "$(num "$NOW")" "$(str "$HOST")" "$(str "$ROLE")" "$(num "$UPTIME")" "$LOAD"
printf '"mem_total":%s,"mem_available":%s,"cpu_temp_c":%s,' \
    "$(num "$MEM_TOTAL")" "$(num "$MEM_AVAIL")" "$(num "$CPU_TEMP")"
printf '"conntrack":{"count":%s,"max":%s},"dhcp_clients":%s,' \
    "$(num "$CT_COUNT")" "$(num "$CT_MAX")" "$(num "$DHCP_CLIENTS")"
printf '"wan":%s,"wan6":%s,"wan_dev":%s,"wan_rx_bytes":%s,"wan_tx_bytes":%s,' \
    "$WAN_JSON" "$WAN6_JSON" "$(str "$WAN_DEV")" "$(num "$WAN_RX")" "$(num "$WAN_TX")"
printf '"wg":[%s],"tailscale":%s}\n' "$WG_JSON" "$TS_JSON"
