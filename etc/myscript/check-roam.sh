#!/bin/sh
# =====================================================================
# check-roam.sh — 監控指定 client 在 AP 之間的漫遊, 切換時推播
#
# 用法: check-roam.sh <IP|名稱樣式> [...]
#   例: check-roam.sh 192.168.1.10          # 指定 IP
#       check-roam.sh Phone                  # 所有名稱含 Phone 的(自動展開)
#       check-roam.sh Phone Pad 192.168.1.87 # 可混用
#   ★ 名稱樣式會即時查 DHCP 租約展開, 所以新手機加入後不必改 cron。
#
# 推播內容: 從哪台切到哪台 + 訊號(只報「有沒有切換」, 不含 ping)
#
# ★ 判斷「現在關聯在哪台 AP」的方法(實測 2026-09-11 才確定):
#   usteer 的 ubus 介面會同時回報本機與遠端節點, 例如同一個 MAC 底下有:
#       "hostapd.phy1-ap0"              (本機)
#       "192.168.1.4#hostapd.phy1-ap0"  (遠端節點)
#   ⚠️ 但漫遊後「兩邊的 connected 都會是 true」(舊的關聯尚未被清掉),
#      所以 **不能只看 connected**, 會一直誤判成在切換。
#   ★ 正解: 用 iw 的 inactive time 決勝 —— 真正的關聯 inactive 很低。
#     實測同一支手機: .4 的 inactive=460ms(真), .1 的 inactive=20000ms(殘留)。
#     usteer 的 signal 可當輔助佐證(-50 vs -56)。
#
# ⚠️ 不要用 iwinfo / iw scan 取資料: 5G 跑 HE160 時 off-channel scan 會失敗,
#    iw 回 "Resource busy(-16)", 而 iwinfo 會**無限卡住**(實測卡 15 分鐘以上,
#    還會擋住後續所有 iw 呼叫)。詳見 push-wifistatus.sh 的眉角三。
#
# ⚠️ 每輪要夠快才能縮短間隔: 拿掉 ping 後一輪只剩 ubus+iw 約 0.1 秒,
#    因此 --loop 5(每 5 秒一次)完全跑得動。
# =====================================================================

# ---- 常駐模式: --loop <秒> ----
# ★ cron 最快只能「每分鐘」一次, 而漫遊是秒級事件。要 10 秒偵測一次就得常駐。
# ⚠️ 常駐模式「不取 cron_global_lock」: 那把鎖是給每分鐘的排程排隊用的,
#    每 10 秒去搶一次會跟其他所有 cron 工作打架。常駐只用自己的 LOCK。
LOOP=0
if [ "$1" = "--loop" ]; then
    LOOP="${2:-10}"; shift 2
fi

LOCK="/tmp/check-roam.lock"
if [ -f "$LOCK" ]; then
    kill -0 "$(cat "$LOCK")" 2>/dev/null && exit 0
    rm -f "$LOCK"
fi
echo $$ > "$LOCK"

if [ "$LOOP" = "0" ]; then
    trap 'rm -f "$LOCK" /tmp/cron_global.lock' EXIT
    # 單次模式(cron 用): 照慣例排隊, 避免與其他 cron 工作撞在一起
    . /etc/myscript/lock-handler.sh
    cron_global_lock 60 || exit 0
else
    trap 'rm -f "$LOCK"' EXIT INT TERM
fi

# ---- 沒有 usteer 的機器安靜跳過(機隊防護) ----
# ⚠️ 這支 cron 可能下發給整個機隊, 沒跑 usteer 的機器要安靜退出不洗 log。
ubus list 2>/dev/null | grep -qx usteer || exit 0

. /etc/myscript/push-notify.inc
PUSH_NAMES="${PUSH_NAMES:-admin}"

# ★ 狀態檔放 /tmp(tmpfs)不放 /etc/myscript(flash):
#   這裡存的只是「上次判定在哪台 AP」, 屬純執行期資料 —— 重開機後第一輪
#   (5 秒內)就會重建, 完全不需要持久化。
#   ⚠️ 反之放 flash 會被高頻改寫: 常駐每 5 秒一輪 = 最多 17280 次/天,
#      即使只在有變化時才寫, 漫遊頻繁時仍遠高於其他每分鐘一次的腳本。
#   ⚠️ 副作用(刻意接受): 重開機後狀態歸零, 第一次判定因為沒有 _prev
#      而不推播(見下方比對邏輯), 所以開機後的第一次漫遊不會通知。
STATEDIR="/tmp/.roam"
mkdir -p "$STATEDIR" 2>/dev/null

LOGTAG="check-roam"
log() { echo "$1"; logger -t "$LOGTAG" "$1"; }

