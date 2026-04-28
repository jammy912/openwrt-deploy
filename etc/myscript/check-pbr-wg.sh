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
#   - 全程不呼叫 pbr reload / pbr-cust start，避免中斷其他介面
#================================================================

LOCK="/tmp/check-pbr-wg.lock"
if [ -f "$LOCK" ]; then
    kill -0 "$(cat "$LOCK")" 2>/dev/null && exit 0
    rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK" /tmp/cron_global.lock /tmp/check-pbr-wg.*.cr_done' EXIT

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
    local cache="/tmp/check-pbr-wg.${iface}.custrules"
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
    local cache="/tmp/check-pbr-wg.${iface}.custrules"
    [ ! -f "$cache" ] && return

    while read _src _tbl; do
        [ -z "$_src" ] && continue
        ip rule add prio 200 from "$_src" lookup "$_tbl" 2>/dev/null
        log_event "[UP] $iface CustRule ip rule add from $_src lookup $_tbl"
        log "    動作: CustRule ip rule add from $_src lookup $_tbl"
    done < "$cache"
}

log "開始檢查 PBR WireGuard 介面連線狀態..."

SECTIONS=$(uci show pbr | grep ".dest_addr='wg" | cut -d'.' -f2)

if [ -z "$SECTIONS" ]; then
    log "找不到任何 dest_addr 以 'wg' 開頭的 PBR 策略。"
    exit 0
fi

CURRENT_HHMM=$(date '+%H%M')

for SECTION in $SECTIONS; do
    INTERFACE=$(uci get pbr.${SECTION}.dest_addr)
    POLICY_NAME=$(uci get pbr.${SECTION}.name 2>/dev/null || echo "$SECTION")

    log " -> 正在檢查策略 '$POLICY_NAME' (介面: $INTERFACE)..."

    # 無 endpoint 的 passive wg peer 跳過
    # 用 UCI grep 查（wg show 在介面 down 時會失敗，不可靠）
    _has_endpoint=$(uci show network 2>/dev/null | grep "@wireguard_${INTERFACE}\[" | \
        grep "endpoint_host" | grep -v "=''$" | wc -l)
    if [ "$_has_endpoint" = "0" ]; then
        log "    跳過: $INTERFACE 無 endpoint (passive peer)"
        continue
    fi

    if ping -c $PING_COUNT -W $PING_TIMEOUT -I $INTERFACE $TARGET_IP >/dev/null 2>&1; then
        # --- PING 成功 ---
        log "    狀態: 連線正常 (UP)"

        # ping 成功時順手更新 cache，確保 fwmark 永遠是最新值
        if rule_exists "$INTERFACE"; then
            RULE_CACHE="/tmp/check-pbr-wg.${INTERFACE}.rule"
            ip rule list | awk -v tbl="pbr_${INTERFACE}" '
                $0 ~ "lookup " tbl "$" {
                    prio=$1+0
                    for(i=1;i<=NF;i++) if($i=="fwmark"){fm=$(i+1)}
                    print prio, fm, tbl
                    exit
                }' > "$RULE_CACHE"
        fi

        CURRENT_STATUS=$(uci get pbr.${SECTION}.enabled 2>/dev/null)
        if [ "$CURRENT_STATUS" = "0" ]; then
            # ip rule 加回（若不存在）— 從 /tmp/check-pbr-wg.$INTERFACE.rule 讀取
            # down 時已把完整 rule 字串存檔，直接還原，不靠換算
            if ! rule_exists "$INTERFACE"; then
                RULE_CACHE="/tmp/check-pbr-wg.${INTERFACE}.rule"
                if [ -f "$RULE_CACHE" ]; then
                    # 格式: "<prio> <fwmark>/<mask> <table>"
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
            # custrule_add 每個介面只跑一次（多個 SECTION 同介面時防重複）
            _cr_done_flag="/tmp/check-pbr-wg.${INTERFACE}.cr_done"
            if [ ! -f "$_cr_done_flag" ]; then
                custrule_add "$INTERFACE"
                touch "$_cr_done_flag"
            fi
            uci delete pbr.${SECTION}.enabled
            uci commit pbr
            push_notify "${INTERFACE}_UP"
            log "    動作: 規則已恢復，uci enabled 清除"
        else
            log "    動作: 無需變更"
        fi

    else
        # --- PING 失敗 ---
        log "    狀態: 連線中斷 (DOWN)"

        # 立刻 ip rule del 切回 wan（無感）
        # 先把完整 rule 存檔，以便 UP 時原樣還原
        if rule_exists "$INTERFACE"; then
            RULE_CACHE="/tmp/check-pbr-wg.${INTERFACE}.rule"
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

        # custrule_del 每個介面只跑一次（多個 SECTION 同介面時防重複）
        _cr_done_flag="/tmp/check-pbr-wg.${INTERFACE}.cr_done"
        if [ ! -f "$_cr_done_flag" ]; then
            custrule_del "$INTERFACE"
            touch "$_cr_done_flag"
        fi

        # uci 同步狀態
        CURRENT_STATUS=$(uci get pbr.${SECTION}.enabled 2>/dev/null)
        if [ "$CURRENT_STATUS" != "0" ]; then
            uci set pbr.${SECTION}.enabled='0'
            uci commit pbr
            push_notify "${INTERFACE}_Down"
            log "    動作: uci enabled=0 已同步"
        else
            log "    動作: 規則已停用，無需變更"
        fi

        # 整點：背景重啟 tunnel，流量已切 wan 不影響上網
        if [ "$CURRENT_HHMM" = "0400" ]; then
            log_event "[DOWN] $INTERFACE 整點重啟 tunnel（背景，流量續走 wan）"
            log "    *** 整點重啟 $INTERFACE tunnel（背景執行，流量續走 wan）..."
            (ifdown $INTERFACE; sleep 3; ifup $INTERFACE) &
        fi
    fi
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
