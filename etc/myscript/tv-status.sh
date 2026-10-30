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
# 同上但「就地」改寫變數 (傳變數名), 不開子行程 —— $(num ...) 每次都要 fork 一次,
# 輸出段幾十個欄位累積起來很可觀 (2026-10-28 剖析)
jnum() { for _jv; do eval "_jx=\${$_jv}"; case "$_jx" in ''|-|*[!0-9.-]*) eval "$_jv=null" ;; esac; done; }
jbool() {
    for _jv; do
        eval "_jx=\${$_jv}"
        case "$_jx" in true|1) _jx=true ;; false|0) _jx=false ;; *) _jx=null ;; esac
        eval "$_jv=\$_jx"
    done
}
_CR=$(printf '\r')
jstr() {
    for _jv; do
        eval "_jx=\${$_jv}"
        case "$_jx" in *[\"\\]*|*"$_CR"*) _jx=$(printf '%s' "$_jx" | tr -d '"\\\r\n') ;; esac
        [ -n "$_jx" ] && _jx="\"$_jx\"" || _jx=null
        eval "$_jv=\$_jx"
    done
}

# 慢變欄位的快取 (qosify/Tailscale/Wi-Fi 對照表): 檔案內容 "<epoch> <值>" 單行
# cache_get <檔> <秒數>: 還新鮮就把值放進 _CV 並回 0
cache_get() {
    _ct= _CV=
    read -r _ct _CV 2>/dev/null < "$1"
    case "$_ct" in ''|*[!0-9]*) _CV=; return 1 ;; esac
    [ -n "$_CV" ] && [ $((NOW - _ct)) -ge 0 ] && [ $((NOW - _ct)) -lt "$2" ] && return 0
    _CV=
    return 1
}
cache_put() { echo "$NOW $2" > "$1.$$" 2>/dev/null && mv -f "$1.$$" "$1" 2>/dev/null; }

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

# ---- 本機 AP 的 client 清單 (給主gw 彙整全屋 wifi_mesh 用) ----
# 輸出純文字:  H <hostname>  /  S <mac_hash> <inactive_ms> <band> <ssid...>
# ★ 只列 authorized 的 station; inactive 用來在漫遊重複時判斷「現在在哪台」
# ★ MAC 只回 md5 前 12 碼(跨節點去重用), 不回原始 MAC
tv_stations() {
    echo "H $(cat /proc/sys/kernel/hostname 2>/dev/null)"
    for _hap in $(ubus list 'hostapd.*' 2>/dev/null); do
        _wi=${_hap#hostapd.}
        iw dev "$_wi" info 2>/dev/null | sed "s/^/I $_wi /"
        iw dev "$_wi" station dump 2>/dev/null | sed "s/^/S $_wi /"
    done | awk '
        function flush() { if (m != "" && au == "yes") print m, (in_ == "" ? 0 : in_), (bd[w] == "" ? "_" : bd[w]), (ss[w] == "" ? "_" : ss[w]); m = ""; au = ""; in_ = "" }
        $1 == "I" && $3 == "ssid" { v = $0; sub(/^I [^ ]+ [ \t]*ssid /, "", v); ss[$2] = v; next }
        $1 == "I" && $3 == "channel" { f = $5; gsub(/[()]/, "", f); f += 0
            if (!($2 in ch)) ord[++na] = $2
            ch[$2] = $4; bd[$2] = (f < 3000) ? "2g" : (f < 5925) ? "5g" : "6g"; next }
        $1 == "S" && $3 == "Station" { flush(); w = $2; m = $4; next }
        $1 == "S" && $3 == "inactive" { in_ = $5 + 0; next }
        $1 == "S" && $3 == "authorized:" { au = $4; next }
        # A <band> <channel> <ssid...>: 每個發射中的 AP 一行(沒 client 也列), 給 by_ssid.channels
        END { flush(); for (j = 1; j <= na; j++) { w = ord[j]; print "A", bd[w], ch[w], (ss[w] == "" ? "_" : ss[w]) } }' |
    while read -r _t _m _rest; do
        case "$_t" in
            A) echo "A $_m $_rest" ;;
            *) echo "S $(printf '%s' "$_t" | md5sum | cut -c1-12) $_m $_rest" ;;
        esac
    done
}
case "$QUERY_STRING" in
    *stations*)
        printf 'Content-Type: text/plain\r\n'; hdr; printf '\r\n'
        [ "$REQUEST_METHOD" = HEAD ] || tv_stations
        exit 0 ;;
esac

NOW=$(date +%s)

