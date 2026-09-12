#!/bin/sh
# =====================================================================
# check-roam.sh — 監控 client 漫遊, 切換時推播
#
# 用法: check-roam.sh            # 不帶參數 = 讀 Google Sheet 旗標檔(見下方)
#       check-roam.sh <名稱樣式> # 只看符合的(例: Phone), 優先於旗標檔
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
# ★ .1 與 .4 兩台都跑。因為只推「接上端且 auth_alg=ft」, 同一次漫遊只會由
#   接收的那一台推一則, 不會重複。兩台都跑才看得到完整雙向
#   (漫遊到 RAX3000Z / 漫遊到 x60pro)。
# =====================================================================

# ---- 參數: 裝置名樣式 ----
#   check-roam.sh                  # 不帶參數 = 所有有靜態綁定的裝置
#   check-roam.sh Phone            # 只看名稱含 Phone 的
#   check-roam.sh Phone Pad        # 多個(空白分隔)
#   check-roam.sh "Phone,Pad"      # 多個(逗號分隔)
#   check-roam.sh "Phone;Pad"      # 多個(分號分隔)
# ★ 比對是「不分大小寫的子字串」, 所以 Phone 會涵蓋 Phone_Jammy/Phone_Yiting...
# ⚠️ 逗號與分號要先轉成空白, 否則 `for _p in $PATTERN` 只會依 IFS(空白)切,
#    "Phone,Pad" 會被當成單一字串去比對而全部落空。
PATTERN=$(echo "$*" | tr ',;' '  ')

# ---- Google Sheet 旗標檔(沒帶參數時才生效) ----
#   /etc/myscript/.ft_tracking_time         去重秒數; 0 = 整支不跑
#   /etc/myscript/.ft_tracking_member  裝置名樣式; 空白或 ALL = 全部
# ★ 命令列參數優先於旗標檔, 方便手動臨時指定裝置測試而不動 Sheet。
# ★ 旗標檔不存在 = 行為與加此功能前完全一致(監看全部, 去重 1 秒)。
FT_TRACKING_TIME=$(cat /etc/myscript/.ft_tracking_time 2>/dev/null)
FT_TRACKING_TIME="${FT_TRACKING_TIME:-1}"
if [ -z "$PATTERN" ]; then
    PATTERN=$(cat /etc/myscript/.ft_tracking_member 2>/dev/null | tr ',;' '  ')
fi
# ALL(不分大小寫) = 全部裝置, 等同留空
case "$(echo "$PATTERN" | tr 'A-Z' 'a-z' | tr -d ' ')" in
    all|"") PATTERN="" ;;
esac

# ---- ft_tracking_time=0 -> 不跑 ----
# ★ 放在取鎖之前: 不留鎖檔、不留行程, 純粹安靜退出。
if [ "$FT_TRACKING_TIME" = "0" ]; then
    logger -t check-roam "ft_tracking_time=0, 不啟動漫遊監控"
    exit 0
fi

# ⚠️ 去重秒數必須是數字, 否則後面的算術比較會整個爆掉而讓事件全漏。
case "$FT_TRACKING_TIME" in
    ''|*[!0-9]*) logger -t check-roam "⚠️ ft_tracking_time=[$FT_TRACKING_TIME] 非數字, 改用預設 1 秒"; FT_TRACKING_TIME=1 ;;
esac

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

