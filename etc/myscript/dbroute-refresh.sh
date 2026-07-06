#!/bin/sh

# 定時重新解析所有 dbroute 域名，填充 nft set
# 透過 dnsmasq (127.0.0.1) 查詢，觸發 nftset 指令

# 不排全域 cron 隊:每分鐘跑且僅數個 nslookup,輕量冪等,無需與其他 cron 序列化
# (排隊反而會因長任務持鎖而等待/跳過)。PATH 原由 lock-handler.sh 提供,自行補上。
PATH=/usr/sbin:/sbin:/usr/bin:/bin
export PATH

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

# 降噪：cron 已改每分鐘跑，成功時靜默(否則 1440 行/天沖掉 logread ring buffer)
# 只在異常(conf 有內容卻一個域名都沒解析到)時出聲
[ "$COUNT" -eq 0 ] && logger -t $LOG_TAG "WARNING: refreshed 0 domains (conf 異常?)"
exit 0
