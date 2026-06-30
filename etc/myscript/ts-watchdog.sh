#!/bin/sh
# ts-watchdog.sh — 監看 tailscale exit node,壞了自動恢復
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
# exit node 全動態識別,不寫死任何 IP/hostname(hostname 會被改名,IP 也可能變):
#   exit node = headscale server 同一台 → 找 status 裡 direct endpoint = server IP 的 node;
#   備援:在線且 offers exit node 的 node。
PROBE_HOST="api.ipify.org"               # 查對外出口 IP 的服務
ALLOW_LAN="true"
ACCEPT_DNS="false"
FALLBACK_TO_WAN="1"                       # 救不回時:1=清掉exit node改走WAN保上網,0=維持斷網(fail-closed)
LAST_EXIT_FILE="/etc/myscript/.ts-last-exitnode"  # 記上次 exit node IP(fallback後自動切回用)
FALLBACK_FLAG="/etc/myscript/.ts-fallback-active" # fallback 旗標:有=watchdog清的(該自動切回);無=你手動清的(別碰)。持久化以防 fallback 中途重開機
LOCKFILE="/tmp/ts-watchdog.lock"
PUSH_NAMES="${PUSH_NAMES:-admin}"        # 推播對象(對應 .secrets/pushkey.<name>)
# ----------------------------------------------------------------

# 防重入:拿不到鎖就直接退出(上一輪還在跑)
exec 9>"$LOCKFILE"
flock -n 9 || exit 0

log() { logger -t ts-watchdog "$1"; }

# 推播模組(PushDeer/LINE 即時 + 離線佇列)。載入失敗不影響主流程。
[ -f /etc/myscript/push-notify.inc ] && . /etc/myscript/push-notify.inc
# 即時推播;無模組時 no-op
notify() { command -v push_notify >/dev/null 2>&1 && push_notify "$1"; }
# 救不回專用:即時試送 + 進離線佇列(網路斷也能開機後補送)
notify_fail() {
  notify "$1"
  command -v queue_push >/dev/null 2>&1 && \
    queue_push "tailscale-exitnode-fail" "$1" "" >/dev/null 2>&1
}

# 本機 tailscale IPv4(動態)
ts_ip() { tailscale ip -4 2>/dev/null | head -1; }

# client 設定要用的 exit node ID(你的意圖;實測它不會自己無故消失,設成有效 node 後穩定留著)
exit_node_id() {
  tailscale debug prefs 2>/dev/null | grep -oE '"ExitNodeID": "[^"]*"' | grep -oE '"[^:]*"$' | tr -d '"'
}

# 用 ExitNodeID 反查該 node 的 tailscale IPv4(jq)— 全動態,不寫死、不怕改名、不靠同一台
# (.Peer 是 object,[] 迭代 value;TailscaleIPs[0] 即 IPv4)
exit_node_ip() {
  local id
  id=$(exit_node_id)
  [ -z "$id" ] && return 1
  tailscale status --json 2>/dev/null \
    | jq -r --arg id "$id" '.Peer[] | select(.ID == $id) | .TailscaleIPs[0]' 2>/dev/null
}

# 記憶上次成功使用的 exit node IP(讓 fallback 後 OCI 回來能自動切回)
# ⚠️內容一致就不寫:避免每 10 分鐘對 flash 寫相同內容,減少磨損。
remember_exit() {
  local ip; ip=$(exit_node_ip)
  [ -z "$ip" ] && return 0
  [ "$ip" = "$(cat "$LAST_EXIT_FILE" 2>/dev/null)" ] && return 0   # 一致,不寫
  echo "$ip" > "$LAST_EXIT_FILE" 2>/dev/null
}
last_exit_ip() { cat "$LAST_EXIT_FILE" 2>/dev/null | grep -oE '^100\.[0-9.]+' | head -1; }

