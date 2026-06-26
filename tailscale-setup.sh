#!/bin/sh
# tailscale-setup.sh — 安裝 + 接線 Tailscale(headscale client),把這台加入 mesh 當一個 node
# ============================================================================
# 由 deploy.sh 在部署流程中呼叫(互動),也可單獨手動執行:
#     sh /tmp/deploy/tailscale-setup.sh
#
# 這支腳本把「2026-06 那次手動把家用路由器接上 OCI headscale」的經驗固化成一鍵步驟。
# 對應 headscale/ClientInstallGuide.md。
#
# ★ 這台的定位:「加入主 node 就好」— 只當網路裡的一個 node,LAN 與其他 node 互通,
#   但「不設 exit node」(不整個 LAN 走遠端出口)。
#
# 需要你輸入 2 樣東西(其餘全自動):
#   ① Headscale URL    例: https://mxc5569.duckdns.org
#   ② pre-auth key     例: hskey-auth-xxxxxxxx (headscale 後台產的)
#
# 腳本自動完成(= LuCI「AUTO CONFIGURE FIREWALL」+ 上次踩坑的所有修正):
#   ③ 套件: tailscale + luci-app-tailscale-community + jq(watchdog 反查需要)
#   ④ interface: network.tailscale (proto unmanaged, device tailscale0) → 開機持久
#   ⑤ firewall zone 'ts': masq=1 + mtu_fix=1 + lan↔ts 雙向 forwarding
#                          (LAN 與其他 node 互通的關鍵,不簡化)
#   ⑥ uci tailscale.settings.custom_login_url(watchdog 反查 / 改網址單一真相)
#   ⑦ tailscale up --authkey 登入(--accept-dns=false 避免 MagicDNS 連不上)
#   ⑧ cron: ts-watchdog.sh 每天一次(0 4 * * *)
#
# 不做:exit node、schedule 定時開關(本機定位是純 node)。
#       日後若要當出口:tailscale set --exit-node=<IP> --exit-node-allow-lan-access=true --accept-dns=false
#
# ⚠️ 注意:ts-watchdog.sh 的健檢是「繞著 exit node」設計的;這台沒設 exit node 時,
#    watchdog 跑到健檢1 會判定「ExitNodeID 空=使用者意圖,尊重不動」→ 形同空轉(只確認
#    服務在跑,不會做事)。保留 cron 是為了「日後一旦設了 exit node 就自動有自癒」,
#    純 node 階段它不會干擾。
#
# auto 模式: deploy.sh 帶 --ts-url/--ts-authkey 時自動套用(見下方環境變數)。
# ============================================================================
PATH=/usr/sbin:/sbin:/usr/bin:/bin; export PATH

C_PROMPT='\033[1;33m'; C_GREEN='\033[1;32m'; C_RESET='\033[0m'

# auto 模式可由環境變數帶入(deploy.sh export)
TS_URL="${ARG_TS_URL:-}"
TS_AUTHKEY="${ARG_TS_AUTHKEY:-}"
AUTO_MODE="${AUTO_MODE:-0}"

# 自我補齊:舊版 deploy 裝的機器可能沒有三支 ts-*.sh。
# 若 /etc/myscript/ts-watchdog.sh 不在,從部署包複製過去(支援單獨跑本腳本補裝)。
DEPLOY_DIR="${DEPLOY_DIR:-/tmp/deploy}"
if [ ! -f /etc/myscript/ts-watchdog.sh ] && [ -d "$DEPLOY_DIR/etc/myscript" ]; then
    mkdir -p /etc/myscript
    cp -a "$DEPLOY_DIR"/etc/myscript/ts-*.sh /etc/myscript/ 2>/dev/null
    chmod +x /etc/myscript/ts-*.sh 2>/dev/null
    [ -f /etc/myscript/ts-watchdog.sh ] && echo "  ℹ️ 已從 $DEPLOY_DIR 補齊 ts-*.sh"
fi

# 偵測套件管理器(與 deploy.sh 一致)
if command -v apk >/dev/null 2>&1; then PKG_MGR="apk"; else PKG_MGR="opkg"; fi
pkg_install() { case "$PKG_MGR" in apk) apk add "$@";; opkg) opkg install "$@";; esac; }
pkg_is_installed() {
    case "$PKG_MGR" in
        apk)  apk info --installed "$1" >/dev/null 2>&1 ;;
        opkg) opkg list-installed | grep -q "^$1 " ;;
    esac
}

echo ""
echo "========================================"
echo " Tailscale (Headscale node) 安裝"
echo "========================================"
echo "  把這台加入 headscale mesh 當一個 node,LAN 與其他 node 互通。"
echo "  (不設 exit node;需要時日後再手動設)"
echo "  需要: Headscale URL + pre-auth key。"
echo ""

