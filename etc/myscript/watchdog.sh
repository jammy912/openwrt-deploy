#!/bin/sh

# 网络连接监控脚本
# 监控三个关键DNS服务器的连通性
# 如果三个IP都无法ping通，则自动重启路由器

# 引入通知器
. /etc/myscript/push_notify.inc
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
        # 三个IP都失败 - 准备重启
        log "⚠️ 警告：所有IP都无法连接！"
        log "⚠️ 网络完全中断，准备重启路由器..."
        push_notify "⚠️ 网络完全中断！所有DNS无法连接，路由器即将重启"

        # 等待5秒，确保通知发送和日志写入
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
