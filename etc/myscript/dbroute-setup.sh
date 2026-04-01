#!/bin/sh
# 動態設定域名 PBR 路由規則
# 讀取 /etc/iproute2/rt_tables 中所有 pbr_wg_* 項目
# 為每個有對應 nft set 的介面建立 ip rule + route

RT_TABLES="/etc/iproute2/rt_tables"
CONF="/etc/dnsmasq.d/dbroute-domains.conf"

# 清除所有舊的域名路由 fwmark 規則（priority 100）
ip rule show | grep "priority 100" | while read -r line; do
    fwmark=$(echo "$line" | sed -n 's/.*fwmark \(0x[0-9a-f]*\).*/\1/p')
    table=$(echo "$line" | sed -n 's/.*lookup \([0-9]*\).*/\1/p')
    if [ -n "$fwmark" ] && [ -n "$table" ]; then
        ip rule del fwmark "$fwmark" lookup "$table" 2>/dev/null
    fi
done

# 從 dbroute-domains.conf 找出所有使用中的 nft set 名稱（route_<iface>_v4 格式）
if [ ! -f "$CONF" ]; then
    logger -t dbroute "No dbroute-domains.conf found, skipping"
    exit 0
fi

# 取得所有不重複的介面名稱
INTERFACES=$(sed -n 's/.*#inet#fw4#route_\(.*\)_v4$/\1/p' "$CONF" | sort -u)

if [ -z "$INTERFACES" ]; then
    logger -t dbroute "No domain route interfaces found in $CONF"
    exit 0
fi

for IFACE in $INTERFACES; do
    # wan 使用固定 table 254 (main)，讓域名走回預設路由
    if [ "$IFACE" = "wan" ]; then
        ip rule add fwmark 0xfe lookup 254 priority 100 2>/dev/null
        logger -t dbroute "Domain routing via wan (table 254/main, fwmark 0xfe) configured"
        continue
    fi

    # 從 rt_tables 找 table ID
    TABLE_ID=$(awk -v name="pbr_${IFACE}" '$2 == name {print $1}' "$RT_TABLES")

    if [ -z "$TABLE_ID" ]; then
        logger -t dbroute "WARNING: No rt_table entry for pbr_${IFACE}, skipping"
        continue
    fi

    # fwmark = table ID 的十六進位
    FWMARK=$(printf "0x%x" "$TABLE_ID")

    # 檢查介面是否存在
    if ! ip link show "$IFACE" >/dev/null 2>&1; then
        logger -t dbroute "WARNING: Interface $IFACE not up, skipping"
        continue
    fi

    ip rule add fwmark "$FWMARK" lookup "$TABLE_ID" priority 100
    ip route replace default dev "$IFACE" table "$TABLE_ID"

    logger -t dbroute "Domain routing via $IFACE (table $TABLE_ID, fwmark $FWMARK) configured"
done
