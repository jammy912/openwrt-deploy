#!/bin/sh

LOCK="/tmp/check-adguard.lock"
if [ -f "$LOCK" ]; then
    kill -0 "$(cat "$LOCK")" 2>/dev/null && exit 0
    rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# 引入通知器
. /etc/myscript/push_notify.inc
PUSH_NAMES="admin" # 多人用分號分隔，例如 "admin;ann"

# client 模式不用 AGH，跳過檢查
_role=$(cat /etc/myscript/.mesh_role_active 2>/dev/null)
[ "$_role" = "client" ] && exit 0

TEST_DNS="127.0.0.1"
TEST_PORT=53535
# 使用確定存在的域名，確保有正常的 DNS 回應
TEST_DOMAIN="www.twse.com.tw"

UPSTREAM_DNS1="8.8.8.8"
UPSTREAM_DNS2="1.1.1.1"

log() {
    echo "$1"
    logger -t adguard-switch "$1"
}

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
CURRENT_UPSTREAM1=$(echo "$CURRENT_SERVERS" | grep -w "$UPSTREAM_DNS1")
CURRENT_UPSTREAM2=$(echo "$CURRENT_SERVERS" | grep -w "$UPSTREAM_DNS2")

# 標記是否需要提交變更
NEED_RELOAD=0

# ==============================
# DNS 測試函數
# ==============================
test_dns() {
    # 方法1: 使用 dig 測試，不加 +short 以便檢查狀態
    local result
    result=$(dig @"$TEST_DNS" -p "$TEST_PORT" "$TEST_DOMAIN" +time=2 +tries=1 2>&1)
    local exitcode=$?

    # 檢查是否有 "connection timed out" 或 "no servers could be reached"
    if echo "$result" | grep -q "connection timed out\|no servers could be reached"; then
        return 1
    fi

    # 檢查返回碼
    if [ $exitcode -ne 0 ]; then
        return 1
    fi

    # 檢查是否有 ANSWER 或 status: NXDOMAIN (兩者都代表 DNS 服務器有響應)
    if echo "$result" | grep -q "ANSWER SECTION\|status: NXDOMAIN\|status: NOERROR"; then
        return 0
    fi

    return 1
}

# ==============================
# 主要邏輯
# ==============================
if test_dns; then
    # AdGuardHome 正常
    if [ -n "$CURRENT_ADG" ]; then
        log "✅ AdGuardHome 正常且已啟用,無需切換"
        exit 0
    fi

    log "✅ AdGuardHome 正常,切換 dnsmasq 指向 127.0.0.1#53535"
    uci -q del_list dhcp.@dnsmasq[0].server="$UPSTREAM_DNS1"
    uci -q del_list dhcp.@dnsmasq[0].server="$UPSTREAM_DNS2"
    uci -q del_list dhcp.@dnsmasq[0].server="127.0.0.1#53535"
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

    # 檢查是否已經切換到上游 DNS
    if [ -n "$CURRENT_UPSTREAM1" ] && [ -n "$CURRENT_UPSTREAM2" ]; then
        log "⚠️ 已經使用 WAN 上游 DNS,無需切換"
        exit 0
    fi

    log "⚠️ AdGuardHome 無法使用,切換 dnsmasq 上游 DNS 為 WAN"
    uci -q del_list dhcp.@dnsmasq[0].server="127.0.0.1#53535"
    uci -q add_list dhcp.@dnsmasq[0].server="$UPSTREAM_DNS1"
    uci -q add_list dhcp.@dnsmasq[0].server="$UPSTREAM_DNS2"
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
