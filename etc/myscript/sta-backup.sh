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
#   /etc/myscript/.sta_backup_ap      ★ 候選清單, 每行 band<TAB>ssid<TAB>key (600)
#                                       來自 Sheet 的 sta_backup_{ssid,key,band}{1,2,3}
#                                       依行序 1→2→3 試, 第一個連上的就用
#                                       band 可填 2g / 5g / auto(auto=掃描決定)
#   /etc/myscript/.sta_backup_enable  1=啟用自動判斷, 0=完全不動作(預設)
#   -- 以下為舊的單組旗標, 僅在 .sta_backup_ap 不存在時當退路(向後相容) --
#   /etc/myscript/.sta_backup_ssid    上游 AP 名稱
#   /etc/myscript/.sta_backup_key     密碼 (600)
#   /etc/myscript/.sta_backup_band    2g / 5g (預設 2g)
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
# ★ 多組候選清單(2026-09-28): 每行一組, TAB 分三欄 band<TAB>ssid<TAB>key
#   由 sync-googleconfig.sh 從 Sheet 的 sta_backup_{ssid,key,band}{1,2,3} 落檔。
#   依行序 1→2→3 嘗試, 第一個「掃到得且連得上」的就用。
#   ⚠️ 用 TAB 而非 / ; , : 空白 —— 那些字元在 WiFi 密碼與 SSID 裡都合法,
#     當分隔符會靜默解析錯位, 而且只在真的斷線(人在外面)時才發作。
#   ⚠️ 不存在或空 = 退回讀舊的三個單組旗標(部署時差 / 舊 Sheet 相容)。
AP_F="$CFG_DIR/.sta_backup_ap"

STATE_F="/tmp/.sta_backup_state"       # active / idle
# ★ 自動解套計時器(落 flash, 跨重開有效):
#   記錄「失去所有出路」的起始時間。超過 STUCK_LIMIT 仍沒救回 → 重開機。
#   為什麼需要: STA 備援可能把自己卡在「連上了但判斷函式看不到、或路由只
#   建了一半」的中間態 —— 那時人在外面完全進不去, 只能等。重開至少能回到
#   乾淨狀態讓 WAN/mesh 重新協商。
# ⚠️ 必須放 flash: 放 /tmp 的話重開就歸零, 永遠累積不到門檻, 等於沒有保險。
STUCK_F="/etc/myscript/.sta_backup_stuck_since"
STUCK_LIMIT=600                        # 10 分鐘
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

# ★ log 必須同時落 flash —— 這功能的故障場景就是「機器失聯/重開」,
#   而 /tmp 與 syslog ring buffer 都會在重開後消失, 正好在最需要證據時沒了。
#   實測 2026-09-26 連兩次測試失敗都因此只能靠推測(第三次靠使用者手動
#   貼 /tmp/statest.log 才定位)。
# ⚠️ 只在「真的有事發生」時寫, 不是每輪都寫 —— 否則每分鐘磨 flash。
#   平常判斷無出路只累積計數不寫檔(見主流程), 寫的是狀態轉換與錯誤。
# ⚠️ 自行截斷到 400 行, 避免無限長大。
STA_FLOG="/etc/myscript/.sta_backup.log"
log() {
    logger -t "$TAG" "$1"
    [ -n "$STA_VERBOSE" ] && echo "$1"
    echo "$(date '+%m-%d %H:%M:%S') $1" >> "$STA_FLOG" 2>/dev/null
    # 超過 500 行才修剪, 攤提寫入成本
    if [ "$(wc -l < "$STA_FLOG" 2>/dev/null || echo 0)" -gt 500 ]; then
        tail -n 400 "$STA_FLOG" > "${STA_FLOG}.tmp" 2>/dev/null && mv "${STA_FLOG}.tmp" "$STA_FLOG"
    fi
}

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
# 用法: pick_radio [band]   band 省略時讀舊旗標 .sta_backup_band(預設 2g)
pick_radio() {
    _want="$1"
    [ -z "$_want" ] && _want=$(_read "$BAND_F")
    [ -z "$_want" ] && _want=2g
    for _r in radio0 radio1 radio2 radio3; do
        _b=$(uci -q get wireless.$_r.band 2>/dev/null)
        [ "$_b" = "$_want" ] && { echo "$_r"; return 0; }
    done
    return 1
}

# ---------- 候選清單 ----------
# 輸出: 每行 band<TAB>ssid<TAB>key
# 優先讀 AP_F; 沒有就用舊的三個單組旗標組一行出來(向後相容)。
ap_list() {
    if [ -s "$AP_F" ]; then
        # 只輸出至少有 ssid(第 2 欄非空)的行
        awk -F'\t' 'NF>=2 && $2 != "" {print}' "$AP_F" 2>/dev/null
        return 0
    fi
    _ls=$(_read "$SSID_F")
    [ -n "$_ls" ] || return 0
    _lb=$(_read "$BAND_F"); [ -z "$_lb" ] && _lb=2g
    printf '%s\t%s\t%s\n' "$_lb" "$_ls" "$(_read "$KEY_F")"
}

