#!/bin/sh

LOCK="/tmp/check-adguard.lock"
if [ -f "$LOCK" ]; then
    kill -0 "$(cat "$LOCK")" 2>/dev/null && exit 0
    rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK" /tmp/cron_global.lock' EXIT

# 全域 cron 排隊鎖
. /etc/myscript/lock_handler.sh
cron_global_lock 60 || exit 0

# 引入通知器
. /etc/myscript/push_notify.inc
PUSH_NAMES="admin" # 多人用分號分隔，例如 "admin;ann"

# AGH 正在啟動中 (rc.local/auto-role 建立的 lock)，跳過檢查
. /etc/myscript/lock_handler.sh
if lock_is_active "agh_startup" 300; then
    logger -t adguard-switch "agh_startup lock 有效，跳過檢查"
    exit 0
fi

TEST_DNS="127.0.0.1"
TEST_PORT=53535
# 使用確定存在的域名，確保有正常的 DNS 回應
TEST_DOMAIN="www.twse.com.tw"

DNS_LIST_FILE=/etc/myscript/.mesh_upstream_dns
STICKY_FILE=/tmp/.agh_active_upstream
STICKY_FAIL_MAX=3
LATENCY_MAX_MS=200

log() {
    echo "$1"
    logger -t adguard-switch "$1"
}

