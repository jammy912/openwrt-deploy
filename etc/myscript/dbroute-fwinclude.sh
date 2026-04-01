#!/bin/sh
# firewall include — 每次 firewall restart/reload 時自動載入 dbroute nft 規則
NFT_FILE="/etc/myscript/dbroute.nft"

# 檢查 chain 裡是否有 mark 規則（不是只檢查 chain 存在）
if nft list chain inet fw4 domain_prerouting 2>/dev/null | grep -q "meta mark set"; then
    logger -t dbroute "nft rules already loaded, skip (firewall include)"
    exit 0
fi

# 刪除可能殘留的空 chain/set，再重新載入完整規則
nft delete chain inet fw4 domain_prerouting 2>/dev/null
for _set in $(nft list sets inet fw4 2>/dev/null | grep -o 'route_.*_v4'); do
    nft delete set inet fw4 "$_set" 2>/dev/null
done

if [ -f "$NFT_FILE" ]; then
    nft -f "$NFT_FILE" 2>/dev/null && logger -t dbroute "nft rules loaded (firewall include)" || logger -t dbroute "nft rules load failed (firewall include)"
    # 背景：重啟 dnsmasq 讓它重新載入 nftset 指令，再 refresh 填充
    ( sleep 5 && service dnsmasq restart && sleep 3 && /etc/myscript/dbroute-refresh.sh && logger -t dbroute "nft sets refreshed (firewall include)" ) &
fi
