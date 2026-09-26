#!/bin/sh
# sta-backup.sh — WAN 全斷且 mesh 無出路時, 用 2.4G 連鄰居 AP 當最後手段
#
# 用法:
#   sta-backup.sh            # cron 每分鐘跑, 自動判斷
#   sta-backup.sh status     # 只顯示現況, 不做任何變更
#   sta-backup.sh on         # 手動強制啟用(略過連續次數判定)
#   sta-backup.sh off        # 手動強制關閉並還原
#
# 設定來源 (Sheet 的 config batmanmesh → sync-googleconfig.sh 落檔):
#   /etc/myscript/.sta_backup_ssid    上游 AP 名稱
#   /etc/myscript/.sta_backup_key     密碼 (600)
#   /etc/myscript/.sta_backup_band    2g / 5g (預設 2g)
#   /etc/myscript/.sta_backup_enable  1=啟用自動判斷, 0=完全不動作(預設)
#
# 觸發條件 (三者同時成立, 且連續 FAIL_NEED 次):
#   1. WAN 沒有 IP, 或有 IP 但 ping 不通
#   2. batman 沒有鄰居, 或有鄰居但全部 wan_status != up
#   3. 以上連續成立 5 分鐘 (cron 每分鐘一次)
# 還原條件: WAN 或 mesh 任一恢復, 連續 OK_NEED 次
#
# ⚠️ 眉角:
#  1. #channels <= 1 —— 同一 radio 上所有介面必須同頻道。STA 連上鄰居後,
#     該 radio 的 AP/mesh 會被拖到鄰居的頻道。故預設吃 2.4G, 保住主力 5G。
#     (實測 .8 的 phy0/phy1 都是 "#{ AP, mesh point } <= 16, #{ managed } <= 19,
#      total <= 19, #channels <= 1, STA/AP BI must match")
#  2. 本腳本會改 /etc/config/wireless 並 wifi reload —— 那是會把自己鎖在門外
#     的操作。故所有變更都先備份到 /tmp/.sta_backup_wireless.bak, 且 enable=0
#     時「完全不碰」任何設定(連 uci set 都不做)。
#  3. 判定用連續次數而非單次, 因為小烏龜重開/PPPoE 重撥約 1-2 分鐘, 單次判
#     定必然誤觸發。
#  4. 不使用 auto-role.sh 的 .mesh_gw_type —— 那是「主/副 gw」, 與「有沒有
#     外網」是兩回事(副 gw 也可能 WAN 正常)。

PATH=/usr/sbin:/sbin:/usr/bin:/bin
export PATH

. /etc/myscript/push-notify.inc 2>/dev/null
PUSH_NAMES="${PUSH_NAMES:-admin}"

TAG="sta-backup"
CFG_DIR="/etc/myscript"
SSID_F="$CFG_DIR/.sta_backup_ssid"
KEY_F="$CFG_DIR/.sta_backup_key"
BAND_F="$CFG_DIR/.sta_backup_band"
ENABLE_F="$CFG_DIR/.sta_backup_enable"

STATE_F="/tmp/.sta_backup_state"       # active / idle
FAILCNT_F="/tmp/.sta_backup_failcnt"
OKCNT_F="/tmp/.sta_backup_okcnt"
BAK_F="/tmp/.sta_backup_wireless.bak"

# ⚠️ 這裡的「次」不等於「分鐘」: 本腳本掛在 auto-role.sh 尾端, 而 auto-role
#   前面有 WAN ping 重試(3 次、間隔 10 秒)、ARP DAD 探測等, 實測跑完一輪
#   要 3 分鐘 —— cron 雖是每分鐘叫起, 但下一輪會被鎖擋掉。
#   實測 2026-09-26 於 MX4200:
#     23:13:41 fail=1 → 23:16:02 fail=2 → 23:19:02 fail=3 → 23:22:03 fail=4
#     → 23:25:04 fail=5   共 11.5 分鐘, 而非設計的 5 分鐘。
#   故 FAIL_NEED=2 實際約等於 6 分鐘, 對「WAN 真的斷了」仍夠保守。
FAIL_NEED=2      # 連續幾次判定孤島才啟用(實測每次間隔約 3 分鐘)
OK_NEED=3        # 連續幾次判定正常才還原
STA_SECTION="sta_backup"   # uci wifi-iface 的 section 名(固定, 方便清理)