# MAC -> 裝置名 / IP。資料來源是 /etc/config/dhcp 的靜態綁定, 不是 /tmp/dhcp.leases。
#
# ⚠️⚠️ 為什麼不能用 /tmp/dhcp.leases(踩過, 害整支靜默失效):
#   .4 是副 gw, dhcp.lan.ignore='1' 不發 DHCP, 它的 /tmp/dhcp.leases 是 0 bytes。
#   實測 2026-09-12: .1 有 22 筆租約, .4 有 0 筆。曾一度看到 .4 有 8 筆是
#   「短暫當過主 gw 的殘留」, 16:24 被清空 —— 而我剛好在清空前驗證「端到端通過」,
#   等於驗證在即將消失的資料上。角色切換(auto-role)會讓租約檔時有時無,
#   所以本機租約檔在這個架構下根本不可靠。
#
# ★ 改用 /etc/config/dhcp 的 config host 靜態綁定:
#   - 兩台各 38 筆且內容一致(deploy 下發), 不受角色切換影響
#   - 每筆都有 name + mac + ip(已實測 38/38 齊全)
#   ⚠️ uci 裡的 MAC 是大寫('6E:A2:93:A9:6D:F1'), hostapd log 是小寫,
#      必須大小寫無關比對, 否則全查不到。
#
# ★ 快取: 每次事件都跑 uci show 太慢, 開機讀一次進變數。
#   ⚠️ 但新增裝置後要重啟常駐才會生效 —— 這是刻意取捨(靜態綁定很少變動)。
_HOSTMAP=""
load_hostmap() {
    _HOSTMAP=$(uci -q show dhcp 2>/dev/null | awk -F'[.=]' '
        /^dhcp\.@host\[[0-9]+\]\.(name|mac|ip)=/ {
            idx = $2; key = $3
            gsub(/^.*\[|\].*$/, "", idx)
            val = $0; sub(/^[^=]*=/, "", val); gsub(/'"'"'/, "", val)
            if (key == "name") n[idx] = val
            else if (key == "mac") m[idx] = tolower(val)
            else if (key == "ip")  p[idx] = val
        }
        END { for (i in m) if (m[i] != "" && n[i] != "") print m[i]"|"n[i]"|"p[i] }
    ')
}
mac2name() {
    echo "$_HOSTMAP" | awk -F'|' -v m="$(echo "$1" | tr 'A-Z' 'a-z')" '$1==m{print $2; exit}'
}
mac2ip() {
    echo "$_HOSTMAP" | awk -F'|' -v m="$(echo "$1" | tr 'A-Z' 'a-z')" '$1==m{print $3; exit}'
}

HOSTNAME="$(uci -q get system.@system[0].hostname)"

# ★ 一定要載入, 否則 _HOSTMAP 是空的 -> 所有查詢回空 -> 全部被過濾掉不推播。
load_hostmap
_HOSTCNT=$(echo "$_HOSTMAP" | grep -c .)
log "啟動: 監看${PATTERN:+「$PATTERN」}${PATTERN:-所有靜態綁定裝置} (去重 ${FT_TRACKING_TIME}s, 來源: hostapd 事件, 已載入 ${_HOSTCNT} 筆綁定)"

# ⚠️ 載不到就直接退出, 不要靜默空跑。(踩過三次: 看似在跑卻從不推播)
[ "$_HOSTCNT" -lt 1 ] && { log "❌ /etc/config/dhcp 讀不到任何 config host 綁定, 結束"; exit 1; }

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

    # ---- 過濾: 只看 /etc/config/dhcp 裡有靜態綁定的裝置 ----
    # ★ hostapd 看得到的不只自家裝置(鄰居、訪客的隨機 MAC), 沒綁定的推播
    #   只會是一串裸 MAC, 故一律略過。
    _name=$(mac2name "$_mac")
    [ -z "$_name" ] && continue
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

    # ---- 只推「漫遊過來」那一方, 且限 auth_alg=ft ----
    #   - 離開(DISCONNECTED)不推 —— 同一次漫遊由接收端推, 兩邊都推等於重複。
    #   - auth_alg=open/sae 不推 —— 那是全新連線(開機、關開 WiFi、離開後重連),
    #     不是 AP 之間的漫遊。只有 ft 才是 802.11r 快速漫遊。
    # ★ 提前 continue: 不合格的事件「完全不碰狀態檔」。這是關鍵, 見下方說明。
    [ "$_ev" = "connected" ] || continue
    [ "$_alg" = "ft" ] || continue

    # ---- 去重 ----
    # ⚠️⚠️ 舊版把狀態檔當成 connected/disconnected 兩態機, 有兩個漏洞(實測踩到):
    #   (a) auth_alg=open 的全新連線雖然不推播, 卻仍寫入 "connected", 把狀態
    #       卡住; 之後真正的 FT 漫遊因為「狀態沒變」被去重吃掉, 永遠不推。
    #       實測 2026-09-12: Phone_HTC_Android 16:42:26 一筆 open 連線後,
    #       狀態檔=connected, 下次 FT 漫遊必定被吃掉。
    #   (b) 連續兩次 FT CONNECTED 中間若沒有 DISCONNECTED(漫遊走 over-the-air
    #       時本機未必看得到離開事件), 第二次也會被吃掉。
    #       實測: Phone_Jammy 在 .1 的 16:31:03 → 16:31:55 就是連續 CONNECTED。
    #
    # ★ 正解: 去重的目的只是「濾掉 hostapd 對同一次事件連發的重複行」,
    #   不是模擬連線狀態。所以改用「事件指紋」= 時間戳, 只要不是同一秒的
    #   同一筆就放行。不同 auth_alg / 不同時刻的事件不會互相干擾。
    # ★ 去重視窗 = ft_tracking_time 秒(Google Sheet 可調, 預設 1 秒 = 只濾同一秒的重複行)。
    #   調大可抑制「同一支手機在兩台之間來回彈」的連續推播。
    # ⚠️ 用 date +%s 取「現在」而不是解析 log 的時間戳: 時間戳只有時:分:秒,
    #    跨午夜會從 23:59:59 跳回 00:00:00, 拿它做算術會得到負數而讓去重失效。
    _now=$(date +%s)
    _sf="/tmp/.roam/.$(echo "$_mac" | tr -d ':')"
    mkdir -p /tmp/.roam 2>/dev/null
    _prev=$(cat "$_sf" 2>/dev/null)
    case "$_prev" in
        ''|*[!0-9]*) _prev=0 ;;
    esac
    [ $((_now - _prev)) -lt "$FT_TRACKING_TIME" ] && continue
    echo "$_now" > "$_sf"

    log "漫遊: $_name($_ip) FT 漫遊到 $HOSTNAME"
    push_notify "📶${_name}(${_ip}) 漫遊到 ${HOSTNAME}"
done

exit 0