# 讀 alfred type 64,解出 peer (自己以外) 的 ip + agh_status,輸出 "ip agh_status" 一行一筆
parse_peers() {
    local _my_id
    _my_id=$(cat /etc/myscript/.mesh_id 2>/dev/null)
    alfred -r 64 2>/dev/null | awk -v me_id="$_my_id" '
        {
            line = tolower($0)
            id = ""
            if (match(line, /\\"id\\":\\"[0-9a-f]+\\"/)) {
                s = substr(line, RSTART, RLENGTH); sub(/.*\\":\\"/, "", s); sub(/\\".*/, "", s); id = s
            }
            ip = ""
            if (match(line, /\\"ip\\":\\"[0-9.]+\\"/)) {
                s = substr(line, RSTART, RLENGTH); sub(/.*\\":\\"/, "", s); sub(/\\".*/, "", s); ip = s
            }
            agh = "down"
            if (match(line, /\\"agh_status\\":\\"[a-z]+\\"/)) {
                s = substr(line, RSTART, RLENGTH); sub(/.*\\":\\"/, "", s); sub(/\\".*/, "", s); agh = s
            }
            if (id != "" && id == me_id) next
            if (ip == "") next
            print ip, agh
        }
    '
}

# 對 peer 的 :53 跑 3 次 nslookup,取最小毫秒 (全失敗 echo 9999)
probe_dnsmasq() {
    local _ip="$1" _best=9999 _t0 _t1 _dt _ok _i
    [ -z "$_ip" ] && { echo 9999; return; }
    for _i in 1 2 3; do
        _t0=$(date +%s%N)
        _ok=$(nslookup -timeout=3 "$TEST_DOMAIN" "$_ip" 2>/dev/null | grep -c 'Address\|canonical')
        _t1=$(date +%s%N)
        [ "$_ok" -gt 0 ] || continue
        _dt=$(( (_t1 - _t0) / 1000000 ))
        [ $_dt -lt $_best ] && _best=$_dt
    done
    echo $_best
}

# 測自己的 AGH (127.0.0.1:53535) 是否健康 (布林)
test_local_agh() {
    nslookup -port=53535 -timeout=3 "$TEST_DOMAIN" 127.0.0.1 2>/dev/null | grep -q 'Address\|canonical'
}

# 決定最佳 upstream,輸出 "KIND|target|failcount" (KIND=SELF/PEER/DNS/NONE)
pick_upstream() {
    local _run_agh _sticky_kind _sticky_target _sticky_fc _ms _best_ip _best_ms _peers
    _run_agh=$(cat /etc/myscript/.mesh_runagh 2>/dev/null)
    [ -z "$_run_agh" ] && _run_agh=Y

    # 1. SELF
    if [ "$_run_agh" = "Y" ] && test_local_agh; then
        echo "SELF|127.0.0.1#53535|0"; return
    fi

    # 2. Sticky PEER (只測當前選中的)
    if [ -f "$STICKY_FILE" ]; then
        _sticky_kind=$(cut -d'|' -f1 "$STICKY_FILE" 2>/dev/null)
        _sticky_target=$(cut -d'|' -f2 "$STICKY_FILE" 2>/dev/null)
        _sticky_fc=$(cut -d'|' -f3 "$STICKY_FILE" 2>/dev/null)
        [ -z "$_sticky_fc" ] && _sticky_fc=0
        if [ "$_sticky_kind" = "PEER" ] && [ -n "$_sticky_target" ]; then
            _ms=$(probe_dnsmasq "$_sticky_target")
            if [ "$_ms" -lt $LATENCY_MAX_MS ]; then
                # 還確認 alfred 上它仍 agh=up
                if parse_peers | awk -v ip="$_sticky_target" '$1==ip && $2=="up"{f=1} END{exit !f}'; then
                    echo "PEER|$_sticky_target|0"; return
                fi
            fi
            _sticky_fc=$((_sticky_fc + 1))
            if [ "$_sticky_fc" -lt $STICKY_FAIL_MAX ]; then
                echo "PEER|$_sticky_target|$_sticky_fc"; return
            fi
        fi
    fi

    # 3. Rescan PEER (只挑 agh=up,選延遲最低)
    _best_ip=""
    _best_ms=$LATENCY_MAX_MS
    _peers=$(parse_peers | awk '$2=="up"{print $1}')
    for _ip in $_peers; do
        _ms=$(probe_dnsmasq "$_ip")
        if [ "$_ms" -lt "$_best_ms" ]; then
            _best_ms=$_ms
            _best_ip=$_ip
        fi
    done
    if [ -n "$_best_ip" ]; then
        echo "PEER|$_best_ip|0"; return
    fi

    # 4. 外部 DNS fallback (.mesh_upstream_dns,依序 1=雲端 AGH,2=8.8.8.8)
    _picked=$(pick_upstream_dns)
    if [ -n "$_picked" ]; then
        echo "DNS|$_picked|0"; return
    fi

    # 5. NONE (全掛)
    echo "NONE||0"
}

# 從 .mesh_upstream_dns 逐一測試，第一個能解 TEST_DOMAIN 就回傳 (印到 stdout)
pick_upstream_dns() {
    [ -s "$DNS_LIST_FILE" ] || return 1
    local _dns _ans
    while IFS= read -r _dns; do
        [ -z "$_dns" ] && continue
        _ans=$(nslookup -timeout=3 "$TEST_DOMAIN" "$_dns" 2>/dev/null \
            | awk '/^Address/ && !/#/ {print $NF}' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
            | grep -vE '^(0\.|127\.)' \
            | head -1)
        if [ -n "$_ans" ]; then
            echo "$_dns"
            return 0
        fi
    done < "$DNS_LIST_FILE"
    return 1
}

# .mesh_runagh=N 本機不跑 AGH → 停掉 & dnsmasq 改指向 .mesh_upstream_dns 第一個可用的
_run_agh=$(cat /etc/myscript/.mesh_runagh 2>/dev/null)
[ -z "$_run_agh" ] && _run_agh=Y
if [ "$_run_agh" = "N" ]; then
    if pgrep -f adguardhome >/dev/null 2>&1; then
        /etc/init.d/adguardhome stop 2>/dev/null
        /etc/init.d/adguardhome disable 2>/dev/null
        lock_remove "agh_startup" >/dev/null 2>&1
        log "🛑 .mesh_runagh=N，AGH 已停用"
    fi
    _PICKED=$(pick_upstream_dns)
    _CUR=$(uci show dhcp.@dnsmasq[0].server 2>/dev/null)
    if [ -n "$_PICKED" ]; then
        if ! echo "$_CUR" | grep -q "'$_PICKED'" || echo "$_CUR" | grep -q "127.0.0.1#53535"; then
            uci -q delete dhcp.@dnsmasq[0].server
            uci -q add_list dhcp.@dnsmasq[0].server="$_PICKED"
            uci set dhcp.@dnsmasq[0].noresolv='1'
            uci commit dhcp
            /etc/init.d/dnsmasq reload
            log "🔀 .mesh_runagh=N，dnsmasq upstream → $_PICKED"
        else
            log "✅ .mesh_runagh=N，dnsmasq 已指向 $_PICKED，無需切換"
        fi
    else
        # 都無回應 → 清空 server 表，讓 dnsmasq 走 WAN resolv.conf
        if echo "$_CUR" | grep -q "127.0.0.1#53535" || [ -n "$_CUR" ]; then
            uci -q delete dhcp.@dnsmasq[0].server
            uci -q delete dhcp.@dnsmasq[0].noresolv 2>/dev/null
            uci commit dhcp
            /etc/init.d/dnsmasq reload
            log "⚠️ .mesh_runagh=N，.mesh_upstream_dns 全無回應，退回 WAN resolv"
        else
            log "✅ .mesh_runagh=N，.mesh_upstream_dns 全無回應 (已在 WAN resolv)"
        fi
    fi
    exit 0
fi

# 非主 gw 不用 AGH，跳過檢查
_gw_type=$(cat /etc/myscript/.mesh_gw_type 2>/dev/null)
[ "$_gw_type" != "主gw" ] && exit 0

toggle_firewall_rules() {
    local state="$1"
    for sec in $(uci show firewall | grep "=redirect" | cut -d'=' -f1); do
        rule_name=$(uci -q get $sec.name)
        case "$rule_name" in
            adgh_*)
                uci set $sec.enabled="$state"
                ;;
        esac
    done
}

# 取得目前 dnsmasq 設定
CURRENT_SERVERS=$(uci show dhcp.@dnsmasq[0].server 2>/dev/null)
CURRENT_ADG=$(echo "$CURRENT_SERVERS" | grep -w "127.0.0.1#53535")

# 標記是否需要提交變更
NEED_RELOAD=0

# ==============================
# DNS 測試函數
# ==============================
test_dns() {
    # 使用 busybox nslookup (比 dig 輕量，避免 OOM 時被殺)
    local result
    result=$(nslookup -port="$TEST_PORT" -timeout=3 "$TEST_DOMAIN" "$TEST_DNS" 2>&1)
    local exitcode=$?

    [ $exitcode -ne 0 ] && return 1

    # 有回應 Address 或 canonical name 代表 DNS 服務正常
    echo "$result" | grep -q "Address\|canonical name" && return 0

    return 1
}

# AGH oom_score_adj 保護 (Go VmSize 大但 RSS 小，防止被優先 OOM kill)
_AGH_PID=$(ps w 2>/dev/null | grep '/usr/bin/AdGuardHome' | grep -v grep | awk '{print $1}' | head -1)
if [ -n "$_AGH_PID" ] && [ "$(cat /proc/$_AGH_PID/oom_score_adj 2>/dev/null)" != "-200" ]; then
    echo -200 > /proc/$_AGH_PID/oom_score_adj 2>/dev/null
    log "AGH oom_score_adj 設為 -200 (PID=$_AGH_PID)"
fi

# ==============================
# 主要邏輯
# ==============================
# 整點 cron 暴衝時 AGH 可能一時回不了,retry 2 次吸收抖動
if test_dns || (sleep 2 && test_dns) || (sleep 2 && test_dns); then
    # AdGuardHome 正常
    if [ -n "$CURRENT_ADG" ]; then
        log "✅ AdGuardHome 正常且已啟用,無需切換"
        exit 0
    fi

    log "✅ AdGuardHome 正常,切換 dnsmasq 指向 127.0.0.1#53535"
    uci -q delete dhcp.@dnsmasq[0].server
    uci -q add_list dhcp.@dnsmasq[0].server="127.0.0.1#53535"
    uci set dhcp.@dnsmasq[0].noresolv='1'
    toggle_firewall_rules 1
    NEED_RELOAD=1

    push_notify "Adguard Home UP"
else
    # AdGuardHome 異常

    # 取得目前的分鐘數 (00-59)
    CURRENT_MINUTE=$(date '+%M')

    # 如果分鐘數是 '00',代表是整點,嘗試重啟
    if [ "$CURRENT_MINUTE" = "00" ]; then
        log "⚠️ 整點嘗試重啟 AdguardHome"
        lock_check_and_create "agh_startup" 300 >/dev/null 2>&1
        /etc/init.d/adguardhome stop
        sleep 2
        /etc/init.d/adguardhome start
        sleep 3

        # 重啟後再檢查一次
        if test_dns; then
            log "✅ AdguardHome 重啟成功"
            exit 0
        fi
    fi

    # 從 .mesh_upstream_dns 挑第一個能解析的
    PICKED_DNS=$(pick_upstream_dns)
    if [ -z "$PICKED_DNS" ]; then
        log "⚠️ .mesh_upstream_dns 全部無回應，無法切換"
        exit 0
    fi

    # 已指向同一個 upstream 就不重設
    CUR_CLEAN=$(echo "$CURRENT_SERVERS" | grep -w "$PICKED_DNS" | grep -v "127.0.0.1#53535")
    if [ -n "$CUR_CLEAN" ] && [ -z "$CURRENT_ADG" ]; then
        log "⚠️ 已指向 WAN 上游 $PICKED_DNS，無需切換"
        exit 0
    fi

    log "⚠️ AdGuardHome 無法使用,切換 dnsmasq 上游 DNS → $PICKED_DNS"
    uci -q delete dhcp.@dnsmasq[0].server
    uci -q add_list dhcp.@dnsmasq[0].server="$PICKED_DNS"
    toggle_firewall_rules 0
    NEED_RELOAD=1

    push_notify "Adguard Home Down"
fi

# 只在有變更時才提交並 reload
if [ "$NEED_RELOAD" = "1" ]; then
    uci commit dhcp
    uci commit firewall
    /etc/init.d/dnsmasq reload
    /etc/init.d/firewall reload
    log "✅ 設定已更新並重載服務"
fi

# [Commit A 乾跑] 不套用,只 log 新邏輯會選什麼 upstream (方便對照舊邏輯)
_DRY_DECISION=$(pick_upstream 2>/dev/null)
log "🔬 dry-run pick_upstream → $_DRY_DECISION"
