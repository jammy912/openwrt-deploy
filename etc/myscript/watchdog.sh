#!/bin/sh

# 网络连接监控脚本
# 监控三个关键DNS服务器的连通性
# 如果三个IP都无法ping通，则自动重启路由器

# 全域 cron 排隊鎖
. /etc/myscript/lock-handler.sh
cron_global_lock 60 || exit 0
trap 'rm -f /tmp/cron_global.lock' EXIT

# 引入通知器
. /etc/myscript/push-notify.inc
PUSH_NAMES="admin" # 多人用分號分隔，例如 "admin;ann"

# 定义要监控的IP地址
IP1="1.1.1.1"       # Cloudflare DNS
IP2="8.8.8.8"       # Google DNS
IP3="168.95.1.1"    # Taiwan HiNet DNS

# Ping超时时间（秒）
TIMEOUT=5

# 日志函数
log() {
    echo "$1"
    logger -t network-watchdog "$1"
}

# 检查单个IP是否可达
check_ip() {
    local ip="$1"
    if ping -c 2 -W "$TIMEOUT" "$ip" >/dev/null 2>&1; then
        return 0  # 成功
    else
        return 1  # 失败
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

# 主逻辑
log "开始网络连接检查..."

# 检查三个IP
check_ip "$IP1"
result1=$?

check_ip "$IP2"
result2=$?

check_ip "$IP3"
result3=$?

# 统计失败的IP
failed_ips=""
failed_count=0

if [ $result1 -ne 0 ]; then
    log "⚠️ $IP1 连接失败"
    failed_ips="${failed_ips}${IP1} "
    failed_count=$((failed_count + 1))
else
    log "✅ $IP1 连接正常"
fi

if [ $result2 -ne 0 ]; then
    log "⚠️ $IP2 连接失败"
    failed_ips="${failed_ips}${IP2} "
    failed_count=$((failed_count + 1))
else
    log "✅ $IP2 连接正常"
fi

if [ $result3 -ne 0 ]; then
    log "⚠️ $IP3 连接失败"
    failed_ips="${failed_ips}${IP3} "
    failed_count=$((failed_count + 1))
else
    log "✅ $IP3 连接正常"
fi

# 如果有任何IP失败，发送通知
if [ $failed_count -gt 0 ]; then
    if [ $failed_count -eq 3 ]; then
        # 三个IP都失败 - 先等 30 秒再驗一次，避免瞬斷誤判
        log "⚠️ 所有 IP 都失败，30 秒后重试确认..."
        push_notify "⚠️ 网络异常：全部 DNS 失败，30秒后重试"
        sleep 30
        if check_ip "$IP1" || check_ip "$IP2" || check_ip "$IP3"; then
            log "✅ 重试后至少一个恢复，取消重启"
            push_notify "⚠️ 网络短暂中断但已恢复，未重启"
            exit 0
        fi
        log "⚠️ 重试仍全失败，执行重启..."
        # 收集重開前網路診斷 (LAN/WAN gw/外網/traceroute)
        NETDIAG_LOG="/tmp/watchdog-netdiag-$(date +%Y%m%d-%H%M%S).log"
        NETDIAG_SUMMARY=$(collect_netdiag "$NETDIAG_LOG")
        log "netdiag: $NETDIAG_SUMMARY"
        log "完整診斷 → $NETDIAG_LOG"
        # 網路已斷，即時 push 幾乎必失敗 → 寫 queue 讓開機後補送
        queue_push "reboot-watchdog" "all-dns-down" "failed=${failed_ips}| ${NETDIAG_SUMMARY}"

        # 額外推一筆 snapshot 關鍵段 (route + wg handshakes + batctl n),
        # 控制長度避免被通知服務截斷
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
            sec!="" {print}
        ' "$NETDIAG_LOG" | head -c 800)
        queue_push "reboot-snapshot-tail" "" "$SNAP_TAIL"

        sleep 5
        log "🔄 执行重启..."
        reboot
    else
        # 部分IP失败 - 仅通知
        log "⚠️ 有 ${failed_count} 个IP无法连接：${failed_ips}"
        push_notify "⚠️ 网络异常：${failed_ips}无法连接 (${failed_count}/3)"
    fi
else
    log "✅ 网络监控正常，所有DNS都可达"
fi

exit 0
