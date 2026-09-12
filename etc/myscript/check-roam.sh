#!/bin/sh
# =====================================================================
# check-roam.sh — 監控 client 漫遊, 切換時推播
#
# 用法: check-roam.sh            # 監看所有「有 DHCP 租約」的裝置
#       check-roam.sh <名稱樣式> # 只看符合的(例: Phone)
#
# ★ 資料來源是「本機 hostapd 的 syslog 事件」, 不是 usteer。
#   實測 2026-09-12: 對照 4 分鐘的實走測試, hostapd 的 AP-STA-CONNECTED
#   與真實漫遊 7/7 完全吻合, 而舊的 usteer 判定法 12 次裡有 7 次是假的。
#
# ⚠️⚠️ 為什麼放棄 usteer(舊版的真兇, 別再走回頭路):
#   usteer get_clients 對每個節點只給 connected 與 signal 兩個欄位:
#       "46:9d:4d:09:6f:6e": {
#           "hostapd.phy1-ap0":             {"connected": true, "signal": -68},
#           "192.168.1.1#hostapd.phy1-ap0": {"connected": true, "signal": -57}
#       }
#   (a) 漫遊後兩邊 connected 都是 true(舊關聯數分鐘才清), 不能當判準;
#   (b) 遠端節點「沒有 inactive 欄位」, 只好拿 signal 猜 —— 但兩台訊號
#       長期只差幾 dB(實測 -54 vs -60), 每輪隨機翻面, 於是腳本自己在
#       兩台之間亂跳, 推播 7/12 是假的。使用者看到的「同一個一直跳」
#       大部分是這個 bug, 不是手機真的在跳。
#   (c) 想「ssh 去對台查 inactive」也行不通: .4 只有 host key 沒有 client
#       私鑰, 實測 "No auth methods could be used"。
#   -> 結論: 本機 hostapd 事件是唯一可信且拿得到的真相來源。
#
# ★ 只報「本機視角」: CONNECTED = 接上本機, DISCONNECTED = 離開本機。
#   刻意不宣稱「跑去哪一台」—— 那需要對台資料, 而我們拿不到(見上)。
#   硬猜就是舊版造假的根源。
#
# ⚠️ 只在「一台」啟動。兩台各跑會各自從自己視角推播, 同一次漫遊收到兩則
#    (一則「離開」一則「接上」), 且無法合併。目前只在 .4 由 rc.local 啟動。
# =====================================================================

# ---- 參數: 名稱樣式(可省略 = 全部有租約的裝置) ----
PATTERN="$*"

LOCK="/tmp/check-roam.lock"
if [ -f "$LOCK" ]; then
    kill -0 "$(cat "$LOCK")" 2>/dev/null && exit 0
    rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM

# ---- 沒有 hostapd 的機器安靜跳過(機隊防護) ----
# ⚠️ 這支可能下發給整個機隊, 沒跑 AP 的機器要安靜退出不洗 log。
[ -d /var/run/hostapd ] || ubus list 2>/dev/null | grep -q '^hostapd\.' || exit 0

. /etc/myscript/push-notify.inc
PUSH_NAMES="${PUSH_NAMES:-admin}"

LOGTAG="check-roam"
log() { logger -t "$LOGTAG" "$1"; }

# MAC -> 裝置名。★ 回空 = 沒有 DHCP 租約。
# ⚠️ hostapd 與 dhcp.leases 的 MAC 都是小寫冒號格式, 可直接比對(已實測)。
mac2name() {
    awk -v m="$1" 'tolower($2)==tolower(m){print $4; exit}' /tmp/dhcp.leases 2>/dev/null
}
mac2ip() {
    awk -v m="$1" 'tolower($2)==tolower(m){print $3; exit}' /tmp/dhcp.leases 2>/dev/null
}

HOSTNAME="$(uci -q get system.@system[0].hostname)"
log "啟動: 監看${PATTERN:+「$PATTERN」}${PATTERN:-所有有租約的裝置} (來源: hostapd 事件)"

