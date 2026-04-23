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

# 自身識別: sha256(hostname+wan_mac+machine-id+board_name) 前 16 字 (同 auto-role.sh:156)
my_id() {
    local h w m b
    h=$(uci -q get system.@system[0].hostname)
    w=$(cat /sys/class/net/wan/address 2>/dev/null)
    m=$(cat /etc/machine-id 2>/dev/null)
    b=$(cat /tmp/sysinfo/board_name 2>/dev/null)
    printf '%s|%s|%s|%s' "$h" "$w" "$m" "$b" | sha256sum | cut -c1-16
}
my_mac() {
    local _mac
    _mac=$(cat /sys/class/net/br-lan/address 2>/dev/null)
    [ -z "$_mac" ] && _mac=$(cat /sys/class/net/eth0/address 2>/dev/null)
    echo "$_mac" | tr 'A-Z' 'a-z'
}
my_ip() {
    ip -4 addr show br-lan 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1
}

# 讀 alfred type 64,解出 peer (自己以外) 的 ip + agh_status,輸出 "ip agh_status" 一行一筆
# 三重排除自己: id (優先,穩定跨重啟) / mac / ip
parse_peers() {
    local _me_id _me_mac _me_ip
    _me_id=$(my_id)
    _me_mac=$(my_mac)
    _me_ip=$(my_ip)
    alfred -r 64 2>/dev/null | awk \
        -v me_id="$_me_id" \
        -v me_mac="$_me_mac" \
        -v me_ip="$_me_ip" '
        {
            line = tolower($0)
            id = ""
            if (match(line, /\\"id\\":\\"[0-9a-f]+\\"/)) {
                s = substr(line, RSTART, RLENGTH); sub(/.*\\":\\"/, "", s); sub(/\\".*/, "", s); id = s
            }
            mac = ""
            if (match(line, /\\"mac\\":\\"[0-9a-f:]+\\"/)) {
                s = substr(line, RSTART, RLENGTH); sub(/.*\\":\\"/, "", s); sub(/\\".*/, "", s); mac = s
            }
            ip = ""
            if (match(line, /\\"ip\\":\\"[0-9.]+\\"/)) {
                s = substr(line, RSTART, RLENGTH); sub(/.*\\":\\"/, "", s); sub(/\\".*/, "", s); ip = s
            }
            agh = "down"
            if (match(line, /\\"agh_status\\":\\"[a-z]+\\"/)) {
                s = substr(line, RSTART, RLENGTH); sub(/.*\\":\\"/, "", s); sub(/\\".*/, "", s); agh = s
            }
            # 排除自己 (三重)
            if (id != "" && id == me_id) next
            if (mac != "" && mac == me_mac) next
            if (ip != "" && ip == me_ip) next
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

# 從 .mesh_upstream_dns 逐一測試,第一個有任一 DNS 能解 TEST_DOMAIN 的那行就回傳
# 一行支援多 DNS (空白/逗號/分號分隔),例如 "8.8.8.8 8.8.4.4" 或 "8.8.8.8,8.8.4.4"
# 回傳格式: 以空白分隔的 IP 列表 (供 apply_upstream 逐個 add_list)
pick_upstream_dns() {
    [ -s "$DNS_LIST_FILE" ] || return 1
    local _line _normalized _dns _ans _any_ok
    while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        # 正規化: 逗號/分號 → 空白,壓縮多重空白
        _normalized=$(echo "$_line" | tr ',;' '  ' | awk '{$1=$1; print}')
        [ -z "$_normalized" ] && continue
        _any_ok=0
        for _dns in $_normalized; do
            _ans=$(nslookup -timeout=3 "$TEST_DOMAIN" "$_dns" 2>/dev/null \
                | awk '/^Address/ && !/#/ {print $NF}' \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
                | grep -vE '^(0\.|127\.)' \
                | head -1)
            [ -n "$_ans" ] && _any_ok=1 && break
        done
        if [ "$_any_ok" = "1" ]; then
            echo "$_normalized"
            return 0
        fi
    done < "$DNS_LIST_FILE"
    return 1
}

# 切 firewall redirect 的 adgh_* 規則 (SELF 時開,其他時關)
toggle_firewall_rules() {
    local state="$1" sec rule_name
    for sec in $(uci show firewall | grep "=redirect" | cut -d'=' -f1); do
        rule_name=$(uci -q get $sec.name)
        case "$rule_name" in
            adgh_*) uci set $sec.enabled="$state" ;;
        esac
    done
}

# 對齊 AGH process 狀態 (runagh=Y → 確保在跑; runagh=N → 確保停)
# 含整點重啟失敗的 AGH
ensure_agh_state() {
    local _run_agh _pid _current_minute
    _run_agh=$(cat /etc/myscript/.mesh_runagh 2>/dev/null)
    [ -z "$_run_agh" ] && _run_agh=Y

    if [ "$_run_agh" = "N" ]; then
        # 不該跑,停掉
        if pgrep -f adguardhome >/dev/null 2>&1; then
            /etc/init.d/adguardhome stop 2>/dev/null
            /etc/init.d/adguardhome disable 2>/dev/null
            lock_remove "agh_startup" >/dev/null 2>&1
            log "🛑 .mesh_runagh=N,AGH 已停用"
        fi
        return
    fi

    # runagh=Y: 該跑,對齊狀態
    # oom_score_adj 保護 (Go VmSize 大但 RSS 小,防 OOM 優先擊殺)
    _pid=$(ps w 2>/dev/null | grep '/usr/bin/AdGuardHome' | grep -v grep | awk '{print $1}' | head -1)
    if [ -n "$_pid" ] && [ "$(cat /proc/$_pid/oom_score_adj 2>/dev/null)" != "-200" ]; then
        echo -200 > /proc/$_pid/oom_score_adj 2>/dev/null
        log "AGH oom_score_adj 設為 -200 (PID=$_pid)"
    fi

    # AGH 沒跑 → 啟動 (避開開機早期 180s、避開 agh_startup lock 內)
    if ! pgrep -f adguardhome >/dev/null 2>&1; then
        _uptime=$(awk -F. '{print $1}' /proc/uptime)
        if [ "$_uptime" -le 180 ]; then
            log "AGH 未運行,開機早期 (${_uptime}s),由 rc.local 延遲處理"
            return
        fi
        if lock_is_active "agh_startup" 300; then
            log "AGH 未運行,agh_startup lock 有效,跳過啟動"
            return
        fi
        lock_check_and_create "agh_startup" 300 >/dev/null 2>&1
        /etc/init.d/adguardhome enable 2>/dev/null
        /etc/init.d/adguardhome start 2>/dev/null
        log "AGH 未運行,已啟動"
        return
    fi

    # AGH 有跑但自己 test 不通 → 整點試一次重啟 (retry 3 次吸收抖動)
    if ! (test_local_agh || (sleep 2 && test_local_agh) || (sleep 2 && test_local_agh)); then
        _current_minute=$(date '+%M')
        if [ "$_current_minute" = "00" ]; then
            log "⚠️ 整點 AGH 無回應,嘗試重啟"
            lock_check_and_create "agh_startup" 300 >/dev/null 2>&1
            /etc/init.d/adguardhome stop 2>/dev/null
            sleep 2
            /etc/init.d/adguardhome start 2>/dev/null
        else
            log "⚠️ AGH process 在跑但 :53535 無回應 (非整點不動,留給整點處理)"
        fi
    fi
}

# 套用 upstream 到 dnsmasq (只在值不同時才動 uci)
# $1: target 字串 - 可以是單個 (例如 "127.0.0.1#53535" / "192.168.1.4")
#                   或空白分隔多個 (例如 "8.8.8.8 8.8.4.4")
#                   空 = 走 WAN resolv
# $2: KIND (SELF/PEER/DNS/NONE) - 決定 firewall redirect 開關
apply_upstream() {
    local _target="$1" _kind="$2" _cur _need_reload=0 _need_fw=0 _cur_fw_state _want_fw _dns

    # 當前 uci server list (以空白合併成一行,方便比對)
    _cur=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | tr '\n' ' ' | awk '{$1=$1; print}')

    # Firewall redirect: 只有 SELF (本機 AGH 接管 client :53) 時才開
    case "$_kind" in
        SELF) _want_fw=1 ;;
        *)    _want_fw=0 ;;
    esac

    if [ -z "$_target" ]; then
        # NONE: 清空 server,走 WAN resolv
        if [ -n "$_cur" ] || [ "$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null)" = "1" ]; then
            uci -q delete dhcp.@dnsmasq[0].server
            uci -q delete dhcp.@dnsmasq[0].noresolv
            uci commit dhcp
            _need_reload=1
            log "⚠️ 無任何 upstream 可用,退回 WAN resolv"
        fi
    else
        # 正規化 target (把 , ; 也當空白) 以便比對
        _target=$(echo "$_target" | tr ',;' '  ' | awk '{$1=$1; print}')
        if [ "$_cur" != "$_target" ]; then
            uci -q delete dhcp.@dnsmasq[0].server
            for _dns in $_target; do
                uci add_list dhcp.@dnsmasq[0].server="$_dns"
            done
            uci set dhcp.@dnsmasq[0].noresolv='1'
            uci commit dhcp
            _need_reload=1
            log "🔀 dnsmasq upstream → $_target ($_kind)"
        fi
    fi

    # firewall redirect: 任一 adgh_* rule 狀態跟期望不同就 toggle (一次全刷)
    _cur_fw_state=0
    for sec in $(uci show firewall | grep "=redirect" | cut -d'=' -f1); do
        _rn=$(uci -q get "$sec".name)
        case "$_rn" in
            adgh_*)
                _en=$(uci -q get "$sec".enabled 2>/dev/null || echo 1)
                _cur_fw_state="$_en"
                break
                ;;
        esac
    done
    if [ "$_cur_fw_state" != "$_want_fw" ]; then
        toggle_firewall_rules "$_want_fw"
        uci commit firewall
        /etc/init.d/firewall reload >/dev/null 2>&1
        log "firewall adgh_* rules → enabled=$_want_fw"
    fi

    [ "$_need_reload" = "1" ] && /etc/init.d/dnsmasq reload
}

# ==============================
# 主要邏輯
# ==============================
ensure_agh_state

DECISION=$(pick_upstream)
KIND=$(echo "$DECISION" | cut -d'|' -f1)
TARGET=$(echo "$DECISION" | cut -d'|' -f2)

# sticky: SELF 時不寫 (沒意義),其他都寫
case "$KIND" in
    SELF) rm -f "$STICKY_FILE" ;;
    *)    echo "$DECISION" > "$STICKY_FILE" ;;
esac

log "pick: $DECISION"
apply_upstream "$TARGET" "$KIND"