log() { logger -t "$TAG" "$1"; [ -n "$STA_VERBOSE" ] && echo "$1"; }

_read() { cat "$1" 2>/dev/null; }

_cnt_get() {
    _v=$(cat "$1" 2>/dev/null)
    case "$_v" in ''|*[!0-9]*) _v=0 ;; esac
    echo "$_v"
}

# ---------- 判斷:本機 WAN 有沒有外網 ----------
# ★ 由 auto-role.sh 呼叫時會帶 STA_WAN_OK(它剛算過, 最長花了 23 秒重試),
#   直接沿用可省掉重複 ping, 也避免兩支腳本各自判斷而結論不一致。
#   手動執行(status/on/off)時沒有這個變數, 就自己量。
wan_ok() {
    case "$STA_WAN_OK" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    _wif=$(uci -q get network.wan.device 2>/dev/null || echo wan)
    _wip=$(uci -q get network.wan.ipaddr 2>/dev/null)
    [ -z "$_wip" ] && _wip=$(ifstatus wan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
    [ -z "$_wip" ] || [ "$_wip" = "0.0.0.0" ] && return 1
    # 有 IP 還要能通 —— 上游掛掉時 IP 仍在
    ping -c 1 -W 3 -I "$_wif" 8.8.8.8 >/dev/null 2>&1 && return 0
    ping -c 1 -W 3 -I "$_wif" 1.1.1.1 >/dev/null 2>&1 && return 0
    return 1
}

# ---------- 判斷:mesh 有沒有人能出去 ----------
# ★ 不能只看「有沒有鄰居」: 鄰居可能也全部沒有 WAN。
#   alfred 的 wan_status 是各節點自己廣播的, 用它判斷才準。
mesh_ok() {
    command -v batctl >/dev/null 2>&1 || return 1
    _n=$(batctl n 2>/dev/null | grep -c ':')
    [ "$_n" -eq 0 ] 2>/dev/null && return 1
    # 有鄰居, 再看有沒有人 wan_status=up
    command -v alfred >/dev/null 2>&1 || return 0   # 沒 alfred 就只看鄰居數
    # ⚠️ alfred 的輸出是「JSON 字串裡再包一層 JSON」, 跳脫字元只有一個反斜線:
    #      { "86:76:...", "{\"wan_status\":\"up\", \"priority\":90, ...}" }
    #    原本寫成 '"wan_status\\":\\"up\\"'(單引號內 \\ = 兩個字面反斜線)
    #    永遠比對不到 → _up 恆為 0 → mesh_ok() 恆回 false
    #    → 只要 WAN 一斷就觸發 STA, 即使旁邊那台還有網路。
    #    改用不含跳脫的關鍵片段比對, 避開反斜線數量的陷阱。
    _up=$(alfred -r 64 2>/dev/null | grep -c 'wan_status[^,]*up')
    [ "$_up" -gt 0 ] 2>/dev/null && return 0
    return 1
}

# ---------- 取得要用的 radio ----------
pick_radio() {
    _want=$(_read "$BAND_F"); [ -z "$_want" ] && _want=2g
    for _r in radio0 radio1 radio2 radio3; do
        _b=$(uci -q get wireless.$_r.band 2>/dev/null)
        [ "$_b" = "$_want" ] && { echo "$_r"; return 0; }
    done
    return 1
}

# ---------- policy routing ----------
# ★ 為什麼不用主路由表: 見 sta_on() 內 defaultroute=0 的說明。鄰居網段極可能
#   與本地 LAN 相同(192.168.1.0/24 是台灣最常見的預設), 路由重疊會讓回本地
#   的封包被送去鄰居, 整台失聯。
# ⚠️ 位址是 DHCP 給的, 每次續約都可能不同 —— 一律「執行時動態取得」,
#   絕不可寫死。刪除時也不能用 `ip rule del from <ip>`(舊 IP 已不可知),
#   故所有規則都掛固定 pref, 用 pref 精準刪除。
STA_TABLE=99
STA_PREF_SRC=990       # from <sta_ip>  → table 99
STA_PREF_LAN=991       # from <lan_net> → table 99 (LAN 出去的流量)

sta_rules_clear() {
    # 反覆刪到沒有為止: 同一 pref 可能因重試而堆疊多筆
    for _p in "$STA_PREF_SRC" "$STA_PREF_LAN"; do
        while ip rule del pref "$_p" 2>/dev/null; do :; done
    done
    ip route flush table "$STA_TABLE" 2>/dev/null
}

sta_rules_apply() {
    _ip=$(ifstatus wwan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
    _mask=$(ifstatus wwan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].mask' 2>/dev/null)
    _dev=$(ifstatus wwan 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
    _gw=$(ifstatus wwan 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
    [ -z "$_mask" ] && _mask=24

    if [ -z "$_ip" ] || [ -z "$_dev" ] || [ -z "$_gw" ]; then
        log "規則未套用: wwan 資訊不全 (ip=$_ip dev=$_dev gw=$_gw)"
        return 1
    fi

    sta_rules_clear

    # 上游網段(由實際位址推算, 不可假設是 /24 或 192.168.1.x)
    _upnet=$(_net_of "$_ip" "$_mask")
    _lan_ip=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    _lan_cidr=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | head -1)
    _lan_mask=$(echo "$_lan_cidr" | cut -d/ -f2)
    _lannet=$(_net_of "$_lan_ip" "$_lan_mask")

    # table 99: 走上游
    ip route add "$_upnet" dev "$_dev" src "$_ip" table "$STA_TABLE" 2>/dev/null
    ip route add default via "$_gw" dev "$_dev" table "$STA_TABLE" 2>/dev/null
    # ★ 本地 LAN 必須「優先於」預設路由留在本機 —— 否則 LAN 內互連會被送上游
    ip route add "$_lannet" dev br-lan src "$_lan_ip" table "$STA_TABLE" 2>/dev/null

    ip rule add from "$_ip" table "$STA_TABLE" pref "$STA_PREF_SRC" 2>/dev/null
    ip rule add from "$_lannet" table "$STA_TABLE" pref "$STA_PREF_LAN" 2>/dev/null

    log "規則已套用: ip=$_ip dev=$_dev gw=$_gw upnet=$_upnet lannet=$_lannet table=$STA_TABLE"
    [ "$_upnet" = "$_lannet" ] && \
        log "⚠️ 上游與本地同網段($_upnet) —— 已用 policy routing 隔離, 但 LAN 內若有與上游相同的主機位址仍會有歧義"
    return 0
}

# 由 IP + mask 算出網段(busybox 沒有 ipcalc 時自己算)
_net_of() {
    _a="$1"; _m="$2"
    if command -v ipcalc.sh >/dev/null 2>&1; then
        _n=$(ipcalc.sh "$_a/$_m" 2>/dev/null | sed -n 's/^NETWORK=//p')
        [ -n "$_n" ] && { echo "$_n/$_m"; return; }
    fi
    # 退路: 只處理 /24 以內的常見情況
    case "$_m" in
        24) echo "$(echo "$_a" | cut -d. -f1-3).0/24" ;;
        16) echo "$(echo "$_a" | cut -d. -f1-2).0.0/16" ;;
        8)  echo "$(echo "$_a" | cut -d. -f1).0.0.0/8" ;;
        *)  echo "$_a/$_m" ;;
    esac
}

