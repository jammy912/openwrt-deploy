#!/bin/sh
# 智慧 Wi-Fi 功率管理 V7.3 - 比例動態調整 & 精確斷線檢測

LOG_FILE="/tmp/wifi-signal.log"
STATE_DIR="/tmp"

STATE_5G_CLIENTS="$STATE_DIR/wifi_clients_on_5g.state"
STATE_2G_CLIENTS="$STATE_DIR/wifi_clients_on_2g.state"
STATE_2G_BOOST="$STATE_DIR/wifi_2g_boost.state"
STATE_2G_BOOST_START="$STATE_DIR/wifi_2g_boost_start.state"
STATE_5G_BOOST="$STATE_DIR/wifi_5g_boost.state"
STATE_5G_BOOST_START="$STATE_DIR/wifi_5g_boost_start.state"

# =====================
# 預設值 (可由命令列參數覆寫)
# =====================
# --- 演算法參數 ---
HYSTERESIS=3                # 遲滯值 (dBm), 防止信號波動造成頻繁調整
BOOST_TIMEOUT_SECONDS=180   # 救援模式超時時間 (秒)
PROPORTIONAL_FACTOR=3       # [V7.3 新增] 比例調整因子。值越大調整越平緩，建議 2-5

# --- 5GHz 參數 ---
THRESHOLD_5G=-55            # 5G 目標信號強度 (dBm)
LOW_PWR_5G=5                # 5G 最小功率 (dBm)
HIGH_PWR_5G=20              # 5G 最大功率 (dBm)
BOOST_PWR_5G=23             # 5G 救援模式功率 (dBm)
ENABLE_5G=1                 # 1 為啟用, 0 為停用

# --- 2.4GHz 參數 ---
THRESHOLD_2G=-55            # 2.4G 目標信號強度 (dBm)
LOW_PWR_2G=0                # 2.4G 最小功率 (dBm)
HIGH_PWR_2G=15              # 2.4G 最大功率 (dBm)
BOOST_PWR_2G=20             # 2.4G 救援模式功率 (dBm)
ENABLE_2G=1                 # 1 為啟用, 0 為停用


# --- 無人連線降功率設定 ---
NO_CLIENT_TIMEOUT=300       # 5 分鐘沒人連線就降到最低
STATE_5G_LAST_ACTIVE="$STATE_DIR/wifi_5g_last_active.state"
STATE_2G_LAST_ACTIVE="$STATE_DIR/wifi_2g_last_active.state"


# --- 日誌與模式開關 ---
ENABLE_LOG=1            # 1 為啟用日誌, 0 為停用
RSSI_KICK_5G=""         # 5G 信號低於此值(dBm)踢掉客戶端，空值=不啟用 (如 -75)
RSSI_KICK_2G=""         # 2.4G 信號低於此值(dBm)踢掉客戶端，空值=不啟用 (如 -75)
KICK_COOLDOWN=""        # 踢除後冷卻時間(分鐘)，冷卻期內同一MAC不再踢，空值=不限制
USE_HEARING_MAP="0"     # [新增] 1=引入 usteer hearing map 作為訊號檢測基準並做 AP 擇強 (強制 MONITOR_MODE=0); 0=原行為
MONITOR_MODE=1          # [V7.5 新增] 1=廣泛模式(Phone+ARP), 0=嚴格模式(僅關鍵字)
DEVICE_KEYWORDS="Phone"  # DHCP 租約中要匹配的裝置名稱關鍵字，多個用分號分隔 (如 Phone;iPad;Laptop)

# =====================
# 命令列參數讀取 (保留向下相容性)
# =====================
[ -n "$1" ] && THRESHOLD_5G="$1"
[ -n "$2" ] && LOW_PWR_5G="$2"
[ -n "$3" ] && HIGH_PWR_5G="$3"
[ -n "$4" ] && BOOST_PWR_5G="$4"
[ -n "$5" ] && THRESHOLD_2G="$5"
[ -n "$6" ] && LOW_PWR_2G="$6"
[ -n "$7" ] && HIGH_PWR_2G="$7"
[ -n "$8" ] && BOOST_PWR_2G="$8"
[ -n "$9" ] && ENABLE_5G="$9"

shift 9
[ -n "$1" ] && ENABLE_2G="$1"
# V7.2 的 STEP 參數已由比例調整取代，為相容性保留讀取但不使用
# [ -n "$2" ] && STEP="$2"
[ -n "$3" ] && HYSTERESIS="$3"
[ -n "$4" ] && BOOST_TIMEOUT_SECONDS="$4"
[ -n "$5" ] && PROPORTIONAL_FACTOR="$5" # 讀取新的比例因子參數
[ -n "$6" ] && ENABLE_LOG="$6"           # 第 15 個參數: 日誌開關
[ -n "$7" ] && RSSI_KICK_5G="$7"         # 第 16 個參數: 5G RSSI 踢除門檻 (如 -75)
[ -n "$8" ] && RSSI_KICK_2G="$8"         # 第 17 個參數: 2.4G RSSI 踢除門檻 (如 -75)

shift 8
[ -n "$1" ] && KICK_COOLDOWN="$1"        # 第 18 個參數: 踢除冷卻時間(分鐘)
[ -n "$2" ] && USE_HEARING_MAP="$2"      # 第 19 個參數: 使用 usteer hearing map (1/0)
[ -n "$3" ] && MONITOR_MODE="$3"         # 第 20 個參數: 監控模式
[ -n "$4" ] && DEVICE_KEYWORDS="$4"      # 第 21 個參數: 裝置名稱關鍵字

