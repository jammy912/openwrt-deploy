#!/bin/sh
# watchdog-tailscale.sh — 監看 tailscale exit node,壞了自動恢復
# 每 10 分鐘由 cron 跑一次。對應 ClientInstallGuide.md §6 的已知故障。
# 健檢三項:(1) exit node 設定還在 (2) tailscale0 有 IPv4 (3) 出口確實走 exit node
# 自動修復分級:補介面 IP -> 重設 exit node -> 重啟 tailscaled
#
# IP 全部動態偵測,不寫死:
#   - 本機 tailscale IP   : tailscale ip -4
#   - exit node 隧道 IP   : 用 hostname 從 status 找
#   - exit node 對外 IP   : 解析 server_url 域名(exit node=headscale 同一台);
#                           備援:status 的 direct/CurAddr endpoint
#   - 「有沒有走出去」判斷 : curl 對外出口 IP == exit node 對外 IP
#     (★不可用 WAN 介面 IP 對照:double-NAT 下 WAN介面IP != 對外公網IP 會誤判)
#
# 設定 ------------------------------------------------------------
EXIT_HOST="openwrt-router"               # exit node hostname(你的意圖;比 ID 穩,ID 會變)
PROBE_HOST="api.ipify.org"               # 查對外出口 IP 的服務
ALLOW_LAN="true"
ACCEPT_DNS="false"
LOCKFILE="/tmp/watchdog-tailscale.lock"
# ----------------------------------------------------------------

# 防重入:拿不到鎖就直接退出(上一輪還在跑)
exec 9>"$LOCKFILE"
flock -n 9 || exit 0

log() { logger -t watchdog-tailscale "$1"; }

# 本機 tailscale IPv4(動態)
ts_ip() { tailscale ip -4 2>/dev/null | head -1; }

# exit node 的 tailscale IP(用 hostname 找,避開 ID 漂移)
exit_node_ip() {
  tailscale status 2>/dev/null | awk -v h="$EXIT_HOST" '$2==h {print $1; exit}'
}

# exit node 的「對外公網 IP」(動態;走 exit node 後對外應看到這個)
# 主來源:解析 headscale server_url 域名(exit node = 同一台 headscale 主機)
# 備援  :status 的 direct/CurAddr endpoint IP
expect_exit_ip() {
  local host ip
  host=$(uci get tailscale.settings.custom_login_url 2>/dev/null | sed 's|https\?://||; s|/.*||')
  if [ -n "$host" ]; then
    ip=$(nslookup "$host" 2>/dev/null | awk '/^Address/{a=$NF} END{print a}' | grep -oE '^[0-9.]+$')
  fi
  if [ -z "$ip" ]; then
    ip=$(tailscale status 2>/dev/null | awk -v h="$EXIT_HOST" '$2==h' \
         | grep -oE 'direct [0-9.]+' | grep -oE '[0-9.]+' | head -1)
  fi
  echo "$ip"
}

# 套用 exit node 設定
apply_exit() {
  EIP=$(exit_node_ip)
  [ -z "$EIP" ] && return 1                 # 找不到 exit node,沒得設
  tailscale set --exit-node="$EIP" \
    --exit-node-allow-lan-access="$ALLOW_LAN" \
    --accept-dns="$ACCEPT_DNS" >/dev/null 2>&1
}

# 健康判定:對外出口 IP == exit node 對外 IP(代表確實經 exit node 出去)
# 回傳 0=健康, 1=不健康;順帶把當下出口 IP 放進 $OUT
check_egress() {
  OUT=$(curl -4 -sS -m 12 "https://$PROBE_HOST" 2>/dev/null)
  EXP=$(expect_exit_ip)
  [ -n "$OUT" ] && [ -n "$EXP" ] && [ "$OUT" = "$EXP" ]
}

# ---- Gate:若是「刻意停用」就略過,不要自動修復(否則關不掉)----
# 任一成立即視為使用者主動停用,安靜離開:
#   a) tailscale 服務沒 enabled(/etc/init.d/tailscale disable)
#   b) WantRunning=false(tailscale down)
#   c) tailscale0 介面不存在(服務沒在跑,沒得修)
if ! /etc/init.d/tailscale enabled 2>/dev/null; then
  exit 0
fi
if ! ip link show tailscale0 >/dev/null 2>&1; then
  exit 0
fi
WANT=$(tailscale debug prefs 2>/dev/null | grep -oE '"WantRunning": (true|false)' | grep -oE '(true|false)$')
if [ "$WANT" = "false" ]; then
  exit 0
fi

TS_IP=$(ts_ip)

# ---- 健檢 1:exit node 設定是否還在 ----
EID=$(tailscale debug prefs 2>/dev/null | grep -oE '"ExitNodeID": "[^"]*"' | grep -oE '"[^:]*"$' | tr -d '"')
if [ -z "$EID" ]; then
  log "FAIL: ExitNodeID 空,重新套用 exit node"
  apply_exit
  sleep 3
fi

# ---- 健檢 2:tailscale0 有 IPv4 嗎(★最大坑)----
if [ -n "$TS_IP" ] && ! ip addr show tailscale0 2>/dev/null | grep -q "inet $TS_IP"; then
  log "FAIL: tailscale0 缺 IPv4 $TS_IP -> 補上"
  ip addr add "$TS_IP/32" dev tailscale0 2>/dev/null
  sleep 2
  # 補了還是沒有 -> 重啟 tailscaled(它會自己配回來)
  if ! ip addr show tailscale0 2>/dev/null | grep -q "inet $TS_IP"; then
    log "WARN: 手動補 IP 無效 -> 重啟 tailscaled"
    /etc/init.d/tailscale restart >/dev/null 2>&1
    sleep 10
    apply_exit
    sleep 3
  fi
fi

# ---- 健檢 3:出口確實走 exit node 嗎 ----
if check_egress; then
  exit 0                                     # 一切正常,安靜離開
fi

# 出口不對(空白 或 等於 WAN IP=沒走出去)-> 分級恢復
log "FAIL: 出口異常 (出口='$OUT' 期望='$(expect_exit_ip)') -> 重設 exit node"
apply_exit
sleep 4
if check_egress; then
  log "RECOVERED: 重設 exit node 後出口恢復 ($OUT)"
  exit 0
fi

# 還是不對 -> 重啟 tailscaled(最後手段)
log "WARN: 重設無效 (出口='$OUT') -> 重啟 tailscaled"
/etc/init.d/tailscale restart >/dev/null 2>&1
sleep 12
TS_IP=$(ts_ip)
[ -n "$TS_IP" ] && { ip addr show tailscale0 2>/dev/null | grep -q "inet $TS_IP" || ip addr add "$TS_IP/32" dev tailscale0 2>/dev/null; }
apply_exit
sleep 4
if check_egress; then
  log "RECOVERED: 重啟 tailscaled 後出口恢復 ($OUT)"
else
  log "ERROR: 自動恢復失敗,出口='$OUT' 期望='$(expect_exit_ip)',需人工介入"
fi
exit 0
