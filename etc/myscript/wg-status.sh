#!/bin/sh
# wg-status.sh - 一則 push 回報 wg 介面狀態 + PBR(CustRule)/DBR(domain routing) 是否 enable 中
# 放置位置: /etc/myscript/wg-status.sh
#
# 判定方式 (與 check-pbr-wg.sh 同源, 全部唯讀不改任何狀態):
#   介面狀態: 有 /tmp/check-pbr-wg/<if>.pingresult 且非 skip → 直接用 (up/down/pending/down-hold)
#             否則 (passive peer 或無 PBR 的介面) 用 handshake ≤180s 判 連入/斷線
#   PBR     : uci pbr <section>.enabled (未設或 1 = on, 0 = off); 高頻停用另標 flap
#   DBR     : ip rule 是否存在該介面 dbr table 的 fwmark (check-pbr-wg DOWN 時會移除)
#
# 用法:
#   /etc/myscript/wg-status.sh                     # 所有 wg 介面, 印出 + 推播
#   /etc/myscript/wg-status.sh wg1,wg2,wg3         # 只查指定介面 (逗號分隔)
#   /etc/myscript/wg-status.sh --no-push           # 只印不推播 (debug / 手動查)
#   /etc/myscript/wg-status.sh wg2 --no-push       # 參數可混用, 順序不拘
#
# 輸出範例:
#   wg2:1/1連入(hs56s) PBR:on DBR:on | wg5:up PBR:on DBR:off

# 不排全域 cron 隊: 唯讀查詢, 不與其他 cron 競態; on-demand 查詢也不該被長任務卡住
PATH=/usr/sbin:/sbin:/usr/bin:/bin
export PATH

NO_PUSH=0
IFLIST=""
for ARG in "$@"; do
    case "$ARG" in
        --no-push) NO_PUSH=1 ;;
        *) IFLIST="$ARG" ;;
    esac
done

PUSH_NAMES="${PUSH_NAMES:-admin}"
. /etc/myscript/push-notify.inc

STATE_DIR="/tmp/check-pbr-wg"
DBR_CONF="/etc/dnsmasq.d/dbroute-domains.conf"
RT_TABLES="/etc/iproute2/rt_tables"
HS_TIMEOUT=180
NOW=$(date +%s)

# 介面清單: 有帶參數用參數 (逗號分隔), 不帶 = 所有 wg 介面
if [ -n "$IFLIST" ]; then
    IFACES=$(echo "$IFLIST" | tr ',' '\n')
else
    IFACES=$(wg show interfaces 2>/dev/null | tr ' ' '\n' | sort)
fi

MSG=""
for IF in $IFACES; do
    [ -z "$IF" ] && continue

    # 指定的介面不存在時明講 (只掃到的不會進這裡)
    if ! ip link show "$IF" >/dev/null 2>&1; then
        ITEM="${IF}:介面不存在"
        [ -n "$MSG" ] && MSG="${MSG} | "
        MSG="${MSG}${ITEM}"
        continue
    fi

    # --- 介面狀態 ---
    ST=""
    PR=$(cat "${STATE_DIR}/${IF}.pingresult" 2>/dev/null)
    if [ -n "$PR" ] && [ "$PR" != "skip" ]; then
        ST="$PR"
    else
        # handshake 判定: 全 peer 掃一輪, 記最新一次的 age
        total=0; online=0; latest_age=""
        while read -r _pk _hs; do
            [ -z "$_pk" ] && continue
            total=$((total + 1))
            if [ "$_hs" -gt 0 ] 2>/dev/null; then
                _age=$(( NOW - _hs ))
                [ "$_age" -le "$HS_TIMEOUT" ] && online=$((online + 1))
                if [ -z "$latest_age" ] || [ "$_age" -lt "$latest_age" ]; then
                    latest_age=$_age
                fi
            fi
        done <<EOF
$(wg show "$IF" latest-handshakes 2>/dev/null)
EOF
        if [ "$total" -eq 0 ]; then
            ST="無peer"
        elif [ "$online" -gt 0 ]; then
            ST="${online}/${total}連入(hs${latest_age}s)"
        else
            ST="${online}/${total}斷線"
        fi
    fi

    # --- PBR (CustRule) enable 狀態 ---
    pbr_total=0; pbr_on=0
    for SEC in $(uci show pbr 2>/dev/null | grep "\.dest_addr='${IF}'" | cut -d'.' -f2); do
        pbr_total=$((pbr_total + 1))
        _en=$(uci -q get "pbr.${SEC}.enabled")
        [ "$_en" != "0" ] && pbr_on=$((pbr_on + 1))
    done
    if [ "$pbr_total" -eq 0 ]; then
        PBR="-"
    elif [ "$pbr_on" -eq "$pbr_total" ]; then
        PBR="on"
    elif [ "$pbr_on" -eq 0 ]; then
        PBR="off"
    else
        PBR="${pbr_on}/${pbr_total}"
    fi
    # 高頻震盪停用中另標 (check-pbr-wg 的 flap disable)
    _until=$(cat "${STATE_DIR}/${IF}.disabled_until" 2>/dev/null)
    if [ "$_until" -gt "$NOW" ] 2>/dev/null; then
        PBR="${PBR}(flap停用$(( (_until - NOW) / 60 ))m)"
    fi

    # --- DBR (domain routing) enable 狀態 ---
    DBR="-"
    if [ -f "$DBR_CONF" ] && grep -q "#inet#fw4#route_${IF}_v4" "$DBR_CONF" 2>/dev/null; then
        _tbl=$(awk -v name="dbr_${IF}" '$2 == name {print $1}' "$RT_TABLES" 2>/dev/null)
        if [ -n "$_tbl" ]; then
            _fwmark=$(printf "0x%x" "$_tbl")
            if ip rule show | grep -q "fwmark $_fwmark "; then
                DBR="on"
            else
                DBR="off"
            fi
        fi
    fi

    ITEM="${IF}:${ST} PBR:${PBR} DBR:${DBR}"
    [ -n "$MSG" ] && MSG="${MSG} | "
    MSG="${MSG}${ITEM}"
done

[ -z "$MSG" ] && MSG="無任何 wg 介面"

echo "$MSG"
logger -t wg-status "$MSG"
[ "$NO_PUSH" = "0" ] && push_notify "$MSG"
exit 0