# USE_HEARING_MAP=1 時強制 MONITOR_MODE=0，避免把鄰居裝置納入監控
if [ "$USE_HEARING_MAP" = "1" ]; then
    if [ "$MONITOR_MODE" != "0" ]; then
        MONITOR_MODE=0
    fi
fi

# =====================
# ash 兼容 log 函式
# =====================
log() {
    # 僅在 ENABLE_LOG 為 1 時寫入檔案
    if [ "$ENABLE_LOG" -ne 0 ]; then
        NOW=$(date +"%Y-%m-%d %H:%M:%S")
        echo "$NOW - $1" >> "$LOG_FILE"
    fi
}


log "命令列參數載入:
  5G(閾=$THRESHOLD_5G, min=$LOW_PWR_5G, max=$HIGH_PWR_5G, boost=$BOOST_PWR_5G, enable=$ENABLE_5G)
2.4G(閾=$THRESHOLD_2G, min=$LOW_PWR_2G, max=$HIGH_PWR_2G, boost=$BOOST_PWR_2G, enable=$ENABLE_2G)
HYSTERESIS=$HYSTERESIS, BOOST_TIMEOUT=$BOOST_TIMEOUT_SECONDS, PROPORTIONAL_FACTOR=$PROPORTIONAL_FACTOR
日誌=$ENABLE_LOG, RSSI_KICK_5G=$RSSI_KICK_5G, RSSI_KICK_2G=$RSSI_KICK_2G, KICK_COOLDOWN=${KICK_COOLDOWN:-無}分鐘
HEARING_MAP=$USE_HEARING_MAP, 監控模式=$MONITOR_MODE, 裝置關鍵字=$DEVICE_KEYWORDS"

# =====================
# RSSI 踢除弱信號客戶端
# =====================
# 掃描指定介面的客戶端，信號低於門檻的用 ubus del_client 踢掉
# $1=hostapd介面名(如 phy1-ap0)  $2=RSSI門檻(如 -75)
# 冷卻機制: 踢除後記錄時間戳到 /tmp/kick_<MAC>.ts，冷卻期內不重複踢
kick_weak_clients() {
    local hapd_iface="$1"
    local threshold="$2"
    local now=$(date +%s)

    [ -z "$threshold" ] && return

    # 用 iw station dump 取得客戶端 MAC 和信號
    iw dev "$hapd_iface" station dump 2>/dev/null | awk -v th="$threshold" '
        /^Station/ { mac=$2 }
        /signal:/ && !/signal avg/ { gsub(/\[.*\]/,""); sig=$2+0; if (sig < th) print mac, sig }
    ' | while read mac sig; do
        # 冷卻檢查
        if [ -n "$KICK_COOLDOWN" ]; then
            local kick_file="/tmp/kick_$(echo "$mac" | tr ':' '_').ts"
            if [ -f "$kick_file" ]; then
                local last_kick=$(cat "$kick_file")
                local elapsed=$(( now - last_kick ))
                local cooldown_sec=$(( KICK_COOLDOWN * 60 ))
                if [ "$elapsed" -lt "$cooldown_sec" ]; then
                    log "[RSSI-KICK] ${hapd_iface}: 跳過 $mac (冷卻中, 剩$(( (cooldown_sec - elapsed) / 60 ))分鐘)"
                    continue
                fi
            fi
            echo "$now" > "$kick_file"
        fi
        log "[RSSI-KICK] ${hapd_iface}: 踢除 $mac (信號=${sig}dBm, 門檻=${threshold}dBm)"
        ubus call hostapd.${hapd_iface} del_client "{\"addr\":\"$mac\",\"reason\":5,\"deauth\":true}" 2>/dev/null
    done
}



# =====================
# UCI & IFACE 名稱設定 (動態偵測 band，支援 tri-band)
# =====================
UCI_RADIO_2G=""
UCI_RADIO_5G=""
for _r in radio0 radio1 radio2 radio3; do
    _b=$(uci -q get wireless.$_r.band 2>/dev/null)
    case "$_b" in
        2g) [ -z "$UCI_RADIO_2G" ] && UCI_RADIO_2G="$_r" ;;
        5g) [ -z "$UCI_RADIO_5G" ] && UCI_RADIO_5G="$_r" ;;
    esac
done
[ -z "$UCI_RADIO_2G" ] && UCI_RADIO_2G="radio0"
[ -z "$UCI_RADIO_5G" ] && UCI_RADIO_5G="radio1"
UCI_IFACE_2G="default_${UCI_RADIO_2G}"
UCI_IFACE_5G="default_${UCI_RADIO_5G}"

log "設定 2.4GHz: $UCI_RADIO_2G, 介面: $UCI_IFACE_2G"
log "設定 5GHz  : $UCI_RADIO_5G, 介面: $UCI_IFACE_5G"

# 踢除弱信號客戶端 (僅在有設定門檻時)
# 動態取得 phy 名稱: radioN → phyN
_PHY_5G=$(echo "$UCI_RADIO_5G" | sed 's/radio/phy/')
_PHY_2G=$(echo "$UCI_RADIO_2G" | sed 's/radio/phy/')
[ "$ENABLE_5G" -eq 1 ] && [ -n "$RSSI_KICK_5G" ] && kick_weak_clients "${_PHY_5G}-ap0" "$RSSI_KICK_5G"
[ "$ENABLE_2G" -eq 1 ] && [ -n "$RSSI_KICK_2G" ] && kick_weak_clients "${_PHY_2G}-ap0" "$RSSI_KICK_2G"

change_occured=0

