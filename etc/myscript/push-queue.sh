#!/bin/sh
# push-queue.sh - 開機後穩定時，將 .pushqueue/ 內的 JSON 事件逐一推播給 admin
# 放置位置：/etc/myscript/push-queue.sh
# 用法：
#   /etc/myscript/push-queue.sh            # 一般模式：等網路穩定後送出
#   /etc/myscript/push-queue.sh --now      # 跳過等待，立即嘗試送出
#   /etc/myscript/push-queue.sh --list     # 列出目前 queue 內檔案
#   /etc/myscript/push-queue.sh --purge    # 清空 queue (debug 用)

. /etc/myscript/push-notify.inc
PUSH_NAMES="admin"     # 多人用分號分隔，例如 "admin;ann"

QUEUE_DIR="${PUSH_QUEUE_DIR:-/etc/myscript/.pushqueue}"
LOCK_FILE="/tmp/push-queue.lock"
LOG_TAG="push-queue"

# 穩定性判斷參數
BOOT_WAIT_MIN_UP=60          # 開機後至少等 uptime >= 60 秒才開始
NET_CHECK_IPS="1.1.1.1 8.8.8.8 168.95.1.1"
NET_CHECK_TIMEOUT=3
NET_STABLE_RETRY=30          # 最多重試幾次
NET_STABLE_INTERVAL=10       # 每次間隔秒數
SEND_INTERVAL=1              # 每則訊息之間的間隔

log() {
    echo "$1"
    logger -t "$LOG_TAG" "$1"
}

# 避免重入
acquire_lock() {
    if [ -e "$LOCK_FILE" ]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log "另一個 push-queue 實例仍在執行 (pid=$pid)，離開"
            exit 0
        fi
    fi
    echo $$ > "$LOCK_FILE"
}
release_lock() { rm -f "$LOCK_FILE"; }
trap 'release_lock' EXIT INT TERM

# 從 JSON 取單一欄位值 (簡易版：只處理字串/數字)
json_field() {
    local file="$1" key="$2"
    sed -n "s/.*\"${key}\":\"\\([^\"]*\\)\".*/\\1/p; s/.*\"${key}\":\\([0-9]\\+\\).*/\\1/p" "$file" | head -1
}

# 等 uptime 達標
wait_boot_stable() {
    local up
    while :; do
        up=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
        [ -z "$up" ] && up=0
        [ "$up" -ge "$BOOT_WAIT_MIN_UP" ] && return 0
        sleep 5
    done
}

# 任一 IP 通即視為網路就緒
net_ready() {
    local ip
    for ip in $NET_CHECK_IPS; do
        if ping -c 1 -W "$NET_CHECK_TIMEOUT" "$ip" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

wait_net_stable() {
    local i=0
    while [ $i -lt $NET_STABLE_RETRY ]; do
        if net_ready; then
            log "網路就緒"
            return 0
        fi
        i=$((i + 1))
        sleep $NET_STABLE_INTERVAL
    done
    log "等待網路逾時 ($((NET_STABLE_RETRY * NET_STABLE_INTERVAL))s)，放棄本次推送"
    return 1
}

# 送出單筆：成功 return 0 並刪檔；失敗保留
send_one() {
    local f="$1"
    [ -f "$f" ] || return 0

    local ts_iso event reason detail msg
    ts_iso=$(json_field "$f" ts_iso)
    event=$(json_field "$f"  event)
    reason=$(json_field "$f" reason)
    detail=$(json_field "$f" detail)

    msg="📮 ${event}"
    [ -n "$reason" ] && msg="${msg} | ${reason}"
    [ -n "$detail" ] && msg="${msg} | ${detail}"
    [ -n "$ts_iso" ] && msg="${msg} @ ${ts_iso}"

    # 送出前再驗一次網路
    if ! net_ready; then
        log "送出前網路中斷，保留: $(basename "$f")"
        return 1
    fi

    # 先驗 PUSH_KEYS 是否有內容 (ash 的 function return code 不可靠，
    # push_notify 在 curl 成功送出後有時仍回傳非 0，會造成永遠刪不掉)
    local _probe_keys=""
    local _old_ifs="$IFS"; IFS=";"
    for _pn in $PUSH_NAMES; do
        [ -s "/etc/myscript/.secrets/pushkey.${_pn}" ] && _probe_keys="y"
    done
    IFS="$_old_ifs"
    if [ -z "$_probe_keys" ]; then
        log "PUSH_NAMES='${PUSH_NAMES}' 無對應 pushkey 檔，保留: $(basename "$f")"
        return 1
    fi

    push_notify "$msg"
    log "已送出並刪除: $(basename "$f")"
    rm -f "$f"
    return 0
}

process_queue() {
    ls "$QUEUE_DIR"/*.json >/dev/null 2>&1 || {
        log "queue 無待送項目"
        return 0
    }

    local f sent=0 failed=0
    for f in $(ls "$QUEUE_DIR"/*.json 2>/dev/null | sort); do
        if send_one "$f"; then
            sent=$((sent + 1))
            sleep $SEND_INTERVAL
        else
            failed=$((failed + 1))
            net_ready || break
        fi
    done
    log "完成：送出 ${sent} 筆，保留 ${failed} 筆"
}

# ---- main ----
mkdir -p "$QUEUE_DIR"

case "$1" in
    --list)
        ls -la "$QUEUE_DIR"/*.json 2>/dev/null || echo "(空)"
        exit 0
        ;;
    --purge)
        rm -f "$QUEUE_DIR"/*.json
        log "queue 已清空"
        exit 0
        ;;
    --now)
        acquire_lock
        process_queue
        ;;
    *)
        acquire_lock
        log "等待開機穩定 (uptime >= ${BOOT_WAIT_MIN_UP}s)..."
        wait_boot_stable
        log "等待網路就緒..."
        wait_net_stable || exit 0
        process_queue
        ;;
esac

exit 0