# ---------- 啟用 STA ----------
sta_on() {
    _ssid=$(_read "$SSID_F")
    _key=$(_read "$KEY_F")
    if [ -z "$_ssid" ]; then
        log "❌ 無法啟用: .sta_backup_ssid 是空的"
        return 1
    fi
    _radio=$(pick_radio) || { log "❌ 找不到 band=$(_read "$BAND_F") 的 radio"; return 1; }

    # 已經在了就不重複做
    if [ -n "$(uci -q get wireless.${STA_SECTION} 2>/dev/null)" ]; then
        log "STA 介面已存在, 不重複建立"
        return 0
    fi

    # ⚠️ 動 wireless 前先備份, 這是會把自己鎖在門外的操作
    uci export wireless > "$BAK_F" 2>/dev/null
    log "已備份 wireless 到 $BAK_F"

    uci -q delete wireless.${STA_SECTION} 2>/dev/null
    uci set wireless.${STA_SECTION}=wifi-iface
    uci set wireless.${STA_SECTION}.device="$_radio"
    uci set wireless.${STA_SECTION}.mode='sta'
    uci set wireless.${STA_SECTION}.network='wwan'
    uci set wireless.${STA_SECTION}.ssid="$_ssid"
    if [ -n "$_key" ]; then
        uci set wireless.${STA_SECTION}.encryption='psk2'
        uci set wireless.${STA_SECTION}.key="$_key"
    else
        uci set wireless.${STA_SECTION}.encryption='none'
    fi

    # wwan 介面(DHCP client)
    # ★ defaultroute=0 + peerdns=0: 絕對不可讓 DHCP 把路由寫進主表。
    #   實測 2026-09-25 於 MX4200(.9): 鄰居網段與本地 LAN 同為 192.168.1.0/24,
    #   且鄰居閘道也是 192.168.1.1 —— DHCP 寫入
    #     default via 192.168.1.1 dev phy1-sta0
    #     192.168.1.0/24 dev phy1-sta0 src 192.168.1.138
    #   與本地的
    #     192.168.1.0/24 dev br-lan   src 192.168.1.5
    #   完全重疊, 回本地 LAN 的封包被送去鄰居 → SSH 立刻斷, 整台失聯。
    #   改由本腳本把路由放進獨立 table(見 sta_rules_apply), 主表不受污染。
    uci -q delete network.wwan 2>/dev/null
    uci set network.wwan=interface
    uci set network.wwan.proto='dhcp'
    uci set network.wwan.metric='200'
    uci set network.wwan.defaultroute='0'
    uci set network.wwan.peerdns='0'
    # ⚠️ 必須放進 wan zone 才會做 NAT, 否則 LAN 出不去
    _zi=0
    while [ -n "$(uci -q get firewall.@zone[$_zi] 2>/dev/null)" ]; do
        if [ "$(uci -q get firewall.@zone[$_zi].name)" = "wan" ]; then
            uci -q del_list firewall.@zone[$_zi].network='wwan' 2>/dev/null
            uci add_list firewall.@zone[$_zi].network='wwan'
            break
        fi
        _zi=$((_zi + 1))
    done

    uci commit wireless
    uci commit network
    uci commit firewall

    # ⚠️ 不可用 `wifi reload` —— 那是全域指令, 會把「所有」radio 一起重啟。
    #   實測 2026-09-25 於 MX4200(.9): 觸發後 SSH 與 Tailscale 同時斷, 只能
    #   現場重開。該台 5G 上有 AP、2.4G 上有 AP+mesh, 全部重啟等於把管理路徑
    #   一起砍掉, 而 STA 最快也要數十秒才可能連上 —— 中間完全失聯。
    #   改用 `wifi up <radio>` 只動目標 radio, 另一個 radio 的 AP/mesh 不受影響,
    #   管理路徑得以保留。
    log "🔌 啟用 STA 備援: radio=$_radio ssid=$_ssid → wifi up $_radio"
    wifi up "$_radio" 2>/dev/null || wifi reload

    # 等關聯 + DHCP。⚠️ 不能只 sleep 固定秒數就當成功 —— 連不上鄰居 AP 時
    #   wwan 介面仍存在但永遠沒有位址, 那時若直接宣告成功, auto-role 會把
    #   角色升成 gateway 並搶 192.168.1.1, 全家指向一個不通的閘道。
    _got=0
    _w=0
    while [ "$_w" -lt 45 ]; do
        sleep 5
        _w=$(( _w + 5 ))
        _chk=$(ifstatus wwan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
        [ -n "$_chk" ] && [ "$_chk" != "0.0.0.0" ] && { _got=1; break; }
    done

    if [ "$_got" = "0" ]; then
        log "❌ ${_w}s 內未取得 IP(可能連不上 $_ssid 或密碼錯), 還原設定"
        sta_off_raw
        push_notify "STA備援啟用失敗: ${_w}s 內未取得 IP, 檢查 [$_ssid] 名稱/密碼/訊號"
        return 1
    fi

    /etc/init.d/firewall reload >/dev/null 2>&1
    sta_rules_apply

    echo active > "$STATE_F"
    _shownet=$(ifstatus wwan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
    push_notify "STA備援已啟用: 連上 [$_ssid] 取得 $_shownet (WAN 與 mesh 皆無出路)"
    return 0
}

# ---------- 關閉 STA 並還原 ----------
# sta_off_raw: 只做清理, 不推播 —— 給「啟用失敗要回滾」用,
#              那種情況由呼叫端自己推更精確的訊息。
sta_off_raw() {
    sta_rules_clear
    ifdown wwan 2>/dev/null
    if [ -z "$(uci -q get wireless.${STA_SECTION} 2>/dev/null)" ] \
       && [ -z "$(uci -q get network.wwan 2>/dev/null)" ]; then
        echo idle > "$STATE_F"
        return 0
    fi
    # ⚠️ 必須在 delete 之前取得 radio —— 刪掉就查不到了, 後面只能退回
    #    全域 wifi reload(那正是要避免的)。
    _radio=$(uci -q get wireless.${STA_SECTION}.device 2>/dev/null)
    uci -q delete wireless.${STA_SECTION}
    uci -q delete network.wwan
    _zi=0
    while [ -n "$(uci -q get firewall.@zone[$_zi] 2>/dev/null)" ]; do
        if [ "$(uci -q get firewall.@zone[$_zi].name)" = "wan" ]; then
            uci -q del_list firewall.@zone[$_zi].network='wwan' 2>/dev/null
            break
        fi
        _zi=$((_zi + 1))
    done
    uci commit wireless
    uci commit network
    uci commit firewall
    # 同 sta_on: 只重啟目標 radio, 不要動到另一個 radio 上的 AP/mesh
    if [ -n "$_radio" ]; then
        log "🔌 關閉 STA 備援 → wifi up $_radio"
        wifi up "$_radio" 2>/dev/null || wifi reload
    else
        log "🔌 關閉 STA 備援 → wifi reload (查不到原 radio)"
        wifi reload
    fi
    sleep 8
    /etc/init.d/firewall reload >/dev/null 2>&1
    echo idle > "$STATE_F"
    return 0
}

sta_off() {
    # 已經是乾淨狀態就不做事, 也不推播
    if [ -z "$(uci -q get wireless.${STA_SECTION} 2>/dev/null)" ] \
       && [ -z "$(uci -q get network.wwan 2>/dev/null)" ]; then
        sta_rules_clear
        echo idle > "$STATE_F"
        return 0
    fi
    sta_off_raw
    push_notify "STA備援已關閉: WAN 或 mesh 已恢復, 已還原"
    return 0
}

# ---------- status ----------
show_status() {
    echo "=== STA 備援現況 ==="
    echo "  enable   : $(_read "$ENABLE_F")  (1=自動判斷啟用, 0=完全不動作)"
    echo "  ssid     : $(_read "$SSID_F")"
    echo "  key      : $([ -s "$KEY_F" ] && echo "已設定($(wc -c < "$KEY_F" | tr -d ' ') bytes)" || echo '(空)')"
    echo "  band     : $(_read "$BAND_F")  → radio: $(pick_radio 2>/dev/null || echo '找不到')"
    echo "  state    : $(_read "$STATE_F")"
    echo "  失敗計數 : $(_cnt_get "$FAILCNT_F") / $FAIL_NEED"
    echo "  正常計數 : $(_cnt_get "$OKCNT_F") / $OK_NEED"
    echo "--- 目前判定 ---"
    if wan_ok; then echo "  WAN  : ✅ 通"; else echo "  WAN  : ❌ 不通"; fi
    if mesh_ok; then echo "  mesh : ✅ 有出路"; else echo "  mesh : ❌ 無出路"; fi
    echo "--- uci 現況 ---"
    if [ -n "$(uci -q get wireless.${STA_SECTION} 2>/dev/null)" ]; then
        echo "  STA 介面: 存在 (device=$(uci -q get wireless.${STA_SECTION}.device))"
    else
        echo "  STA 介面: 不存在"
    fi
    echo "  wwan    : $(uci -q get network.wwan >/dev/null 2>&1 && echo '存在' || echo '不存在')"
    _sip=$(ifstatus wwan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
    echo "  wwan IP : ${_sip:-(無)}"
    echo "--- policy routing ---"
    _r=$(ip rule show 2>/dev/null | grep -cE "^(${STA_PREF_SRC}|${STA_PREF_LAN}):")
    echo "  ip rule : $_r 條 (pref $STA_PREF_SRC/$STA_PREF_LAN)"
    ip rule show 2>/dev/null | grep -E "^(${STA_PREF_SRC}|${STA_PREF_LAN}):" | sed 's/^/    /'
    echo "  table $STA_TABLE:"
    ip route show table "$STA_TABLE" 2>/dev/null | sed 's/^/    /' || echo "    (空)"
    echo "--- 主路由表健康檢查 ---"
    # ★ 主表若出現兩筆相同網段 = 上游路由污染了主表, 那正是 2026-09-25
    #   MX4200 失聯的成因。這裡當成告警指標。
    _dup=$(ip route show 2>/dev/null | awk '$1 ~ /\// {print $1}' | sort | uniq -d | tr '\n' ' ')
    if [ -n "$_dup" ]; then
        echo "  ⚠️ 主表有重複網段: $_dup"
    else
        echo "  ✅ 主表無重複網段"
    fi
}

# ===================== main =====================
case "$1" in
    # ⚠️ status 清掉 STA_WAN_OK: 手動查現況時要看「實際量測值」,
    #    不能沿用呼叫端傳進來的快取, 否則顯示的 WAN 狀態可能是舊的。
    status) STA_VERBOSE=1; unset STA_WAN_OK; show_status; exit 0 ;;
    on)     STA_VERBOSE=1; log "手動啟用"; sta_on; exit $? ;;
    off)    STA_VERBOSE=1; log "手動關閉"; sta_off; exit $? ;;
    # 由 hotplug 呼叫: DHCP 續約可能換位址, 規則要跟著重建。
    # ⚠️ 不可只在 sta_on() 套一次 —— 位址一變, 舊的 `from <ip>` 規則就失效,
    #    流量會落回主表(而主表刻意沒有上游路由)→ 整條備援靜默失效。
    rules-refresh) sta_rules_apply; exit $? ;;
    rules-clear)   sta_rules_clear; exit 0 ;;
