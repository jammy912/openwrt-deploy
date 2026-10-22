#!/bin/sh
# wan6 flap 蒐證器 (2026-10-22, 暫時性: 查到根因就該移除)
#
# 目的: 抓「netifd 為什麼對 wan6 進入無限 retry loop」的現場證據。
#
# ★ 為什麼改成數 flap 不數 odhcp6c 行程(2026-10-22 修正):
#   第一版監看「odhcp6c 行程數 > 1」, 但那是誤判 —— odhcp6c 每次收到
#   上游 RA/DHCPv6 更新都會 fork 自己去跑 /lib/netifd/dhcpv6.script,
#   子行程 exec 前名字還是 odhcp6c, 所以 pidof 會短暫看到 2 個。
#   實測 17:01~17:05 四分鐘內「抓到」7 次, 全是正常 fork
#   (父子關係可證: 第二個的 PPID 指向第一個)。
#   真正的故障指標是 flap 頻率: 正常 0 次/分, 發作時 300+ 次/分。
#
# 設計:
#   - 常駐 loop 不用 cron: cron 最快 1 分鐘, 而 log_size 只有 128KB
#     (實測僅涵蓋 ~58 分鐘), 事後回看一定已被洗掉。
#   - 只讀不改: 絕不 kill、絕不動 wan6。自癒是 watchdog 的事。
#   - 快照寫 /tmp (tmpfs) 避免燒 flash; 發生時推播叫人來看。
#   - 門檻 5 比 watchdog 的 10 低: 蒐證要比自癒更早動作, 才抓得到
#     「剛開始 flap」的前因; watchdog 晚一點動手才不會誤觸發。

CATCH_DIR="/tmp/wan6-flap-catch"
INTERVAL=10
THRESHOLD=5
ARMED=1          # 1=可觸發, 0=已觸發過等恢復 (避免同一次事件連環存檔)

. /etc/myscript/push-notify.inc 2>/dev/null
PUSH_NAMES="admin"

log() { logger -t catch-wan6flap "$1"; }

# 單一實例保護: PID 檔 + 驗活
# ⚠️ 不能用 pidof <腳本名>: busybox 的 ps 顯示成 {catch-odhcp6c.s}(截斷),
#   pidof 認不出來 —— 2026-10-22 實測第一版就是這樣失守, 跑出兩個實例。
# ⚠️ 也不能只看 PID 檔存在: 上次被 kill 或重開會留下陳舊 PID。
PID_F="/tmp/.catch-wan6flap.pid"
if [ -f "$PID_F" ]; then
    _old=$(cat "$PID_F" 2>/dev/null)
    case "$_old" in ''|*[!0-9]*) _old="" ;; esac
    if [ -n "$_old" ] && [ -d "/proc/$_old" ]; then
        case "$(tr '\0' ' ' < /proc/$_old/cmdline 2>/dev/null)" in
            *catch-odhcp6c*) log "已有實例在跑(PID $_old), 退出"; exit 0 ;;
        esac
    fi
fi
echo $$ > "$PID_F"
trap 'rm -f "$PID_F" 2>/dev/null' EXIT

mkdir -p "$CATCH_DIR" 2>/dev/null
log "開始監看 wan6 flap (每 ${INTERVAL}s, 門檻 ${THRESHOLD} 次/分, 只蒐證不處理)"

# 近 60 秒內 wan6 進入 setting up 的次數
flapcnt() {
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

snapshot() {
    _n="$1"
    _ts=$(date +%Y%m%d-%H%M%S)
    _f="$CATCH_DIR/catch-$_ts.log"
    {
        echo "=== wan6 flap ${_n} 次/分: $(date) ==="
        echo ""
        echo "[loadavg]"
        cat /proc/loadavg
        echo ""
        echo "[★ 關鍵: netifd 啟動時間 —— 若剛重啟, 兇手是重啟它的人]"
        _nf=$(pidof netifd)
        echo "netifd PID=$_nf 啟動=$(ls -ld /proc/$_nf 2>/dev/null | awk '{print $6,$7,$8}')"
        echo ""
        echo "[odhcp6c 行程樹(父子關係: 子行程是正常 fork, 不是故障)]"
        for _p in $(pidof odhcp6c 2>/dev/null); do
            _pp=$(awk '{print $4}' /proc/$_p/stat 2>/dev/null)
            echo "PID=$_p PPID=$_pp 啟動=$(ls -ld /proc/$_p 2>/dev/null | awk '{print $6,$7,$8}')"
            echo "  父: $(tr '\0' ' ' < /proc/$_pp/cmdline 2>/dev/null)"
        done
        echo ""
        echo "[當下在跑的可疑腳本: 誰動了網路]"
        ps w | grep -E "[s]ync-googleconfig|[a]uto-role|[n]etwork (reload|restart)|[i]fup|[i]fdown|[d]broute|[p]br|[c]heck-" || echo "(無)"
        echo ""
        echo "[wan6 / wan 狀態]"
        ifstatus wan6 2>/dev/null
        echo "--- wan ---"
        ifstatus wan 2>/dev/null | grep -E '"up"|"address"'
        echo ""
        echo "[eth1 IPv6 位址]"
        ip -6 addr show dev eth1 2>/dev/null | grep inet6
        echo ""
        echo "[tailscaled CPU(flap 會餵爆它)]"
        top -bn1 2>/dev/null | grep '[t]ailscaled' | head -1
        echo ""
        echo "[★ 關鍵: 完整 log 尾段 —— 看 flap 開始前一刻是誰動了網路]"
        logread | tail -120
    } > "$_f" 2>&1
    log "已存快照: $_f"
    echo "$_f"
}

while :; do
    _n=$(flapcnt)
    if [ "$_n" -ge "$THRESHOLD" ] && [ "$ARMED" = "1" ]; then
        _snap=$(snapshot "$_n")
        ARMED=0
        log "⚠️ 抓到! wan6 flap ${_n} 次/分, 快照 $_snap"
        push_notify "🔍 抓到 wan6 開始 flap 的現場 (${_n} 次/分, 正常為 0)。這是查根因用的蒐證, 不是故障推播 —— watchdog 會照常自癒。快照在 x60pro 的 ${_snap}, ⚠️ 位於 /tmp 重開機就消失, 請盡快告訴 AI 來讀。"
    elif [ "$_n" -lt "$THRESHOLD" ] && [ "$ARMED" = "0" ]; then
        # 已恢復 → 重新上膛, 下次再發作會再抓一次
        ARMED=1
        log "flap 已回復正常 (${_n} 次/分), 重新上膛"
    fi
    sleep "$INTERVAL"
done
