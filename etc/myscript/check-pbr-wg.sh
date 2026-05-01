#!/bin/sh

#================================================================
# PBR WireGuard Interface Health Check Script (V3)
#
# 功能:
#   - 檢查所有 PBR 規則中，以 'wg' 開頭的介面。
#   - 透過指定的介面對外 PING 測試。
#   - PING 失敗: 立刻 ip rule del 切回 wan（無感）+ uci enabled=0
#   - PING 成功: ip rule add 加回（無感）+ uci delete enabled
#   - 整點且持續失敗: 背景 ifdown/ifup 重建 tunnel，ifup 完成後
#     由本腳本下一輪 ping 成功時自動加回 ip rule
#   - 1小時內 DOWN 超過 5 次: 停用該介面 PBR 規則 24 小時
#   - 全程不呼叫 pbr reload / pbr-cust start，避免中斷其他介面
#================================================================

STATE_DIR="/tmp/check-pbr-wg"
mkdir -p "$STATE_DIR"

# 一次性遷移舊檔（散落在 /tmp 根目錄的）到子目錄
for _old in /tmp/check-pbr-wg.*; do
    [ -e "$_old" ] || continue
    [ -d "$_old" ] && continue
    _base=${_old#/tmp/check-pbr-wg.}
    mv -f "$_old" "$STATE_DIR/$_base" 2>/dev/null
done

LOCK="$STATE_DIR/.lock"
if [ -f "$LOCK" ]; then
    kill -0 "$(cat "$LOCK")" 2>/dev/null && exit 0
    rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK" /tmp/cron_global.lock "$STATE_DIR"/*.cr_done' EXIT

# 全域 cron 排隊鎖
. /etc/myscript/lock-handler.sh
cron_global_lock 60 || exit 0

# 非主gw 不需要檢查 PBR/WG 狀態
GW_TYPE=$(cat /etc/myscript/.mesh_gw_type 2>/dev/null)
[ "$GW_TYPE" != "主gw" ] && exit 0

# 引入通知器
. /etc/myscript/push-notify.inc
PUSH_NAMES="admin"

# --- 設定 ---
TARGET_IP="8.8.8.8"
PING_COUNT=3
PING_TIMEOUT=5
QUIET_MODE=0
DOWN_THRESHOLD=5      # 1小時內 DOWN 幾次觸發停用
DOWN_WINDOW=3600      # 滑動視窗秒數
DISABLE_DURATION=86400 # 停用秒數（24小時）

if [ "$1" = "--quiet" ] || [ "$1" = "-q" ]; then
    QUIET_MODE=1
fi

log() {
    [ "$QUIET_MODE" -eq 1 ] && return
    logger -t PBR_HealthCheck "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# 切換事件強制寫 logread，不受 QUIET_MODE 影響
log_event() {
    logger -t PBR_HealthCheck "$1"
}

# 記錄一次 DOWN 事件時間戳，並清除視窗外舊記錄
record_down_event() {
    local iface="$1"
    local downlog="${STATE_DIR}/${iface}.downlog"
    local now=$(date '+%s')
    local cutoff=$((now - DOWN_WINDOW))
    echo "$now" >> "$downlog"
    # 只保留視窗內的記錄
    awk -v cutoff="$cutoff" '$1 > cutoff' "$downlog" > "${downlog}.tmp" && mv "${downlog}.tmp" "$downlog"
}

# 檢查是否觸發高頻停用，或是否已到恢復時間
# 回傳 0 = 正常可用，1 = 目前在停用期（跳過 ping）
check_flap_disable() {
    local iface="$1"
    local downlog="${STATE_DIR}/${iface}.downlog"
    local disabled_until_file="${STATE_DIR}/${iface}.disabled_until"
    local now=$(date '+%s')

    # 檢查是否在停用期
    if [ -f "$disabled_until_file" ]; then
        local until=$(cat "$disabled_until_file")
        if [ "$now" -lt "$until" ]; then
            local remain=$(( (until - now) / 3600 ))
            log "    [$iface] 高頻停用中，剩餘約 ${remain} 小時，跳過"
            return 1
        else
            # 停用到期，自動恢復
            rm -f "$disabled_until_file" "$downlog"
            log_event "[FLAP] $iface 停用期滿，自動恢復"
            log "    [$iface] 停用期滿，已自動恢復"
            push_notify "${iface}_FlapDisable_Recovered"
        fi
    fi

    # 檢查視窗內 DOWN 次數是否超標
    if [ -f "$downlog" ]; then
        local cutoff=$((now - DOWN_WINDOW))
        local count=$(awk -v cutoff="$cutoff" '$1 > cutoff' "$downlog" | wc -l)
        if [ "$count" -ge "$DOWN_THRESHOLD" ]; then
            local until=$((now + DISABLE_DURATION))
            echo "$until" > "$disabled_until_file"
            log_event "[FLAP] $iface 1小時內 DOWN ${count} 次，停用 PBR 24 小時"
            log "    [$iface] 高頻異常（${count} 次/小時），停用 PBR 規則 24 小時"
            push_notify "${iface}_FlapDisable_24h"
            return 1
        fi
    fi

    return 0
}

# 從 ip rule 動態查出介面對應的 fwmark 與 priority
# 輸出: "<prio> <fwmark> <mask> <table>"，查無則空
get_iface_rule() {
    local iface="$1"
    local table="pbr_${iface}"
    ip rule list | awk -v tbl="$table" '
        $0 ~ "lookup " tbl "$" {
            prio = $1+0
            for (i=1;i<=NF;i++) {
                if ($i == "fwmark") { split($(i+1), fm, "/"); fwmark=fm[1]; mask=fm[2] }
            }
            print prio, fwmark, mask, tbl
            exit
        }'
}

# ip rule 是否存在（fwmark 類）
rule_exists() {
    local iface="$1"
    ip rule list | grep -q "lookup pbr_${iface}$"
}

# CustRule per-IP rule del（介面 DOWN 時移除）
custrule_del() {
    local iface="$1"
    local cache="${STATE_DIR}/${iface}.custrules"
    local entries=""

    if [ -f "$cache" ]; then
        entries=$(cat "$cache")
    else
        # cache 不存在時從 ip rule list 即時查（table 1000-4000）
        entries=$(ip rule list | awk '$1=="200:" && $2=="from" && $3!="all" {
            tbl=$5+0; if(tbl>=1000 && tbl<=4000) print $3, tbl}')
        # 只保留指向本介面的（從 uci 比對）
        entries=$(echo "$entries" | while read _src _tbl; do
            _name=$(uci show pbr | grep "src_addr='${_src}'" | cut -d'.' -f2 | \
                while read _sec; do
                    _dev=$(uci get "pbr.${_sec}.dest_addr" 2>/dev/null)
                    [ "$_dev" = "$iface" ] && echo "$_src $_tbl" && break
                done)
            [ -n "$_name" ] && echo "$_name"
        done)
    fi

    echo "$entries" | while read _src _tbl; do
        [ -z "$_src" ] && continue
        ip rule del prio 200 from "$_src" lookup "$_tbl" 2>/dev/null
        log_event "[DOWN] $iface CustRule ip rule del from $_src lookup $_tbl"
        log "    動作: CustRule ip rule del from $_src lookup $_tbl"
    done
}

# CustRule per-IP rule add（介面 UP 時還原）
custrule_add() {
    local iface="$1"
    local cache="${STATE_DIR}/${iface}.custrules"
    [ ! -f "$cache" ] && return

    while read _src _tbl; do
        [ -z "$_src" ] && continue
        ip rule add prio 200 from "$_src" lookup "$_tbl" 2>/dev/null
        log_event "[UP] $iface CustRule ip rule add from $_src lookup $_tbl"
        log "    動作: CustRule ip rule add from $_src lookup $_tbl"
    done < "$cache"
}

# CustRule table default route 自我修復
# pbr 服務 reload 會清掉 1000-4000 table 的 route 但保留 ip rule，
# 造成 rule 命中後 table 查不到 → fallthrough 走 wan。
custrule_route_repair() {
    local iface="$1"
    local cache="${STATE_DIR}/${iface}.custrules"
    [ ! -f "$cache" ] && return

    while read _src _tbl; do
        [ -z "$_tbl" ] && continue
        if ! ip route show table "$_tbl" 2>/dev/null | grep -q "^default dev ${iface} "; then
            ip route replace default dev "$iface" table "$_tbl" 2>/dev/null
            log_event "[REPAIR] $iface table $_tbl 缺 default route，已補 default dev $iface"
            log "    修復: table $_tbl 補上 default dev $iface"
        fi
    done < "$cache"
}

log "開始檢查 PBR WireGuard 介面連線狀態..."

SECTIONS=$(uci show pbr | grep ".dest_addr='wg" | cut -d'.' -f2)

if [ -z "$SECTIONS" ]; then
    log "找不到任何 dest_addr 以 'wg' 開頭的 PBR 策略。"
    exit 0
fi

CURRENT_HHMM=$(date '+%H%M')

# === 第一階段：每個介面只 ping 一次，結果存 ${STATE_DIR}/<iface>.pingresult (up/down/skip) ===
CHECKED_IFACES=""
for SECTION in $SECTIONS; do
    INTERFACE=$(uci get pbr.${SECTION}.dest_addr)
    echo "$CHECKED_IFACES" | grep -qw "$INTERFACE" && continue

    # 無 endpoint 的 passive wg peer 跳過
    _has_endpoint=$(uci show network 2>/dev/null | grep "@wireguard_${INTERFACE}\[" | \
        grep "endpoint_host" | grep -v "=''$" | wc -l)
    if [ "$_has_endpoint" = "0" ]; then
        echo "skip" > "${STATE_DIR}/${INTERFACE}.pingresult"
        CHECKED_IFACES="$CHECKED_IFACES $INTERFACE"
        continue
    fi

    # 高頻停用檢查：停用中則跳過此介面
    if ! check_flap_disable "$INTERFACE"; then
        echo "skip" > "${STATE_DIR}/${INTERFACE}.pingresult"
        CHECKED_IFACES="$CHECKED_IFACES $INTERFACE"
        continue
    fi

    log " -> 正在檢查介面: $INTERFACE ..."
    if ping -c $PING_COUNT -W $PING_TIMEOUT -I $INTERFACE $TARGET_IP >/dev/null 2>&1; then
        echo "up" > "${STATE_DIR}/${INTERFACE}.pingresult"
        log "    狀態: 連線正常 (UP)"

        # ping 成功時順手更新 fwmark cache
        if rule_exists "$INTERFACE"; then
            RULE_CACHE="${STATE_DIR}/${INTERFACE}.rule"
            ip rule list | awk -v tbl="pbr_${INTERFACE}" '
                $0 ~ "lookup " tbl "$" {
                    prio=$1+0
                    for(i=1;i<=NF;i++) if($i=="fwmark"){fm=$(i+1)}
                    print prio, fm, tbl
                    exit
                }' > "$RULE_CACHE"
        fi

        # 自我修復：確保 CustRule table 都有 default route（防 pbr reload 把 route 清掉）
        custrule_route_repair "$INTERFACE"

        # ip rule 加回（若介面曾被標記 DOWN）
        if ! rule_exists "$INTERFACE"; then
            RULE_CACHE="${STATE_DIR}/${INTERFACE}.rule"
            if [ -f "$RULE_CACHE" ]; then
                _prio=$(awk '{print $1}' "$RULE_CACHE")
                _fm=$(awk '{print $2}' "$RULE_CACHE")
                _tbl=$(awk '{print $3}' "$RULE_CACHE")
                ip rule add prio $_prio fwmark $_fm lookup $_tbl 2>/dev/null
                log_event "[UP] $INTERFACE ip rule 已還原 (prio=$_prio fwmark=$_fm) → 流量切回 wg"
                log "    動作: ip rule add prio=$_prio fwmark=$_fm lookup=$_tbl (從 cache 還原)"
            else
                log_event "[UP] $INTERFACE ping 恢復但無 rule cache，等下次 pbr reload"
                log "    警告: 無 rule cache，無法還原 ip rule，等下次 pbr reload 自動補上"
            fi
        fi

        # custrule_add 只在曾被標記 DOWN（prevresult=down）時才還原
        PREV_RESULT_UP=$(cat "${STATE_DIR}/${INTERFACE}.prevresult" 2>/dev/null)
        if [ "$PREV_RESULT_UP" = "down" ]; then
            _cr_done_flag="${STATE_DIR}/${INTERFACE}.cr_done"
            if [ ! -f "$_cr_done_flag" ]; then
                custrule_add "$INTERFACE"
                touch "$_cr_done_flag"
            fi
        fi
    else
        echo "down" > "${STATE_DIR}/${INTERFACE}.pingresult"
        log "    狀態: 連線中斷 (DOWN)"

        # 記錄 DOWN 事件（高頻偵測）
        record_down_event "$INTERFACE"

        # ip rule del 切回 wan（無感）
        if rule_exists "$INTERFACE"; then
            RULE_CACHE="${STATE_DIR}/${INTERFACE}.rule"
            ip rule list | awk -v tbl="pbr_${INTERFACE}" '
                $0 ~ "lookup " tbl "$" {
                    prio=$1+0
                    for(i=1;i<=NF;i++) if($i=="fwmark"){fm=$(i+1)}
                    print prio, fm, tbl
                    exit
                }' > "$RULE_CACHE"
            _prio=$(awk '{print $1}' "$RULE_CACHE")
            _fm=$(awk '{print $2}' "$RULE_CACHE")
            _tbl=$(awk '{print $3}' "$RULE_CACHE")
            ip rule del prio $_prio fwmark $_fm lookup $_tbl 2>/dev/null
            log_event "[DOWN] $INTERFACE ip rule 已移除 (prio=$_prio fwmark=$_fm) → 流量切回 wan"
            log "    動作: ip rule del prio=$_prio fwmark=$_fm → 流量切回 wan（無感）"
        fi

        _cr_done_flag="${STATE_DIR}/${INTERFACE}.cr_done"
        if [ ! -f "$_cr_done_flag" ]; then
            custrule_del "$INTERFACE"
            touch "$_cr_done_flag"
        fi

        # 整點：背景重啟 tunnel
        if [ "$CURRENT_HHMM" = "0400" ]; then
            log_event "[DOWN] $INTERFACE 整點重啟 tunnel（背景，流量續走 wan）"
            log "    *** 整點重啟 $INTERFACE tunnel（背景執行，流量續走 wan）..."
            (ifdown $INTERFACE; sleep 3; ifup $INTERFACE) &
        fi
    fi

    CHECKED_IFACES="$CHECKED_IFACES $INTERFACE"
done

# === 第二階段：所有 section 同步 uci enabled 狀態 ===
for SECTION in $SECTIONS; do
    INTERFACE=$(uci get pbr.${SECTION}.dest_addr)
    POLICY_NAME=$(uci get pbr.${SECTION}.name 2>/dev/null || echo "$SECTION")
    PING_RESULT=$(cat "${STATE_DIR}/${INTERFACE}.pingresult" 2>/dev/null)

    case "$PING_RESULT" in
        up)
            CURRENT_STATUS=$(uci get pbr.${SECTION}.enabled 2>/dev/null)
            if [ "$CURRENT_STATUS" = "0" ]; then
                uci delete pbr.${SECTION}.enabled
                log " -> $POLICY_NAME ($INTERFACE): uci enabled 清除"
            fi
            ;;
        down)
            CURRENT_STATUS=$(uci get pbr.${SECTION}.enabled 2>/dev/null)
            if [ "$CURRENT_STATUS" != "0" ]; then
                uci set pbr.${SECTION}.enabled='0'
                log " -> $POLICY_NAME ($INTERFACE): uci enabled=0"
            fi
            ;;
    esac
