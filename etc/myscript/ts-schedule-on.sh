#!/bin/sh
# ts-schedule-on.sh [exit-node] — 定時「開」Tailscale:up + 設回 exit node
# 對應 ts-schedule-off.sh(tailscale down)。由 cron 排程呼叫。
#
# 參數(optional):$1 = 指定 exit node,帶了就「覆寫」預設目標。可為:
#   - tailscale IP(100.64.0.x)直接用
#   - ExitNodeID(純數字)→ jq 反查成 IP
#   不帶 → 用 watchdog 記憶檔的上次 IP;再沒有 → 自動抓在線 offers exit node 的。
PATH=/usr/sbin:/sbin:/usr/bin:/bin; export PATH
WANT_EXIT="$1"                                      # optional 覆寫目標

LAST_EXIT_FILE="/etc/myscript/.ts-last-exitnode"   # watchdog 記的上次 exit node IP
FALLBACK_FLAG="/etc/myscript/.ts-fallback-active"
PUSH_NAMES="${PUSH_NAMES:-admin}"
[ -f /etc/myscript/push-notify.inc ] && . /etc/myscript/push-notify.inc
notify() { command -v push_notify >/dev/null 2>&1 && push_notify "$1"; }
log() { logger -t ts-schedule "$1"; }

# headscale 登入網址:從 uci 動態取得(與 watchdog-tailscale.sh 同一真相來源,
# 改網址只需改 uci tailscale.settings.custom_login_url 一處)。讀不到才退回預設,
# 避免靜默連錯 server。
LOGIN_URL=$(uci get tailscale.settings.custom_login_url 2>/dev/null)
[ -z "$LOGIN_URL" ] && { LOGIN_URL="https://mxc5569.duckdns.org"; log "WARN: uci 無 custom_login_url,用預設 $LOGIN_URL"; }

log "排程開機:啟動 tailscale 並設回 exit node"

# 1) 確保服務在跑
/etc/init.d/tailscale enabled 2>/dev/null || /etc/init.d/tailscale enable >/dev/null 2>&1
ps w | grep -q "[t]ailscaled" || { /etc/init.d/tailscale start >/dev/null 2>&1; sleep 8; }

# 2) tailscale up 拉起 WantRunning
#    ⚠️ tailscale down 之後,普通 up 拉不起 WantRunning(實測無效),必須 --reset 才行。
#    --reset 會清掉 prefs(含 exit node),但第 4 步本來就會重設,正好。背景跑+kill 避免卡互動。
( tailscale up --reset --login-server="$LOGIN_URL" --accept-routes=false >/dev/null 2>&1 ) &
UP_PID=$!
sleep 12
kill "$UP_PID" 2>/dev/null

# 3) 補 tailscale0 IP(以防沒配上)
TSIP=$(tailscale ip -4 2>/dev/null | head -1)
[ -n "$TSIP" ] && { ip addr show tailscale0 2>/dev/null | grep -q "inet $TSIP" || ip addr add "$TSIP/32" dev tailscale0 2>/dev/null; }

# 4) 決定 exit node 目標(優先序):
#    參數 $1 覆寫 → 記憶檔 → 自動抓在線 offers exit node
EIP=""
if [ -n "$WANT_EXIT" ]; then
  case "$WANT_EXIT" in
    100.*) EIP="$WANT_EXIT" ;;                        # 已是 tailscale IP
    *[!0-9]*) EIP="$WANT_EXIT" ;;                     # 非純數字,當 IP/原樣交給 tailscale
    *) # 純數字 = ExitNodeID,反查成 IP
       EIP=$(tailscale status --json 2>/dev/null \
             | jq -r --arg id "$WANT_EXIT" '.Peer[] | select(.ID == $id) | .TailscaleIPs[0]' 2>/dev/null) ;;
  esac
fi
[ -z "$EIP" ] && EIP=$(grep -oE '^100\.[0-9.]+' "$LAST_EXIT_FILE" 2>/dev/null | head -1)
[ -z "$EIP" ] && EIP=$(tailscale status 2>/dev/null | awk '/offers exit node/ && !/offline/ {print $1; exit}')
if [ -n "$EIP" ]; then
  tailscale set --exit-node="$EIP" --exit-node-allow-lan-access=true --accept-dns=false >/dev/null 2>&1
  rm -f "$FALLBACK_FLAG"                   # 排程開=正常意圖,清 fallback 旗標
  sleep 4
  OUT=$(curl -4 -sS -m 12 https://api.ipify.org 2>/dev/null)
  log "排程開機完成:exit node=$EIP 出口=${OUT:-未知}"
  notify "🟢 Tailscale 排程開啟,LAN 走 exit node $EIP(出口 ${OUT:-未知})"
else
  log "排程開機:找不到可用 exit node,僅 up(走 WAN)"
  notify "🟡 Tailscale 排程開啟,但找不到在線 exit node,暫走 WAN"
fi