# ---------- 掃描: 目標 SSID 在不在 ----------
# 用法: scan_find <ssid> <band>   band=auto 時兩個 radio 都掃
# 輸出: 掃到的話印出該 radio 名稱並 return 0; 沒掃到 return 1
# ★ 為什麼一定要先掃: sta_try_one() 連不上時要等 45 秒 timeout 才回滾。三組
#   候選若都硬試就是 135 秒全家沒網。掃描成本實測便宜得多 ——
#   2026-09-28 於 x60pro: phy0(2.4G) 2 秒掃到 61 個 SSID, phy1(5G) 5 秒。
# ⚠️ 但「掃不到」絕不等於「不存在」: 同一次實測 phy1-ap0 掃到 0 個 SSID
#   (正在當 AP 用的 radio 掃描結果可能不含所有頻道)。若只信掃描結果,
#   5G 的候選會永遠不被嘗試 —— 故 sta_on() 必須保留「盲試」第二段。
scan_find() {
    _sf_ssid="$1"; _sf_band="$2"
    [ -n "$_sf_ssid" ] || return 1
    command -v iwinfo >/dev/null 2>&1 || return 1
    case "$_sf_band" in
        auto) _sf_bands="2g 5g" ;;
        *)    _sf_bands="$_sf_band" ;;
    esac
    for _sf_b in $_sf_bands; do
        _sf_r=$(pick_radio "$_sf_b") || continue
        # radio 上任一個既有 iface 的 device 名稱都可拿來掃。
        # ★ 用 ubus 取(實測 2026-09-28 於 x60pro: radio0→phy0-ap0, radio1→phy1-ap0)。
        # ⚠️ 不要試圖從 `iwinfo` 無參數輸出反查 radio —— 它只印 "PHY name: phy0",
        #   完全沒有 radioN 字樣, 任何比對 radioN 的 awk 都永遠不會 match。
        _sf_dev=$(ubus call network.wireless status 2>/dev/null \
            | jsonfilter -e "@[\"$_sf_r\"].interfaces[0].ifname" 2>/dev/null)
        # fallback: 由 radioN 推 phyN, 取該 phy 第一個介面
        if [ -z "$_sf_dev" ]; then
            _sf_phy="phy${_sf_r#radio}"
            _sf_dev=$(iwinfo 2>/dev/null | awk -v p="$_sf_phy" '
                $2 == "ESSID:" { dev=$1 }
                /PHY name:/ && $NF == p { print dev; exit }')
        fi
        [ -z "$_sf_dev" ] && continue
        # ⚠️ 精準比對整個 ESSID 欄位, 不可用 grep 子字串 —— "IOT" 會誤中 "IOT-5G"
        if iwinfo "$_sf_dev" scan 2>/dev/null \
           | sed -n 's/^[[:space:]]*ESSID:[[:space:]]*"\(.*\)"$/\1/p' \
           | grep -qxF "$_sf_ssid"; then
            echo "$_sf_r"
            return 0
        fi
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
    # ★ 主表裡那兩筆 metric 300 也要清 —— 它們指向 STA 介面, STA 拆掉後
    #   會變成殘留的死路由, 讓本機以為還有出口。
    #   用 metric 300 精準比對, 不會誤刪 WAN(metric 0)或 wg 的路由。
    ip route show default 2>/dev/null | grep -q 'metric 300' \
        && ip route del default metric 300 2>/dev/null
    ip route show 2>/dev/null | awk '/metric 300/ && !/^default/ {print $1}' | while read -r _n; do
        [ -n "$_n" ] && ip route del "$_n" metric 300 2>/dev/null
    done
}

