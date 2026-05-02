#!/bin/sh

#================================================================
# PBR WireGuard Interface Health Check Script (V4 抗抖動版)
#
# 功能:
#   - 檢查所有 PBR 規則中，以 'wg' 開頭的介面。
#   - 透過指定的介面對外 PING 測試（5 包，允許 ≤ 2 包遺失）。
#   - PING 失敗: 連續 DOWN_CONFIRM 輪都失敗才 ip rule del 切回 wan，
#     單次抖動只記為 pending，不動 ip rule、不推播、不計入 24h 視窗。
#   - PING 成功: 若先前被切走，需連續 UP_CONFIRM 輪 UP 才把 ip rule
#     加回 wg（冷靜期），避免抖動期間反覆 flip 影響長連線。
#   - 整點且確認失敗: 背景 ifdown/ifup 重建 tunnel，ifup 完成後
#     由本腳本下一輪 ping 成功時自動進入冷靜期，再加回 ip rule。
#   - 1小時內 DOWN 超過 DOWN_THRESHOLD 次: 短鎖 5 分鐘;24 小時內
#     累計達 LOCK_ESCALATE_THRESHOLD 次自動升級為長鎖 24 小時。
#   - 全程不呼叫 pbr reload / pbr-cust start，避免中斷其他介面。
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
trap 'rm -f "$LOCK" /tmp/cron_global.lock' EXIT
# 註: 不清 *.cr_done, 讓它跨輪持續存在; 只在 DOWN/UP 切換時 toggle

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
PING_COUNT=5             # 每輪送 5 包
PING_LOSS_TOLERATE=2     # 5 包中允許最多 2 包遺失仍視為 up（success >= 3）
PING_TIMEOUT=5
QUIET_MODE=0
DOWN_CONFIRM=2           # 連續 N 輪 ping 失敗才真的切走 wan
UP_CONFIRM=4             # 從 DOWN 恢復後, 需連續 N 輪 UP 才加回 wg（≈ 2 分鐘冷靜期）
DOWN_THRESHOLD=10              # 1小時內 DOWN 幾次觸發停用
DOWN_WINDOW=3600               # 滑動視窗秒數
SHORT_LOCK_DURATION=300        # 短鎖時長: 5 分鐘
LONG_LOCK_DURATION=86400       # 長鎖時長: 24 小時
LOCK_ESCALATE_THRESHOLD=3      # 短鎖累計 N 次升級到長鎖
LOCK_ESCALATE_WINDOW=86400     # 累計視窗: 24 小時
DISABLE_DURATION=86400 # 停用秒數（24小時, 保留為相容變數, 未使用）

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

# 連敗 / 連勝計數器（跨輪累計，存於 STATE_DIR）
fail_count_get()   { cat "${STATE_DIR}/${1}.failcount" 2>/dev/null || echo 0; }
fail_count_inc()   { echo $(( $(fail_count_get "$1") + 1 )) > "${STATE_DIR}/${1}.failcount"; }
fail_count_reset() { rm -f "${STATE_DIR}/${1}.failcount"; }

up_count_get()     { cat "${STATE_DIR}/${1}.upcount" 2>/dev/null || echo 0; }
up_count_inc()     { echo $(( $(up_count_get "$1") + 1 )) > "${STATE_DIR}/${1}.upcount"; }
up_count_reset()   { rm -f "${STATE_DIR}/${1}.upcount"; }

# dbroute (域名路由) 獨立計數器與 prev 紀錄
db_fail_get()      { cat "${STATE_DIR}/${1}.dbfailcount" 2>/dev/null || echo 0; }
db_fail_inc()      { echo $(( $(db_fail_get "$1") + 1 )) > "${STATE_DIR}/${1}.dbfailcount"; }
db_fail_reset()    { rm -f "${STATE_DIR}/${1}.dbfailcount"; }
db_up_get()        { cat "${STATE_DIR}/${1}.dbupcount" 2>/dev/null || echo 0; }
db_up_inc()        { echo $(( $(db_up_get "$1") + 1 )) > "${STATE_DIR}/${1}.dbupcount"; }
db_up_reset()      { rm -f "${STATE_DIR}/${1}.dbupcount"; }
db_prev_get()      { cat "${STATE_DIR}/${1}.dbprevresult" 2>/dev/null; }
db_prev_set()      { echo "$2" > "${STATE_DIR}/${1}.dbprevresult"; }

