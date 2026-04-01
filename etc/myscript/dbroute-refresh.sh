#!/bin/sh
# 定時重新解析所有 dbroute 域名，填充 nft set
# 透過 dnsmasq (127.0.0.1) 查詢，觸發 nftset 指令

CONF="/etc/dnsmasq.d/dbroute-domains.conf"
LOG_TAG="dbroute-refresh"

if [ ! -f "$CONF" ]; then
    logger -t $LOG_TAG "No config found, skipping"
    exit 0
fi

# 確保 nft table 存在
if ! nft list table inet fw4 >/dev/null 2>&1; then
    logger -t $LOG_TAG "nft table fw4 not found, skipping"
    exit 1
fi

# 從 conf 提取所有域名（去掉註釋和格式）
DOMAINS=$(grep "^nftset=" "$CONF" | sed 's/nftset=\/\(.*\)\/4#.*/\1/' | tr '/' '\n' | sort -u)

COUNT=0
for DOM in $DOMAINS; do
    [ -z "$DOM" ] && continue
    nslookup "$DOM" 127.0.0.1 >/dev/null 2>&1
    COUNT=$((COUNT + 1))
done

logger -t $LOG_TAG "Refreshed $COUNT domains"
