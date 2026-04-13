#!/bin/sh
# hitron-pf-redirect.sh - 將 Hitron CGN5-AP 上 wg* 開頭的 port forward
# 規則 localIpAddr 改指向本機 WAN IP (auto-role.sh 切主 gw 時呼叫)
#
# 用法: hitron-pf-redirect.sh

HITRON=http://192.168.168.1
USER=admin
PASS=password
CK=/tmp/.hitron_pf_ck.$$
LOG=/tmp/hitron-pf.log

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
cleanup() { rm -f "$CK"; }
trap cleanup EXIT

# 取本機 WAN IP
WAN_DEV=$(uci get network.wan.device 2>/dev/null)
[ -z "$WAN_DEV" ] && WAN_DEV=$(ifstatus wan 2>/dev/null | sed -n 's/.*"l3_device": "\([^"]*\)".*/\1/p')
TARGET_IP=$(ifstatus wan 2>/dev/null | sed -n 's/.*"address": "\([^"]*\)".*/\1/p' | head -1)
[ -z "$TARGET_IP" ] && TARGET_IP=$(ip -4 addr show dev "$WAN_DEV" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)

if [ -z "$TARGET_IP" ]; then
    log "[ERROR] 取不到 WAN IP"
    exit 1
fi
log "[INFO] 本機 WAN IP = $TARGET_IP"

# 登入
curl -s -c "$CK" "$HITRON/login.html" -o /dev/null || { log "[ERROR] GET login.html 失敗"; exit 1; }
RESP=$(curl -s -b "$CK" -c "$CK" -X POST "$HITRON/goform/login" \
    -d "usr=$USER&pwd=$PASS&preSession=")
if [ "$RESP" != "success" ]; then
    log "[ERROR] 登入失敗: $RESP"
    exit 1
fi
log "[INFO] 登入成功"

# 讀規則
RULES=$(curl -s -b "$CK" "$HITRON/data/getForwardingRules.asp")
if ! echo "$RULES" | grep -q '^\['; then
    log "[ERROR] 讀規則失敗: $RULES"
    exit 1
fi

# 修改 wg* 開頭規則的 localIpAddr
NEW=$(echo "$RULES" | jq --arg ip "$TARGET_IP" '
    map(if (.appName | test("^wg"; "i")) then .localIpAddr = $ip else . end)
')
if [ -z "$NEW" ] || ! echo "$NEW" | grep -q '^\['; then
    log "[ERROR] jq 處理失敗"
    exit 1
fi

# 檢查是否真的變動
CHANGED=$(echo "$RULES$NEW" | md5sum | awk '{print $1}')
OLD_HASH=$(echo "$RULES" | md5sum | awk '{print $1}')
NEW_HASH=$(echo "$NEW" | md5sum | awk '{print $1}')
if [ "$OLD_HASH" = "$NEW_HASH" ]; then
    log "[INFO] wg* 規則已指向 $TARGET_IP，無需變更"
    exit 0
fi

# 列出將被修改的規則
echo "$NEW" | jq -r '.[] | select(.appName | test("^wg"; "i")) | "  \(.appName): \(.pubStart) -> \(.localIpAddr):\(.priStart) (\(.protocal))"' | while read line; do
    log "[CHANGE]$line"
done

# 取 CSRF 並送 PfwCollection
TS=$(date +%s%N 2>/dev/null | cut -c1-13)
[ -z "$TS" ] && TS=$(date +%s)000
TOKEN=$(curl -s -b "$CK" "$HITRON/data/getCsrf.asp?_=$TS" | grep -oE '[A-Za-z0-9]{20,}' | head -1)
if [ -z "$TOKEN" ]; then
    log "[ERROR] 取 CSRF token 失敗"
    exit 1
fi

RESP=$(curl -s -b "$CK" -X POST "$HITRON/goform/PfwCollection" \
    --data-urlencode "model=$NEW" \
    --data-urlencode "CsrfToken=$TOKEN" \
    -d "CsrfTokenFlag=0")
log "[INFO] PfwCollection 回應: ${RESP:-<空>}"

# 套用開關
TS=$(date +%s%N 2>/dev/null | cut -c1-13)
[ -z "$TS" ] && TS=$(date +%s)000
TOKEN=$(curl -s -b "$CK" "$HITRON/data/getCsrf.asp?_=$TS" | grep -oE '[A-Za-z0-9]{20,}' | head -1)
RESP=$(curl -s -b "$CK" -X POST "$HITRON/goform/Firewall" \
    --data-urlencode 'model={"rulesOnOff":"Enabled","privateLan":"192.168.168.1","subMask":"255.255.255.0","forwardingRuleStatus":"1"}' \
    --data-urlencode "CsrfToken=$TOKEN" \
    -d "CsrfTokenFlag=0")
log "[INFO] Firewall 回應: ${RESP:-<空>}"
log "[DONE] wg* 規則已指向 $TARGET_IP"