# 將秒數轉成「N 小時」/「N 分鐘」/「N 秒」可讀字串
fmt_duration() {
    local s="$1"
    if [ "$s" -ge 3600 ]; then
        echo "$(( s / 3600 )) 小時"
    elif [ "$s" -ge 60 ]; then
        echo "$(( s / 60 )) 分鐘"
    else
        echo "${s} 秒"
    fi
}

# 檢查是否觸發高頻停用，或是否已到恢復時間
# 階梯式停用: 短鎖 SHORT_LOCK_DURATION (5 分鐘),
# 24 小時內累計 LOCK_ESCALATE_THRESHOLD (3) 次升級為長鎖 LONG_LOCK_DURATION (24 小時)
# 回傳 0 = 正常可用，1 = 目前在停用期（跳過 ping）
check_flap_disable() {
    local iface="$1"
    local downlog="${STATE_DIR}/${iface}.downlog"
    local disabled_until_file="${STATE_DIR}/${iface}.disabled_until"
    local lock_history_file="${STATE_DIR}/${iface}.lockhistory"
    local now=$(date '+%s')

    # 檢查是否在停用期
    if [ -f "$disabled_until_file" ]; then
        local until=$(cat "$disabled_until_file")
        if [ "$now" -lt "$until" ]; then
            local remain=$(( until - now ))
            log "    [$iface] 高頻停用中，剩餘約 $(fmt_duration $remain)，跳過"
            return 1
        else
            # 停用到期，自動恢復 (downlog 清掉重新計數, lockhistory 保留供升級判斷)
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
            # 寫入鎖歷史並清掉視窗外舊紀錄
            echo "$now" >> "$lock_history_file"
            local lock_cutoff=$((now - LOCK_ESCALATE_WINDOW))
            awk -v cutoff="$lock_cutoff" '$1 > cutoff' "$lock_history_file" \
                > "${lock_history_file}.tmp" && mv "${lock_history_file}.tmp" "$lock_history_file"
            local lock_count=$(wc -l < "$lock_history_file")

            local lock_dur lock_label notify_tag
            if [ "$lock_count" -ge "$LOCK_ESCALATE_THRESHOLD" ]; then
                lock_dur=$LONG_LOCK_DURATION
                lock_label="長鎖 $(fmt_duration $LONG_LOCK_DURATION) (累計第 ${lock_count} 次)"
                notify_tag="${iface}_FlapDisable_Long"
            else
                lock_dur=$SHORT_LOCK_DURATION
                lock_label="短鎖 $(fmt_duration $SHORT_LOCK_DURATION) (累計第 ${lock_count}/${LOCK_ESCALATE_THRESHOLD} 次)"
                notify_tag="${iface}_FlapDisable_Short"
            fi

            local until=$((now + lock_dur))
            echo "$until" > "$disabled_until_file"
            log_event "[FLAP] $iface 1小時內 DOWN ${count} 次，${lock_label}"
            log "    [$iface] 高頻異常（${count} 次/小時），${lock_label}"
            push_notify "$notify_tag"
            return 1
        fi
    fi

    return 0
}

# 從 ip rule 動態查出介面對應的 fwmark 與 priority
# 只抓主 PBR rule (prio >= 29000), 排除 dbroute (prio 100) 與 cust (prio 200)
# 輸出: "<prio> <fwmark> <mask> <table>"，查無則空
get_iface_rule() {
    local iface="$1"
    local table="pbr_${iface}"
    ip rule list | awk -v tbl="$table" '
        $0 ~ "lookup " tbl "$" {
            prio = $1+0
            if (prio < 29000) next
            for (i=1;i<=NF;i++) {
                if ($i == "fwmark") { split($(i+1), fm, "/"); fwmark=fm[1]; mask=fm[2] }
            }
            print prio, fwmark, mask, tbl
            exit
        }'
}

