#!/bin/sh
# =====================================================================
# check-client-stuck.sh — 偵測「WiFi 連上了但完全不通」的 client
#
# ⚠️ 真實案例 2026-09-08 (.4 副gw): Nana/Jammy 的手機關聯正常(authorized、
#    訊號 -44dBm、inactive 只有 20ms), 但完全上不了網。實測 conntrack 只有
#    一堆重試中的 DNS 查詢、零對外連線, 使用者只看到「無網際網路連線」。
#    ★ 每次都要 ssh 進來翻 conntrack 才查得出來, 故做成自動偵測。
#
# 判準(三個條件同時成立才算卡住, 缺一不可):
#   1. WiFi 已關聯且 authorized  —— 排除「根本沒連上」
#   2. inactive time 短(< 門檻)  —— ★ 排除「手機螢幕關著在睡」, 睡著的
#      裝置 inactive 會是幾十秒, 那是正常的不該告警
#   3. 主 gw 上有 DHCP 租約, 但該 IP 的 conntrack 對外連線數為 0
#      —— 有 IP 代表它拿得到位址, 卻連不出去 = 真的卡住
#
# ⚠️ 為什麼要查「主 gw」的租約: 副 gw 的 dhcp.lan.ignore=1 不發 DHCP,
#    租約只存在主 gw 的 /tmp/dhcp.leases。在副 gw 上查一定查不到,
#    會把所有 client 都誤判成卡住(踩過)。
# ⚠️ 為什麼不能只看 ping: iPhone/Android 省電時不回應 ICMP, ping 不通
#    是常態不是故障(本 repo 誤判過兩次)。要看 conntrack 才準。
# ⚠️ 連續 N 輪都判定卡住才動作: 剛連上的裝置本來就還沒有連線紀錄,
#    單輪判定會誤報。
#
# 用法:
#   check-client-stuck.sh            # 正常執行(cron)
#   check-client-stuck.sh --show     # 只印不推、不重開機
# =====================================================================

. /etc/myscript/push-notify.inc 2>/dev/null
PUSH_NAMES="${PUSH_NAMES:-admin}"

SHOW_ONLY=0
[ "$1" = "--show" ] && SHOW_ONLY=1

LOGTAG="client-stuck"
STATEDIR="/etc/myscript/.client-stuck"
LOCKFILE="/tmp/check-client-stuck.lock"

# 判準門檻
INACTIVE_MAX_MS="${INACTIVE_MAX_MS:-5000}"   # 超過這個就當作在睡, 不算卡住
STRIKES_NEEDED="${STRIKES_NEEDED:-3}"        # 連續幾輪才確認(cron */5 => 15 分鐘)
MIN_STUCK_CLIENTS="${MIN_STUCK_CLIENTS:-2}"  # ★ 至少幾台同時卡住才重開機
REBOOT_COOLDOWN="${REBOOT_COOLDOWN:-14400}"  # 重開機冷卻 4 小時
AUTO_REBOOT="${AUTO_REBOOT:-0}"              # ★ 預設只推播不重開, 要明確開啟

log() { logger -t "$LOGTAG" "$1"; [ "$SHOW_ONLY" = "1" ] && echo "$1"; }

# ---- 併發鎖(--show 不搶) ----
if [ "$SHOW_ONLY" = "0" ]; then
    if [ -f "$LOCKFILE" ]; then
        _op=$(cat "$LOCKFILE" 2>/dev/null)
        [ -n "$_op" ] && kill -0 "$_op" 2>/dev/null && exit 0
        rm -f "$LOCKFILE"
    fi
    echo $$ > "$LOCKFILE"
    trap 'rm -f "$LOCKFILE"' EXIT INT TERM
fi

mkdir -p "$STATEDIR" 2>/dev/null

GW_TYPE=$(cat /etc/myscript/.mesh_gw_type 2>/dev/null)

# ---- 取得 MAC → IP 對照 ----
# ⚠️ 不要靠「跟主 gw 要 /tmp/dhcp.leases」: 路由器之間沒有 ssh 互信
#    (實查 .4 根本沒有 /root/.ssh/, 連線直接 "No auth methods could be used")。
# ★ 改用本機 ARP 表: client 只要跟本機有過任何 L2 往來就會出現在這裡,
#   副 gw 完全自給自足, 不需跨機認證。
#   有租約表(自己是主 gw)時優先用它, 因為附帶主機名比較好讀。
_leases=""
[ -f /tmp/dhcp.leases ] && _leases=$(cat /tmp/dhcp.leases 2>/dev/null)

# mac2ip <mac> -> 印出 IP(找不到印空)
mac2ip() {
    _m="$1"
    if [ -n "$_leases" ]; then
        _r=$(echo "$_leases" | grep -i " $_m " | awk '{print $3; exit}')
        [ -n "$_r" ] && { echo "$_r"; return; }
    fi
    ip neigh show 2>/dev/null | grep -i "$_m" | awk '{print $1; exit}'
}
# mac2name <mac> -> 有租約才有名字, 否則回 MAC
mac2name() {
    _m="$1"
    if [ -n "$_leases" ]; then
        _r=$(echo "$_leases" | grep -i " $_m " | awk '{print $4; exit}')
        [ -n "$_r" ] && [ "$_r" != "*" ] && { echo "$_r"; return; }
    fi
    echo "$_m"
}