done

# push_notify 只推一次（以介面為單位，避免同介面多 section 重複推）
NOTIFIED_IFACES=""
for SECTION in $SECTIONS; do
    INTERFACE=$(uci get pbr.${SECTION}.dest_addr)
    echo "$NOTIFIED_IFACES" | grep -qw "$INTERFACE" && continue
    PING_RESULT=$(cat "${STATE_DIR}/${INTERFACE}.pingresult" 2>/dev/null)
    PREV_RESULT="${STATE_DIR}/${INTERFACE}.prevresult"
    PREV=$(cat "$PREV_RESULT" 2>/dev/null)
    if [ "$PING_RESULT" != "$PREV" ]; then
        case "$PING_RESULT" in
            up)   push_notify "${INTERFACE}_UP" ;;
            down) push_notify "${INTERFACE}_Down" ;;
        esac
        echo "$PING_RESULT" > "$PREV_RESULT"
    fi
    NOTIFIED_IFACES="$NOTIFIED_IFACES $INTERFACE"
done

# 如果有任何變更，則提交設定並重載服務
uci changes pbr | grep -q . && uci commit pbr

# === 域名路由健康檢查（動態，所有 route_*_v4 介面） ===
RT_TABLES="/etc/iproute2/rt_tables"
DBR_CONF="/etc/dnsmasq.d/dbroute-domains.conf"
DBR_NFT="/etc/myscript/dbroute.nft"

