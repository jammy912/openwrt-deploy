
#!/bin/sh
# check-qosify.sh
# 檢查 qosify 規則在各介面是否生效

echo "==== QoSify 規則檢查 ===="
echo ""

# 假設規則在 /etc/qosify/rules/
RULE_DIR="/etc/qosify/rules"

# 取得所有介面
IFACES=$(uci show network | grep '=interface' | cut -d. -f2 | cut -d= -f1)

for iface in $IFACES; do
    echo ">>> 檢查介面: $iface"

    # 顯示 qdisc
    echo "qdisc:"
    tc qdisc show dev $iface 2>/dev/null || echo "  (無 qdisc)"

    # 顯示 class
    echo "class:"
    tc class show dev $iface 2>/dev/null || echo "  (無 class)"

    # 顯示 filter
    echo "filter:"
    tc filter show dev $iface 2>/dev/null || echo "  (無 filter)"

    echo "------------------------------------------------"
done

echo ""
echo "=== 規則檔案 ==="
if [ -d "$RULE_DIR" ]; then
    ls -l $RULE_DIR
else
    echo "(找不到規則資料夾 $RULE_DIR )"
fi

echo ""
echo "檢查完成：qdisc/class/filter 出現規則，代表生效。空白則未生效。"

