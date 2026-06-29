#!/bin/sh
# 動態設定域名路由(DBR)規則
# 讀取 /etc/iproute2/rt_tables 中所有 dbr_<iface> 項目
# 為每個有對應 nft set 的介面建立 ip rule + route
# DBR table 別名用 dbr_<iface> 前綴，與 OpenWrt PBR 套件的 pbr_<iface> 分開。
# 注意：兩者 table id 都是「rt_tables 最大 id + 1」動態分配，會交錯/漂移，
#       不能用 id 區間區分；只能用名字前綴(dbr_ vs pbr_)與 DBR conf 白名單。

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

# DBR table 命名遷移：把舊的 pbr_<iface> 改名為 dbr_<iface>，保留同 table id。
# **只遷移 DBR conf 裡確實存在的介面（$INTERFACES 白名單）**，
# 嚴禁用 table id 區間判斷——OpenWrt PBR 套件的 pbr_* 別名 id 會漂移(可能 >300)，
# 若用 id 區間會誤改套件別名，觸發套件 reload 重建新 pbr_ → 本函式再改 → 死循環。
# 套件用 get_rt_tables_id 以名字 pbr_<iface> 查 id，故只要不碰它的別名即安全。
# wan 不進此區(DBR 的 wan 用 table 254/main)，故白名單裡的 wan 不會有 pbr_wan 被改。
for _if in $INTERFACES; do
    [ "$_if" = "wan" ] && continue
    _old="pbr_${_if}"
    _new="dbr_${_if}"
    _id=$(awk -v n="$_old" '$2 == n {print $1; exit}' "$RT_TABLES")
    [ -z "$_id" ] && continue   # 沒有舊 pbr_<iface> 就不用遷移
    # 已有同名 dbr_<iface> 則只刪舊 pbr_，否則改名(保留 id)
    sed -i "/^${_id}[[:space:]]\+${_old}\$/d" "$RT_TABLES"
    grep -q "[[:space:]]${_new}\$" "$RT_TABLES" || echo "$_id $_new" >> "$RT_TABLES"
    logger -t dbroute "Migrated rt_table alias $_old → $_new (id $_id)"
done

for IFACE in $INTERFACES; do
    # wan 使用固定 table 254 (main)，讓域名走回預設路由
    if [ "$IFACE" = "wan" ]; then
        # 冪等：add 前先 del 同 key，避免開頭清除迴圈漏清(格式沒被 sed 抓到)
        # 時 add 撞 "RTNETLINK answers: File exists" 導致規則沒建成、DBR 失效。
        ip rule del fwmark 0xfe lookup 254 priority 100 2>/dev/null
        ip rule add fwmark 0xfe lookup 254 priority 100 2>/dev/null
        logger -t dbroute "Domain routing via wan (table 254/main, fwmark 0xfe) configured"
        continue
    fi

    # 從 rt_tables 找 table ID
    TABLE_ID=$(awk -v name="dbr_${IFACE}" '$2 == name {print $1}' "$RT_TABLES")

    # 沒對應條目就自動分配下一個可用 table id 並寫入
    # Why: PBR 套件只管 uci 設為 interface 的 wg,wg2 之類「反向接入但 dbroute 要走」
    # 的介面 PBR 不管,rt_tables 沒它的份,dbroute-setup.sh 過去直接 skip 不建 route。
    # 由 dbroute 自己補登,Google Sheet 加新介面就能自動生效,不用手動改 rt_tables。
    if [ -z "$TABLE_ID" ]; then
        TABLE_ID=$(($(awk '/^[0-9]+/{print $1}' "$RT_TABLES" | sort -n | tail -1) + 1))
        # DBR 從 300 起,跟 PBR 套件 256-261 區隔
        [ "$TABLE_ID" -lt 300 ] && TABLE_ID=300
        echo "$TABLE_ID dbr_${IFACE}" >> "$RT_TABLES"
        logger -t dbroute "Auto-registered dbr_${IFACE} → table $TABLE_ID"
    fi

    # fwmark = table ID 的十六進位
    FWMARK=$(printf "0x%x" "$TABLE_ID")

    # 檢查介面是否存在
    if ! ip link show "$IFACE" >/dev/null 2>&1; then
        logger -t dbroute "WARNING: Interface $IFACE not up, skipping"
        continue
    fi

    # 冪等：add 前先 del 同 key(理由同 wan 段)，避免 File exists 讓規則沒建成
    ip rule del fwmark "$FWMARK" lookup "$TABLE_ID" priority 100 2>/dev/null
    ip rule add fwmark "$FWMARK" lookup "$TABLE_ID" priority 100
    ip route replace default dev "$IFACE" table "$TABLE_ID"

    logger -t dbroute "Domain routing via $IFACE (table $TABLE_ID, fwmark $FWMARK) configured"
done
