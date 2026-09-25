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

FAIL_NEED=5      # 連續幾次判定孤島才啟用
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
    # 有鄰居, 再看有沒有人 wan_status=up (排除自己)
    command -v alfred >/dev/null 2>&1 || return 0   # 沒 alfred 就只看鄰居數
    _me=$(cat /etc/myscript/.mesh_id 2>/dev/null)
    _up=$(alfred -r 64 2>/dev/null | grep -o '"wan_status\\":\\"up\\"' | wc -l)
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

    # wwan 介面(DHCP client), metric 設高讓它輸給正常 WAN
    uci -q delete network.wwan 2>/dev/null
    uci set network.wwan=interface
    uci set network.wwan.proto='dhcp'
    uci set network.wwan.metric='200'
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

    log "🔌 啟用 STA 備援: radio=$_radio ssid=$_ssid → wifi reload"
    wifi reload
    sleep 10
    /etc/init.d/firewall reload >/dev/null 2>&1

    echo active > "$STATE_F"
    push_notify "STA備援已啟用: 2.4G 連上游 AP [$_ssid] (WAN 與 mesh 皆無出路)"
    return 0
}

# ---------- 關閉 STA 並還原 ----------
sta_off() {
    if [ -z "$(uci -q get wireless.${STA_SECTION} 2>/dev/null)" ]; then
        echo idle > "$STATE_F"
        return 0
    fi
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
    log "🔌 關閉 STA 備援 → wifi reload"
    wifi reload
    sleep 8
    /etc/init.d/firewall reload >/dev/null 2>&1
    echo idle > "$STATE_F"
    push_notify "STA備援已關閉: WAN 或 mesh 已恢復, 2.4G 還原"
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
}

# ===================== main =====================
case "$1" in
    # ⚠️ status 清掉 STA_WAN_OK: 手動查現況時要看「實際量測值」,
    #    不能沿用呼叫端傳進來的快取, 否則顯示的 WAN 狀態可能是舊的。
    status) STA_VERBOSE=1; unset STA_WAN_OK; show_status; exit 0 ;;
    on)     STA_VERBOSE=1; log "手動啟用"; sta_on; exit $? ;;
    off)    STA_VERBOSE=1; log "手動關閉"; sta_off; exit $? ;;
esac

# ★ 總開關: enable != 1 時「完全不碰任何設定」, 直接結束。
#   這是最後一道保險 —— 腳本部署了但還沒準備好時, 不會有任何副作用。
ENABLE=$(_read "$ENABLE_F")
if [ "$ENABLE" != "1" ]; then
    exit 0
fi

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
