#!/bin/sh

# 網路連線監控腳本
# 監控三個關鍵 DNS 伺服器的連通性
# 如果三個 IP 都無法 ping 通，則自動重啟路由器

# 全域 cron 排隊鎖
. /etc/myscript/lock-handler.sh
cron_global_lock 60 || exit 0
trap 'rm -f /tmp/cron_global.lock' EXIT

# 引入通知器
. /etc/myscript/push-notify.inc
PUSH_NAMES="admin" # 多人用分號分隔，例如 "admin;ann"

# 定義要監控的 IP 位址
IP1="1.1.1.1"       # Cloudflare DNS
IP2="8.8.8.8"       # Google DNS
IP3="168.95.1.1"    # Taiwan HiNet DNS

# Ping 逾時時間（秒）
TIMEOUT=5

# 連續重啟計數檔 (持久, 跨 reboot 保留 → 放 /etc/myscript 不放 /tmp)
# 連續 reboot 自己達此次數仍斷網 → 改打上層 Hitron 分享器 (自己重開沒救=問題在上游)
REBOOT_COUNT_FILE="/etc/myscript/.reboot_count"
HITRON_THRESHOLD=3

# 升級重開 Hitron 後的冷卻檔 (存「暫停截止 epoch」; 持久, 跨 reboot 保留)
# 自己連重開 3 次 + 重開上層都做了仍斷網 → 再重試無意義, 冷卻期內跳過連網檢查
HITRON_PAUSE_FILE="/etc/myscript/.hitron_pause_until"
HITRON_PAUSE_SEC=14400  # 4 小時

# 日誌函式
log() {
    echo "$1"
    logger -t network-watchdog "$1"
}

# 檢查單個 IP 是否可達
check_ip() {
    local ip="$1"
    if ping -c 2 -W "$TIMEOUT" "$ip" >/dev/null 2>&1; then
        return 0  # 成功
    else
        return 1  # 失敗
    fi
}