# ---- 改隧道用的 GAS 網址 (只給帶對 token 的電視) ----
# ?token=<tv token> 與 /etc/myscript/.secrets/tv.token 相符才回 gas_url, 否則 null
# ★ 只回 exec 網址本身 (去掉 ? 之後): secret.url 帶的是主 token, 能下載整份設定與寫 Index,
#   絕不能外流; 電視要另帶自己的 TV token 呼叫 GAS 的 SetTunnel (GAS 端另驗)
# ★ token 只接受 [A-Za-z0-9_-], 不做 URL decode; .secrets/ 在 .gitignore, 不進 git
GAS_URL=null
case "&$QUERY_STRING" in
    *"&token="*)
        _qt=${QUERY_STRING#*token=}; _qt=${_qt%%&*}
        _tt=
        read -r _tt 2>/dev/null < /etc/myscript/.secrets/tv.token
        case "$_qt" in ''|*[!A-Za-z0-9_-]*) _qt= ;; esac
        if [ -n "$_qt" ] && [ -n "$_tt" ] && [ "$_qt" = "$_tt" ]; then
            _gu=
            read -r _gu 2>/dev/null < /etc/myscript/.secrets/secret.url
            _gu=${_gu%%\?*}
            case "$_gu" in https://script.google.com/macros/s/*/exec) GAS_URL="\"$_gu\"" ;; esac
        fi
        ;;
esac

# ---- 系統 ----
# ★ 單行檔一律用 read 內建讀, 不 cat/awk (每個 fork 在 a53 上約數 ms)
#   ⚠️ 例外: /proc/sys 的整數檔 (見下方 conntrack 註解)
HOST= _gw= UPTIME= _l1= _l2= _l3=
read -r HOST 2>/dev/null < /proc/sys/kernel/hostname
read -r _gw 2>/dev/null < /etc/myscript/.mesh_gw_type
case "$_gw" in
    主gw*) ROLE=main ;;
    副gw*) ROLE=sub ;;
    *) ROLE="" ;;
esac
read -r UPTIME _x 2>/dev/null < /proc/uptime; UPTIME=${UPTIME%.*}
read -r _l1 _l2 _l3 _x 2>/dev/null < /proc/loadavg
jnum _l1 _l2 _l3
LOAD="[$_l1,$_l2,$_l3]"
MEM_TOTAL= MEM_AVAIL=
eval "$(awk '/^MemTotal:/ {printf "MEM_TOTAL=%d\n", $2*1024} /^MemAvailable:/ {printf "MEM_AVAIL=%d\n", $2*1024}' /proc/meminfo 2>/dev/null)"
CPUS=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)

# ---- CPU 使用率 (%) = 與「上一次被呼叫時」的 /proc/stat 相減 ----
# ★ 不另開取樣服務、也不在 CGI 裡 sleep: 每次呼叫存一份快照到 /tmp,
#   下次呼叫相減; 電視每 5 秒打一次 -> 得到最近約 5 秒的全機平均使用率
# - 上一份快照超過 60 秒(電視剛打開/沒人在看) 或不存在 -> null, 下一次就有值
# - 與上一份相隔 < 2 秒(多個電視同時輪詢) -> 回上次算好的值且不覆蓋快照,
#   避免視窗太短數字亂跳
# - 純 shell 算術 + read 內建, 不 fork
# ⚠️ 數字含 tv-status 自己的 CPU 消耗 (每次約 0.4s CPU, .4 雙核每 5 秒約 4%)
CPU_PCT="" CPU_WIN=""
_cs=/tmp/tv-status.cpustat
read -r _c _u _n _s _i _w _q _sq _st _rest < /proc/stat
_ctot=$((_u + _n + _s + _i + _w + _q + _sq + _st)); _cidle=$((_i + _w))
_pt= _ptot= _pidle= _ppct=
read -r _pt _ptot _pidle _ppct 2>/dev/null < "$_cs"
if [ -n "$_pt" ] && [ $((NOW - _pt)) -lt 2 ]; then
    CPU_PCT=$_ppct
else
    if [ -n "$_pt" ] && [ $((NOW - _pt)) -le 60 ] && [ $((_ctot - _ptot)) -gt 0 ]; then
        _pm=$(( ((_ctot - _ptot) - (_cidle - _pidle)) * 1000 / (_ctot - _ptot) ))
        [ "$_pm" -lt 0 ] && _pm=0
        CPU_PCT="$((_pm / 10)).$((_pm % 10))"
        CPU_WIN=$((NOW - _pt))
    fi
    echo "$NOW $_ctot $_cidle ${CPU_PCT:-_}" > "$_cs.$$" 2>/dev/null && mv -f "$_cs.$$" "$_cs" 2>/dev/null
fi
[ "$CPU_PCT" = "_" ] && CPU_PCT=""