# ★ DNS upstream 接手(2026-09-28)
#   本機 dnsmasq 是 noresolv='1' + 寫死的 server(這台是 1.1.1.1), 完全不讀
#   resolv.conf.auto。STA 期間那個 upstream 未必通 —— 飯店/公共 WiFi 常攔截
#   或只放行自家 DNS —— client 就全部解析不了。改用上游 AP 給的。
#   ⚠️ 原本放在 95-sta-backup hotplug, 實測 2026-09-28 失敗: 備份檔寫出來了
#     但 uci 沒換成上游的, 連 logger 都沒留紀錄 —— 函式跑到一半中斷, 極可能
#     是中間的 `/etc/init.d/dnsmasq reload` 把 netifd 觸發的 hotplug 帶掉了。
#   ⚠️ 也不能只放在 sta_rules_apply(): 那只在「規則需要重建」時跑, STA 剛起來
#     那一瞬間 ifstatus wwan 的 dns-server 往往還沒填好 -> 錯過就永遠補不上。
#     實測 09:40 切換時沒接手, 直到 09:47 手動 rules-refresh 才成功。
#   ★ 故設計成冪等函式, 由「每輪都會走到」的穩定態路徑也呼叫一次。
sta_dns_takeover() {
    _updns=$(ifstatus wwan 2>/dev/null | jsonfilter -e '@["dns-server"][*]' 2>/dev/null | tr '\n' ' ')
    [ -n "$_updns" ] || return 0
    _curdns=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | tr '\n' ' ')
    # 冪等: 已經是上游那組就不要每分鐘重寫 flash + reload dnsmasq
    [ "$_curdns" = "$_updns" ] && return 0
    [ -f /etc/myscript/.sta_dns_prev ] || \
        { uci -q get dhcp.@dnsmasq[0].server > /etc/myscript/.sta_dns_prev 2>/dev/null \
          || : > /etc/myscript/.sta_dns_prev; }
    uci -q delete dhcp.@dnsmasq[0].server
    for _d in $_updns; do uci add_list dhcp.@dnsmasq[0].server="$_d"; done
    uci commit dhcp
    /etc/init.d/dnsmasq reload >/dev/null 2>&1
    log "DNS upstream 改用上游 AP 提供的: $_updns (原: $_curdns)"
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

    # ★ 死結偵測: 上游閘道與本機 LAN IP 相同 —— 無解, 必須拒絕。
    #   實測 2026-09-27 於 MX4200: 自己是 192.168.1.1, 而鄰居 AP 的閘道
    #   也是 192.168.1.1(192.168.1.0/24 是台灣最常見的預設)。
    #   `default via 192.168.1.1` 在核心眼中會匹配到本地 br-lan 那筆,
    #   封包繞回自己永遠出不去 —— policy routing 也解不了, 因為問題不在
    #   路由表選擇, 而在「同一個 IP 同時是自己和別人」。
    # ★ 解法: 切換本機 LAN IP 到 Sheet 定義的 sta_lan_ip(預設 192.168.1.9)。
    #   同網段但不同位址 —— LAN 裝置的 IP 不用重拿, 只需更新閘道。
    #   平常維持 192.168.1.1 不變, 只有 STA 期間才切, 回復時由 sta_off 還原。
    # ⚠️ 沒設 .sta_lan_ip 就拒絕啟用: 硬上會讓封包繞回自己, 而那個狀態
    #   從外面完全看不出來(STA 連上、拿到 IP、路由都建了, 就是不通)。
    # ⚠️ 通知用 queue_push 不可用 push_notify —— 偵測到衝突的時機正是
    #   「唯一出口還沒建立」, 推播必然送不出去(2026-09-27 使用者指出)。
    _lan_self=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    if [ -n "$_gw" ] && [ "$_gw" = "$_lan_self" ]; then
        _sta_ip=$(cat /etc/myscript/.sta_lan_ip 2>/dev/null)
        case "$_sta_ip" in ''|*[!0-9.]*) _sta_ip="" ;; esac
        if [ -z "$_sta_ip" ] || [ "$_sta_ip" = "$_gw" ]; then
            log "❌ 位址衝突: 上游閘道($_gw) 與本機 LAN IP 相同, 而 .sta_lan_ip 未設或同值"
            log "   解法: 在 Sheet 的 sta_lan_ip 填一個同網段但不同的位址(例如 192.168.1.9)"
            _cf="/etc/myscript/.sta_conflict_notified"
            _now=$(date +%s); _prev=$(cat "$_cf" 2>/dev/null)
            case "$_prev" in ''|*[!0-9]*) _prev=0 ;; esac
            if [ $(( _now - _prev )) -ge 3600 ]; then
                echo "$_now" > "$_cf"
                command -v queue_push >/dev/null 2>&1 && \
                    queue_push "sta-backup-conflict" "sta-lan-ip-unset" \
                        "上游閘道 $_gw 與本機 LAN IP 相同, 但 Sheet 的 sta_lan_ip 未設定。請填一個同網段不同位址(例如 192.168.1.9)。" \
                        >/dev/null 2>&1
            fi
            return 1
        fi
        # 切換本機 LAN IP, 避開上游閘道
        # ⚠️ 記下原值供 sta_off 還原 —— 放 flash, 因為 STA 期間可能重開。
        [ -f /etc/myscript/.sta_lan_ip_prev ] || echo "$_lan_self" > /etc/myscript/.sta_lan_ip_prev
        log "位址衝突($_gw): 本機 LAN $_lan_self → $_sta_ip (避開上游閘道)"
        uci set network.lan.ipaddr="$_sta_ip"
        uci commit network
        ip addr del "$_lan_self/24" dev br-lan 2>/dev/null
        ip addr add "$_sta_ip/24" dev br-lan 2>/dev/null
        # DHCP 也要改發新閘道, 否則 client 仍指向舊位址(那已是上游鄰居)
        uci -q delete dhcp.lan.dhcp_option
        uci add_list dhcp.lan.dhcp_option="3,$_sta_ip"
        uci add_list dhcp.lan.dhcp_option="6,$_sta_ip"
        # ⚠️ 2026-09-28 走過的死路,別再試: 曾在這裡把 dhcp.lan.ra / dhcpv6 設成
        #   'disabled', 想讓 client 別再拿 br-lan 的 ULA(fdff:...::1)當 IPv6 DNS
        #   —— 因為那個位址寫死, 不會跟著 IPv4 從 .1 改成 .9。
        #   ★ 實測是反效果: 停 RA 只讓 client「不再更新」IPv6 設定, 不會讓它
        #     「立刻丟棄」。Windows 仍把 ULA 排在 IPv4 DNS 前面當首選, 但 IPv6
        #     的路由/鄰居關係已經失效 -> 封包根本送不到 -> nslookup 全逾時
        #     (使用者實測: 瀏覽器能上網但 nslookup 對 ULA 連續 timeout)。
        #   ★ 正解是「發了就要能用」: dnsmasq 本來就在 ULA 上監聽(netstat 可證),
        #     只要它的 upstream 是通的(見 sta_dns_takeover 接手上游 AP 的 DNS),
        #     IPv6 查詢一樣查得到。實測 `nslookup ... fdff:fe7f:9ad6::1` ✅通。
        #   所以這裡「不碰」IPv6 RA, 只改 IPv4 的 dhcp_option。
        uci commit dhcp
        /etc/init.d/dnsmasq reload >/dev/null 2>&1
        _lan_self="$_sta_ip"
    fi
    rm -f /etc/myscript/.sta_conflict_notified 2>/dev/null

    sta_rules_clear

    # ★ 把 DHCP 寫進「主表」的那兩筆搬走 —— 這是本功能的核心。
    #   留著的話主表會有兩筆 192.168.1.0/24(br-lan 與 phy1-sta0)互搶,
    #   回本地 LAN 的封包被送去上游 → SSH/Tailscale 同時斷, 整台失聯
    #   (2026-09-25 於 MX4200 實際發生過, 只能現場重開)。
    # ⚠️ 必須在「加 table 99 的規則之前」搬, 否則中間那段時間主表仍是髒的。
    # ⚠️ default 那筆要指定 dev, 不可只 `ip route del default` ——
    #   那會把 WAN 或 wg 的預設路由一起刪掉。
    ip route del default via "$_gw" dev "$_dev" 2>/dev/null

    # ★ 還要清掉 auto-role 在「角色降 client」時加的那筆:
    #     default via 192.168.1.1 dev br-lan proto static
    #   它指向「主 gw」, 但 STA 備援的情境下自己就是唯一出口, 而 192.168.1.1
    #   在 br-lan 側根本沒有人 —— 本機自己發出的封包(dnsmasq 查 upstream、
    #   ntp、推播)會走主表(ip rule 32766)命中這筆, 送進死路。
    #   實測 2026-09-27 於 MX4200: LAN 裝置 tracert 1.1.1.1 完全通(走
    #   table 99), 但 ping www.google.com 找不到主機 —— 只有 DNS 不通,
    #   因為那是 dnsmasq「以本機身分」發出的查詢。
    # ⚠️ 必須指定 dev br-lan, 不可只 `ip route del default` —— 會誤刪 wg 的。
    _lan_gw_route=$(ip route show default dev br-lan 2>/dev/null | head -1)
    if [ -n "$_lan_gw_route" ]; then
        ip route del default dev br-lan 2>/dev/null \
            && log "已移除 client 遺留的 default via br-lan(否則本機自身流量走死路)"
    fi
    ip route del "$(_net_of "$_ip" "$_mask")" dev "$_dev" 2>/dev/null

    # 上游網段(由實際位址推算, 不可假設是 /24 或 192.168.1.x)
    _upnet=$(_net_of "$_ip" "$_mask")
    _lan_ip=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    _lan_cidr=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | head -1)
    _lan_mask=$(echo "$_lan_cidr" | cut -d/ -f2)
    _lannet=$(_net_of "$_lan_ip" "$_lan_mask")

    # table 99 的路由
    # ⚠️ 上游與本地「同網段」時(192.168.1.0/24 是台灣最常見的預設, 實測鄰居
    #    與自家都是), 兩筆 ip route add 的目的網段完全相同 —— 第二筆會因
    #    「路由已存在」而失敗, 且錯誤被 2>/dev/null 吞掉, 完全無聲。
    #    實測 2026-09-27 於 MX4200: t99 只有 2 筆而非預期的 3 筆。
    # ★ 順序也很關鍵: 原本先加「走上游」那筆, 同網段時它會佔住位置,
    #    結果 LAN 內互連(例如連 NAS)全被送去鄰居。
    #    改為「本地 LAN 先寫、且同網段時不再寫上游」——
    #    本地優先是對的: 自家 LAN 的封包不該出門。
    #    非同網段時兩筆都要, 上游網段用於 STA 自己與閘道溝通。
    ip route replace "$_lannet" dev br-lan src "$_lan_ip" table "$STA_TABLE" 2>/dev/null
    if [ "$_upnet" != "$_lannet" ]; then
        ip route replace "$_upnet" dev "$_dev" src "$_ip" table "$STA_TABLE" 2>/dev/null
    else
        # 同網段: 用 /32 主機路由單獨指出閘道, 才不會被上面那筆本地路由蓋掉。
        # 沒有這筆的話 default via $_gw 找不到出介面 → 整個 table 99 形同虛設。
        ip route replace "$_gw" dev "$_dev" src "$_ip" table "$STA_TABLE" 2>/dev/null
    fi
    ip route replace default via "$_gw" dev "$_dev" table "$STA_TABLE" 2>/dev/null

    # ★ 主表也要有一筆走 STA 的 default —— 否則「本機自己」發出的封包無路可走。
    #   ip rule 的 990/991 只涵蓋 from <sta_ip> 與 from <lan_net>, 但本機
    #   程序(dnsmasq 查 upstream、ntp、push_notify)在「還沒決定來源位址」時
    #   查的是主表(rule 32766 from all lookup main)。主表沒有 default
    #   就直接 unreachable, 連來源位址都選不出來。
    # ⚠️ metric 設高(300): 真正的 WAN 恢復時它的 default(metric 0)會優先,
    #   不會被這筆蓋住; sta_rules_clear 也會把它清掉。
    # ⚠️ 這筆刻意「不」放 table 99 —— 它的作用對象就是主表的使用者。
    # ⚠️ 必須先在主表加 /32 主機路由指出閘道的出介面, 否則下一行會失敗:
    #   主表此時只剩 `192.168.1.0/24 dev br-lan`, 核心認為 192.168.1.1 在
    #   br-lan 上而非 phy1-sta0, 於是拒絕建立 `default via 192.168.1.1
    #   dev phy1-sta0`(錯誤被 2>/dev/null 吞掉, 完全無聲)。
    #   實測 2026-09-27: 監控顯示 defrt=0 —— 主表 default 被刪光卻沒補回來,
    #   本機所有對外流量回 "Network unreachable"。
    ip route replace "$_gw" dev "$_dev" src "$_ip" metric 300 2>/dev/null
    ip route replace default via "$_gw" dev "$_dev" metric 300 2>/dev/null \
        && log "主表已補 default via $_gw dev $_dev metric 300(供本機自身流量)"

    # ★ 驗證主表真的有 default —— 沒有的話本機完全出不去, 必須回報失敗
    #   讓上層回滾, 不要停在「看似成功實則斷網」的狀態。
    if [ "$(ip route show default 2>/dev/null | wc -l)" -eq 0 ]; then
        log "❌ 主表沒有任何 default route, 本機將完全無法對外"
        ip route show 2>/dev/null | head -6 | while read -r _l; do log "   主表: $_l"; done
        return 1
    fi

    ip rule add from "$_ip" table "$STA_TABLE" pref "$STA_PREF_SRC" 2>/dev/null
    ip rule add from "$_lannet" table "$STA_TABLE" pref "$STA_PREF_LAN" 2>/dev/null

    # ★ 驗證 table 99 真的有 default —— 少了它整個備援等於沒出口,
    #   而 ip route add 失敗是被 2>/dev/null 吞掉的無聲錯誤。
    if ! ip route show table "$STA_TABLE" 2>/dev/null | grep -q '^default'; then
        log "❌ table $STA_TABLE 沒有 default route, 規則建立失敗:"
        ip route show table "$STA_TABLE" 2>/dev/null | while read -r _l; do log "   t99: $_l"; done
        return 1
    fi
    _t99n=$(ip route show table "$STA_TABLE" 2>/dev/null | wc -l)
    log "table $STA_TABLE 共 ${_t99n} 筆:"
    ip route show table "$STA_TABLE" 2>/dev/null | while read -r _l; do log "   t99: $_l"; done

    log "規則已套用: ip=$_ip dev=$_dev gw=$_gw upnet=$_upnet lannet=$_lannet table=$STA_TABLE"
    [ "$_upnet" = "$_lannet" ] && \
        log "⚠️ 上游與本地同網段($_upnet) —— 已用 policy routing 隔離, 但 LAN 內若有與上游相同的主機位址仍會有歧義"

    sta_dns_takeover

    # ★ 驗證: 主表不可再有指向 STA 介面的路由, 否則等於沒搬(仍會失聯)。
    #   搬不乾淨時寧可整個回滾, 也不要留在「連上了但把自己鎖在門外」的狀態。
    # ⚠️ 必須排除 metric 300 —— 那兩筆是本函式「刻意」補進主表的
    #   (供本機自身流量使用, 見上方說明)。不排除的話會自我矛盾:
    #   剛補完就被判定為「搬移失敗」→ 回滾 STA → 10 分鐘後自動重開。
    #   實測 2026-09-27 15:18:17 就是這樣連鎖觸發重開的。
    # ⚠️ 只檢查「會搶走整片流量」的路由 —— default 與整段網段(含 /24 等)。
    #   不可把所有指向該介面的路由都當殘留:
    #     * metric 300 是本函式刻意補進主表的(供本機自身流量)
    #     * PBR 的 CustRule 會把特定主機 /32 指向當前出口, WAN 斷線期間
    #       自然會指到 phy1-sta0 —— 那是 pbr 的正常行為, 不是我們的殘留。
    #   實測 2026-09-27 21:31: 主表有
    #     180.177.189.12 via 192.168.1.1 dev phy1-sta0 proto static metric 200
    #     211.72.195.28  via 192.168.1.1 dev phy1-sta0 proto static metric 200
    #   被誤判為搬移失敗 → sta_rules_apply 一直 return 1 → sta_off 走不到
    #   → STA 拆不掉, t99/rule/metric300 全部殘留。
    _leftover=$(ip route show 2>/dev/null | grep " dev $_dev " \
        | grep -v 'metric 300' \
        | grep -cE '^default |^[0-9.]+/[0-9]+ ')
    if [ "$_leftover" -gt 0 ]; then
        log "❌ 主表仍有 ${_leftover} 筆會搶走流量的 $_dev 路由, 搬移失敗:"
        ip route show 2>/dev/null | grep " dev $_dev " | grep -v 'metric 300' \
            | grep -E '^default |^[0-9.]+/[0-9]+ ' \
            | while read -r _l; do log "   主表殘留: $_l"; done
        return 1
    fi
    log "✅ 主表已無會搶流量的 $_dev 路由, 隔離完成"
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
# ---------- 嘗試單一組候選 ----------
# 用法: sta_try_one <band> <ssid> <key> [radio]
#   radio 省略時由 band 決定(band=auto 且沒給 radio 視為錯誤 —— 呼叫端
#   應該已用 scan_find 決定好 radio)。
# 回傳: 0=成功(已連上且路由建好), 1=失敗(已自行回滾)
sta_try_one() {
    _band="$1"; _ssid="$2"; _key="$3"; _radio="$4"
    if [ -z "$_ssid" ]; then
        log "❌ 無法啟用: SSID 是空的"
        return 1
    fi
    if [ -z "$_radio" ]; then
        case "$_band" in
            auto) log "❌ band=auto 但未指定 radio(掃描未命中), 跳過 [$_ssid]"; return 1 ;;
        esac
        _radio=$(pick_radio "$_band") || { log "❌ 找不到 band=$_band 的 radio"; return 1; }
    fi

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
    # ⚠️ defaultroute 必須是 1(2026-09-27 修正):
    #   原本設 0 想避免污染主表, 但那同時也讓 udhcpc 不去建那筆路由 ——
    #   於是 `ifstatus wwan` 的 .route[] 是空陣列, sta_rules_apply() 取
    #   @.route[0].nexthop 拿不到 gateway, 直接 return 1 不建任何規則。
    #   實測 2026-09-26 於 MX4200: STA 成功連上 IOT 並拿到 192.168.1.249,
    #   但監控全程 rule=0, LAN 完全出不去(tracert 回「目的地主機無法連線」)。
    #   ★ 自己關掉主表路由, 又要求一定要有 gateway 才肯建替代規則 —— 自相矛盾。
    #   改為讓 DHCP 正常建路由, 再由 hotplug(95-sta-backup)在 ifup 時
    #   把它從主表搬進 table 99。代價是有數秒空窗期主表是髒的。
    uci set network.wwan.defaultroute='1'
    # ⚠️ peerdns 必須是 1(2026-09-28 修正):
    #   原本設 0, 想避免上游 DNS 污染設定, 結果 dnsmasq 只剩寫死的 upstream
    #   (本機 uci dhcp.@dnsmasq[0].server, 這台是 1.1.1.1)。那在飯店/公共
    #   WiFi 幾乎一定失敗 —— 它們常攔截或只允許自家 DNS。
    #   實測 2026-09-28 於 MX4200: STA 起來後 client DNS 連續三分鐘查不到
    #   (09:16 ❌ / 09:17 ❌ / 09:18 ❌, 09:19 才 ✅), 而 ping 1.1.1.1 在
    #   09:18 就通了 —— 差距是 dnsmasq 對不通的 upstream 在做退避重試。
    #   ★ 收下上游給的 DNS 當 upstream(那是上游自己的, 一定通),
    #     由 95-sta-backup hotplug 寫進 dnsmasq 並 reload。
    uci set network.wwan.peerdns='1'
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
        # ⚠️ 不在這裡推播 —— 多組候選時每組失敗各推一次會連發三則。
        #   把原因記進 $STA_FAILMSG, 由 sta_on() 在「全部都失敗」時推一則。
        STA_FAILMSG="${_w}s 內未取得 IP, 檢查 [$_ssid] 名稱/密碼/訊號"
        return 1
    fi

    /etc/init.d/firewall reload >/dev/null 2>&1

    # ★ 必須檢查回傳值: 規則沒建成就等於「連上了但沒有出口」, 而且主表可能
    #   還留著與本地 LAN 衝突的路由 —— 那正是 2026-09-25 整台失聯的狀態。
    #   寧可回滾成「沒有備援」, 也不要停在「看似成功實則鎖死」。
    if ! sta_rules_apply; then
        log "❌ policy routing 建立失敗, 回滾 STA"
        _gwchk=$(ifstatus wwan 2>/dev/null | jsonfilter -e '@.route[0].nexthop' 2>/dev/null)
        _lanchk=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
        sta_off_raw
        # ⚠️ 同上: 原因留給 sta_on() 統一推播, 避免多組候選連發。
        if [ -n "$_gwchk" ] && [ "$_gwchk" = "$_lanchk" ]; then
            STA_FAILMSG="上游 [$_ssid] 的閘道($_gwchk)與本機 LAN IP 相同, 網段衝突無解。需把自家 LAN 或上游其一改網段。"
        else
            STA_FAILMSG="已連上 [$_ssid] 但路由隔離失敗, 已回滾(避免失聯)"
        fi
        return 1
    fi

    echo active > "$STATE_F"
    _shownet=$(ifstatus wwan 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
    _via=$(ip route show table "$STA_TABLE" 2>/dev/null | awk '/^default/{print $3}')
    push_notify "STA備援已啟用: 連上 [$_ssid] 取得 ${_shownet} (閘道 ${_via:-?}, WAN 與 mesh 皆無出路)"
    return 0
}

