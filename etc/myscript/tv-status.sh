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
CPUS=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
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

# ---- qosify 頻寬 (電視端當流量負載的分母) ----
# ★ 讀 tc 上實際生效的 cake bandwidth, 不讀 uci 數字:
#   uci 有設不代表有套用 (副gw 的 wg0 有設定但沒有介面, 就不會有 cake),
#   qosify 沒跑時 cake 也不在 -> 自然得到 null
# 上行 = dev 本身 root cake, 下行 = ifb-<dev> 的 ingress cake
# 介面清單取 uci qosify 的 interface section (name 是 UCI 介面名, 例如 wan/wg0)
cake_bps() {
    tc qdisc show dev "$1" 2>/dev/null | awk '/ cake / {
        for (i = 1; i < NF; i++) if ($i == "bandwidth") {
            v = $(i+1); n = v + 0
            if (v ~ /Gbit$/) n *= 1000000000
            else if (v ~ /Mbit$/) n *= 1000000
            else if (v ~ /Kbit$/) n *= 1000
            else if (v !~ /bit$/) next
            printf "%.0f", n; exit
        }
    }'
}
QOS_JSON=""
if pidof qosify >/dev/null 2>&1; then
    for _s in $(uci -q show qosify | sed -n "s/^qosify\.\([^.]*\)=interface$/\1/p"); do
        [ "$(uci -q get "qosify.$_s.disabled")" = 1 ] && continue
        _n=$(uci -q get "qosify.$_s.name")
        [ -n "$_n" ] || continue
        _d=$(ubus call "network.interface.$_n" status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
        [ -n "$_d" ] || continue
        _up=$(cake_bps "$_d")
        _dn=$(cake_bps "ifb-$_d")
        [ -n "$_up$_dn" ] || continue
        QOS_JSON="${QOS_JSON:+$QOS_JSON,}$(printf '{"iface":%s,"dev":%s,"down_bps":%s,"up_bps":%s}' \
            "$(str "$_n")" "$(str "$_d")" "$(num "$_dn")" "$(num "$_up")")"
    done
fi
[ -n "$QOS_JSON" ] && QOS_JSON="[$QOS_JSON]" || QOS_JSON=null

# ---- 實體連接埠 (同 LuCI「連接埠狀態」) ----
# 清單取 /etc/board.json: wan.device + lan.ports; 不列 eth0(CPU 埠)/br-lan 等虛擬介面
# role 是 board.json 的出廠角色; attached 是執行期實際掛在哪個 master
#   (⚠️ 兩台的 lan2 都在 bat0 = batman mesh 有線, 不在 br-lan)
# ★ 迴圈內只用 read 內建 (不 fork), 最後一次 awk 組 JSON
#   —— 原本每個值都 $(readf)/$(num) 各 fork 一次, 5 個埠約 125 次, 實測讓
#      整支 CPU 時間從 0.31s 翻到 0.71s/次 (電視每 5 秒打一次 = 吃掉 .4 單核 14%)
_bw=$(jsonfilter -i /etc/board.json -e '@.network.wan.device' 2>/dev/null)
_bl=$(jsonfilter -i /etc/board.json -e '@.network.lan.ports[*]' 2>/dev/null)
PORTS_JSON=$(
    for _pd in $_bw $_bl; do
        _sd="/sys/class/net/$_pd"
        [ -d "$_sd" ] || continue
        [ "$_pd" = "$_bw" ] && _role=wan || _role=lan
        _car= _spd= _dup= _rx= _tx= _att=
        read -r _car 2>/dev/null < "$_sd/carrier"   # 介面 down 時讀取會 EINVAL -> 空
        read -r _spd 2>/dev/null < "$_sd/speed"
        read -r _dup 2>/dev/null < "$_sd/duplex"
        read -r _rx 2>/dev/null < "$_sd/statistics/rx_bytes"
        read -r _tx 2>/dev/null < "$_sd/statistics/tx_bytes"
        [ -L "$_sd/master" ] && { _att=$(readlink "$_sd/master"); _att=${_att##*/}; }
        echo "$_pd $_role ${_att:-_} ${_car:-_} ${_spd:-_} ${_dup:-_} ${_rx:-_} ${_tx:-_}"
    done | awk '
        function n(v) { return (v == "_" || v == "") ? "null" : v }
        function s(v) { return (v == "_" || v == "") ? "null" : "\"" v "\"" }
        {
            up  = ($4 == "1")
            spd = (up && $5 ~ /^[0-9]+$/) ? $5 : "_"     # 未連結時 speed 是 -1
            dup = (up && $6 != "unknown") ? $6 : "_"
            o = o (o == "" ? "" : ",") sprintf("{\"name\":\"%s\",\"role\":\"%s\",\"attached\":%s,\"up\":%s,\"speed_mbps\":%s,\"duplex\":%s,\"rx_bytes\":%s,\"tx_bytes\":%s}", \
                $1, $2, s($3), (up ? "true" : "false"), n(spd), s(dup), n($7), n($8))
        }
        END { print (o == "" ? "null" : "[" o "]") }')

# ---- 生效中的 Wi-Fi (一個 SSID 一筆) ----
# 只列 hostapd.<ifname> 存在的 = 真的在發射的 AP; disabled 或 radio 起不來的不會出現
# radio/band/hidden 由 network.wireless status 反查 (它只列啟用中的介面)
# ⚠️ AP 模式下 iwinfo 的 Signal/Bit Rate 是「連上來的 client」的值, 不是 AP 本身;
#    沒 client 時會是 0 dBm / unknown -> 一律回 null
# ★ 同連接埠: 原始資料加前綴丟給單一 awk 組 JSON, 不逐值 fork
#   MAP <ifname> <radio> <band> <hidden>   /   IF <ifname> <clients>   /   I <ifname> <iwinfo 原文>
_wst=$(ubus call network.wireless status 2>/dev/null)
_wmap=""
for _r in $(uci -q show wireless | sed -n "s/^wireless\.\([^.]*\)=wifi-device$/\1/p"); do
    _band=$(echo "$_wst" | jsonfilter -e "@.$_r.config.band" 2>/dev/null)
    _k=0
    while :; do
        _i= _s=
        eval "$(echo "$_wst" | jsonfilter -e "_i=@.$_r.interfaces[$_k].ifname" \
            -e "_s=@.$_r.interfaces[$_k].section" 2>/dev/null)"
        [ -n "$_s" ] || break
        _h=false; [ "$(uci -q get "wireless.$_s.hidden")" = 1 ] && _h=true
        [ -n "$_i" ] && _wmap="${_wmap}MAP $_i $_r ${_band:-_} $_h
"
        _k=$((_k + 1))
    done
done
WIFI_JSON=$(
    {
        printf '%s' "$_wmap"
        for _hap in $(ubus list 'hostapd.*' 2>/dev/null); do
            _wi=${_hap#hostapd.}
            echo "IF $_wi $(ubus call "$_hap" get_clients 2>/dev/null | grep -oE '"([0-9a-f]{2}:){5}[0-9a-f]{2}"' | wc -l)"
            iwinfo "$_wi" info 2>/dev/null | sed "s/^/I $_wi /"
        done
    } | awk '
        function n(v) { return (v == "") ? "null" : v }
        # SSID 的 JSON 跳脫。⚠️ busybox awk 和 gawk 行為不同, 實測只有這樣才對:
        #   /\\/ 會把 \/ 當跳脫斜線害 regex 延伸到後面 -> 用 [\\]
        #   replacement 要 8 個反斜線才得到 \\, 引號要 "\\\\\"" 才得到 \"
        function s(v) { if (v == "" || v == "_") return "null"; gsub(/[\\]/, "\\\\\\\\", v); gsub(/"/, "\\\\\"", v); return "\"" v "\"" }
        $1 == "MAP" { rd[$2] = $3; bd[$2] = $4; hd[$2] = $5; next }
        $1 == "IF"  { ord[++cnt] = $2; cl[$2] = $3; next }
        $1 == "I"   {
            w = $2; l = substr($0, length($1) + length($2) + 3)   # 保留 SSID 內的連續空白
            k = split(l, a, " ")
            if (l ~ /ESSID:/) { v = l; sub(/.*ESSID: "/, "", v); sub(/"[ \t]*$/, "", v); ss[w] = v }
            if (l ~ /Mode:/) {
                for (i = 1; i <= k; i++) {
                    # ⚠️ 這行有兩個 "Mode:" (Mode: Master ... HT Mode: HT20), 只取第一個
                    if (a[i] == "Mode:" && !(w in md)) md[w] = a[i+1]
                    if (a[i] == "Channel:") { ch[w] = a[i+1]; f = a[i+2]; gsub(/[()]/, "", f); fq[w] = sprintf("%d", f * 1000) }
                }
            }
            if (a[1] == "Signal:") { sg[w] = a[2]; nz[w] = a[5] }
            # ⚠️ 一律 sprintf %d: awk 預設 6 位有效數字, 1 Gbit 以上會變科學記號
            if (a[1] == "Bit" && a[2] == "Rate:" && a[3] != "unknown") br[w] = sprintf("%d", a[3] * 1000)
        }
        END {
            for (j = 1; j <= cnt; j++) {
                w = ord[j]
                sig = (cl[w] > 0 && sg[w] != "0") ? sg[w] : ""
                bit = (cl[w] > 0) ? br[w] : ""
                o = o (o == "" ? "" : ",") sprintf("{\"radio\":%s,\"band\":%s,\"ifname\":\"%s\",\"ssid\":%s,\"hidden\":%s,\"mode\":%s,\"channel\":%s,\"freq_mhz\":%s,\"clients\":%s,\"bitrate_kbps\":%s,\"signal_dbm\":%s,\"noise_dbm\":%s}", \
                    s(rd[w]), s(bd[w]), w, s(ss[w]), (w in hd ? hd[w] : "null"), s(md[w]), \
                    n(ch[w]), n(fq[w]), n(cl[w]), n(bit), n(sig), n(nz[w]))
            }
            print (o == "" ? "null" : "[" o "]")
        }')

# ---- Ping (check-pbr-wg.sh 旁路留下的 /tmp/tv-ping/<iface>) ----
# 格式 "<epoch> <avg_ms|null> <loss%|null>"; 經該介面 ping 8.8.8.8 (端到端出口延遲)
# 只有 check-pbr-wg 健檢會 ping 的介面才有 (wg3/wg8ts/wg0 未被 flap 鎖時), 其餘回 null
# ⚠️ 只信主gw: 副gw 不跑 check-pbr-wg, 但 /tmp/tv-ping 會留著當主gw 時的舊檔
tvp_read() {
    TVP_TS= TVP_MS= TVP_LOSS=
    [ "$ROLE" = main ] && [ -f "/tmp/tv-ping/$1" ] || return 0
    read TVP_TS TVP_MS TVP_LOSS < "/tmp/tv-ping/$1" 2>/dev/null
    return 0
}
PING_JSON=null
tvp_read wan
[ -n "$TVP_TS" ] && PING_JSON=$(printf '[{"target":"8.8.8.8","iface":"wan","ms":%s,"loss":%s,"ping_ts":%s}]' \
    "$(num "$TVP_MS")" "$(num "$TVP_LOSS")" "$(num "$TVP_TS")")

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
    tvp_read "$_i"
    _p=$(printf '"ping_ms":%s,"ping_loss":%s,"ping_ts":%s' \
        "$(num "$TVP_MS")" "$(num "$TVP_LOSS")" "$(num "$TVP_TS")")
    if [ -n "$_stat" ]; then
        set -- $_stat
        _o=$(printf '{"name":"%s","up":%s,"handshake_age":%s,"peers":%s,"peers_active":%s,"rx_bytes":%s,"tx_bytes":%s,%s}' \
            "$_i" "$_up" "$(num "$2")" "$(num "$1")" "$(num "$3")" "$(num "$4")" "$(num "$5")" "$_p")
    else
        _o=$(printf '{"name":"%s","up":%s,"handshake_age":null,"peers":null,"peers_active":null,"rx_bytes":null,"tx_bytes":null,%s}' \
            "$_i" "$_up" "$_p")
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
printf '{"v":1,"ts":%s,"host":%s,"role":%s,"uptime":%s,"cpus":%s,"load":%s,' \
    "$(num "$NOW")" "$(str "$HOST")" "$(str "$ROLE")" "$(num "$UPTIME")" "$(num "$CPUS")" "$LOAD"
printf '"mem_total":%s,"mem_available":%s,"cpu_temp_c":%s,' \
    "$(num "$MEM_TOTAL")" "$(num "$MEM_AVAIL")" "$(num "$CPU_TEMP")"
printf '"conntrack":{"count":%s,"max":%s},"dhcp_clients":%s,' \
    "$(num "$CT_COUNT")" "$(num "$CT_MAX")" "$(num "$DHCP_CLIENTS")"
printf '"wan":%s,"wan6":%s,"wan_dev":%s,"wan_rx_bytes":%s,"wan_tx_bytes":%s,' \
    "$WAN_JSON" "$WAN6_JSON" "$(str "$WAN_DEV")" "$(num "$WAN_RX")" "$(num "$WAN_TX")"
printf '"ports":%s,"wifi":%s,' "$PORTS_JSON" "$WIFI_JSON"
printf '"qosify":%s,"ping":%s,"wg":[%s],"tailscale":%s}\n' "$QOS_JSON" "$PING_JSON" "$WG_JSON" "$TS_JSON"