# 偵測是否為開機後首次執行（state 檔不存在）
# 首次執行只儲存狀態，不觸發 wifi reload（避免 mesh+AP channel 歸 0）
FIRST_RUN=0
[ ! -f "$STATE_5G_CLIENTS" ] && FIRST_RUN=1

# =====================
# Enable / Disable 介面
# =====================
# 非主gw 不啟用 IOT (2G)，避免 wifi-signal 把 auto-role 停用的 IOT 開回來
GW_TYPE=$(cat /etc/myscript/.mesh_gw_type 2>/dev/null)
[ "$GW_TYPE" != "主gw" ] && ENABLE_2G=0

CURRENT_2G_STATUS=$(uci get wireless.$UCI_IFACE_2G.disabled 2>/dev/null || echo 0)
CURRENT_5G_STATUS=$(uci get wireless.$UCI_IFACE_5G.disabled 2>/dev/null || echo 0)

DESIRED_2G_STATUS=$((1 - ENABLE_2G))
[ "$CURRENT_2G_STATUS" -ne "$DESIRED_2G_STATUS" ] && {
    uci set "wireless.$UCI_IFACE_2G.disabled=$DESIRED_2G_STATUS"
    # 連同 radio 一起開關，讓 LuCI 顯示正確的 ❌ 狀態
    if [ "$ENABLE_2G" -eq 1 ]; then
        uci delete "wireless.$UCI_RADIO_2G.disabled" 2>/dev/null
    else
        uci set "wireless.$UCI_RADIO_2G.disabled=1"
    fi
    change_occured=1
    [ "$ENABLE_2G" -eq 1 ] && log "[$UCI_IFACE_2G+$UCI_RADIO_2G] 啟用" || log "[$UCI_IFACE_2G+$UCI_RADIO_2G] 停用"
}

DESIRED_5G_STATUS=$((1 - ENABLE_5G))
[ "$CURRENT_5G_STATUS" -ne "$DESIRED_5G_STATUS" ] && {
    uci set "wireless.$UCI_IFACE_5G.disabled=$DESIRED_5G_STATUS"
    change_occured=1
    [ "$ENABLE_5G" -eq 1 ] && log "[$UCI_IFACE_5G] 啟用" || log "[$UCI_IFACE_5G] 停用"
}


# =====================
# BATMAN mesh 本機客戶端偵測
# =====================
BATMAN_ENABLED=0
BATMAN_LOCAL_MACS=""
if ip link show bat0 >/dev/null 2>&1; then
    BATMAN_ENABLED=1
    # BATMAN tl 只列「透過 bat0 加入 mesh」的客戶端；
    # 實務上 AP 介面多半掛 br-lan (非 bat0)，本機 AP 客戶端不會進 TT，
    # 故聯集本機 iwinfo assoclist (hostapd 即時回報) 補足
    _bat_tl=$(batctl meshif bat0 tl 2>/dev/null | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}')
    _iw_local=""
    for _ifc in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
        _mode=$(iw dev "$_ifc" info 2>/dev/null | awk '/type/{print $2; exit}')
        [ "$_mode" = "AP" ] || continue
        _iw_local="$_iw_local