esac

# ★ 總開關: enable != 1 時「完全不碰任何設定」, 直接結束。
#   這是最後一道保險 —— 腳本部署了但還沒準備好時, 不會有任何副作用。
ENABLE=$(_read "$ENABLE_F")
if [ "$ENABLE" != "1" ]; then
    exit 0
fi

# ⚠️ 防重入: 本腳本由 auto-role.sh 用 `&` 背景呼叫, 而 sta_on() 內要等最多
#   45 秒 DHCP。auto-role 每分鐘跑一次 —— 沒有鎖的話上一輪還在等 DHCP,
#   下一輪又進來再做一次 uci set + wifi up, 兩邊互相打斷,
#   結果是 radio 反覆重啟而永遠連不上。
LOCK_D="/tmp/.sta_backup.lock"
if ! mkdir "$LOCK_D" 2>/dev/null; then
    # 鎖超過 5 分鐘視為殘留(前一輪被 kill 或斷電), 清掉重來
    _age=$(( $(date +%s) - $(date -r "$LOCK_D" +%s 2>/dev/null || echo 0) ))
    if [ "$_age" -gt 300 ]; then
        log "清除殘留鎖 (${_age}s)"
        rmdir "$LOCK_D" 2>/dev/null
        mkdir "$LOCK_D" 2>/dev/null || exit 0
    else
        exit 0
    fi