if [ -f "$DBR_CONF" ]; then
    # 確保 nft table 存在（可能被 firewall restart 清掉）
    if ! nft list table inet fw4 >/dev/null 2>&1; then
        if [ -f "$DBR_NFT" ]; then
            nft -f "$DBR_NFT" && log "nft table fw4 重建成功" || log "nft table fw4 重建失敗"
            service dnsmasq restart
            push_notify "dbroute_nft_rebuilt"
        fi
    fi

    DR_IFACES=$(sed -n 's/.*#inet#fw4#route_\(.*\)_v4$/\1/p' "$DBR_CONF" | sort -u)

    for DR_IFACE in $DR_IFACES; do
        if ! ip link show "$DR_IFACE" >/dev/null 2>&1; then
            continue
        fi

        DR_TABLE=$(awk -v name="pbr_${DR_IFACE}" '$2 == name {print $1}' "$RT_TABLES")
        [ -z "$DR_TABLE" ] && continue
        DR_FWMARK=$(printf "0x%x" "$DR_TABLE")

        if ping -c $PING_COUNT -W $PING_TIMEOUT -I "$DR_IFACE" $TARGET_IP >/dev/null 2>&1; then
            if ! ip rule show | grep -q "fwmark $DR_FWMARK"; then
                /etc/myscript/dbroute-setup.sh
                log "${DR_IFACE} UP → 恢復 domain routing"
                push_notify "${DR_IFACE}_DomainRoute_UP"
            fi
        else
            if ip rule show | grep -q "fwmark $DR_FWMARK"; then
                ip rule del fwmark "$DR_FWMARK" lookup "$DR_TABLE" 2>/dev/null
                log "${DR_IFACE} DOWN → 移除 domain routing"
                push_notify "${DR_IFACE}_DomainRoute_Down"
            fi
            if [ "$CURRENT_HHMM" = "0400" ]; then
                log "${DR_IFACE} 整點重啟（背景）..."
                (ifdown "$DR_IFACE"; sleep 3; ifup "$DR_IFACE") &
            fi
        fi
    done
fi

log "檢查完畢。"