$(iwinfo "$_ifc" assoclist 2>/dev/null | grep -oE '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}')"
    done
    BATMAN_LOCAL_MACS=$(printf '%s\n%s\n' "$_bat_tl" "$_iw_local" | grep -E '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | tr 'a-z' 'A-Z' | sort -u | tr '\n' ' ')
    log "[BATMAN] 偵測到 bat0 介面，本機客戶端 MAC (tl∪iwinfo): ${BATMAN_LOCAL_MACS:-無}"
else
    log "[BATMAN] 未偵測到 bat0 介面，使用標準模式"
fi

# 過濾客戶端列表，僅保留 BATMAN 本機客戶端（無 BATMAN 時原樣回傳）
filter_batman_local() {
    local clients="$1"
    [ "$BATMAN_ENABLED" -ne 1 ] && { echo "$clients"; return; }
    local filtered=""
    for mac in $clients; do
        if echo "$BATMAN_LOCAL_MACS" | grep -qi "$mac"; then
            filtered="$filtered $mac"
        fi
    done
    echo "$filtered" | sed 's/^ //'
}

# =====================
# 動態獲取監控裝置 MAC (V7.5 - 根據模式決定)
# =====================
get_monitored_macs() {
    local awk_pattern=$(echo "$DEVICE_KEYWORDS" | sed 's/;/|/g')

    # 來源一：從 DHCP 租約中匹配關鍵字
    local lease_macs=$(awk -v pat="$awk_pattern" 'tolower($4) ~ tolower(pat) {print toupper($2)}' /tmp/dhcp.leases 2>/dev/null)

    # 來源二：從 UCI DHCP 靜態設定中匹配關鍵字
    local uci_macs=$(uci show dhcp 2>/dev/null | awk -F"[=']" -v pat="$awk_pattern" '
        /\.name=/ { name=$3 }
        /\.mac=/ {
            mac=toupper($3)
            if (tolower(name) ~ tolower(pat)) print mac
            name=""
        }
    ')

    local final_macs="$lease_macs $uci_macs"

    # 來源三：根據監控模式，決定是否從 ARP 表獲取所有無線裝置
    if [ "$MONITOR_MODE" -eq 1 ]; then
        log "[動態監控] 啟用廣泛模式，掃描 ARP 表"
        local wireless_macs=$(cat /proc/net/arp 2>/dev/null | awk '$3 == "0x2" {print $4}' | tr 'a-z' 'A-Z')
        final_macs="$final_macs $wireless_macs"
    else
        log "[動態監控] 啟用嚴格模式，僅監控符合關鍵字 '$DEVICE_KEYWORDS' 的裝置"
    fi

    # 合併並去重
    echo "$final_macs" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' '
}

# BATMAN 廣泛模式：直接用本機客戶端，略過關鍵字
if [ "$BATMAN_ENABLED" -eq 1 ] && [ "$MONITOR_MODE" -eq 1 ]; then
    MONITORED_MACS="$BATMAN_LOCAL_MACS"
    log "[動態監控] BATMAN 廣泛模式，監控所有本機客戶端"
else
    MONITORED_MACS=$(get_monitored_macs)
    # BATMAN 嚴格模式：用關鍵字匹配後再過濾本機客戶端
    if [ "$BATMAN_ENABLED" -eq 1 ] && [ -n "$BATMAN_LOCAL_MACS" ]; then
        MONITORED_MACS=$(filter_batman_local "$MONITORED_MACS")
    fi
fi

# =====================
# [新增] usteer hearing map 快取 & 擇強過濾 (僅 USE_HEARING_MAP=1 啟用)
# =====================
HEARING_MAP_JSON=""

# 對給定 MAC，從 hearing map 解析出本機訊號與最強遠端訊號，
# 輸出格式: "<decision> <local_sig> <max_remote_sig>"
# decision: KEEP / SKIP / NOTFOUND / NOLOCAL
# 本機節點 key 不含 '#'；遠端節點 key 形如 '<ip>#hostapd.xxx'
hm_lookup_mac() {
    local mac="$1"
    local lc_mac
    # busybox tr 對 '[:upper:]' 支援不一致，改用明確範圍
    lc_mac=$(echo "$mac" | tr 'A-Z' 'a-z')
    echo "$HEARING_MAP_JSON" | awk -v target="$lc_mac" '
        BEGIN { in_mac=0; depth=0; current_key=""; local_sig=""; max_remote=""; found_local=0; found_remote=0 }
        {
            line=$0
            lc=tolower(line)
            if (in_mac==0) {
                if (match(lc, /"([0-9a-f]{2}:){5}[0-9a-f]{2}"[[:space:]]*:[[:space:]]*\{/)) {
                    m=substr(lc, RSTART+1, 17)
                    if (m == target) { in_mac=1; depth=1 }
                }
                next
            }
            tmp=line; n_open=gsub(/\{/, "{", tmp)
            tmp=line; n_close=gsub(/\}/, "}", tmp)
            depth += n_open - n_close

            if (match(line, /"[^"]+"[[:space:]]*:[[:space:]]*\{/)) {
                key=substr(line, RSTART+1)
                q=index(key, "\"")
                current_key=substr(key, 1, q-1)
            }
            if (match(line, /"signal"[[:space:]]*:[[:space:]]*-?[0-9]+/)) {
                s=substr(line, RSTART, RLENGTH)
                sub(/.*:[[:space:]]*/, "", s)
                sig=s+0
                if (index(current_key, "#")==0) {
                    if (found_local==0 || sig > local_sig) local_sig=sig
                    found_local=1
                } else {
                    if (found_remote==0 || sig > max_remote) max_remote=sig
                    found_remote=1
                }
            }

            if (depth<=0) {
                if (found_local==0) { print "NOLOCAL 0 0"; exit }
                if (found_remote==0) { printf "KEEPLOCAL %d 0\n", local_sig; exit }
                if (local_sig+0 >= max_remote+0) printf "KEEP %d %d\n", local_sig, max_remote
                else printf "SKIP %d %d\n", local_sig, max_remote
                exit
            }
        }
        END { if (in_mac==0) print "NOTFOUND 0 0" }
    '
}

filter_by_hearing_map() {
    local in_macs="$1"
    [ -z "$in_macs" ] && { echo ""; return; }
    [ -z "$HEARING_MAP_JSON" ] && { echo "$in_macs"; return; }
    local kept="" mac r d lsig rsig
    for mac in $in_macs; do
        r=$(hm_lookup_mac "$mac")
        d=$(echo "$r" | awk '{print $1}')
        lsig=$(echo "$r" | awk '{print $2}')
        rsig=$(echo "$r" | awk '{print $3}')
        case "$d" in
            KEEP)
                kept="$kept $mac"
                log "[HearingMap] 保留 $mac (本機=${lsig}dBm 遠端最強=${rsig}dBm)"
                ;;
            KEEPLOCAL)
                kept="$kept $mac"
                log "[HearingMap] 保留 $mac (本機=${lsig}dBm，無其他 AP 看到此裝置)"
                ;;
            SKIP)
                log "[HearingMap] 跳過 $mac (本機=${lsig}dBm < 遠端=${rsig}dBm，讓較強 AP 處理)"
                ;;
            NOLOCAL)
                log "[HearingMap] 跳過 $mac (本機節點無此裝置訊號資料)"
                ;;
            NOTFOUND|*)
                kept="$kept $mac"
                log "[HearingMap] 保留 $mac (hearing map 查無資料，預設保留)"
                ;;
        esac
    done
    echo "$kept" | sed 's/^ //'
}

if [ "$USE_HEARING_MAP" = "1" ]; then
    HEARING_MAP_JSON=$(ubus call usteer get_clients 2>/dev/null)
    if [ -z "$HEARING_MAP_JSON" ]; then
        log "[HearingMap] ubus call usteer get_clients 無回應，本次不做擇強過濾"
    else
        BEFORE_MACS="$MONITORED_MACS"
        MONITORED_MACS=$(filter_by_hearing_map "$MONITORED_MACS")
        log "[HearingMap] 擇強過濾完成: 原=[$BEFORE_MACS] -> 過濾後=[$MONITORED_MACS]"
    fi