# 某 tailscale IP 的 node 現在是否在線(status 那行沒 offline)
node_online() {
  [ -n "$1" ] && tailscale status 2>/dev/null | awk -v n="$1" '$1==n && $0 !~ /offline/ {f=1} END{exit !f}'
}

# 用 ExitNodeID 反查該 node 的「對外公網 IP」(走 exit node 後對外應看到這個)
# 主:CurAddr 的 IP(direct 時有);備:走 relay 時 CurAddr 可能空 → 用 server_url 解析
expect_exit_ip() {
  local id ip
  id=$(exit_node_id)
  [ -z "$id" ] && return 1
  ip=$(tailscale status --json 2>/dev/null \
    | jq -r --arg id "$id" '.Peer[] | select(.ID == $id) | .CurAddr' 2>/dev/null \
    | grep -oE '^[0-9.]+' | head -1)
  if [ -z "$ip" ]; then
    # CurAddr 空(走 relay)→ 退而用 headscale server_url 解析(多數情境 exit node=同台)
    local h
    h=$(uci get tailscale.settings.custom_login_url 2>/dev/null | sed 's|https\?://||; s|/.*||')
    [ -n "$h" ] && ip=$(nslookup "$h" 2>/dev/null | awk '/^Address/{a=$NF} END{print a}' | grep -oE '^[0-9.]+$')
  fi
  echo "$ip"
}