CPU_TEMP= _t=
read -r _t 2>/dev/null < /sys/class/thermal/thermal_zone0/temp
case "$_t" in ''|*[!0-9]*) ;; *) _t=$(( (_t + 50) / 100 )); CPU_TEMP="$((_t / 10)).$((_t % 10))" ;; esac
# ⚠️ /proc/sys 的整數檔不能用 read 內建: busybox ash 的 read 一次讀 1 byte,
#    而 proc_dointvec 在 offset≠0 時直接回 EOF -> 只讀到第一個字元
#    (2026-10-28 實測 582 讀成 5、31232 讀成 3)。用一次 cat 兩個檔
#    (/proc/uptime、loadavg 是 seq_file, sysfs、hostname 字串型都沒這問題)
CT_COUNT= CT_MAX=
set -- $(cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
[ $# -eq 2 ] && CT_COUNT=$1 CT_MAX=$2
# ⚠️ 副gw 是 dhcp.lan.ignore=1 不發 DHCP, 但 /tmp/dhcp.leases 會留著當主gw 時的舊檔
#    (實測 .4 舊檔 6 筆) -> 不發 DHCP 時回 null, 免得電視端看到假數字
DHCP_CLIENTS=""
[ "$(uci -q get dhcp.lan.ignore)" != 1 ] && [ -f /tmp/dhcp.leases ] && \
    DHCP_CLIENTS=$(grep -c . /tmp/dhcp.leases)

# ---- WAN / WAN6 (ubus network.interface.*) ----
# 結果放 IFJ: {"up":..,"uptime":..,"has_ipv4|6":..,"ipv4|6_masked":..}; IF_DEV = l3_device
# ★ 不用 $( ) 呼叫: 一次 ubus 同時拿 l3_device (原本 wan 要另外再 ubus 一次),
#   遮罩用參數展開不開 awk
iface_json() {
    IFJ=null IF_DEV=
    _st=$(ubus call "network.interface.$1" status 2>/dev/null)
    [ -n "$_st" ] || return 0
    _up= _upt= _a4= _a6= _p6= _dev=
    eval "$(jsonfilter -s "$_st" \
        -e '_up=@.up' -e '_upt=@.uptime' -e '_dev=@.l3_device' \
        -e '_a4=@["ipv4-address"][0].address' \
        -e '_a6=@["ipv6-address"][0].address' \
        -e '_p6=@["ipv6-prefix"][0].address' 2>/dev/null)"
    IF_DEV=$_dev
    jbool _up; jnum _upt
    _m=null _has=false
    if [ "$2" = 4 ]; then
        if [ -n "$_a4" ]; then _has=true; _r=${_a4#*.}; _m="\"${_a4%%.*}.${_r%%.*}.x.x\""; fi
        IFJ="{\"up\":$_up,\"uptime\":$_upt,\"has_ipv4\":$_has,\"ipv4_masked\":$_m}"
    else
        _v6=${_p6:-$_a6}
        if [ -n "$_v6" ]; then _has=true; _r=${_v6#*:}; _m="\"${_v6%%:*}:${_r%%:*}:x:x\""; fi
        IFJ="{\"up\":$_up,\"uptime\":$_upt,\"has_ipv6\":$_has,\"ipv6_masked\":$_m}"
    fi
}
iface_json wan 4;  WAN_JSON=$IFJ WAN_DEV=$IF_DEV
iface_json wan6 6; WAN6_JSON=$IFJ

WAN_RX="" WAN_TX=""
if [ -n "$WAN_DEV" ] && [ -d "/sys/class/net/$WAN_DEV" ]; then
    read -r WAN_RX 2>/dev/null < "/sys/class/net/$WAN_DEV/statistics/rx_bytes"
    read -r WAN_TX 2>/dev/null < "/sys/class/net/$WAN_DEV/statistics/tx_bytes"
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
# ★ 頻寬設定幾乎不變: 快取 60 秒 (qosify 起停/改頻寬最多晚 60 秒反映)
QOS_JSON=""
if cache_get /tmp/tv-status.qos 60; then
    QOS_JSON=$_CV
elif pidof qosify >/dev/null 2>&1; then
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
    [ -n "$QOS_JSON" ] && QOS_JSON="[$QOS_JSON]"
fi
if [ -z "$_CV" ]; then
    [ -n "$QOS_JSON" ] || QOS_JSON=null
    cache_put /tmp/tv-status.qos "$QOS_JSON"
fi

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
# ★ MAP 對照表只在 wifi reload 時會變, 每個介面要 2~3 次 jsonfilter/uci fork,
#   快取 60 秒 (/tmp/tv-status.wmap: 第一行 epoch, 其餘 MAP 行)
# ★ clients 只算 authorized (iw station dump), 和 wifi_mesh 一致;
#   hostapd get_clients 會把還沒完成驗證的也算進去 (實測 .4 Portkey 4 筆中 1 筆未驗證)
_wf=/tmp/tv-status.wmap _wt=
read -r _wt 2>/dev/null < "$_wf"
case "$_wt" in ''|*[!0-9]*) _wt=0 ;; esac
if [ $((NOW - _wt)) -lt 0 ] || [ $((NOW - _wt)) -ge 60 ]; then
    _wst=$(ubus call network.wireless status 2>/dev/null)
    {
        echo "$NOW"
        for _r in $(uci -q show wireless | sed -n "s/^wireless\.\([^.]*\)=wifi-device$/\1/p"); do
            _band=$(jsonfilter -s "$_wst" -e "@.$_r.config.band" 2>/dev/null)
            _k=0
            while :; do
                _i= _s=
                eval "$(jsonfilter -s "$_wst" -e "_i=@.$_r.interfaces[$_k].ifname" \
                    -e "_s=@.$_r.interfaces[$_k].section" 2>/dev/null)"
                [ -n "$_s" ] || break
                _h=false; [ "$(uci -q get "wireless.$_s.hidden")" = 1 ] && _h=true
                [ -n "$_i" ] && echo "MAP $_i $_r ${_band:-_} $_h"
                _k=$((_k + 1))
            done
        done
    } > "$_wf.$$" 2>/dev/null && mv -f "$_wf.$$" "$_wf" 2>/dev/null
fi
WIFI_JSON=$(
    {
        cat "$_wf" 2>/dev/null
        for _hap in $(ubus list 'hostapd.*' 2>/dev/null); do
            _wi=${_hap#hostapd.}
            echo "IF $_wi $(iw dev "$_wi" station dump 2>/dev/null | grep -c 'authorized:[[:space:]]*yes')"
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

# ---- 全屋 Wi-Fi client (只有主gw 提供) ----
# 主gw 向各節點 GET /cgi-bin/tv-status?stations, 加上本機, 依 MAC hash 去重
# ★ 不用 usteer: 實測它只看 ssid_list 裡的 Portkey(IOT 不在), remote 也只看到 .4
# ★ 節點 IP = auto-role 依 DHCP 靜態租約給副gw 的位址 (AX3000T .2/.3、RAX3000Z .4、
#   MX4200 .5、x60pro .6), 主gw 固定 .1; 本機的 br-lan IP 會自動略過
# ★ 漫遊重複: 同一 hash 出現在多台時只算一次, 歸給 inactive 最小(最近有收發)的那台
# ★ 快取 30 秒、背景更新: 電視請求不等 curl (離線節點最多卡 3 秒)
#   沒快取(開機後第一次)時這欄回 null, 下一輪就有; ts = 彙整時間
TV_MESH_NODES="192.168.1.1 192.168.1.2 192.168.1.3 192.168.1.4 192.168.1.5 192.168.1.6"
tv_mesh_refresh() {
    _d="/tmp/tv-mesh.$$"
    mkdir -p "$_d" || return
    _self=" $(ip -4 -o addr show br-lan 2>/dev/null | awk '{sub(/\/.*/, "", $4); printf "%s ", $4}')"
    tv_stations > "$_d/local" 2>/dev/null
    for _ip in $TV_MESH_NODES; do
        case "$_self" in *" $_ip "*) continue ;; esac
        curl -sf -m 3 -o "$_d/$_ip" "http://$_ip/cgi-bin/tv-status?stations" 2>/dev/null || : > "$_d/$_ip" &
    done
    wait
    _ips=$(ls "$_d" | grep -v '^local$' | tr '\n' ' ')
    for _f in "$_d"/*; do sed "s|^|${_f##*/} |" "$_f"; done | awk -v now="$NOW" -v ips="$_ips" '
        function s(v) { if (v == "" || v == "_") return "null"; gsub(/[\\]/, "\\\\\\\\", v); gsub(/"/, "\\\\\"", v); return "\"" v "\"" }
        $2 == "H" { if (!($3 in seen)) { seen[$3] = 1; nodes[++nn] = $3 }; hn[$1] = $3; next }
        # <file> A <band> <channel> <ssid...>: 該節點這個 SSID 正在發射的頻道
        $2 == "A" {
            node = hn[$1]; if (node == "") next
            v = $0; sub(/^[^ ]+ A [^ ]+ [^ ]+ /, "", v)
            k = v SUBSEP $3; if (!(k in bys)) { ko[++nk] = k; bys[k] = 0 }
            if ($4 ~ /^[0-9]+$/) chn[k, node] = $4
            next
        }
        $2 == "S" {
            h = $3; node = hn[$1]; if (node == "") next
            v = $0; sub(/^[^ ]+ S [^ ]+ [^ ]+ [^ ]+ /, "", v)
            if (!(h in best) || $4 + 0 < best[h]) { best[h] = $4 + 0; bn[h] = node; bb[h] = $5; bs[h] = v }
            next
        }
        END {
            for (f in hn) ok[f] = 1
            for (h in best) { tot++; byn[bn[h]]++; k = bs[h] SUBSEP bb[h]; if (!(k in bys)) ko[++nk] = k; bys[k]++ }
            # channels 依 by_node 的節點順序; 該節點沒發射這個 SSID 就不列
            for (j = 1; j <= nk; j++) { split(ko[j], p, SUBSEP); oc = ""
                for (i = 1; i <= nn; i++) if ((ko[j], nodes[i]) in chn)
                    oc = oc (oc == "" ? "" : ",") sprintf("{\"node\":%s,\"channel\":%d}", s(nodes[i]), chn[ko[j], nodes[i]])
                o1 = o1 (o1 == "" ? "" : ",") sprintf("{\"ssid\":%s,\"band\":%s,\"clients\":%d,\"channels\":[%s]}", s(p[1]), s(p[2]), bys[ko[j]], oc) }
            for (j = 1; j <= nn; j++)
                o2 = o2 (o2 == "" ? "" : ",") sprintf("{\"node\":%s,\"clients\":%d}", s(nodes[j]), byn[nodes[j]])
            n = split(ips, ia, " ")
            for (j = 1; j <= n; j++) if (!(ia[j] in ok))
                o3 = o3 (o3 == "" ? "" : ",") "\"" ia[j] "\""
            printf "{\"total\":%d,\"by_ssid\":[%s],\"by_node\":[%s],\"nodes_seen\":%d,\"nodes_missing\":[%s],\"ts\":%d}\n", \
                tot, o1, o2, nn, o3, now
        }' > /tmp/tv-status.mesh.tmp \
        && mv -f /tmp/tv-status.mesh.tmp /tmp/tv-status.mesh
    rm -rf "$_d"
}
MESH_JSON=null
if [ "$ROLE" = main ]; then
    _ml=
    read -r _ml 2>/dev/null < /tmp/tv-status.mesh.lock
    _mt=
    [ -s /tmp/tv-status.mesh ] && _mt=$(date -r /tmp/tv-status.mesh +%s 2>/dev/null)
    # 快取滿 30 秒且沒有進行中的更新(鎖超過 60 秒視為殘留)才觸發
    if { [ -z "$_mt" ] || [ $((NOW - _mt)) -ge 30 ]; } && { [ -z "$_ml" ] || [ $((NOW - _ml)) -ge 60 ]; }; then
        echo "$NOW" > /tmp/tv-status.mesh.lock
        ( tv_mesh_refresh; rm -f /tmp/tv-status.mesh.lock ) </dev/null >/dev/null 2>&1 &
    fi
    [ -s /tmp/tv-status.mesh ] && read -r MESH_JSON < /tmp/tv-status.mesh
fi

# ---- 流量前 10 名的 LAN 裝置 (只有主gw 提供) ----
# 來源 = conntrack 的 bytes 計數 (nf_conntrack_acct=1), 不改防火牆、不裝套件
# ★ 軟體 flow offload 不會漏算: fw4 的 flowtable 有 counter 旗標, [OFFLOAD] 的連線
#   bytes 照樣會更新 (nft list flowtables 可查)
# ★ 速率 = 每條連線和「上一次呼叫」的快照相減, 再依 MAC 加總 (同 cpu_pct 的做法)
#   新出現的連線整條算進本區間; 兩次呼叫之間就結束的短連線會漏算
# ⚠️ /proc/net/nf_conntrack 是邊走雜湊表邊輸出, 不是原子快照: 實測連讀 3 次,
#    533 條中偶爾漏 1 條或重複 1 條 -> 漏掉的下一輪會被當新連線「整條」算進去
#    (曾把一條 615MB 的舊 UDP 算成 702Mbps)。對策:
#    1. 同一次讀取重複的 key 只算一次
#    2. 上一輪有、這一輪沒讀到的連線, 帶舊值留在快照最多 2 輪 (第 4 欄 = 已漏讀次數)
#    3. 上一輪是基準快照(第一行第 2 欄 gen=0)時, 沒看過的連線算 0 不整條算
# ★ 裝置歸屬: 原始方向來源 IP 在 br-lan neigh 表(或 DHCP 租約)裡 = LAN 發起,
#   up=原始方向 bytes, down=回程 bytes; 反過來(外部連進來, 例如 port forward)則對調
#   走 wg 的連線原始來源仍是 LAN IP, 會算回那台裝置; 隧道外層封包來源是路由器自己, 不會重複算
#   IPv6 也經 neigh 表對到 MAC, 和 IPv4 合併成同一台
# ★ 看不到: 不經主gw 的流量 (LAN 內互傳、同一台 AP 底下互傳)
# ★ 快照超過 60 秒或不存在回 null; 相隔 < 2 秒回上次結果且不覆蓋快照 (多台電視同時輪詢)
TOP_JSON=null TOP_WIN=null
if [ "$ROLE" = main ]; then
    _ts=/tmp/tv-status.ctsnap _tc=/tmp/tv-status.tophosts
    _pt= _pg=
    read -r _pt _pg 2>/dev/null < "$_ts"
    if [ -n "$_pt" ] && [ $((NOW - _pt)) -lt 2 ]; then
        [ -s "$_tc" ] && { read -r TOP_WIN; read -r TOP_JSON; } < "$_tc"
    else
        _win=
        [ -n "$_pt" ] && [ $((NOW - _pt)) -le 60 ] && _win=$((NOW - _pt))
        # ★ 效能: 欄位由 sed 一次抽出(C 實作), awk 只處理固定欄位; 原本 awk 逐欄跑迴圈
        #   392 條就要 0.17s 且隨連線數線性成長, 改 sed 後約一半
        # sed 輸出 C<TAB>原始src<TAB>key<TAB>原始bytes<TAB>回程src<TAB>回程bytes
        #   key = 協定 + 原始方向 src dst + 其餘欄位(sport/dport 或 icmp type/code/id)
        #   [UNREPLIED](單向 UDP 等) 夾在中間要允許
        # 快照格式: 第一行 "<epoch> <gen>", 其餘 key<TAB>原始bytes<TAB>回程bytes<TAB>已漏讀次數
        # ⚠️ bytes 一律保留原字串寫快照: busybox awk 數字超過 6 位有效數字可能印成科學記號
        _T=$(printf '\t')
        _sx="s/^[^ ]* *[0-9]* \([^ ]*\)[^=]* src=\([^ ]*\) dst=\([^ ]*\)\(.*\) packets=[0-9]* bytes=\([0-9]*\) \(\[UNREPLIED\] \)\{0,1\}src=\([^ ]*\) .* bytes=\([0-9]*\).*/C${_T}\2${_T}\1 \2 \3\4${_T}\5${_T}\7${_T}\8/p"
        _top=$(
            {
                ip neigh show dev br-lan 2>/dev/null | sed "s/^/N${_T}/"
                sed "s/^/L${_T}/" /tmp/dhcp.leases 2>/dev/null
                [ -n "$_win" ] && sed "1d; s/^/P${_T}/" "$_ts" 2>/dev/null
                sed -n "$_sx" /proc/net/nf_conntrack 2>/dev/null
            } | awk -F"$_T" -v win="$_win" -v now="$NOW" -v gen="${_pg:-0}" -v snap="$_ts.$$" '
                BEGIN { print now, ((win == "") ? 0 : gen + 1) > snap }
                $1 == "N" { n = split($2, a, " "); for (i = 2; i < n; i++) if (a[i] == "lladdr") mac[a[1]] = a[i+1]; next }
                # 租約: <到期> <mac> <ip> <hostname> <client-id>; neigh 沒有的 IP 用租約補
                $1 == "L" { split($2, a, " "); if (a[4] != "*") nm[a[2]] = a[4]; if (!(a[3] in mac)) mac[a[3]] = a[2]; ip4[a[2]] = a[3]; next }
                $1 == "P" { pu[$2] = $3; pd[$2] = $4; pm[$2] = $5 + 0; next }
                $1 == "C" {
                    k = $3
                    if (k in cur) next
                    cur[k] = 1
                    print k "\t" $4 "\t" $6 "\t0" > snap
                    if (win == "") next
                    os = $2; rs = $5; ob = $4 + 0; rb = $6 + 0
                    if (k in pu) { d1 = (ob >= pu[k]) ? ob - pu[k] : ob; d2 = (rb >= pd[k]) ? rb - pd[k] : rb }
                    else if (gen == 0) { d1 = 0; d2 = 0 }
                    else { d1 = ob; d2 = rb }
                    if (os in mac)      { m = mac[os]; up[m] += d1; dn[m] += d2; if (os ~ /\./) ipm[m] = os }
                    else if (rs in mac) { m = mac[rs]; up[m] += d2; dn[m] += d1; if (rs ~ /\./) ipm[m] = rs }
                    next
                }
                END {
                    for (k in pu) if (!(k in cur) && pm[k] < 2) print k "\t" pu[k] "\t" pd[k] "\t" (pm[k] + 1) > snap
                    close(snap)
                    if (win == "") exit
                    # 取前 10 名 (裝置數只有幾十台, 直接選擇法)
                    for (c = 1; c <= 10; c++) {
                        best = ""; bv = 0
                        for (m in up) if (!(m in done) && up[m] + dn[m] > bv) { bv = up[m] + dn[m]; best = m }
                        if (best == "") break
                        done[best] = 1
                        ip = (best in ipm) ? ipm[best] : ((best in ip4) ? ip4[best] : "_")
                        n = (best in nm) ? nm[best] : "_"; gsub(/[^A-Za-z0-9._-]/, "", n); if (n == "") n = "_"
                        printf "%s %s %d %d %s\n", best, ip, dn[best] * 8 / win, up[best] * 8 / win, n
                    }
                }')
        [ -s "$_ts.$$" ] && mv -f "$_ts.$$" "$_ts" 2>/dev/null || rm -f "$_ts.$$"
        if [ -n "$_win" ]; then
            TOP_WIN=$_win
            _o=""
            while read -r _m _ip _dn _up _nm; do
                [ -n "$_m" ] || continue
                _h=$(printf '%s' "$_m" | md5sum | cut -c1-12)
                [ "$_nm" = _ ] && _nm=null || _nm="\"$_nm\""
                [ "$_ip" = _ ] && _ip=null || _ip="\"$_ip\""
                _o="${_o:+$_o,}{\"name\":$_nm,\"ip\":$_ip,\"mac_hash\":\"$_h\",\"down_bps\":$_dn,\"up_bps\":$_up}"
            done <<EOF
$_top
EOF
            TOP_JSON="[$_o]"
            printf '%s\n%s\n' "$TOP_WIN" "$TOP_JSON" > "$_tc.$$" 2>/dev/null && mv -f "$_tc.$$" "$_tc" 2>/dev/null
        else
            rm -f "$_tc" 2>/dev/null
        fi
    fi
fi

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
if [ -n "$TVP_TS" ]; then
    jnum TVP_MS TVP_LOSS TVP_TS
    PING_JSON="[{\"target\":\"8.8.8.8\",\"iface\":\"wan\",\"ms\":$TVP_MS,\"loss\":$TVP_LOSS,\"ping_ts\":$TVP_TS}]"
fi

# ---- WireGuard ----
# ⚠️ 介面清單從 uci 的 proto=wireguard section 列舉, 不用 `wg show interfaces`
#    —— 後者只列現存介面, 掉線的隧道會整條消失, 電視端看不出它斷了
# handshake_age = 所有 peer 中最近一次 handshake 距今秒數, 從沒握手回 null
# peers_active = 180 秒內有 handshake 的 peer 數 (wg1 這類撥入伺服器常 0)
# ★ 一次 `wg show all dump` 拿全部隧道 + 單一 awk 組 JSON (原本每條隧道
#   wg/awk/printf/num 合計約 10 次 fork, 9 條隧道 0.08s)
#   W <if> <up 0|1> <ping_ts> <ping_ms> <loss>  /  dump 的 peer 行(9 欄):
#   <if> <pubkey> <psk> <endpoint> <allowed> <handshake> <rx> <tx> <keepalive>
#   ⚠️ dump 的介面行(5 欄)含私鑰: awk 只認 9 欄的 peer 行, 且只取數字欄, 什麼都不原樣輸出
# ★ pbr / dbr: 這條隧道被 PBR(CustRule) / DBR(網域) 用到時的健檢狀態, 沒用到回 null
#   全部讀 check-pbr-wg 已寫好的狀態檔 (/tmp/check-pbr-wg/), 不另跑指令; 副gw 不跑健檢 → null
#   - pbr.rules  = <if>.custrules 行數 (pbr-cust 依 uci 重建 = Sheet 有勾選的)
#   - pbr.state  ← <if>.pingresult: up/pending=ok(pending=失敗確認中, 流量仍走隧道)
#                  down=down(已切回 WAN) down-hold=down(NO_FALLBACK, 流量卡在隧道不切 WAN)
#                  skip/無檔=unchecked(例如 wg2 撥入型, 健檢不 ping)
#   - dbr.domains = dbroute-domains.conf 裡 route_<if>_v4 的網域數
#   - dbr.state  ← <if>.dbprevresult: up=ok down=down 無檔=unchecked
#   - 兩者共用 <if>.disabled_until (FLAP 鎖): 未到期 → state=locked 並附 until
#   - raw = 原始狀態字串, 前端要細分時用
WG_JSON=$(
    {
        _sd=/tmp/check-pbr-wg
        for _i in $(uci -q show network | sed -n "s/^network\.\([^.]*\)\.proto='wireguard'$/\1/p"); do
            _f=0
            read -r _f 2>/dev/null < "/sys/class/net/$_i/flags"
            case "$_f" in ''|*[!0-9a-fx]*) _f=0 ;; esac
            tvp_read "$_i"
            _pr= _dp= _du= _nc=0
            if [ "$ROLE" = main ]; then
                read -r _pr 2>/dev/null < "$_sd/$_i.pingresult"
                read -r _dp 2>/dev/null < "$_sd/$_i.dbprevresult"
                read -r _du 2>/dev/null < "$_sd/$_i.disabled_until"
                if [ -f "$_sd/$_i.custrules" ]; then
                    while read -r _x _y; do [ -n "$_x" ] && _nc=$((_nc + 1)); done < "$_sd/$_i.custrules"
                fi
            fi
            echo "W $_i $(( _f & 1 )) ${TVP_TS:-_} ${TVP_MS:-_} ${TVP_LOSS:-_} ${_pr:-_} ${_dp:-_} ${_du:-_} $_nc"
        done
        [ "$ROLE" = main ] && sed -n 's|^nftset=/[^/]*/.*#route_\(.*\)_v4$|D \1|p' /etc/dnsmasq.d/dbroute-domains.conf 2>/dev/null
        wg show all dump 2>/dev/null
    } | awk -v now="$NOW" '
        function n(v) { return (v ~ /^-?[0-9.]+$/) ? v : "null" }
        function q(v) { return (v == "" || v == "_") ? "null" : "\"" v "\"" }
        $1 == "W" && NF == 10 { ord[++c] = $2; up[$2] = $3; ts[$2] = $4; ms[$2] = $5; ls[$2] = $6
                                pr[$2] = $7; dp[$2] = $8; du[$2] = $9; nc[$2] = $10; next }
        $1 == "D" && NF == 2 { dm[$2]++; next }
        NF == 9 {
            i = $1; np[i]++; rx[i] += $7; tx[i] += $8
            if ($6 > hs[i]) hs[i] = $6
            if ($6 > 0 && now - $6 < 180) act[i]++
        }
        END {
            for (j = 1; j <= c; j++) {
                i = ord[j]
                p = sprintf("\"ping_ms\":%s,\"ping_loss\":%s,\"ping_ts\":%s", n(ms[i]), n(ls[i]), n(ts[i]))
                lk = (du[i] ~ /^[0-9]+$/ && du[i] + 0 > now)
                ul = lk ? sprintf(",\"until\":%d", du[i]) : ""
                pb = "null"
                if (nc[i] > 0) {
                    st = lk ? "locked" : (pr[i] == "up" || pr[i] == "pending") ? "ok" : (pr[i] == "down" || pr[i] == "down-hold") ? "down" : "unchecked"
                    pb = sprintf("{\"used\":true,\"rules\":%d,\"state\":\"%s\",\"raw\":%s%s}", nc[i], st, q(pr[i]), ul)
                }
                db = "null"
                if (dm[i] > 0) {
                    st = lk ? "locked" : (dp[i] == "up") ? "ok" : (dp[i] == "down") ? "down" : "unchecked"
                    db = sprintf("{\"used\":true,\"domains\":%d,\"state\":\"%s\",\"raw\":%s%s}", dm[i], st, q(dp[i]), ul)
                }
                p = p ",\"pbr\":" pb ",\"dbr\":" db
                if (up[i] == 1)
                    s = sprintf("{\"name\":\"%s\",\"up\":true,\"handshake_age\":%s,\"peers\":%d,\"peers_active\":%d,\"rx_bytes\":%.0f,\"tx_bytes\":%.0f,%s}", \
                        i, (hs[i] > 0) ? sprintf("%d", now - hs[i]) : "null", np[i], act[i], rx[i], tx[i], p)
                else
                    s = sprintf("{\"name\":\"%s\",\"up\":false,\"handshake_age\":null,\"peers\":null,\"peers_active\":null,\"rx_bytes\":null,\"tx_bytes\":null,%s}", i, p)
                o = o (o == "" ? "" : ",") s
            }
            print o
        }')

# ---- Tailscale ----
# ★ `tailscale status --json` 是 Go 程式且輸出大, 狀態變化慢: 快取 30 秒
TS_JSON=null
if cache_get /tmp/tv-status.ts 30; then
    TS_JSON=$_CV
else
    if command -v tailscale >/dev/null 2>&1; then
        _ts=$(run_limited 3 tailscale status --json)
        if [ -n "$_ts" ]; then
            _state= _online=
            eval "$(jsonfilter -s "$_ts" -e '_state=@.BackendState' -e '_online=@.Self.Online' 2>/dev/null)"
            set -- $(jsonfilter -s "$_ts" -e '@.Peer[*].Online' 2>/dev/null | awk '{ t++ } $0 == "true" { o++ } END { print t + 0, o + 0 }')
            _ptot=$1 _pon=$2
            jstr _state; jbool _online; jnum _pon _ptot
            TS_JSON="{\"state\":$_state,\"online\":$_online,\"peers_online\":$_pon,\"peers_total\":$_ptot}"
        fi
    fi
    cache_put /tmp/tv-status.ts "$TS_JSON"
fi

# ---- 輸出 ----
printf 'Content-Type: application/json\r\n'; hdr; printf '\r\n'
[ "$REQUEST_METHOD" = HEAD ] && exit 0
_ts_now=$NOW _role=$ROLE _wdev=$WAN_DEV
jnum _ts_now UPTIME CPUS CPU_PCT CPU_WIN MEM_TOTAL MEM_AVAIL CPU_TEMP CT_COUNT CT_MAX DHCP_CLIENTS WAN_RX WAN_TX
jstr HOST _role _wdev
printf '{"v":1,"ts":%s,"host":%s,"role":%s,"uptime":%s,"cpus":%s,"cpu_pct":%s,"cpu_pct_window_s":%s,"load":%s,' \
    "$_ts_now" "$HOST" "$_role" "$UPTIME" "$CPUS" "$CPU_PCT" "$CPU_WIN" "$LOAD"
printf '"mem_total":%s,"mem_available":%s,"cpu_temp_c":%s,' "$MEM_TOTAL" "$MEM_AVAIL" "$CPU_TEMP"
printf '"conntrack":{"count":%s,"max":%s},"dhcp_clients":%s,' "$CT_COUNT" "$CT_MAX" "$DHCP_CLIENTS"
printf '"wan":%s,"wan6":%s,"wan_dev":%s,"wan_rx_bytes":%s,"wan_tx_bytes":%s,' \
    "$WAN_JSON" "$WAN6_JSON" "$_wdev" "$WAN_RX" "$WAN_TX"
printf '"ports":%s,"wifi":%s,"wifi_mesh":%s,' "$PORTS_JSON" "$WIFI_JSON" "$MESH_JSON"
printf '"top_hosts":%s,"top_hosts_window_s":%s,' "$TOP_JSON" "$TOP_WIN"
printf '"qosify":%s,"ping":%s,"wg":[%s],"tailscale":%s,"gas_url":%s}\n' "$QOS_JSON" "$PING_JSON" "$WG_JSON" "$TS_JSON" "$GAS_URL"
