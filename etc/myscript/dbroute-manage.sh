#!/bin/sh
# 域名路由管理工具
# 用法:
#   dbroute-manage.sh add <interface> <domain1> [domain2 ...]
#   dbroute-manage.sh del <domain1> [domain2 ...]
#   dbroute-manage.sh list
#   dbroute-manage.sh status
#   dbroute-manage.sh reload

CONF="/etc/dnsmasq.d/dbroute-domains.conf"
RT_TABLES="/etc/iproute2/rt_tables"

case "$1" in
    add)
        shift
        IFACE="$1"; shift
        if [ -z "$IFACE" ] || [ -z "$1" ]; then
            echo "用法: $0 add <interface> <domain1> [domain2 ...]"
            exit 1
        fi
        NFTSET="4#inet#fw4#route_${IFACE}_v4"
        echo "nftset=/$(echo "$@" | tr ' ' '/')/${NFTSET}" >> "$CONF"
        service dnsmasq restart
        ;;
    del)
        shift
        for d in "$@"; do sed -i "/${d}/d" "$CONF"; done
        service dnsmasq restart
        ;;
    list)
        cat "$CONF"
        ;;
    status)
        echo "===== Domain-Based Route Status ====="
        echo ""

        # 取得所有介面
        IFACES=$(sed -n 's/.*#inet#fw4#route_\(.*\)_v4$/\1/p' "$CONF" 2>/dev/null | sort -u)

        if [ -z "$IFACES" ]; then
            echo "No domain routes configured."
            exit 0
        fi

        for IFACE in $IFACES; do
            SET_NAME="route_${IFACE}_v4"
            TABLE_ID=$(awk -v name="pbr_${IFACE}" '$2 == name {print $1}' "$RT_TABLES" 2>/dev/null)
            FWMARK=""
            [ -n "$TABLE_ID" ] && FWMARK=$(printf "0x%x" "$TABLE_ID")

            # 介面狀態
            if ip link show "$IFACE" >/dev/null 2>&1; then
                IF_STATUS="UP"
            else
                IF_STATUS="DOWN"
            fi

            echo "--- $IFACE ($IF_STATUS) | table=$TABLE_ID fwmark=$FWMARK ---"

            # 域名清單
            DOMAINS=$(grep "route_${IFACE}_v4" "$CONF" | sed 's/nftset=\/\(.*\)\/4#.*/\1/' | tr '/' ' ')
            echo "  Domains: $DOMAINS"

            # nft set 已填充的 IP 數量
            IP_COUNT=$(nft list set inet fw4 "$SET_NAME" 2>/dev/null | grep -c "expires")
            echo "  Cached IPs: $IP_COUNT"

            # ip rule
            RULE=$(ip rule show 2>/dev/null | grep "fwmark $FWMARK" | head -1)
            if [ -n "$RULE" ]; then
                echo "  IP Rule: $RULE"
            else
                echo "  IP Rule: MISSING"
            fi

            # 路由
            ROUTE=$(ip route show table "$TABLE_ID" 2>/dev/null | head -1)
            if [ -n "$ROUTE" ]; then
                echo "  Route: $ROUTE"
            else
                echo "  Route: MISSING"
            fi

            echo ""
        done

        # nft chain counter
        echo "--- nft prerouting chain ---"
        nft list chain inet fw4 domain_prerouting 2>/dev/null | grep -v "^table\|^}$\|^$" | sed 's/^/  /'
        ;;
    reload)
        service dnsmasq restart
        # 清空所有域名路由 nft set
        nft list sets inet fw4 2>/dev/null | grep "route_.*_v4" | awk '{print $2}' | while read -r setname; do
            nft flush set inet fw4 "$setname" 2>/dev/null
        done
        ;;
    *)
        echo "用法: $0 {add|del|list|status|reload}"
        ;;
esac