fi

log "[動態監控] 本次監控 MAC 列表: $MONITORED_MACS"

# =====================
# 獲取指定 radio 下所有介面的客戶端列表
# =====================
get_clients_on_radio() {
    local radio_name="$1"
    local interface_prefix=$(echo "$radio_name" | sed 's/radio/phy/')

    local interfaces=$(iwinfo | awk -v p="$interface_prefix" '$1 ~ p {print $1}')
    [ -z "$interfaces" ] && { echo ""; return; }

    local all_clients=$(
        for interface in $interfaces; do
            if iwinfo "$interface" info >/dev/null 2>&1; then
                iwinfo "$interface" assoclist 2>/dev/null
            fi
        done | grep -oE "([0-9A-F]{2}:){5}[0-9A-F]{2}" | tr 'a-z' 'A-Z' | sort -u | tr '\n' ' '
    )

    # BATMAN 啟用時僅保留本機客戶端
    all_clients=$(filter_batman_local "$all_clients")

    echo "$all_clients"
}

# =====================
# 獲取最弱 RSSI (僅監控列表中的裝置)
# =====================
get_weakest_signal() {
    local radio_name="$1"

    # [新增] USE_HEARING_MAP=1 時，改用 hearing map 的本機節點訊號 (包含 probe-only 裝置)
    # 只計算對應 radio 的介面 (phy0=2.4G, phy1=5G)
    if [ "$USE_HEARING_MAP" = "1" ] && [ -n "$HEARING_MAP_JSON" ]; then
        local hm_prefix="hostapd.$(echo "$radio_name" | sed 's/radio/phy/')"
        local weakest_hm
        weakest_hm=$(echo "$HEARING_MAP_JSON" | awk -v macs="$MONITORED_MACS" -v pfx="$hm_prefix" '
            BEGIN {
                n=split(tolower(macs), arr, " ")
                for (i=1;i<=n;i++) want[arr[i]]=1
                depth=0; in_mac=0; cur_mac=""; cur_key=""; found=0; weakest=0
            }
            {
                line=$0
                tmp=line; no=gsub(/\{/, "{", tmp)
                tmp=line; nc=gsub(/\}/, "}", tmp)

                if (in_mac==0) {
                    if (match(line, /"([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}"[[:space:]]*:[[:space:]]*\{/)) {
                        m=substr(line, RSTART+1, 17); m=tolower(m)
                        if (m in want) { in_mac=1; cur_mac=m; depth=1; next }
                    }
                    next
                }
                depth += no - nc
                if (match(line, /"[^"]+"[[:space:]]*:[[:space:]]*\{/)) {
                    k=substr(line, RSTART+1); q=index(k, "\"")
                    cur_key=substr(k, 1, q-1)
                }
                if (match(line, /"signal"[[:space:]]*:[[:space:]]*-?[0-9]+/)) {
                    s=substr(line, RSTART, RLENGTH); sub(/.*:[[:space:]]*/, "", s); sig=s+0
                    # 只取本機節點 (不含 #) 且符合 radio 前綴
                    if (index(cur_key, "#")==0 && index(cur_key, pfx)==1) {
                        if (found==0 || sig < weakest) weakest=sig
                        found=1
                    }
                }
                if (depth<=0) { in_mac=0; cur_mac=""; cur_key="" }
            }
            END { if (found) print weakest; else print -1 }
        ')
        log "[HearingMap] ${radio_name} 最弱訊號 (來自 hearing map) = ${weakest_hm}"
        echo "$weakest_hm"
        return
    fi

    local interface_prefix=$(echo "$radio_name" | sed 's/radio/phy/')

    local interfaces=$(iwinfo | awk -v p="$interface_prefix" '$1 ~ p {print $1}' | sort -u)
    [ -z "$interfaces" ] && {
        log "[錯誤] 找不到 ${radio_name} 的接口"
        echo "-1"
        return
    }

    local weakest_rssi=$(
        for interface in $interfaces; do
            if iwinfo "$interface" info >/dev/null 2>&1; then
                iwinfo "$interface" assoclist 2>/dev/null
            fi
        done | awk -v macs="$MONITORED_MACS" -v batman="$BATMAN_ENABLED" -v local_macs="$BATMAN_LOCAL_MACS" '
        BEGIN {
            # 將監控 MAC 字串拆解為陣列
            n_macs = split(macs, monitored_macs, " ")
            # 將 BATMAN 本機 MAC 字串拆解為陣列
            n_local = split(local_macs, batman_local, " ")
            weakest = 0
            found = 0
        }
        # 匹配包含 MAC 位址和 RSSI 的行
        /([0-9A-F]{2}:){5}[0-9A-F]{2}/ {
            mac = toupper($1)
            rssi = $2

            # BATMAN 啟用時，跳過非本機客戶端
            if (batman == 1 && n_local > 0) {
                is_local = 0
                for (i=1; i<=n_local; i++) {
                    if (mac == toupper(batman_local[i])) {
                        is_local = 1
                        break
                    }
                }
                if (!is_local) next
            }

            # 檢查當前客戶端是否在監控列表中
            is_monitored = 0
            for (i=1; i<=n_macs; i++) {
                if (mac == toupper(monitored_macs[i])) {
                    is_monitored = 1
                    break
                }
            }

            # 如果是監控裝置，更新最弱訊號值
            if (is_monitored) {
                if (found == 0 || rssi < weakest) {
                    weakest = rssi
                }
                found = 1
            }
        }
        END {
            if (found == 1) {
                print weakest
            } else {
                print -1
            }
        }'
    )
    
    echo "$weakest_rssi"
}

# =====================
# 讀取與比較客戶端狀態
# =====================
PREV_5G_CLIENTS=$(cat "$STATE_5G_CLIENTS" 2>/dev/null)
PREV_2G_CLIENTS=$(cat "$STATE_2G_CLIENTS" 2>/dev/null)
CURRENT_5G_CLIENTS=$(get_clients_on_radio "$UCI_RADIO_5G")
CURRENT_2G_CLIENTS=$(get_clients_on_radio "$UCI_RADIO_2G")

log "[客戶端狀態] 5G 前次: $PREV_5G_CLIENTS"
log "[客戶端狀態] 5G 當前: $CURRENT_5G_CLIENTS"
log "[客戶端狀態] 2.4G 前次: $PREV_2G_CLIENTS"
log "[客戶端狀態] 2.4G 當前: $CURRENT_2G_CLIENTS"

# =====================
# 斷線裝置檢查 (精確檢測監控中的裝置)
# =====================
dropped_from_5g=""
dropped_from_2g=""

# 檢查 5GHz 斷線 - 只關注監控列表中的裝置
for mac in $MONITORED_MACS; do
    # 檢查該 MAC 之前是否在 5G，現在是否不在 5G
    if echo "$PREV_5G_CLIENTS" | grep -qi "$mac" && ! echo "$CURRENT_5G_CLIENTS" | grep -qi "$mac"; then
        dropped_from_5g="$mac"
        log "[斷線檢測] 5G 監控裝置 $mac 斷線"
        break
    fi
done

# 檢查 2.4GHz 斷線 - 只關注監控列表中的裝置
for mac in $MONITORED_MACS; do
    # 檢查該 MAC 之前是否在 2.4G，現在是否不在 2.4G
    if echo "$PREV_2G_CLIENTS" | grep -qi "$mac" && ! echo "$CURRENT_2G_CLIENTS" | grep -qi "$mac"; then
        dropped_from_2g="$mac"
        log "[斷線檢測] 2.4G 監控裝置 $mac 斷線"
        break
    fi
done

# =====================
# 救援模式處理 (精確觸發)
# =====================
handle_boost() {
    local BAND=$1 RADIO=$2 BOOST_STATE=$3 BOOST_START=$4 LOW_PWR=$5 BOOST_PWR=$6 DROPPED_MAC="$7"

    # 如果有監控裝置斷線，且救援模式未啟動，則啟動救援
    if [ -n "$DROPPED_MAC" ] && [ ! -f "$BOOST_STATE" ]; then
        log "[救援觸發] $BAND 監控裝置斷線 ($DROPPED_MAC)，啟動救援模式"
        uci set "wireless.$RADIO.txpower=$BOOST_PWR"
        change_occured=1
        touch "$BOOST_STATE"
        date +%s > "$BOOST_START"
        echo "$DROPPED_MAC" > "$BOOST_START.mac"
        return
    fi

    # 如果救援模式已啟動，檢查是否要解除
    if [ -f "$BOOST_STATE" ]; then
        local boost_start_time=$(cat "$BOOST_START" 2>/dev/null)
        local original_dropped_mac=$(cat "$BOOST_START.mac" 2>/dev/null)
        local current_time=$(date +%s)
        
        if [ -z "$boost_start_time" ] || [ -z "$original_dropped_mac" ]; then
            log "[救援錯誤] $BAND 救援狀態檔案損壞，清除狀態"
            rm -f "$BOOST_STATE" "$BOOST_START" "$BOOST_START.mac"
            return
        fi
        
        # 檢查是否超時
        if [ $((current_time - boost_start_time)) -ge "$BOOST_TIMEOUT_SECONDS" ]; then
            log "[救援結束] $BAND 救援模式超時，恢復自動調整"
            #uci set "wireless.$RADIO.txpower=$LOW_PWR"
            change_occured=1
            rm -f "$BOOST_STATE" "$BOOST_START" "$BOOST_START.mac"
        else
            # 檢查原始斷線裝置是否重新連線到任何頻段
            local current_5g_clients=$(get_clients_on_radio "$UCI_RADIO_5G")
            local current_2g_clients=$(get_clients_on_radio "$UCI_RADIO_2G")
            
            if echo "$current_5g_clients $current_2g_clients" | grep -qi "$original_dropped_mac"; then
                log "[救援成功] $BAND 裝置 $original_dropped_mac 已重新連線，解除救援"
                rm -f "$BOOST_STATE" "$BOOST_START" "$BOOST_START.mac"
            else
                log "[救援中] $BAND 等待裝置 $original_dropped_mac 連線，維持 BOOST_PWR=$BOOST_PWR"
                uci set "wireless.$RADIO.txpower=$BOOST_PWR"
                change_occured=1
            fi
        fi
    fi
}

# 處理 2.4GHz 救援模式
handle_boost "2.4GHz" "$UCI_RADIO_2G" "$STATE_2G_BOOST" "$STATE_2G_BOOST_START" "$LOW_PWR_2G" "$BOOST_PWR_2G" "$dropped_from_2g"

# 處理 5GHz 救援模式
handle_boost "5GHz" "$UCI_RADIO_5G" "$STATE_5G_BOOST" "$STATE_5G_BOOST_START" "$LOW_PWR_5G" "$BOOST_PWR_5G" "$dropped_from_5g"

# =====================
# 無人降功率
# =====================
check_no_clients_power_reduction() {
    local BAND=$1 RADIO=$2 CURRENT_CLIENTS=$3 LAST_ACTIVE_FILE=$4 LOW_PWR=$5
    if [ -n "$CURRENT_CLIENTS" ]; then
        date +%s > "$LAST_ACTIVE_FILE"
        log "[活動檢測] $BAND 有客戶端連線，更新最後活動時間"
        return
    fi
    if [ -f "$LAST_ACTIVE_FILE" ]; then
        local last_active=$(cat "$LAST_ACTIVE_FILE")
        local current_time=$(date +%s)
        local time_since_active=$((current_time - last_active))
        if [ $time_since_active -ge $NO_CLIENT_TIMEOUT ]; then
            local CURRENT_PWR=$(uci get "wireless.$RADIO.txpower" 2>/dev/null || echo "$LOW_PWR")
            [ "$CURRENT_PWR" -ne "$LOW_PWR" ] && {
                log "[無人降功率] $BAND 無人連線超過 ${NO_CLIENT_TIMEOUT} 秒，降低功率至 $LOW_PWR"
                uci set "wireless.$RADIO.txpower=$LOW_PWR"
                change_occured=1
            }
        else
            log "[無人檢測] $BAND 無人連線，但尚未超時（已過 $time_since_active 秒）"
        fi
    else
        date +%s > "$LAST_ACTIVE_FILE"
        log "[無人檢測] $BAND 首次記錄無人連線時間"
    fi
}

[ ! -f "$STATE_2G_BOOST" ] && [ "$ENABLE_2G" -eq 1 ] && check_no_clients_power_reduction "2.4GHz" "$UCI_RADIO_2G" "$CURRENT_2G_CLIENTS" "$STATE_2G_LAST_ACTIVE" "$LOW_PWR_2G"
[ ! -f "$STATE_5G_BOOST" ] && [ "$ENABLE_5G" -eq 1 ] && check_no_clients_power_reduction "5GHz" "$UCI_RADIO_5G" "$CURRENT_5G_CLIENTS" "$STATE_5G_LAST_ACTIVE" "$LOW_PWR_5G"

# =====================
# 調整功率函式 (V7.3 - 比例調整)
# =====================
adjust_radio_power_proportional() {
    local BAND_NAME=$1
    local UCI_RADIO=$2
    local THRESHOLD=$3
    local LOW_PWR=$4
    local HIGH_PWR=$5

    # 獲取最弱信號，如果沒有監控的客戶端，則返回-1表示無人
    local SIGNAL=$(get_weakest_signal "$UCI_RADIO" | tr -d '[:space:]')
    
    
    local CURRENT_PWR=$(uci get "wireless.$UCI_RADIO.txpower" 2>/dev/null || echo "$LOW_PWR")
    
    # 如果沒有監控中的客戶端，則執行降功率邏輯
    if [ "$SIGNAL" -eq -1 ]; then
        log "[功率調整] $BAND_NAME: 沒有找到監控中的客戶端。"
        
        # 檢查是否有任何客戶端連線 (即使不是監控中的)
        local any_client_connected=$(get_clients_on_radio "$UCI_RADIO")
        if [ -n "$any_client_connected" ]; then
            # 如果有普通客戶端，但沒有監控客戶端，則降至最低功率
            if [ "$CURRENT_PWR" -ne "$LOW_PWR" ]; then
                log "[功率調整] $BAND_NAME: 有非監控客戶端連線，將功率降至最低 $LOW_PWR"
                uci set "wireless.$UCI_RADIO.txpower=$LOW_PWR"
                change_occured=1
            else
                log "[功率調整] $BAND_NAME: 功率已是最低 $LOW_PWR，無需調整"
            fi
        fi
        # 如果連普通客戶端都沒有，則由 'check_no_clients_power_reduction' 處理，此處跳過
        return
    fi

    local CURRENT_PWR=$(uci get "wireless.$UCI_RADIO.txpower" 2>/dev/null || echo "$LOW_PWR")
    CURRENT_PWR=$(echo "$CURRENT_PWR" | tr -d '[:space:]')
    [ -z "$CURRENT_PWR" ] && CURRENT_PWR=$LOW_PWR

    log "[功率調整] $BAND_NAME: RSSI=$SIGNAL, 當前功率=$CURRENT_PWR, 閾值=$THRESHOLD, 遲滯=$HYSTERESIS"

    # 檢查信號是否在遲滯區間內，如果是，則不調整
    if [ "$SIGNAL" -ge $((THRESHOLD - HYSTERESIS)) ] && [ "$SIGNAL" -le $((THRESHOLD + HYSTERESIS)) ]; then
        log "[功率調整] $BAND_NAME 信號在遲滯範圍內 ($((THRESHOLD - HYSTERESIS)) ~ $((THRESHOLD + HYSTERESIS)))，不調整"
        return
    fi

    # --- 核心比例調整邏輯 ---
    # 1. 計算信號差距
    local SIGNAL_DIFF=$((THRESHOLD - SIGNAL))

    # 2. 根據差距和比例因子計算功率調整量
    #    使用 awk 進行浮點運算以獲得更精確的調整值，然後四捨五入
    local ADJUSTMENT=$(awk -v diff="$SIGNAL_DIFF" -v factor="$PROPORTIONAL_FACTOR" 'BEGIN { printf "%.0f\n", diff / factor }')

    # 3. 確保最小調整量為 1，避免因差距過小而被忽略
    if [ "$ADJUSTMENT" -eq 0 ] && [ "$SIGNAL_DIFF" -ne 0 ]; then
        [ "$SIGNAL_DIFF" -gt 0 ] && ADJUSTMENT=1 || ADJUSTMENT=-1
    fi

    # 4. 計算新的目標功率
    local NEW_PWR=$((CURRENT_PWR + ADJUSTMENT))

    # 5. 功率範圍限制 (Clamping)
    if [ "$NEW_PWR" -gt "$HIGH_PWR" ]; then
        NEW_PWR=$HIGH_PWR
        log "[功率調整] $BAND_NAME 調整值超出上限，設定為最大功率 $HIGH_PWR"
    elif [ "$NEW_PWR" -lt "$LOW_PWR" ]; then
        NEW_PWR=$LOW_PWR
        log "[功率調整] $BAND_NAME 調整值超出下限，設定為最低功率 $LOW_PWR"
    fi
    
    # 只有在計算出的新功率與當前功率不同時才進行設定
    if [ "$NEW_PWR" -ne "$CURRENT_PWR" ]; then
        uci set "wireless.$UCI_RADIO.txpower=$NEW_PWR"
        change_occured=1
        log "[功率調整] $BAND_NAME 比例調整: 差距=$SIGNAL_DIFF, 調整量=$ADJUSTMENT, 功率 $CURRENT_PWR -> $NEW_PWR"
    else
        log "[功率調整] $BAND_NAME 發射功率已達最佳 ($CURRENT_PWR)，無需變更"
    fi
}


# =====================
# 主邏輯：執行功率調整 (避開救援模式)
# =====================
main() {
    # (此處應貼上您 V7.2 版本中從 "Enable / Disable 介面" 到 "無人降功率" 結束的所有函式和邏輯)

    if [ "$ENABLE_2G" -eq 1 ] && [ ! -f "$STATE_2G_BOOST" ]; then
        adjust_radio_power_proportional "2.4GHz" "$UCI_RADIO_2G" $THRESHOLD_2G $LOW_PWR_2G $HIGH_PWR_2G
    fi

    if [ "$ENABLE_5G" -eq 1 ] && [ ! -f "$STATE_5G_BOOST" ]; then
        adjust_radio_power_proportional "5GHz" "$UCI_RADIO_5G" $THRESHOLD_5G $LOW_PWR_5G $HIGH_PWR_5G
    fi

    # =====================
    # 儲存本次客戶端狀態
    # =====================
    echo "$CURRENT_5G_CLIENTS" > "$STATE_5G_CLIENTS"
    echo "$CURRENT_2G_CLIENTS" > "$STATE_2G_CLIENTS"

    # =====================
    # 套用變更
    # =====================
    if [ $change_occured -eq 1 ]; then
        if [ "$FIRST_RUN" -eq 1 ]; then
            log "[系統] 首次執行（開機後），僅儲存狀態，跳過 wifi reload"
            uci revert wireless
        else
            log "[系統] 偵測到變更，即時套用功率（不 reload WiFi）"
            # 用 iw 即時套用 txpower，避免 wifi reload 導致 mesh+AP channel 歸 0
            for _radio in $UCI_RADIO_2G $UCI_RADIO_5G; do
                _pwr=$(uci get wireless.$_radio.txpower 2>/dev/null)
                [ -z "$_pwr" ] && continue
                _phy=$(uci get wireless.$_radio.path 2>/dev/null)
                for _dev in $(iwinfo | awk '/'$(echo $_radio | sed 's/radio/phy/')'-/{print $1}' | head -1); do
                    iw dev "$_dev" set txpower fixed $((_pwr * 100)) 2>/dev/null && \
                        log "[系統] $_dev txpower -> ${_pwr} dBm (iw)"
                done
            done
            uci commit wireless
        fi
    else
        log "[系統] 設定無需調整"
    fi

    # =====================
    # Channel 0 自動修復
    # =====================
    if [ "$FIRST_RUN" -ne 1 ]; then
        _ch0_found=0
        for _iface in $(iwinfo | awk '{print $1}' | grep '^phy'); do
            if iwinfo "$_iface" info 2>/dev/null | grep -q "Channel: 0"; then
                _ch0_found=1
                log "[嚴重] $_iface 偵測到 Channel 0"
                break
            fi
        done
        if [ "$_ch0_found" -eq 1 ]; then
            # 第一步：嘗試 wifi restart
            log "[修復] 嘗試 wifi down/up 修復..."
            wifi down; sleep 5; wifi up; sleep 10

            # 再次檢查
            _still_bad=0
            for _iface in $(iwinfo | awk '{print $1}' | grep '^phy'); do
                if iwinfo "$_iface" info 2>/dev/null | grep -q "Channel: 0"; then
                    _still_bad=1
                    break
                fi
            done

            if [ "$_still_bad" -eq 1 ]; then
                # 第二步：wifi restart 救不回，reboot
                log "[嚴重] wifi restart 無效，即將 reboot"
                . /etc/myscript/push_notify.inc 2>/dev/null
                PUSH_NAMES="admin"
                push_notify "WiFi異常: Channel 0, wifi restart 無效, 請手動 reboot" 2>/dev/null
                # sleep 3
                # reboot  # 暫時註解，排查 Lucy 連線問題
            else
                log "[修復] wifi restart 成功修復 Channel 0"
                . /etc/myscript/push_notify.inc 2>/dev/null
                PUSH_NAMES="admin"
                push_notify "WiFi異常: Channel 0, 已透過 wifi restart 修復" 2>/dev/null
            fi
        fi
    fi

    # =====================
    # 記錄系統狀態
    # =====================
    [ -f /sys/class/thermal/thermal_zone0/temp ] && {
        TEMP=$(cat /sys/class/thermal/thermal_zone0/temp)
        log "[系統] CPU 溫度: $((TEMP/1000))°C"
    }

    log "================== 智慧功率調整執行完畢 =================="
    exit 0
}

# 執行主函式
main