# 主 PBR ip rule 是否存在 (只看 prio>=29000, 排除 dbroute/cust)
rule_exists() {
    local iface="$1"
    ip rule list | awk -v tbl="pbr_${iface}" '
        $0 ~ "lookup " tbl "$" {
            prio = $1+0
            if (prio >= 29000) { found=1; exit }
        }
        END { exit !found }'
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
    _received=$(ping -c $PING_COUNT -W $PING_TIMEOUT -I $INTERFACE $TARGET_IP 2>/dev/null \
        | sed -n 's/^.*, \([0-9][0-9]*\) packets received.*/\1/p')
    _received=${_received:-0}
    _need=$(( PING_COUNT - PING_LOSS_TOLERATE ))
    if [ "$_received" -ge "$_need" ]; then
        log "    狀態: 連線正常 (UP, ${_received}/${PING_COUNT})"

        # 清掉 DOWN 連敗計數
        fail_count_reset "$INTERFACE"

        # ping 成功時順手更新 fwmark cache (只抓主 PBR, 排除 dbroute/cust)
        if rule_exists "$INTERFACE"; then
            RULE_CACHE="${STATE_DIR}/${INTERFACE}.rule"
            ip rule list | awk -v tbl="pbr_${INTERFACE}" '
                $0 ~ "lookup " tbl "$" {
                    prio=$1+0
                    if (prio < 29000) next
                    for(i=1;i<=NF;i++) if($i=="fwmark"){fm=$(i+1)}
                    print prio, fm, tbl
                    exit
                }' > "$RULE_CACHE"
        fi

        # 自我修復：確保 CustRule table 都有 default route（防 pbr reload 把 route 清掉）
        custrule_route_repair "$INTERFACE"

        if rule_exists "$INTERFACE"; then
            # 已在 wg, 不需冷靜期
            up_count_reset "$INTERFACE"

            # 保險: 若 prevresult=down 表示先前被腳本切走,
            # 但主 rule 已被外部 (pbr reload / hotplug ifup) 補回,
            # 此時 custrules 可能仍未回復, 用 cache 補上一次。
            # cr_done 旗標代表「DOWN 階段已 custrule_del」, 需要對應 add 還原
            PREV_RESULT_UP=$(cat "${STATE_DIR}/${INTERFACE}.prevresult" 2>/dev/null)
            if [ "$PREV_RESULT_UP" = "down" ]; then
                _cr_done_flag="${STATE_DIR}/${INTERFACE}.cr_done"
                if [ -f "$_cr_done_flag" ]; then
                    log_event "[REPAIR] $INTERFACE 主 rule 已由外部重建, 補 CustRule"
                    custrule_add "$INTERFACE"
                    rm -f "$_cr_done_flag"
                fi
            fi

            echo "up" > "${STATE_DIR}/${INTERFACE}.pingresult"
        else
            # 先前被切走, 進入冷靜期累計
            up_count_inc "$INTERFACE"
            _upc=$(up_count_get "$INTERFACE")
            if [ "$_upc" -lt "$UP_CONFIRM" ]; then
                log "    冷靜期 ${_upc}/${UP_CONFIRM}: 仍走 wan, 暫不加回 ip rule"
                log_event "[PENDING] $INTERFACE 冷靜期 ${_upc}/${UP_CONFIRM} (ping ${_received}/${PING_COUNT})"
                # cooldown 期間第二階段不該動 uci, 標 pending
                echo "pending" > "${STATE_DIR}/${INTERFACE}.pingresult"
            else
                # 連勝確認完成, 還原 ip rule
                RULE_CACHE="${STATE_DIR}/${INTERFACE}.rule"
                if [ -f "$RULE_CACHE" ]; then
                    _prio=$(awk '{print $1}' "$RULE_CACHE")
                    _fm=$(awk '{print $2}' "$RULE_CACHE")
                    _tbl=$(awk '{print $3}' "$RULE_CACHE")
                    ip rule add prio $_prio fwmark $_fm lookup $_tbl 2>/dev/null
                    log_event "[UP] $INTERFACE 冷靜期完成, ip rule 已還原 (prio=$_prio fwmark=$_fm) → 流量切回 wg"
                    log "    動作: ip rule add prio=$_prio fwmark=$_fm lookup=$_tbl (從 cache 還原)"
                else
                    log_event "[UP] $INTERFACE 冷靜期完成但無 rule cache，等下次 pbr reload"
                    log "    警告: 無 rule cache，無法還原 ip rule，等下次 pbr reload 自動補上"
                fi

                # custrule_add 只在曾被標記 DOWN 時才還原
                # cr_done 旗標 = DOWN 階段已 custrule_del, UP 階段對應 add 並清旗標
                PREV_RESULT_UP=$(cat "${STATE_DIR}/${INTERFACE}.prevresult" 2>/dev/null)
                if [ "$PREV_RESULT_UP" = "down" ]; then
                    _cr_done_flag="${STATE_DIR}/${INTERFACE}.cr_done"
                    if [ -f "$_cr_done_flag" ]; then
                        custrule_add "$INTERFACE"
                        rm -f "$_cr_done_flag"
                    fi
                fi

                up_count_reset "$INTERFACE"
                echo "up" > "${STATE_DIR}/${INTERFACE}.pingresult"
            fi
        fi
    else
        log "    狀態: 連線異常 (DOWN, ${_received}/${PING_COUNT})"

        # 清掉 UP 連勝計數
        up_count_reset "$INTERFACE"

        # 連敗確認: 未達門檻只記 pending, 不動 ip rule、不計入 24h 視窗
        # 達門檻後不再 inc, 避免長期離線累積成大數字 (與第三階段 dbroute 一致)
        _fc=$(fail_count_get "$INTERFACE")
        if [ "$_fc" -lt "$DOWN_CONFIRM" ]; then
            fail_count_inc "$INTERFACE"
            _fc=$(fail_count_get "$INTERFACE")
        fi
        if [ "$_fc" -lt "$DOWN_CONFIRM" ]; then
            log "    DOWN 確認中 ${_fc}/${DOWN_CONFIRM}: 暫不切回 wan"
            log_event "[PENDING] $INTERFACE DOWN 確認中 ${_fc}/${DOWN_CONFIRM} (ping ${_received}/${PING_COUNT})"
            echo "pending" > "${STATE_DIR}/${INTERFACE}.pingresult"
            CHECKED_IFACES="$CHECKED_IFACES $INTERFACE"
            continue
        fi

        echo "down" > "${STATE_DIR}/${INTERFACE}.pingresult"

        # 連敗確認完成 → 真切走
        record_down_event "$INTERFACE"

        # ip rule del 切回 wan（無感, 只刪主 PBR rule, 不影響 dbroute/cust）
        if rule_exists "$INTERFACE"; then
            RULE_CACHE="${STATE_DIR}/${INTERFACE}.rule"
            ip rule list | awk -v tbl="pbr_${INTERFACE}" '
                $0 ~ "lookup " tbl "$" {
                    prio=$1+0
                    if (prio < 29000) next
                    for(i=1;i<=NF;i++) if($i=="fwmark"){fm=$(i+1)}
                    print prio, fm, tbl
                    exit
                }' > "$RULE_CACHE"
            _prio=$(awk '{print $1}' "$RULE_CACHE")
            _fm=$(awk '{print $2}' "$RULE_CACHE")
            _tbl=$(awk '{print $3}' "$RULE_CACHE")
            ip rule del prio $_prio fwmark $_fm lookup $_tbl 2>/dev/null
            log_event "[DOWN] $INTERFACE 連 ${_fc} 輪確認失敗, ip rule 已移除 (prio=$_prio fwmark=$_fm) → 流量切回 wan"
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
        pending|skip|"") ;;  # 連敗確認中 / 冷靜期 / 未檢查 → 不動 uci
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
    # pending / skip 不更新 prevresult, 避免破壞 up↔down 對比
    if [ "$PING_RESULT" != "$PREV" ] && [ "$PING_RESULT" != "pending" ] && [ "$PING_RESULT" != "skip" ]; then
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

    DBR_NOW=$(date '+%s')
    DBR_HS_TIMEOUT=180  # handshake 超過 180 秒視為對端離線, 直接判 down 不 ping

    for DR_IFACE in $DR_IFACES; do
        DR_TABLE=$(awk -v name="pbr_${DR_IFACE}" '$2 == name {print $1}' "$RT_TABLES")
        [ -z "$DR_TABLE" ] && continue
        DR_FWMARK=$(printf "0x%x" "$DR_TABLE")

        # --- 判定 up/down ---
        # 介面消失 (ifdown) / 對端離線 (handshake 過期) / ping 失敗 → 都視為 down
        DBR_RESULT="down"
        if ! ip link show "$DR_IFACE" >/dev/null 2>&1; then
            # 介面不存在, 直接 down (避免 fwmark 命中後流量進空 table)
            log_event "[PENDING] $DR_IFACE 介面不存在 (ifdown), 視為 down"
        elif [ "$DR_IFACE" = "wan" ]; then
            # wan 沒 wg handshake, 直接 ping
            DBR_HS_OK=1
        else
            DBR_LATEST_HS=$(wg show "$DR_IFACE" latest-handshakes 2>/dev/null \
                | awk '{print $2}' | sort -n | tail -1)
            if [ -z "$DBR_LATEST_HS" ] || [ "$DBR_LATEST_HS" = "0" ]; then
                DBR_HS_OK=0
            else
                DBR_AGE=$(( DBR_NOW - DBR_LATEST_HS ))
                [ "$DBR_AGE" -le "$DBR_HS_TIMEOUT" ] && DBR_HS_OK=1 || DBR_HS_OK=0
            fi
        fi

        if [ "${DBR_HS_OK:-0}" = "1" ]; then
            DBR_RX=$(ping -c $PING_COUNT -W $PING_TIMEOUT -I "$DR_IFACE" $TARGET_IP 2>/dev/null \
                | sed -n 's/^.*, \([0-9][0-9]*\) packets received.*/\1/p')
            DBR_RX=${DBR_RX:-0}
            DBR_NEED=$(( PING_COUNT - PING_LOSS_TOLERATE ))
            [ "$DBR_RX" -ge "$DBR_NEED" ] && DBR_RESULT="up"
        fi
        unset DBR_HS_OK

        DBR_PREV=$(db_prev_get "$DR_IFACE")
        DBR_HAS_RULE=0
        ip rule show | grep -q "fwmark $DR_FWMARK" && DBR_HAS_RULE=1

        if [ "$DBR_RESULT" = "up" ]; then
            db_fail_reset "$DR_IFACE"

            if [ "$DBR_HAS_RULE" = "1" ]; then
                db_up_reset "$DR_IFACE"
                # 保險: dbprev=down 但 fwmark 已被外部 (hotplug ifup /
                # dbroute-setup.sh / sync-googleconfig) 補回, 推一次 UP 同步狀態
                if [ "$DBR_PREV" = "down" ]; then
                    log_event "[REPAIR] $DR_IFACE dbroute fwmark 已由外部重建, 同步狀態"
                    push_notify "${DR_IFACE}_DomainRoute_UP"
                    db_prev_set "$DR_IFACE" "up"
                fi
            else
                db_up_inc "$DR_IFACE"
                _dbu=$(db_up_get "$DR_IFACE")
                if [ "$_dbu" -lt "$UP_CONFIRM" ]; then
                    log_event "[PENDING] $DR_IFACE dbroute 冷靜期 ${_dbu}/${UP_CONFIRM}"
                else
                    /etc/myscript/dbroute-setup.sh
                    log "${DR_IFACE} UP → 恢復 domain routing"
                    log_event "[UP] $DR_IFACE dbroute 冷靜期完成, fwmark $DR_FWMARK 已建"
                    db_up_reset "$DR_IFACE"
                    if [ "$DBR_PREV" != "up" ]; then
                        push_notify "${DR_IFACE}_DomainRoute_UP"
                        db_prev_set "$DR_IFACE" "up"
                    fi
                fi
            fi
        else
            db_up_reset "$DR_IFACE"

            # 達門檻後不再 inc, 避免 23 小時離線無限累計
            _dbf=$(db_fail_get "$DR_IFACE")
            if [ "$_dbf" -lt "$DOWN_CONFIRM" ]; then
                db_fail_inc "$DR_IFACE"
                _dbf=$(db_fail_get "$DR_IFACE")
            fi

            if [ "$_dbf" -lt "$DOWN_CONFIRM" ]; then
                log_event "[PENDING] $DR_IFACE dbroute DOWN 確認中 ${_dbf}/${DOWN_CONFIRM}"
            else
                if [ "$DBR_HAS_RULE" = "1" ]; then
                    ip rule del fwmark "$DR_FWMARK" lookup "$DR_TABLE" 2>/dev/null
                    log "${DR_IFACE} DOWN → 移除 domain routing"
                    log_event "[DOWN] $DR_IFACE dbroute 連 ${DOWN_CONFIRM} 輪確認失敗, fwmark $DR_FWMARK 已移除"
                    if [ "$DBR_PREV" != "down" ]; then
                        push_notify "${DR_IFACE}_DomainRoute_Down"
                        db_prev_set "$DR_IFACE" "down"
                    fi
                fi
                # 整點: 真確認 down 且介面存在才 ifdown/ifup
                # (介面不存在通常是用戶手動 ifdown, 不該自動 ifup 違反用戶意圖)
                if [ "$CURRENT_HHMM" = "0400" ] && [ "$DR_IFACE" != "wan" ] \
                    && ip link show "$DR_IFACE" >/dev/null 2>&1; then
                    log "${DR_IFACE} 整點重啟（背景）..."
                    (ifdown "$DR_IFACE"; sleep 3; ifup "$DR_IFACE") &
                fi
            fi
        fi
    done
fi

log "檢查完畢。"
