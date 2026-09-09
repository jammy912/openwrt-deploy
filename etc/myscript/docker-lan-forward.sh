#!/bin/sh
# 讓 LAN client 能經本機 NAT 出去 —— 修 Docker 的 iptables FORWARD policy DROP。
#
# ⚠️ 真兇紀錄 2026-09-09 (.4 當主 gw 時 client 全部斷網):
#    OpenWrt 的防火牆是 nftables(fw4), Docker 用的是傳統 iptables, 兩套並存。
#    fw4 的 accept_to_wan 明明已經 accept, 封包接著仍要過 iptables 的
#    filter FORWARD 鏈, 而 Docker 把它的 policy 設成 DROP。LAN->WAN 的流量
#    不匹配任何 DOCKER-* 規則 -> 全部落到 policy DROP。
#    實測 `iptables -L FORWARD -n -v` 顯示 "policy DROP 38094 packets, 12M bytes"。
#
# ★ 只有「本機當主 gw 做 NAT 轉發」時才會發作:
#    - 副 gw 不轉發 (client 的閘道是主 gw) -> 不經 FORWARD -> 沒事
#    - 路由器自己對外走 OUTPUT 不走 FORWARD -> 沒事
#    所以裝完 Docker 當下不會發現, 等角色切換成主 gw 才爆, 極難聯想。
#
# ★ 抓到真兇的方法(可重用): 一般的 tcpdump/計數器只能看到「fw4 放行了但封包
#    沒出去」這個矛盾, 要用 nft monitor trace 才看得到它掉在 iptables 那一側:
#      nft add table inet trc
#      nft add chain inet trc pre '{ type filter hook prerouting priority -350; policy accept; }'
#      nft add rule inet trc pre ip saddr <client> tcp dport 443 meta nftrace set 1
#      nft monitor trace          # 看最後一行是不是 "ip filter FORWARD policy drop"
#
# DOCKER-USER 是 Docker 官方保留給使用者的鏈, docker 重啟不會覆蓋它。
LAN_IF="${1:-br-lan}"
WAN_IF="${2:-$(ip route show default 2>/dev/null | awk '/^default/{print $5; exit}')}"
[ -z "$WAN_IF" ] && exit 0
command -v iptables >/dev/null 2>&1 || exit 0
iptables -L DOCKER-USER -n >/dev/null 2>&1 || exit 0   # 沒裝 Docker 就安靜跳過

# 先刪再加, 避免 reload 時累積重複規則
iptables -D DOCKER-USER -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null
iptables -D DOCKER-USER -i "$WAN_IF" -o "$LAN_IF" \
    -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
# 回程規則要在前面(-I 1 會把後加的推到最上面, 故先加去程再加回程)
iptables -I DOCKER-USER 1 -i "$LAN_IF" -o "$WAN_IF" -j ACCEPT
iptables -I DOCKER-USER 1 -i "$WAN_IF" -o "$LAN_IF" \
    -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
logger -t docker-lan-forward "已放行 $LAN_IF -> $WAN_IF (修 Docker FORWARD policy DROP)"