# ---------- 啟用 STA(依序試多組候選) ----------
# ★ 依 .sta_backup_ap 的行序 1→2→3 嘗試, 第一個成功的就停(使用者自己排優先權)。
# ★ 兩段式: 先「只試掃到的」, 全都沒掃到才「盲試」沒掃到的那些。
#   為什麼分兩段: iwinfo scan 對正在當 AP 用的 radio 可能掃不全(頻道受限),
#   「掃不到」不等於「不存在」。若只信掃描結果, 會在 AP 其實在場時完全不試。
#   但也不能無條件盲試每一組 —— 每組失敗要 45 秒, 三組就是 135 秒全家沒網。
#   折衷: 掃到的優先(快且準), 沒掃到的當退路(慢但不放棄)。
sta_on() {
    # 已經在了就不重複做(在進迴圈前先檔掉, 省掉掃描)
    if [ -n "$(uci -q get wireless.${STA_SECTION} 2>/dev/null)" ]; then
        log "STA 介面已存在, 不重複建立"
        return 0
    fi

    _list=$(ap_list)
    if [ -z "$_list" ]; then
        log "❌ 無法啟用: 候選清單是空的(.sta_backup_ap 與 .sta_backup_ssid 都沒有值)"
        return 1
    fi
    _total=$(printf '%s\n' "$_list" | grep -c .)
    log "STA 候選共 $_total 組, 開始掃描"

    STA_FAILMSG=""
    _tried=0
    _unscanned=""

    # ── 第一段: 掃到的才試 ──
    _i=0
    while IFS='	' read -r _b _s _k; do
        [ -n "$_s" ] || continue
        _i=$(( _i + 1 ))
        [ -z "$_b" ] && _b=2g
        if _r=$(scan_find "$_s" "$_b"); then
            log "組$_i [$_s] band=$_b: 掃到(radio=$_r), 嘗試連線"
            _tried=$(( _tried + 1 ))
            if sta_try_one "$_b" "$_s" "$_k" "$_r"; then
                log "✅ 組$_i [$_s] 連線成功"
                return 0
            fi
            log "組$_i [$_s] 失敗: ${STA_FAILMSG:-未知原因}"
        else
            log "組$_i [$_s] band=$_b: 未掃到, 暫時跳過"
            # ⚠️ 用 TAB 保持欄位完整(SSID/密碼可能含空白)
            _unscanned="${_unscanned}${_b}	${_s}	${_k}
"
        fi
    done <<EOF
$_list
EOF

    # ── 第二段: 全都沒連上, 盲試沒掃到的 ──
    if [ -n "$_unscanned" ]; then
        log "掃到的候選都不成(或都沒掃到), 改盲試未掃到的組"
        _j=0
        while IFS='	' read -r _b _s _k; do
            [ -n "$_s" ] || continue
            _j=$(( _j + 1 ))
            [ -z "$_b" ] && _b=2g
            # band=auto 且沒掃到 → 無從得知該用哪個 radio, 退回 2g(較可能)
            case "$_b" in auto) _b=2g ;; esac
            log "盲試$_j [$_s] band=$_b"
            _tried=$(( _tried + 1 ))
            if sta_try_one "$_b" "$_s" "$_k" ""; then
                log "✅ 盲試$_j [$_s] 連線成功"
                return 0
            fi
            log "盲試$_j [$_s] 失敗: ${STA_FAILMSG:-未知原因}"
        done <<EOF