# ---- 主迴圈: 串流 hostapd 事件 ----
# ★ 用 logread -f 串流而非輪詢: 漫遊是秒級事件, 輪詢會漏也會延遲。
#   實測 logread 有 -f(Follow log messages)。
# ⚠️ 用 -e 先在 logread 端過濾, 避免把整個 log 都丟進 shell 迴圈。
# ⚠️ while 由管線餵食 = 跑在子 shell, 迴圈內設的變數帶不出來。本迴圈
#    刻意不依賴任何值傳出去(推播在迴圈內完成), 故子 shell 不影響正確性。
logread -f -e "AP-STA-" 2>/dev/null | while read -r line; do

    case "$line" in
        *AP-STA-CONNECTED*)    _ev="connected" ;;
        *AP-STA-DISCONNECTED*) _ev="disconnected" ;;
        *) continue ;;
    esac

    # 行格式(實測逐字):
    #   Sat Sep 12 16:10:12 2026 daemon.notice hostapd: phy1-ap0: AP-STA-CONNECTED 46:9d:4d:09:6f:6e auth_alg=ft
    #   Sat Sep 12 16:10:37 2026 daemon.notice hostapd: phy1-ap0: AP-STA-DISCONNECTED 46:a2:41:eb:f2:97
    # ⚠️⚠️ 必須匹配「完整 6 段」MAC, 不能只寫前兩段:
    #    時間戳 "16:13:55" 也符合 ^[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:
    #    (16/13/55 都是合法十六進位), 而時間欄排在 MAC 前面, 會先被抓走,
    #    導致每一行都查不到租約而被跳過 —— 腳本看似在跑卻從不推播。
    #    實測 2026-09-12 踩過: 解析出 MAC=[16:13:55], 真實漫遊完全沒推。
    _mac=$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9a-fA-F][0-9a-fA-F](:[0-9a-fA-F][0-9a-fA-F]){5}$/){print tolower($i); exit}}')
    [ -z "$_mac" ] && continue

    # auth_alg=ft 代表走 802.11r 快速漫遊(只有 CONNECTED 行才有)
    _alg=$(echo "$line" | sed -n 's/.*auth_alg=\([a-z]*\).*/\1/p')

    # ---- 過濾: 只看有 DHCP 租約的裝置 ----
    # ★ 使用者選擇「只限有租約的」: usteer/hostapd 看得到 19 台, 但其中
    #   11 台是無租約的隨機 MAC(鄰居裝置、訪客), 推播只會是一串裸 MAC。
    _name=$(mac2name "$_mac")
    [ -z "$_name" ] && continue
    [ "$_name" = "*" ] && continue          # 租約有但沒主機名的也跳過
    _ip=$(mac2ip "$_mac")

    # ---- 名稱樣式過濾(有給才比對) ----
    if [ -n "$PATTERN" ]; then
        _hit=0
        for _p in $PATTERN; do
            case "$(echo "$_name" | tr 'A-Z' 'a-z')" in
                *"$(echo "$_p" | tr 'A-Z' 'a-z')"*) _hit=1; break ;;
            esac
        done
        [ "$_hit" = "1" ] || continue
    fi

    # ---- 去重 ----
    # ⚠️ hostapd 對同一次漫遊會連發多行(DISCONNECTED + associated + CONNECTED
    #    同一秒), 且重連時會先 DISCONNECTED 再立刻 CONNECTED。
    #    只推「狀態真的改變」的那一次, 用 /tmp 記住上次狀態。
    _sf="/tmp/.roam/.$(echo "$_mac" | tr -d ':')"
    mkdir -p /tmp/.roam 2>/dev/null
    _prev=$(cat "$_sf" 2>/dev/null)
    [ "$_prev" = "$_ev" ] && continue
    echo "$_ev" > "$_sf"

    # ★ 首次看到這台不推播(沒有前一個狀態可比), 避免剛啟動就洗一輪。
    [ -z "$_prev" ] && continue

    # ★ 只推「漫遊過來」那一方, 且限 auth_alg=ft:
    #   - 離開(DISCONNECTED)不推 —— 同一次漫遊會由接收端推, 兩邊都推等於重複。
    #   - auth_alg=open/sae 不推 —— 那是全新連線(開機、關開 WiFi、離開後重連),
    #     不是 AP 之間的漫遊。只有 ft 才是 802.11r 快速漫遊。
    #   ⚠️ 但 DISCONNECTED 仍要記狀態(上面已寫 $_sf), 否則下次 CONNECTED
    #      會因為狀態沒變而被去重吃掉。
    if [ "$_ev" = "connected" ] && [ "$_alg" = "ft" ]; then
        log "漫遊: $_name($_ip) FT 漫遊到 $HOSTNAME"
        push_notify "📶${_name}(${_ip}) 漫遊到 ${HOSTNAME}"
    fi
done

exit 0