# 收集重開前網路診斷資訊
# 輸出：/tmp/watchdog-netdiag-<ts>.log  (reboot 後仍可能殘留可查)
# 回傳：stdout 為精簡單行摘要 (供 queue_push detail 用)
#
# 角色判斷：
#   gateway/hybrid-gw 節點：default route 從實體 wan 出 → 診斷 WAN gw/ext
#   client/mesh 節點    ：default route 走 br-lan (上游為 mesh gw) → 診斷 mesh gw
collect_netdiag() {
    local out="$1"
    local self_ip def_gw def_if role
    self_ip=$(uci get network.lan.ipaddr 2>/dev/null)
    def_gw=$(ip -4 route show default | awk '/^default/ && $5!~/^wg/ {print $3; exit}')
    def_if=$(ip -4 route show default | awk '/^default/ && $5!~/^wg/ {print $5; exit}')

    # 若 default 從 br-lan 出 = client 節點，WAN 對它來說就是上游 mesh gw
    case "$def_if" in
        br-lan|br-*) role="client" ;;
        wan|eth*|wwan*) role="gateway" ;;
        *) role="unknown" ;;
    esac

    # client 細化探點 (供 detail 摘要用)
    local bat_n_count="" mesh_sta_count="" lan_gw_loss=""
    if [ "$role" = "client" ]; then
        bat_n_count=$(batctl n 2>/dev/null | awk 'NR>2 && NF>0' | wc -l)
        for _msh in mesh0 mesh1 mesh2; do
            ip link show "$_msh" >/dev/null 2>&1 || continue
            local _c
            _c=$(iw dev "$_msh" station dump 2>/dev/null | grep -c '^Station')
            mesh_sta_count="${mesh_sta_count}${_msh}=${_c} "
        done
        if [ -n "$def_gw" ]; then
            lan_gw_loss=$(ping -c 2 -W 2 "$def_gw" 2>&1 | awk '/packet loss/{sub(/.*received, /,"");sub(/ packet.*/,"");print;exit}')
        fi
    fi

    {
        echo "=== watchdog netdiag @ $(date -Iseconds 2>/dev/null || date) ==="
        echo "[role]      $role (def_if=$def_if def_gw=$def_gw self=$self_ip)"
        echo "[uptime]    $(uptime)"
        echo "[loadavg]   $(cat /proc/loadavg)"
        echo "[routes]"
        ip -4 route show default
        echo
        echo "[ip rule]"
        ip rule show 2>&1
        echo
        echo "[ifstatus wan]"
        ifstatus wan 2>&1 | head -40
        echo "[ifstatus wan6]"
        ifstatus wan6 2>&1 | head -20
        echo
        echo "[wg peers]"
        wg show all latest-handshakes 2>&1
        wg show all endpoints 2>&1
        echo
        if command -v batctl >/dev/null 2>&1; then
            echo "[batctl n (鄰居)]"
            batctl n 2>&1
            echo "[batctl o (originators, top 20)]"
            batctl o 2>&1 | head -22
            echo
        fi
        if [ "$role" = "client" ]; then
            echo "[client 細化]"
            echo "  bat_n_count   = $bat_n_count"
            echo "  mesh_sta      = $mesh_sta_count"
            echo "  lan_gw_loss   = $lan_gw_loss"
            echo
        fi
        echo "[ping default gw $def_gw]"
        if [ -n "$def_gw" ]; then
            ping -c 2 -W 2 "$def_gw" 2>&1
        else
            echo "(無 default gateway — 路由表異常)"
        fi
        echo "[ping 8.8.8.8 via $def_if]"
        if [ -n "$def_if" ]; then
            ping -c 2 -W 2 -I "$def_if" 8.8.8.8 2>&1
        else
            ping -c 2 -W 2 8.8.8.8 2>&1
        fi
        echo "[traceroute 8.8.8.8 (max 12 hop, 2s)]"
        traceroute -n -w 2 -q 1 -m 12 8.8.8.8 2>&1
        echo
        echo "[logread tail -100]"
        logread 2>&1 | tail -100
        echo "=== end ==="
    } >"$out" 2>&1

    # 同步寫一份「最後 snapshot」固定路徑;reboot 後仍可查
    cp -f "$out" /etc/myscript/.last_reboot_snapshot.log 2>/dev/null
    sync 2>/dev/null

    # 精簡摘要：default gw loss% + 外網 loss% + traceroute 最後有效 hop
    local gw_loss ext_loss tr_last
    gw_loss=$(awk '
        /^\[ping default gw/ {flag=1; next}
        /^\[ping 8.8.8.8/    {flag=0}
        flag && /packet loss/ {sub(/.*received, /,""); sub(/ packet.*/,""); print; exit}
    ' "$out")
    ext_loss=$(awk '
        /^\[ping 8.8.8.8/ {flag=1; next}
        /^\[traceroute/   {flag=0}
        flag && /packet loss/ {sub(/.*received, /,""); sub(/ packet.*/,""); print; exit}
    ' "$out")
    # traceroute 區塊內，hop 行格式：" N  X.X.X.X  ..."；超時則 "*"。只抓有 IP 的最後一跳。
    tr_last=$(awk '
        /^\[traceroute/ {flag=1; next}
        /^=== end ===/  {flag=0}
        flag && /^ *[0-9]+ +[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {hop=$1; ip=$2}
        END{if(hop) print hop" "ip; else print "none"}
    ' "$out")

    if [ "$role" = "client" ]; then
        printf 'role=%s def_if=%s gw=%s(loss=%s) ext=8.8.8.8(loss=%s) tr_last=%s bat_n=%s mesh=%slan_gw=%s' \
            "$role" "$def_if" \
            "$def_gw" "${gw_loss:-NA}" \
            "${ext_loss:-NA}" \
            "${tr_last:-NA}" \
            "${bat_n_count:-NA}" \
            "${mesh_sta_count:-NA }" \
            "${lan_gw_loss:-NA}"
    else
        printf 'role=%s def_if=%s gw=%s(loss=%s) ext=8.8.8.8(loss=%s) tr_last=%s' \
            "$role" "$def_if" \
            "$def_gw" "${gw_loss:-NA}" \
            "${ext_loss:-NA}" \
            "${tr_last:-NA}"
    fi
}

# === wan6 無限 flap 自癒 (2026-10-22) ===
# ★ 真兇與誤判史(重要, 別再走回頭路):
#   早上 load 7.95 / idle 13% / 1088 threads 的災難是真的, 機制是:
#     netifd 對 wan6 無限 retry("Invalid argument") → 每秒 down/up 5~6 次
#     → 每次都丟 RTM_NEWROUTE/DELROUTE → tailscaled 的 network monitor
#       被餵到吃滿一顆核 → 連鎖觸發 firewall reload → 堆積 235 個
#       dnsmasq restart 行程。
#     restart wan6 實測有效(idle 13%→84%, tailscaled 44%→4%)。
#
#   ⚠️ 但第一版用「odhcp6c 行程數 > 1」當觸發條件是錯的 ——
#     odhcp6c 每次收到上游 RA/DHCPv6 更新, 會 fork 自己去執行
#     /lib/netifd/dhcpv6.script(該檔開頭就寫 "should be run by odhcpc6c")。
#     fork 出來的子行程在 exec 成 shell 前, /proc 裡的名字還是 odhcp6c,
#     所以 pidof 會「短暫」看到 2 個 —— 這是完全正常的行為。
#     實測 2026-10-22 17:01~17:05 四分鐘內出現 7 次, 每次存活僅數秒
#     (父子關係可證: PPID 指向另一個 odhcp6c)。
#     後果: 舊版會在正常 fork 的瞬間誤觸發, 平白無故 restart WAN6。
#     10:28 與 16:49 那兩次「成功自癒」極可能根本沒病。
#
# ★ 正確的故障指標是 flap 頻率, 不是行程數:
#     正常   = 近 60 秒 0 次  (實測)
#     發作時 = 每秒 5~6 次 → 一分鐘 300+ 次 (實測)
#   區分度極高, 門檻取 10 不可能誤判。
# ⚠️ 擺在 Load 警告之前: 這是 load 高的已知成因, 先修因,
#   避免被下面 load>=12 的規則直接 reboot 掉。
_W6_COOL="/tmp/.wan6_flap_fix_until"
# 數「近 60 秒內」wan6 進入 setting up 的次數
_w6_flapcnt() {
    _ns=$(date +%H:%M:%S | awk -F: '{print $1*3600+$2*60+$3}')
    logread 2>/dev/null | grep "wan6' is setting up" | awk -v now="$_ns" '
    {
        split($4, t, ":")
        s = t[1]*3600 + t[2]*60 + t[3]
        age = now - s
        if (age < 0) age += 86400
        if (age <= 60) n++
    }
    END { print n+0 }'
}
_W6_FLAP=$(_w6_flapcnt)
if [ "$_W6_FLAP" -gt 10 ]; then
    _w6_now=$(date +%s)
    _w6_until=$(cat "$_W6_COOL" 2>/dev/null)
    case "$_w6_until" in ''|*[!0-9]*) _w6_until=0 ;; esac
    if [ "$_w6_now" -lt "$_w6_until" ]; then
        log "⚠️ wan6 近 60 秒 flap ${_W6_FLAP} 次, 但冷卻中 (剩 $(( (_w6_until - _w6_now) / 60 )) 分), 不重複處理"
    else
        _w6_load_before=$(awk '{print $1, $2, $3}' /proc/loadavg)
        log "⚠️ wan6 近 60 秒 flap ${_W6_FLAP} 次(門檻 10) → netifd retry loop, 執行 restart wan6 自癒"
        # 動手前先推: restart 會動到 WAN 介面, 即使後續卡住也要留紀錄
        push_notify "🔧 watchdog 偵測到 wan6 無限 flap: 近 60 秒 ${_W6_FLAP} 次(正常為 0) —— 這會害 tailscaled 吃滿一顆核、堆積大量 dnsmasq restart。現在開始 restart wan6 自癒(約 20 秒)。load(1m/5m/15m)=${_w6_load_before}"
        # 冷卻先寫: 萬一卡死或機器重開, 醒來不會立刻再衝一次
        echo $(( _w6_now + 1800 )) > "$_W6_COOL"
        ifdown wan6 2>/dev/null
        sleep 5
        # 清殘留 odhcp6c 再起 —— 注意這裡是「清乾淨再起」的手段,
        # 不是把行程數當判斷依據(那是上面講的誤判)。
        killall -q odhcp6c 2>/dev/null
        sleep 2
        ifup wan6 2>/dev/null
        # 等 flap 真的停: 給 60 秒, 每 10 秒重數一次近 60 秒的 flap
        _w6_ok=0
        _w6_i=0
        while [ "$_w6_i" -lt 6 ]; do
            sleep 10
            if [ "$(_w6_flapcnt)" -le 10 ]; then _w6_ok=1; break; fi
            _w6_i=$(( _w6_i + 1 ))
        done
        _w6_after=$(_w6_flapcnt)
        _w6_load_after=$(awk '{print $1}' /proc/loadavg)
        if [ "$_w6_ok" = "1" ]; then
            log "✅ wan6 flap 已停 (近 60 秒 ${_w6_after} 次), 自癒成功"
            push_notify "✅ wan6 restart 完成: flap ${_W6_FLAP} → ${_w6_after} 次/分, 已停止。load(1m) ${_w6_load_before%% *} → ${_w6_load_after} (load 是衰減平均, 會再過幾分鐘才完全降下來)。根因(netifd 為何進入 retry loop)仍未明, 若頻繁發生請回報此訊息時間。"
        else
            log "⚠️ restart wan6 後 flap 仍有 ${_w6_after} 次/分"
            push_notify "⚠️ wan6 restart 後仍在 flap (${_w6_after} 次/分) —— 自癒無效, 需人工介入。冷卻 30 分鐘後才會再試。"
        fi
    fi
fi

# === Load 警告 / 過高自動重啟 ===
LOAD_1M=$(awk -F. '{print $1}' /proc/loadavg)
if [ "$LOAD_1M" -ge 4 ] && [ "$LOAD_1M" -lt 12 ]; then
    log "⚠️ Load 偏高 ($(cat /proc/loadavg))"
    _OOM_LOG=$(logread | grep -i -E "oom|killed" | tail -5)
    if [ -n "$_OOM_LOG" ]; then
        push_notify "⚠️ Load $(cat /proc/loadavg)
$_OOM_LOG"
    else
        push_notify "⚠️ Load 偏高 ($(cat /proc/loadavg))"
    fi
fi
if [ "$LOAD_1M" -ge 12 ]; then
    UPTIME_SEC=$(awk -F. '{print $1}' /proc/uptime)
    if [ "$UPTIME_SEC" -le 300 ]; then
        log "⚠️ Load 高但開機未滿 5 分鐘，跳過重啟"
    elif pgrep -f "check-custpkgs\|opkg\|apk add" >/dev/null 2>&1; then
        log "⚠️ Load 高但套件安裝中 ($(cat /proc/loadavg))，跳過重啟"
    else
        log "⚠️ Load 過高 ($(cat /proc/loadavg))，重啟路由器"
        # 即時 push + queue 雙保險 (load 高可能伴隨網路異常)
        push_notify "⚠️ Load 過高 ($(cat /proc/loadavg))，重啟中"
        queue_push "reboot-watchdog" "load-high" "loadavg=$(cat /proc/loadavg)"
        sleep 3
        reboot
    fi
fi

# === Hitron 升級後冷卻期: 期間內跳過連網檢查/重啟 (上面的 load 監控照常跑) ===
if [ -f "$HITRON_PAUSE_FILE" ]; then
    PAUSE_UNTIL=$(cat "$HITRON_PAUSE_FILE" 2>/dev/null)
    case "$PAUSE_UNTIL" in ''|*[!0-9]*) PAUSE_UNTIL=0 ;; esac
    NOW=$(date +%s)
    if [ "$NOW" -lt "$PAUSE_UNTIL" ]; then
        log "⏸️ Hitron 重開後冷卻中 (剩 $(( (PAUSE_UNTIL - NOW) / 60 )) 分)，跳過連網檢查"
        exit 0
    fi
    rm -f "$HITRON_PAUSE_FILE"; sync 2>/dev/null
    log "▶️ 冷卻期結束，恢復連網檢查"
fi

# === STA 備援進行中: 跳過連網檢查/重啟 ===
# ★ 實測 2026-09-26 於 MX4200: ifdown wan 後
#     22:49:02 WAN 斷
#     22:54:26 watchdog 判定所有 DNS 不通, 拍快照
#     22:58:58 reboot
#   而 STA 備援需要「連續 5 分鐘判定孤島」才觸發, 再加最多 45 秒連線 ——
#   watchdog 是 */7, 幾乎必然先重開, STA 永遠沒機會啟動完成。
#   兩者都在處理「沒網路」, 但 watchdog 的手段(reboot)會直接消滅另一邊。
# ⚠️ 只在 sta_backup_enable=1 時才跳過; 沒開這功能的機器行為完全不變。
# ⚠️ 上限 20 分鐘: 避免 STA 一直連不上時 watchdog 被永久癱瘓 ——
#   那會讓真正的斷網失去自癒能力。超過就恢復原本的檢查與重啟。
_STA_EN=$(cat /etc/myscript/.sta_backup_enable 2>/dev/null)
if [ "$_STA_EN" = "1" ]; then
    _STA_STATE=$(cat /tmp/.sta_backup_state 2>/dev/null)
    _STA_FAIL=$(cat /tmp/.sta_backup_failcnt 2>/dev/null)
    case "$_STA_FAIL" in ''|*[!0-9]*) _STA_FAIL=0 ;; esac
    # 正在累積失敗計數(備援即將啟動), 或已經啟用 → 讓它跑完
    if [ "$_STA_STATE" = "active" ] || [ "$_STA_FAIL" -gt 0 ]; then
        _STA_MARK=/tmp/.sta_backup_wd_since
        [ -f "$_STA_MARK" ] || date +%s > "$_STA_MARK"
        _since=$(cat "$_STA_MARK" 2>/dev/null)
        case "$_since" in ''|*[!0-9]*) _since=$(date +%s) ;; esac
        _elapsed=$(( $(date +%s) - _since ))
        if [ "$_elapsed" -lt 1200 ]; then
            log "⏸️ STA 備援進行中 (state=${_STA_STATE:-idle} fail=${_STA_FAIL} 已 ${_elapsed}s)，跳過連網檢查與重啟"
            exit 0
        fi
        log "▶️ STA 備援已逾 ${_elapsed}s 仍未成功，恢復 watchdog 正常檢查"
    else
        rm -f /tmp/.sta_backup_wd_since 2>/dev/null
    fi
fi
# 主邏輯
# 檢查三個 IP
check_ip "$IP1"
result1=$?

check_ip "$IP2"
result2=$?

check_ip "$IP3"
result3=$?

# 統計失敗的 IP
failed_ips=""
failed_count=0

if [ $result1 -ne 0 ]; then
    log "⚠️ $IP1 連線失敗"
    failed_ips="${failed_ips}${IP1} "
    failed_count=$((failed_count + 1))
fi

if [ $result2 -ne 0 ]; then
    log "⚠️ $IP2 連線失敗"
    failed_ips="${failed_ips}${IP2} "
    failed_count=$((failed_count + 1))
fi

if [ $result3 -ne 0 ]; then
    log "⚠️ $IP3 連線失敗"
    failed_ips="${failed_ips}${IP3} "
    failed_count=$((failed_count + 1))
fi

# 網路正常 (至少一個 IP 通) → 清零連續重啟計數 (代表上網已恢復)
if [ $failed_count -lt 3 ] && [ -f "$REBOOT_COUNT_FILE" ]; then
    rm -f "$REBOOT_COUNT_FILE"
    log "✅ 網路正常，清零連續重啟計數"
fi

# 如果有任何 IP 失敗，發送通知
if [ $failed_count -gt 0 ]; then
    if [ $failed_count -eq 3 ]; then
        # 三個 IP 都失敗 - 先等 5 分鐘再驗一次，容忍短暫斷線
        log "⚠️ 所有 IP 都失敗，5 分鐘後重試確認..."
        push_notify "⚠️ 網路異常：全部 DNS 失敗，5 分鐘後重試"
        sleep 300
        if check_ip "$IP1" || check_ip "$IP2" || check_ip "$IP3"; then
            log "✅ 重試後至少一個恢復，取消重啟"
            push_notify "⚠️ 網路短暫中斷但已恢復，未重啟"
            exit 0
        fi
        log "⚠️ 重試仍全失敗"
        # 收集重開前網路診斷 (LAN/WAN gw/外網/traceroute)
        NETDIAG_LOG="/tmp/watchdog-netdiag-$(date +%Y%m%d-%H%M%S).log"
        NETDIAG_SUMMARY=$(collect_netdiag "$NETDIAG_LOG")
        log "netdiag: $NETDIAG_SUMMARY"
        log "完整診斷 → $NETDIAG_LOG"

        # 連續重啟計數 +1 (持久檔, 上面網路恢復時會清零)
        REBOOT_N=$(cat "$REBOOT_COUNT_FILE" 2>/dev/null)
        case "$REBOOT_N" in ''|*[!0-9]*) REBOOT_N=0 ;; esac
        REBOOT_N=$((REBOOT_N + 1))
        echo "$REBOOT_N" > "$REBOOT_COUNT_FILE"; sync 2>/dev/null
        log "⚠️ 連續重啟計數 = $REBOOT_N / $HITRON_THRESHOLD"

        # 連續重啟自己已達門檻仍斷網 → 自己重開沒救, 改打上層 Hitron 分享器,
        # 這次不 reboot 自己 (等上層回來自己應恢復; 下輪再判)。
        if [ "$REBOOT_N" -ge "$HITRON_THRESHOLD" ]; then
            log "⚠️ 已連續重啟 $REBOOT_N 次仍斷網，改重開上層 Hitron 分享器"
            queue_push "reboot-watchdog" "hitron-escalate" "連續自重啟 ${REBOOT_N} 次仍斷網, 改重開上層 Hitron, watchdog 冷卻 4h| failed=${failed_ips}| ${NETDIAG_SUMMARY}"
            rm -f "$REBOOT_COUNT_FILE"; sync 2>/dev/null    # 升級打 hitron = 換策略, 計數歸零重新算
            if [ -x /etc/myscript/hitron_reboot.sh ]; then
                /etc/myscript/hitron_reboot.sh -y
            else
                log "❌ /etc/myscript/hitron_reboot.sh 不存在或不可執行"
            fi
            # 自己重開 3 次 + 打上層都試過 → 再 try 無意義, 冷卻 4h 不再檢查/重啟
            echo $(( $(date +%s) + HITRON_PAUSE_SEC )) > "$HITRON_PAUSE_FILE"; sync 2>/dev/null
            log "⏸️ 進入冷卻期 $((HITRON_PAUSE_SEC / 3600)) 小時，期間跳過連網檢查與自動重啟"
            log "ℹ️ 已下達 Hitron 重開，本輪不 reboot 自己，等上層恢復"
            exit 0
        fi

        log "🔄 準備重啟自己 (第 $REBOOT_N 次)..."
        # 網路已斷，即時 push 幾乎必失敗 → 寫 queue 讓開機後補送
        queue_push "reboot-watchdog" "all-dns-down" "failed=${failed_ips}| ${NETDIAG_SUMMARY}"

        # 額外推一筆 snapshot 關鍵段 (route + wg handshakes + batctl n),
        # 控制長度避免被通知服務截斷
        # wg 段第二欄是 peer 公鑰: 推播只留前 8 碼(足以分辨 peer, 不外洩完整金鑰;
        # 本地 NETDIAG_LOG / .last_reboot_snapshot.log 仍是完整版)
        SNAP_TAIL=$(awk '
            /^\[routes\]/        {sec="route"; print; next}
            /^\[wg peers\]/      {sec="wg";    print; next}
            /^\[batctl n/        {sec="batn";  print; next}
            /^\[ip rule\]/       {sec="";      next}
            /^\[ifstatus/        {sec="";      next}
            /^\[batctl o/        {sec="";      next}
            /^\[client 細化\]/   {sec="cli";   print; next}
            /^\[ping/            {sec="";      next}
            /^\[logread/         {sec="";      next}
            /^\[traceroute/      {sec="";      next}
            /^=== end ===/       {exit}
            sec=="wg" { if (NF >= 2) $2 = substr($2, 1, 8) ".."; print; next }
            sec!="" {print}
        ' "$NETDIAG_LOG" | head -c 800)
        queue_push "reboot-snapshot-tail" "" "$SNAP_TAIL"

        sleep 5
        log "🔄 執行重啟..."
        reboot
    else
        # 部分 IP 失敗 - 僅通知
        log "⚠️ 有 ${failed_count} 個 IP 無法連線：${failed_ips}"
        push_notify "⚠️ 網路異常：${failed_ips}無法連線 (${failed_count}/3)"
    fi
fi

exit 0