$_unscanned
EOF
    fi

    # 全部都失敗 —— 推一則, 不是每組一則
    log "❌ $_total 組候選全部失敗(實際嘗試 $_tried 組)"
    push_notify "STA備援啟用失敗: $_total 組候選全試過都連不上。最後一組原因: ${STA_FAILMSG:-未知}"
    return 1
}

# ---------- 關閉 STA 並還原 ----------
# sta_off_raw: 只做清理, 不推播 —— 給「啟用失敗要回滾」用,
#              那種情況由呼叫端自己推更精確的訊息。
sta_off_raw() {
    sta_rules_clear
    ifdown wwan 2>/dev/null

    # ★ 還原 STA 期間切換過的 LAN IP。
    # ⚠️ 必須在這裡做而非交給 auto-role —— auto-role 的主 gw 分支寫死
    #   192.168.1.1, 但本機當下可能是 client 角色(WAN 還沒回來), 那條
    #   路徑不會執行, LAN IP 會一直停在 sta_lan_ip。
    # ⚠️ .sta_lan_ip_prev 放 flash: STA 期間可能重開, 放 /tmp 會失去原值。
    _prev_ip=$(cat /etc/myscript/.sta_lan_ip_prev 2>/dev/null)
    case "$_prev_ip" in ''|*[!0-9.]*) _prev_ip="" ;; esac
    if [ -n "$_prev_ip" ]; then
        _now_ip=$(ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
        if [ "$_now_ip" != "$_prev_ip" ]; then
            log "還原 LAN IP: $_now_ip → $_prev_ip"
            uci set network.lan.ipaddr="$_prev_ip"
            uci commit network
            ip addr del "$_now_ip/24" dev br-lan 2>/dev/null
            ip addr add "$_prev_ip/24" dev br-lan 2>/dev/null
        fi
        # DHCP option 一併清掉, 回到 dnsmasq 預設(發自己的介面位址)
        if [ -n "$(uci -q get dhcp.lan.dhcp_option 2>/dev/null)" ]; then
            uci -q delete dhcp.lan.dhcp_option
            uci commit dhcp
            /etc/init.d/dnsmasq reload >/dev/null 2>&1
        fi
        # 舊版(2026-09-28 上午)曾在 STA 期間把 ra/dhcpv6 設成 disabled, 那是
        # 死路已移除(見 ~line 257 的說明)。這裡只負責「把舊版留下的旗標還原後
        # 清掉」—— 升級前就進入 STA 的機器, 旗標會殘留在 flash。
        if [ -f /etc/myscript/.sta_ra_prev ]; then
            uci set dhcp.lan.ra="$(cat /etc/myscript/.sta_ra_prev)"
            _dh6=$(cat /etc/myscript/.sta_dhcpv6_prev 2>/dev/null)
            [ -n "$_dh6" ] && uci set dhcp.lan.dhcpv6="$_dh6"
            rm -f /etc/myscript/.sta_ra_prev /etc/myscript/.sta_dhcpv6_prev
            uci commit dhcp
            /etc/init.d/odhcpd restart >/dev/null 2>&1
            log "STA 拆除: 已還原舊版停用的 IPv6 RA/DHCPv6(相容處理)"
        fi
        # ★ 還原 dnsmasq 的 upstream DNS(hotplug 95-sta-backup 在 STA 期間
        #   改成上游 AP 給的)。這裡再做一次是保險 —— 若 wwan 是被直接刪掉
        #   而非 ifdown, hotplug 不會觸發, DNS 就會卡在上游的值。
        if [ -f /etc/myscript/.sta_dns_prev ]; then
            uci -q delete dhcp.@dnsmasq[0].server
            while read -r _d; do
                [ -n "$_d" ] && uci add_list dhcp.@dnsmasq[0].server="$_d"
            done < /etc/myscript/.sta_dns_prev
            rm -f /etc/myscript/.sta_dns_prev
            uci commit dhcp
            /etc/init.d/dnsmasq reload >/dev/null 2>&1
            log "STA 拆除: 已還原 DNS upstream"
        fi
        rm -f /etc/myscript/.sta_lan_ip_prev
        # ★ 還原 STA 期間被停掉的 wg / PBR / DBR(2026-09-28)
        #   STA 供網時 auto-role 會主動停掉它們(見 auto-role.sh ~line 540 的
        #   決策說明), WAN 恢復後要在這裡開回來。
        if [ -f /tmp/.sta_dbr_stopped ]; then
            if [ -f /tmp/.sta_dbroute-domains.conf.bak ]; then
                mv /tmp/.sta_dbroute-domains.conf.bak /etc/dnsmasq.d/dbroute-domains.conf 2>/dev/null
                /etc/init.d/dnsmasq reload >/dev/null 2>&1
                [ -x /etc/myscript/dbroute-setup.sh ] && /etc/myscript/dbroute-setup.sh >/dev/null 2>&1
                log "STA 拆除: 已還原 DBR 域名分流"
            else
                # ⚠️ 備份檔放 /tmp, STA 期間若重開機就沒了(實測 2026-09-28 踩到:
                #   還原後 dbroute-domains.conf 整個不見, dbroute-setup.sh 只會
                #   log "No dbroute-domains.conf found, skipping" —— 它是讀取者
                #   不是產生者, 產生者是 sync-googleconfig 的 DB Route 段)。
                #   ★ 刻意不改放 flash(避免磨損), 改用 sync 重建。
                #   ⚠️ 必須先刪 state —— 否則 sync 會判定「內容未變化, 跳過更新」,
                #   而實際檔案已經不在了, state 與現實不一致。
                find /etc/myscript -name "*dbroute*state*" -delete 2>/dev/null
                [ -x /etc/myscript/sync-googleconfig.sh ] \
                    && /etc/myscript/sync-googleconfig.sh --apply --force >/dev/null 2>&1
                log "STA 拆除: DBR 備份檔已失(期間重開過), 改由 sync 重建"
            fi
            rm -f /tmp/.sta_dbr_stopped
        fi
        if [ -f /tmp/.sta_pbr_stopped ]; then
            /etc/init.d/pbr start >/dev/null 2>&1
            rm -f /tmp/.sta_pbr_stopped
            log "STA 拆除: 已還原 PBR"
        fi
        # wg 介面: 交給 netifd 自己拉(auto-role 下一輪的 WG 延遲啟動會處理),
        # 這裡只確保 client 端那幾支有被踢一次, 不然要等到下次角色切換。
        for _w in $(uci -q show network 2>/dev/null \
                    | sed -n 's/^network\.@wireguard_\([^[]*\)\[[0-9]*\]\.endpoint_host=.*/\1/p' \
                    | sort -u); do
            [ "$(ifstatus "$_w" 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null)" = "true" ] && continue
            ifup "$_w" 2>/dev/null
        done
        log "STA 拆除: 已重新拉起 wg client 介面"
    fi
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
    # ★ 候選清單(不印密碼, 只印長度)
    echo "  候選組數 : $(ap_list | grep -c .)  (來源: $([ -s "$AP_F" ] && echo "$AP_F" || echo '舊單組旗標'))"
    ap_list | awk -F'\t' 'NF>=2 && $2!="" {
        printf "    %d) band=%-5s ssid=[%s] key=%s\n", ++n, $1, $2, ($3=="" ? "(無密碼)" : "已設定(" length($3) " 字元)")
    }'
    echo "  ssid(舊) : $(_read "$SSID_F")"
    echo "  key(舊)  : $([ -s "$KEY_F" ] && echo "已設定($(wc -c < "$KEY_F" | tr -d ' ') bytes)" || echo '(空)')"
    echo "  band(舊) : $(_read "$BAND_F")  → radio: $(pick_radio 2>/dev/null || echo '找不到')"
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