[ $# -eq 0 ] && { echo "用法: $0 <IP> [IP2 ...]"; exit 1; }

# IP -> MAC (查 DHCP 租約)
ip2mac() {
    awk -v ip="$1" '$3==ip{print $2; exit}' /tmp/dhcp.leases 2>/dev/null
}
# MAC -> 裝置名
mac2name() {
    awk -v m="$1" '$2==m{print $4; exit}' /tmp/dhcp.leases 2>/dev/null
}

# 取該 MAC 在本機各介面的 inactive time(毫秒); 找不到回空
local_inactive() {
    _m="$1"
    for _if in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
        _v=$(iw dev "$_if" station get "$_m" 2>/dev/null \
             | awk '/inactive time:/{print $3; exit}')
        [ -n "$_v" ] && { echo "$_v"; return; }
    done
}

# (原本會附上切換前後的 ping 值, 已移除: 只要知道「有沒有切換」。
#  ★ ping 是每輪最慢的部分(5 次 x 3 台約 15 秒), 拿掉後一輪只剩 ubus+iw
#    約 0.1 秒, 才能做到 5 秒偵測一次。
#  ⚠️ 而且不是每台都 ping 得到 —— 實測 Phone_Yiting 100% 遺失, 那串
#     "5 packets transmitted, 0 packets received" 會被當成 ping 值推播出去。)

# ---- 參數展開: 名稱樣式 -> 實際 IP ----
# ★ 非 IP 格式的參數當成「名稱樣式」, 即時查 DHCP 租約展開成所有符合的 IP。
#   這樣新手機加入後不必改 cron(例: 傳 Phone 就涵蓋 Phone_Jammy/Yiting/HTC...)。
# ⚠️ 只展開「目前有租約」的裝置; 沒上線的(如 uci 靜態設定裡的 Phone_Nana)
#    不會出現, 這是刻意的 —— 沒關聯的裝置本來就無從判斷漫遊。

while :; do

# ★ 目標展開放在迴圈「內」: DHCP 租約會變(新手機加入、租約更新),
#   每輪重新展開才抓得到新裝置。
_TARGETS=""
for _a in "$@"; do
    case "$_a" in
        # 看起來像 IPv4 就直接用
        [0-9]*.[0-9]*.[0-9]*.[0-9]*)
            _TARGETS="$_TARGETS $_a"
            ;;
        *)
            _m=$(awk -v p="$_a" 'tolower($4) ~ tolower(p) {print $3}' /tmp/dhcp.leases 2>/dev/null)
            [ -z "$_m" ] && log "樣式 '$_a' 在 DHCP 租約中找不到符合的裝置"
            _TARGETS="$_TARGETS $_m"
            ;;
    esac
done

for _ip in $_TARGETS; do
    _mac=$(ip2mac "$_ip")
    [ -z "$_mac" ] && { log "找不到 $_ip 的 MAC(不在 DHCP 租約)"; continue; }
    _name=$(mac2name "$_mac")

    # ---- 從 usteer 取出該 MAC 在各 AP 的 connected / signal ----
    # 輸出格式: <node>|<connected>|<signal>
    _snap=$(ubus call usteer get_clients 2>/dev/null | awk -v m="$_mac" '
        $0 ~ "\""m"\"" {f=1; next}
        f && /^\t\t"/ { gsub(/[",:]/,""); node=$1; next }
        f && /connected/ { gsub(/[",]/,""); conn=$2; next }
        f && /signal/ { gsub(/[",]/,""); print node"|"conn"|"$2; next }
        f && /^\t}/ {exit}
    ')
    [ -z "$_snap" ] && continue          # usteer 沒看到這台, 跳過不誤報

    # ---- 決定「目前真正關聯在哪」----
    # ★ connected 可能多台都 true(舊關聯未清), 故用 inactive time 決勝:
    #   本機有 inactive 就比較它; 遠端節點無法直接查 inactive, 改用 signal 最強者。
    _local_ia=$(local_inactive "$_mac")
    _best=""; _best_sig=-999
    for _row in $_snap; do
        _node=$(echo "$_row" | cut -d'|' -f1)
        _conn=$(echo "$_row" | cut -d'|' -f2)
        _sig=$(echo "$_row"  | cut -d'|' -f3)
        [ "$_conn" = "true" ] || continue
        case "$_node" in
            hostapd.*)  _label="$(uci -q get system.@system[0].hostname)" ;;
            *#hostapd.*) _label="${_node%%#*}" ;;
            *) _label="$_node" ;;
        esac
        # 本機且 inactive 很低 -> 幾乎確定是它
        if [ "${_node#hostapd.}" != "$_node" ] && [ -n "$_local_ia" ] \
           && [ "$_local_ia" -lt 2000 ] 2>/dev/null; then
            _best="$_label"; _best_sig="$_sig"; break
        fi
        # 否則取訊號最強者
        if [ "${_sig:--999}" -gt "$_best_sig" ] 2>/dev/null; then
            _best="$_label"; _best_sig="$_sig"
        fi
    done
    [ -z "$_best" ] && continue

    # ---- 與上次比對 ----
    _sf="$STATEDIR/.$(echo "$_ip" | tr -d '.')"
    _raw=$(cat "$_sf" 2>/dev/null)
    _prev=$(echo "$_raw" | cut -d'|' -f1)

    if [ -n "$_prev" ] && [ "$_prev" != "$_best" ]; then
        log "漫遊: ${_name:-$_ip} $_prev -> $_best (signal ${_best_sig}dBm)"
        push_notify "📶${_name:-$_ip}($_ip) 漫遊: $_prev → $_best (訊號 ${_best_sig}dBm)"
    fi

    # 只在有變化時才寫(狀態檔已移到 tmpfs, 這裡純粹是省掉無謂的 I/O)。
    [ "$_best" != "$_raw" ] && echo "$_best" > "$_sf"
done

    # 單次模式(cron)跑完就走; 常駐模式睡 $LOOP 秒後再來
    [ "$LOOP" = "0" ] && break
    sleep "$LOOP"
done

exit 0
