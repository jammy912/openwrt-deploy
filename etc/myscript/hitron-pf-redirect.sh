#!/bin/sh
# hitron-pf-redirect.sh - 將 Hitron CGN5-AP wg* port forward 規則 localIpAddr
# 改指向本機 WAN IP (auto-role.sh 切主 gw 時呼叫)
#
# 用法:
#   hitron-pf-redirect.sh                    從 Hitron 抓現有規則改 wg* IP 後寫回
#   hitron-pf-redirect.sh --apply-from FILE  從 FILE 讀完整規則 (Google 拉下來的快照)
#                                            改 wg* IP 後 POST 覆蓋 Hitron
#   hitron-pf-redirect.sh --dry-run          只 log 不寫入

HITRON=http://192.168.168.1
USER=admin
PASS=password
DRY_RUN=0
APPLY_FROM=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)    DRY_RUN=1; shift ;;
        --apply-from) APPLY_FROM="$2"; shift 2 ;;
        *)            echo "未知參數: $1"; exit 1 ;;
    esac
done

CK=/tmp/.hitron_pf_ck.$$
LOG=/tmp/hitron-pf.log

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }
cleanup() {
    [ -f "$CK" ] && curl -s -b "$CK" -X POST "$HITRON/logout" -d "data=byebye" -o /dev/null 2>/dev/null
    rm -f "$CK"
}
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

# 規則來源
if [ -n "$APPLY_FROM" ]; then
    if [ ! -f "$APPLY_FROM" ]; then
        log "[ERROR] 找不到檔案: $APPLY_FROM"
        exit 1
    fi
    RULES=$(cat "$APPLY_FROM")
    log "[INFO] 規則來源: $APPLY_FROM"
else
    # 登入 Hitron 抓現有規則
    curl -s -c "$CK" "$HITRON/login.html" -o /dev/null || { log "[ERROR] GET login.html 失敗"; exit 1; }
    RESP=$(curl -s -b "$CK" -c "$CK" -X POST "$HITRON/goform/login" \
        -d "usr=$USER&pwd=$PASS&preSession=")
    if [ "$RESP" != "success" ]; then
        log "[ERROR] 登入失敗: $RESP"
        exit 1
    fi
    log "[INFO] 登入成功"
    RULES=$(curl -s -b "$CK" "$HITRON/data/getForwardingRules.asp")
    log "[INFO] 規則來源: Hitron 現有"
fi

if ! echo "$RULES" | grep -q '^\['; then
    log "[ERROR] 規則格式錯誤: $RULES"
    exit 1
fi

# 改 wg* 開頭規則的 localIpAddr
NEW=$(echo "$RULES" | jq -c --arg ip "$TARGET_IP" '
    map(if (.appName | ascii_downcase | startswith("wg")) then .localIpAddr = $ip else . end)
')
if [ -z "$NEW" ] || ! echo "$NEW" | grep -q '^\['; then
    log "[ERROR] jq 處理失敗"
    exit 1
fi

# 條數檢查 (防截斷)
OLD_COUNT=$(echo "$RULES" | jq 'length' 2>/dev/null)
NEW_COUNT=$(echo "$NEW" | jq 'length' 2>/dev/null)
if [ -z "$NEW_COUNT" ] || [ "$NEW_COUNT" -lt "$OLD_COUNT" ]; then
    log "[ERROR] 新規則條數異常 (old=$OLD_COUNT, new=$NEW_COUNT)，中止"
    exit 1
fi

# 列出將被修改的規則
echo "$NEW" | jq -r '.[] | select(.appName | ascii_downcase | startswith("wg")) | "  \(.appName): \(.pubStart) -> \(.localIpAddr):\(.priStart) (\(.protocal))"' | while read line; do
    log "[CHANGE]$line"
done

# --apply-from 模式不檢查「無變更」(整包覆蓋是目的)
if [ -z "$APPLY_FROM" ]; then
    OLD_HASH=$(echo "$RULES" | md5sum | awk '{print $1}')
    NEW_HASH=$(echo "$NEW" | md5sum | awk '{print $1}')
    if [ "$OLD_HASH" = "$NEW_HASH" ]; then
        log "[INFO] wg* 規則已指向 $TARGET_IP，無需變更"
        exit 0
    fi
fi

if [ "$DRY_RUN" = "1" ]; then
    log "[DRY-RUN] 不套用變更"
    exit 0
fi

# --apply-from 模式需要先登入 (上面只有預設模式登過)
if [ -n "$APPLY_FROM" ]; then
    curl -s -c "$CK" "$HITRON/login.html" -o /dev/null || { log "[ERROR] GET login.html 失敗"; exit 1; }
    RESP=$(curl -s -b "$CK" -c "$CK" -X POST "$HITRON/goform/login" \
        -d "usr=$USER&pwd=$PASS&preSession=")
    if [ "$RESP" != "success" ]; then
        log "[ERROR] 登入失敗: $RESP"
        exit 1
    fi
    log "[INFO] 登入成功"
fi

# 取 CSRF + POST PfwCollection
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

# Firewall apply
TS=$(date +%s%N 2>/dev/null | cut -c1-13)
[ -z "$TS" ] && TS=$(date +%s)000
TOKEN=$(curl -s -b "$CK" "$HITRON/data/getCsrf.asp?_=$TS" | grep -oE '[A-Za-z0-9]{20,}' | head -1)
RESP=$(curl -s -b "$CK" -X POST "$HITRON/goform/Firewall" \
    --data-urlencode 'model={"rulesOnOff":"Enabled","privateLan":"192.168.168.1","subMask":"255.255.255.0","forwardingRuleStatus":"1"}' \
    --data-urlencode "CsrfToken=$TOKEN" \
    -d "CsrfTokenFlag=0")
log "[INFO] Firewall 回應: ${RESP:-<空>}"
log "[DONE] wg* 規則已指向 $TARGET_IP"