fi
trap 'rmdir "$LOCK_D" 2>/dev/null' EXIT INT TERM

CUR_STATE=$(_read "$STATE_F"); [ -z "$CUR_STATE" ] && CUR_STATE=idle

if wan_ok || mesh_ok; then
    # 有出路 —— 累積正常計數
    echo 0 > "$FAILCNT_F"
    _ok=$(( $(_cnt_get "$OKCNT_F") + 1 ))
    echo "$_ok" > "$OKCNT_F"
    if [ "$CUR_STATE" = "active" ] && [ "$_ok" -ge "$OK_NEED" ]; then
        log "連續 ${_ok} 次判定有出路, 還原 STA"
        sta_off
        echo 0 > "$OKCNT_F"
    fi
else
    # 無出路 —— 累積失敗計數
    echo 0 > "$OKCNT_F"
    _fail=$(( $(_cnt_get "$FAILCNT_F") + 1 ))
    echo "$_fail" > "$FAILCNT_F"
    log "判定無出路 (${_fail}/${FAIL_NEED})"
    if [ "$CUR_STATE" != "active" ] && [ "$_fail" -ge "$FAIL_NEED" ]; then
        log "連續 ${_fail} 次判定孤島, 啟用 STA 備援"
        sta_on
        echo 0 > "$FAILCNT_F"
    fi
fi

exit 0
