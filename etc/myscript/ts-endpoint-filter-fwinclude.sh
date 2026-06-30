#!/bin/sh
# ts-endpoint-filter-fwinclude.sh — firewall include(fw4_compatible）
#
# 目的:阻止 tailscale 把「wg 隧道網段」上的 UDP 41641 當 endpoint candidate。
#   tailscale 會列舉本機所有介面 IP 當直連候選,wg4/wg4ts 等隧道介面的內網 IP
#   (如 192.168.251.x)會被選成最優 direct path;一旦該 wg 隧道不穩,tailscale
#   死抱這條死路不退 → 節點(如 .7↔.8)互通整個垮。tailscale 無官方「排除
#   candidate」設定 → 用 firewall 讓該路徑探測失敗,使其自動棄用、退回公網/DERP。
#   只擋「隧道網段上的 41641」,公網/LAN 上的 41641(其他 peer 直連)不受影響。
#
# 每次 firewall restart/reload 由 fw4 呼叫,冪等重建 table ts_endpoint_filter。
# nft list table inet ts_endpoint_filter 
# 換隧道網段只改這一行(空格分隔多段;wg4/wg4ts=251、wg5=252…):
WG_TUNNEL_NETS="192.168.250.0/24 192.168.251.0/24 192.168.252.0/24"

TS_PORT=41641              # tailscaled 直連 UDP port
TABLE="inet ts_endpoint_filter"

# 冪等:先整桌刪除再重建
nft delete table $TABLE 2>/dev/null

nft add table $TABLE 2>/dev/null
nft add chain $TABLE out "{ type filter hook output priority -10; policy accept; }" 2>/dev/null
nft add chain $TABLE in  "{ type filter hook input  priority -10; policy accept; }" 2>/dev/null

_n=0
for _net in $WG_TUNNEL_NETS; do
    nft add rule $TABLE out ip daddr "$_net" udp dport $TS_PORT drop 2>/dev/null
    nft add rule $TABLE in  ip saddr "$_net" udp sport $TS_PORT drop 2>/dev/null
    _n=$((_n+1))
done

logger -t ts-endpoint-filter "已載入:擋 ${_n} 個隧道網段上的 udp/${TS_PORT}(firewall include)"