# ---- 互動詢問(非 auto) ----
if [ "$AUTO_MODE" != "1" ]; then
    printf "${C_PROMPT}  是否安裝 Tailscale？(y/n) [n]: ${C_RESET}"
    read -r do_ts < /dev/tty
    case "${do_ts:-n}" in
        [Yy]) ;;
        *) echo "  ⏭️  跳過 Tailscale"; return 0 2>/dev/null || exit 0 ;;
    esac

    while [ -z "$TS_URL" ]; do
        printf "${C_PROMPT}  ① Headscale URL (https://...): ${C_RESET}"
        read -r TS_URL < /dev/tty
        echo "$TS_URL" | grep -q '^https\?://' || { echo "  ⚠️ 需以 http(s):// 開頭"; TS_URL=""; }
    done
    while [ -z "$TS_AUTHKEY" ]; do
        printf "${C_PROMPT}  ② pre-auth key (hskey-auth-...): ${C_RESET}"
        read -r TS_AUTHKEY < /dev/tty
        [ -z "$TS_AUTHKEY" ] && echo "  ⚠️ 必填"
    done
else
    # auto 模式:沒帶 --ts-url 就視為不裝
    if [ -z "$TS_URL" ] || [ -z "$TS_AUTHKEY" ]; then
        echo "  ⏭️  auto 模式未提供 --ts-url/--ts-authkey,跳過 Tailscale"
        return 0 2>/dev/null || exit 0
    fi
fi

# ---- ③ 安裝套件 ----
echo ""
echo "📥 安裝套件 (tailscale / luci-app-tailscale-community / jq)..."
pkg_is_installed tailscale || pkg_install tailscale 2>/dev/null
pkg_is_installed jq        || pkg_install jq 2>/dev/null
# luci app 名稱在不同 feed 可能略異,擇一安裝成功即可(失敗不致命,CLI 仍可用)
pkg_install luci-app-tailscale-community 2>/dev/null || \
  pkg_install luci-app-tailscale 2>/dev/null || \
  echo "  ⚠️ luci app 安裝失敗(不影響 CLI 運作)"
if ! command -v tailscale >/dev/null 2>&1; then
    echo "  ❌ tailscale 安裝失敗,中止"; return 1 2>/dev/null || exit 1
fi
echo "  ✅ 套件就緒"

# ---- ⑤ network interface(proto unmanaged, device tailscale0)→ 開機持久 ----
echo ""
echo "🔧 建立 network.tailscale interface..."
uci set network.tailscale=interface
uci set network.tailscale.proto='none'        # unmanaged
uci set network.tailscale.device='tailscale0'
uci commit network
echo "  ✅ network.tailscale (device=tailscale0)"

# ---- ⑥ firewall zone 'ts' + lan↔ts forwarding(= AUTO CONFIGURE FIREWALL)----
echo ""
echo "🔧 設定 firewall zone 'ts' (masq + mtu_fix + lan 雙向 forwarding)..."
zone_exists() {
    local i=0
    while uci get firewall.@zone[$i].name >/dev/null 2>&1; do
        [ "$(uci get firewall.@zone[$i].name)" = "$1" ] && return 0
        i=$((i+1))
    done
    return 1
}
fwd_exists() {
    local i=0
    while uci get firewall.@forwarding[$i] >/dev/null 2>&1; do
        [ "$(uci get firewall.@forwarding[$i].src 2>/dev/null)" = "$1" ] && \
        [ "$(uci get firewall.@forwarding[$i].dest 2>/dev/null)" = "$2" ] && return 0
        i=$((i+1))
    done
    return 1
}
if ! zone_exists ts; then
    uci add firewall zone >/dev/null
    uci set firewall.@zone[-1].name='ts'
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='ACCEPT'
    uci set firewall.@zone[-1].masq='1'        # LAN client 出 tailscale0 要 SNAT 成 100.x
    uci set firewall.@zone[-1].mtu_fix='1'     # MSS clamp,避免大封包卡住
    uci add_list firewall.@zone[-1].network='tailscale'