# ---- 逐一檢查 WiFi client ----
_stuck=""
_stuck_n=0
_checked=0

for _if in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
    # 只看 AP 介面(mesh/monitor 沒有 client)
    case "$_if" in *ap*) ;; *) continue ;; esac

    # ⚠️ 欄位順序不固定(實測 authorized 出現在 inactive time 之前), 不能邊讀邊
    #    print, 否則會印到還沒賦值的變數。★ 在下一個 Station 邊界(或 EOF)才輸出。
    iw dev "$_if" station dump 2>/dev/null \
      | awk '
          /^Station/ { if (m != "") print m, it+0, a; m=$2; it=""; a="" ; next }
          /inactive time/ { it=$3 }
          /authorized/    { a=$2 }
          END { if (m != "") print m, it+0, a }
        ' > "/tmp/.ccs.$$"

    while read -r _mac _inact _auth; do
        [ -z "$_mac" ] && continue
        [ "$_auth" = "yes" ] || continue                    # 判準 1
        case "$_inact" in ''|*[!0-9]*) continue ;; esac
        [ "$_inact" -gt "$INACTIVE_MAX_MS" ] && continue    # 判準 2: 在睡就跳過

        _checked=$((_checked + 1))

        # 判準 3: 拿得到 IP 但零對外連線
        _ip=$(mac2ip "$_mac")
        [ -z "$_ip" ] && continue      # 連 IP 都沒有 = 還沒拿到位址, 屬另一種問題
        _name=$(mac2name "$_mac")

        # ⚠️ 只算「真的出得去」的連線: 排除目的地是本網段/多播的
        #    (DNS 查詢送給 gw 也算 192.168.x, 不能當作通)
        _out=$(grep "src=$_ip " /proc/net/nf_conntrack 2>/dev/null \
               | grep -vc "dst=192\.168\.\|dst=224\.\|dst=10\.\|dst=172\.1[6-9]\.\|dst=172\.2[0-9]\.\|dst=172\.3[01]\.")
        [ "${_out:-0}" -gt 0 ] && continue                   # 有對外連線 = 正常

        _stuck="${_stuck} ${_name:-$_mac}($_ip)"
        _stuck_n=$((_stuck_n + 1))
    done < "/tmp/.ccs.$$"
    rm -f "/tmp/.ccs.$$"
done

# ---- 連續判定(strike) ----
_sf="$STATEDIR/.strikes"
_prev=$(cat "$_sf" 2>/dev/null)
case "$_prev" in ''|*[!0-9]*) _prev=0 ;; esac

if [ "$_stuck_n" -lt "$MIN_STUCK_CLIENTS" ]; then
    [ "$_prev" -gt 0 ] && log "恢復正常(卡住 $_stuck_n 台 < 門檻 $MIN_STUCK_CLIENTS), strike 歸零"
    echo 0 > "$_sf"
    [ "$SHOW_ONLY" = "1" ] && echo "檢查 $_checked 台活躍 client, 卡住 $_stuck_n 台 -> 正常"
    exit 0
fi

_now_strike=$((_prev + 1))
echo "$_now_strike" > "$_sf"
log "偵測到 $_stuck_n 台卡住 (strike $_now_strike/$STRIKES_NEEDED):$_stuck"

if [ "$_now_strike" -lt "$STRIKES_NEEDED" ]; then
    exit 0
fi

# ---- 達標: 推播 ----
_msg="⚠️${GW_TYPE:-本機} 有 ${_stuck_n} 台 WiFi 已連線卻完全不通:${_stuck} (連續 ${_now_strike} 輪)"
log "$_msg"
[ "$SHOW_ONLY" = "1" ] && { echo "[--show] 會推播: $_msg"; exit 0; }
push_notify "$_msg"

# ---- 自動重開機(預設關閉) ----
# ⚠️ 重開機是最後手段: 會斷掉全家人的網路。故 (1) 預設 AUTO_REBOOT=0 只推播
#    (2) 要多台同時卡住才算數 (3) 有冷卻避免反覆重開 (4) 主 gw 更保守。
if [ "$AUTO_REBOOT" != "1" ]; then
    log "AUTO_REBOOT=0, 只推播不重開機"
    exit 0
fi

_rbf="$STATEDIR/.last_reboot"
_last=$(cat "$_rbf" 2>/dev/null)
case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
_now=$(date +%s)
if [ $((_now - _last)) -lt "$REBOOT_COOLDOWN" ]; then
    log "冷卻中($(( (REBOOT_COOLDOWN - (_now - _last)) / 60 )) 分鐘後才可再重開), 本次只推播"
    exit 0
fi

echo "$_now" > "$_rbf"
echo 0 > "$_sf"
push_notify "🔄${GW_TYPE:-本機} 因 ${_stuck_n} 台 client 持續不通, 30 秒後自動重開機"
log "觸發自動重開機"
# 給推播送出的時間, 且用 setsid 避免被 cron 收掉
(sleep 30; reboot) >/dev/null 2>&1 </dev/null &
exit 0