# ---------- STA 自己算不算「有出路」 ----------
# ★ 沒有這個判斷的話, STA 成功接管後 wan_ok() 仍回 false(它只看 network.wan),
#   系統以為備援還沒生效 → fail 持續累加。
#   實測 2026-09-27 於 MX4200: 00:17:21 已 st=active wwan=192.168.1.249,
#   但 fail 仍從 1 一路累加到 5, 每輪都在重複嘗試, 連線因此不穩。
# ⚠️ 不能只看「wwan 有 IP」—— 拿到 IP 不代表真的出得去(上游可能也斷了)。
#   要實際從 STA 介面打出去驗證。
sta_ok() {
    [ "$(_read "$STATE_F")" = "active" ] || return 1
    _sdev=$(ifstatus wwan 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
    [ -z "$_sdev" ] && return 1
    # ⚠️ 真兇 2026-09-28: 原本只用 ping 判定, 但上游 AP(鄰居/飯店)很常擋 ICMP
    #   —— 實測第九輪: STA 10:17:04 起來、10:17:05 DNS 接手成功、http=204 一路
    #   正常, 但 10:18:43 起連續「判定無出路」, 45 秒內就被拆掉退回 .1。
    #   前幾輪也反覆看到同一組合: ping=N 但 http=204。
    #   ★ 改成「HTTP 或 ICMP 任一通就算活著」, HTTP 排前面 —— 它才是「真的
    #     能上網」的判準, ICMP 只是輔助。
    # ⚠️ 前兩發刻意用「純 IP」而非域名: 若拿域名當判準, DNS 一壞 sta_ok 就
    #   跟著失敗 -> 拆 STA -> DNS 更沒機會恢復, 是循環依賴。
    #   實測 2026-09-28 哪些 IP 的 80 埠真的有回應(exit=0 才算):
    #     1.1.1.1 -> 301 ✅   1.0.0.1 -> 301 ✅   223.5.5.5 -> 404 ✅(中國,不用)
    #     8.8.8.8 -> exit 28 ❌   9.9.9.9 -> exit 28 ❌   (它們不開 HTTP)
    #   ★ 判斷看 curl 的 exit code 不是 http_code —— 301/404 都代表「連得上」。
    curl -s -o /dev/null --interface "$_sdev" --max-time 6 http://1.1.1.1/ 2>/dev/null && return 0
    curl -s -o /dev/null --interface "$_sdev" --max-time 6 http://1.0.0.1/ 2>/dev/null && return 0
    # 域名版當第三層: 上游若用透明代理擋裸 IP, 域名可能反而通
    curl -s -o /dev/null --interface "$_sdev" --max-time 6 \
         http://www.gstatic.com/generate_204 2>/dev/null && return 0
    ping -c 1 -W 3 -I "$_sdev" 1.1.1.1 >/dev/null 2>&1 && return 0
    ping -c 1 -W 3 -I "$_sdev" 8.8.8.8 >/dev/null 2>&1 && return 0
    return 1
}

if wan_ok || mesh_ok; then
    # WAN 或 mesh 恢復 —— 累積正常計數, 準備還原 STA
    echo 0 > "$FAILCNT_F"
    rm -f "$STUCK_F" 2>/dev/null
    _ok=$(( $(_cnt_get "$OKCNT_F") + 1 ))
    echo "$_ok" > "$OKCNT_F"
    if [ "$CUR_STATE" = "active" ] && [ "$_ok" -ge "$OK_NEED" ]; then
        log "連續 ${_ok} 次判定 WAN/mesh 有出路, 還原 STA"
        sta_off
        echo 0 > "$OKCNT_F"
    fi
elif sta_ok; then
    # ★ WAN/mesh 仍斷, 但 STA 備援正在正常供網 —— 這是「備援生效中」的
    #   正常狀態, 不該繼續累積失敗計數重複嘗試。
    echo 0 > "$FAILCNT_F"
    rm -f "$STUCK_F" 2>/dev/null
    # ★ 每輪都補一次 DNS 接手(冪等, 已是上游那組就直接 return)。
    #   切換那一瞬間 ifstatus wwan 的 dns-server 常常還沒填好, 只靠
    #   sta_rules_apply() 裡那次會錯過 —— 實測 09:40 切換時沒接手,
    #   到 09:47 手動 rules-refresh 才成功。放這裡才補得回來。
    sta_dns_takeover
    _prev=$(_read "$STUCK_F.notified" 2>/dev/null)
    if [ "$_prev" != "1" ]; then
        log "STA 備援供網中(WAN/mesh 仍斷), 維持現狀"
        echo 1 > "$STUCK_F.notified" 2>/dev/null
    fi
else
    # 完全沒有出路(WAN 斷、mesh 斷、STA 也不通或還沒啟用)
    rm -f "$STUCK_F.notified" 2>/dev/null
    echo 0 > "$OKCNT_F"

    # ★ 卡死自動解套: 記錄「完全沒出路」的起始時間, 超過門檻就重開。
    #   為什麼需要: STA 可能卡在「連上了但路由只建一半」之類的中間態,
    #   人在外面完全進不去。重開至少能回到乾淨狀態重新協商。
    _now=$(date +%s)
    _since=$(_read "$STUCK_F")
    case "$_since" in ''|*[!0-9]*) _since="$_now"; echo "$_now" > "$STUCK_F" ;; esac
    _stuck=$(( _now - _since ))
    if [ "$_stuck" -ge "$STUCK_LIMIT" ]; then
        log "❌ 已 ${_stuck}s 完全無出路(WAN/mesh/STA 皆不通), 重開機自動解套"
        push_notify "STA備援: 已 $(( _stuck / 60 )) 分鐘完全無網路, 自動重開機解套"
        rm -f "$STUCK_F"
        # 先還原設定再重開, 避免開機後又卡在同一個壞狀態
        sta_off_raw
        sync
        ( sleep 5 && reboot ) &
        exit 0
    fi

    _fail=$(( $(_cnt_get "$FAILCNT_F") + 1 ))
    echo "$_fail" > "$FAILCNT_F"
    log "判定無出路 (${_fail}/${FAIL_NEED}, 已卡 ${_stuck}s/${STUCK_LIMIT}s)"
    if [ "$CUR_STATE" != "active" ] && [ "$_fail" -ge "$FAIL_NEED" ]; then
        log "連續 ${_fail} 次判定孤島, 啟用 STA 備援"
        sta_on
        echo 0 > "$FAILCNT_F"
    fi
fi

exit 0