fi
# 三條 forwarding,涵蓋兩種需求(node 互通 + 當出口):
#   lan→ts : LAN 連得到其他 node;LAN 走「別台」exit node 出去
#   ts→lan : 其他 node 連得進這台 LAN(node 互通回程)
#   ts→wan : 別人透過「這台」當 exit node 出公網(需另 tailscale set --advertise-exit-node + headscale 核准路由)
fwd_exists lan ts || { uci add firewall forwarding >/dev/null; uci set firewall.@forwarding[-1].src='lan'; uci set firewall.@forwarding[-1].dest='ts'; }
fwd_exists ts lan || { uci add firewall forwarding >/dev/null; uci set firewall.@forwarding[-1].src='ts';  uci set firewall.@forwarding[-1].dest='lan'; }
fwd_exists ts wan || { uci add firewall forwarding >/dev/null; uci set firewall.@forwarding[-1].src='ts';  uci set firewall.@forwarding[-1].dest='wan'; }
uci commit firewall
echo "  ✅ firewall zone 'ts' + lan↔ts↔wan forwarding(node 互通 + 可當出口)"

# ---- ⑦ 寫 custom_login_url(watchdog/schedule 反查 exit node 對外 IP 的真相來源)----
uci set tailscale=tailscale 2>/dev/null
uci set tailscale.settings=settings 2>/dev/null
uci set tailscale.settings.custom_login_url="$TS_URL"
uci commit tailscale
echo "  ✅ uci tailscale.settings.custom_login_url=$TS_URL"

# ---- ⑨ 確保服務:啟用 + 只起 daemon(不在 init.d 跑 up,exit node 才能存 state 持久)----
/etc/init.d/tailscale enable 2>/dev/null
ps w | grep -q "[t]ailscaled" || { /etc/init.d/tailscale start >/dev/null 2>&1; sleep 6; }

# ---- ⑧ 登入 + 設 exit node ----
echo ""
echo "🔑 tailscale up(登入 headscale)..."
# up 可能卡互動,背景跑 + 給時間 + 收尾
( tailscale up --login-server="$TS_URL" --authkey="$TS_AUTHKEY" \
    --accept-routes=false --accept-dns=false >/dev/null 2>&1 ) &
UP_PID=$!
sleep 12
kill "$UP_PID" 2>/dev/null

# 補 tailscale0 IPv4(★上次頭號真兇:介面掉 IP → LAN 全斷)
TSIP=$(tailscale ip -4 2>/dev/null | head -1)
if [ -n "$TSIP" ]; then
    ip addr show tailscale0 2>/dev/null | grep -q "inet $TSIP" || ip addr add "$TSIP/32" dev tailscale0 2>/dev/null
    echo "  ✅ 已登入,本機 tailscale IP=$TSIP"
else
    echo "  ⚠️ 尚未取得 tailscale IP,請確認 URL/authkey 後手動 tailscale up"
fi

# 預設:已加入 mesh 當 node、LAN 與其他 node 互通(firewall 三條已就緒)。
# 不自動設 exit node(那綁 headscale 端狀態,每台不同,手動設較好維護)。
echo "  ℹ️ 已加入 mesh,LAN 與其他 node 互通。未設 exit node(LAN 走自家 WAN)。"
echo "     ── 日後要當出口,firewall 已備妥,只差以下指令: ──"
echo "     【這台 LAN 走別台 exit node 出去】"
echo "       tailscale set --exit-node=<IP> --exit-node-allow-lan-access=true --accept-dns=false"
echo "     【這台當別人的 exit node(別人透過這台出公網)】"
echo "       tailscale set --advertise-exit-node"
echo "       再到 headscale 核准: headscale nodes approve-routes -i <id> -r '0.0.0.0/0,::/0'"

# ---- ⑧ cron: watchdog 每天一次 ----
# 不裝 schedule 定時開關(本機是純 node)。watchdog 此階段對「無 exit node」是空轉,
# 保留是為了「日後一旦設了 exit node,自癒就自動生效」。
echo ""
echo "⏰ 加入 watchdog cron(每天一次)..."
CRONTAB_FILE="/etc/crontabs/root"
chmod +x /etc/myscript/ts-watchdog.sh 2>/dev/null
if ! grep -qF "ts-watchdog.sh" "$CRONTAB_FILE" 2>/dev/null; then
    echo "0 4 * * * /etc/myscript/ts-watchdog.sh      # Tailscale 自癒(每天 04:00;無 exit node 時空轉)" >> "$CRONTAB_FILE"
    /etc/init.d/cron restart 2>/dev/null
    echo "  ✅ 已加入 0 4 * * * ts-watchdog.sh"
else
    echo "  ✅ cron 已有 ts-watchdog.sh,略過"
fi

echo ""
printf "${C_GREEN}  ✅ Tailscale 安裝完成(已加入 mesh,當一個 node)${C_RESET}\n"
echo "     node 狀態:tailscale status"
echo "     本機 IP  :tailscale ip -4"
echo "     自癒日誌 :logread | grep ts-watchdog"
echo ""