# 套用 exit node 設定(用 ExitNodeID 反查到的 IP 重設,確保 prefs 一致)
apply_exit() {
  EIP=$(exit_node_ip)
  [ -z "$EIP" ] && return 1                 # ExitNodeID 空或查不到 → 沒有意圖可設,放棄
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

# ---- 健檢 0:節點互通路由(table 52)----
# 與 exit node 無關。tailscale 把 peer 路由(100.64.x dev tailscale0)裝在
# table 52(ip rule: from all lookup 52)。網路抖動/角色變動(如 auto-role 改 IP)
# 後，tailscale 重裝路由可能失敗 → table 52 空 → 普通 ping 100.64.x fallback
# 走 wan 丟包(節點互通全斷,但 tailscale ping 仍通 → 易誤判)。
# 此檢查放在 exit-node Gate 之前,因為「無 exit node 的機器(如純互通 client)」
# 也需要它。修復:重啟 tailscaled 讓它重裝 table 52。
TS52_CNT=$(ip route show table 52 2>/dev/null | grep -c "dev tailscale0")
if [ "${TS52_CNT:-0}" -eq 0 ]; then
  log "FAIL: table 52 無 100.64 路由(節點互通斷)-> 重啟 tailscaled 重裝路由"
  /etc/init.d/tailscale restart >/dev/null 2>&1
  sleep 12
  TS52_CNT2=$(ip route show table 52 2>/dev/null | grep -c "dev tailscale0")
  if [ "${TS52_CNT2:-0}" -gt 0 ]; then
    log "RECOVERED: table 52 路由已重建($TS52_CNT2 條),節點互通恢復"
    notify "✅ Tailscale 節點互通自癒成功(table 52 路由重建,$TS52_CNT2 條)"
  else
    log "ERROR: 重啟後 table 52 仍無 100.64 路由,節點互通可能仍斷"
    notify_fail "🛑 Tailscale 節點互通自癒失敗:table 52 無路由,需人工介入"
  fi
fi

TS_IP=$(ts_ip)

# ---- 健檢 0.5:peer 真實互通(ICMP)退化偵測 ----
# 與 exit node 無關,放在 exit-node Gate 之前 → 純互通機(無 exit node)也會跑。
# Why: 健檢0 只看 table 52 是否「空」。但有一類故障是 table 52 路由都在、
#   tailscale ping 經 DERP 也通,但普通 ICMP 對 peer 100% 掉(NAT 打洞退化、
#   兩端 endpoint 學歪成隧道內 IP、資料面只剩 DERP 走不乾淨)。table 52 非空 →
#   健檢0 不觸發 → 過去無人自修。這裡用「對在線 peer 真實 ping」補這個洞。
# 判定:挑最多 3 個在線 peer,普通 ping(每個 2 包),只要任一通就算健康;
#   全不通才算 FAIL。連續 PEER_FAIL_CONFIRM 輪 FAIL 才重啟 tailscaled(避免單次
#   抖動亂重啟)。重啟會重新 netcheck + 清掉學歪的 endpoint 重新協商。
PEER_FAIL_CONFIRM=2                               # 連續 N 輪(每輪10分)互通失敗才重啟
PEER_FAIL_FILE="/tmp/.ts-peer-failcount"
peer_fail_get()   { cat "$PEER_FAIL_FILE" 2>/dev/null || echo 0; }
peer_fail_inc()   { echo $(( $(peer_fail_get) + 1 )) > "$PEER_FAIL_FILE"; }
peer_fail_reset() { rm -f "$PEER_FAIL_FILE"; }

# 只有 table 52 有路由時才做(健檢0 剛補過會是非空;真的空已由健檢0 處理)
TS52_NOW=$(ip route show table 52 2>/dev/null | grep -c "dev tailscale0")
if [ "${TS52_NOW:-0}" -gt 0 ]; then
  # 在線 peer 的 tailscale IPv4(排除自己、offline);最多取 3 個
  PEER_IPS=$(tailscale status 2>/dev/null \
    | awk -v me="$TS_IP" '$1 ~ /^100\./ && $1 != me && $0 !~ /offline/ {print $1}' \
    | head -3)
  if [ -n "$PEER_IPS" ]; then
    PEER_OK=0
    for _pip in $PEER_IPS; do
      if ping -c 2 -W 2 "$_pip" >/dev/null 2>&1; then PEER_OK=1; break; fi
    done
    if [ "$PEER_OK" = "1" ]; then
      peer_fail_reset                            # 有任一 peer 通 → 互通健康
    else
      peer_fail_inc
      _pfc=$(peer_fail_get)
      if [ "$_pfc" -lt "$PEER_FAIL_CONFIRM" ]; then
        log "PENDING: peer 互通 ICMP 全不通(${_pfc}/${PEER_FAIL_CONFIRM} 輪),暫不重啟(避免抖動)"
      else
        log "FAIL: peer 互通連 ${_pfc} 輪 ICMP 全不通(table 52 在=非健檢0 場景)-> 重啟 tailscaled 重新協商 endpoint"
        /etc/init.d/tailscale restart >/dev/null 2>&1
        sleep 14
        # 重啟後重驗
        PEER_IPS2=$(tailscale status 2>/dev/null \
          | awk -v me="$TS_IP" '$1 ~ /^100\./ && $1 != me && $0 !~ /offline/ {print $1}' | head -3)
        PEER_OK2=0
        for _pip in $PEER_IPS2; do
          if ping -c 2 -W 2 "$_pip" >/dev/null 2>&1; then PEER_OK2=1; break; fi
        done
        if [ "$PEER_OK2" = "1" ]; then
          log "RECOVERED: 重啟 tailscaled 後 peer 互通已恢復"
          notify "✅ Tailscale 節點互通自癒成功(peer ICMP 退化→重啟 tailscaled 重新協商)"
          peer_fail_reset
        else
          log "ERROR: 重啟後 peer 互通仍不通(可能 double-NAT 打洞失敗,只剩 DERP),需人工介入"
          notify_fail "🛑 Tailscale 節點互通自癒失敗:重啟後 peer ICMP 仍不通,需人工介入"
          peer_fail_reset                        # 重置避免每輪狂重啟;下輪重新累計
        fi
      fi
    fi
  fi
fi

# ---- 健檢 1:client 是否設有 exit node 意圖 ----
# ExitNodeID 空可能是:(a)你手動/UI 清 (b)watchdog 先前 fallback 走 WAN 清掉的。
# 兩者外觀一樣,靠「fallback 旗標檔」區分:
#   有旗標 = watchdog 自己清的 → node 回來時自動切回;
#   無旗標 = 你手動清的 → 尊重你,不回寫、不設回(避免你清不掉)。
EID=$(exit_node_id)
if [ -z "$EID" ]; then
  if [ ! -f "$FALLBACK_FLAG" ]; then
    log "INFO: ExitNodeID 空且無 fallback 旗標 = 使用者手動清,尊重不動,退出"
    exit 0
  fi
  # 有旗標:是 fallback 造成的,嘗試自動切回
  LAST=$(last_exit_ip)
  if [ -n "$LAST" ] && node_online "$LAST"; then
    log "RECOVER: fallback 後上次 exit node $LAST 已在線 -> 自動切回"
    tailscale set --exit-node="$LAST" \
      --exit-node-allow-lan-access="$ALLOW_LAN" --accept-dns="$ACCEPT_DNS" >/dev/null 2>&1
    sleep 4
    if check_egress; then
      log "RECOVERED: 自動切回 exit node $LAST,出口已恢復走 $OUT"
      notify "✅ Tailscale exit node 已自動切回($LAST),出口恢復走 $OUT(先前 fallback 到 WAN)"
      rm -f "$FALLBACK_FLAG"                  # 切回成功,清旗標
      remember_exit
      exit 0
    fi
    log "WARN: 切回 $LAST 後出口仍異常(出口='$OUT'),繼續往下健檢"
  else
    log "WARN: fallback 中,上次 exit node ${LAST:-無} 未在線,續走 WAN 等待"
    exit 0                                    # 安靜等待 node 回來(不每輪洗推播)
  fi
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
  remember_exit                              # 健康時記住當前 exit node IP(供日後 fallback 自動切回)
  rm -f "$FALLBACK_FLAG"                      # 健康走著 exit node = 沒有未完成的 fallback,清旗標
  exit 0                                     # 一切正常,安靜離開
fi

# 出口不對(空白 或 等於 WAN IP=沒走出去)-> 分級恢復
log "FAIL: 出口異常 (出口='$OUT' 期望='$(expect_exit_ip)') -> 重設 exit node"
apply_exit
sleep 4
if check_egress; then
  log "RECOVERED: 重設 exit node 後出口恢復 ($OUT)"
  notify "✅ Tailscale exit node 自癒成功(重設 exit node),出口已恢復走 $OUT"
  remember_exit
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
  notify "✅ Tailscale exit node 自癒成功(重啟 tailscaled),出口已恢復走 $OUT"
  remember_exit
else
  log "ERROR: 自動恢復失敗,出口='$OUT' 期望='$(expect_exit_ip)'"
  if [ "$FALLBACK_TO_WAN" = "1" ]; then
    # 救不回 -> 清掉 exit node,讓 LAN 改走家用 WAN 保上網(犧牲「不漏明路」)
    # ★清除前先記住當前 exit node IP(此時 ExitNodeID 還在),供恢復後自動切回
    remember_exit
    touch "$FALLBACK_FLAG"                    # 留旗標:標記「這是 watchdog 清的」→ 之後可自動切回
    log "FALLBACK: 清除 exit node,LAN 改走 WAN 以維持上網"
    tailscale set --exit-node= >/dev/null 2>&1
    sleep 3
    NEWOUT=$(curl -4 -sS -m 12 "https://$PROBE_HOST" 2>/dev/null)
    log "FALLBACK done: 現出口='${NEWOUT:-無}'(走 WAN)"
    notify_fail "⚠️ Tailscale exit node 救不回,已 fallback 改走家用 WAN(出口='${NEWOUT:-無}')。網路維持但未走 exit node;恢復後 watchdog 會自動切回。"
  else
    notify_fail "🛑 Tailscale exit node 自癒失敗,需人工介入!出口='${OUT:-無}' 期望='$(expect_exit_ip)'"
  fi
fi
exit 0
