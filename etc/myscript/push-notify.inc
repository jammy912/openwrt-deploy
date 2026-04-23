

#!/bin/sh
# push-notify.inc - 多通道通知模組 (PushDeer + LINE Notify)
# 放置位置：/etc/myscript/push-notify.inc

# 通知服務設定
# 代號對應 /etc/myscript/.secrets/pushkey.<代號> 檔案
# 多個代號用分號分隔，例如 PUSH_NAMES="admin;ann"
# 由呼叫端在 source 後設定 PUSH_NAMES
PUSH_NAMES="${PUSH_NAMES:-}"

# 自動取得主機名稱（若無則 fallback hostname 指令）
HOSTNAME="[$(uci get system.@system[0].hostname 2>/dev/null || hostname)]"


# -----------------------------
# 函數：push_notify <文字訊息>
# -----------------------------
push_notify() {
    local msg="$1"
    [ -z "$msg" ] && return 0

    # 根據 PUSH_NAMES 讀取對應的 key 檔案
    local PUSH_KEYS=""
    local IFS_BAK="$IFS"; IFS=";"
    for _pname in $PUSH_NAMES; do
        local _pkey=$(cat "/etc/myscript/.secrets/pushkey.${_pname}" 2>/dev/null)
        [ -n "$_pkey" ] && PUSH_KEYS="$PUSH_KEYS $_pkey"
    done
    IFS="$IFS_BAK"
    PUSH_KEYS=$(echo "$PUSH_KEYS" | sed 's/^ //')

    [ -z "$PUSH_KEYS" ] && { echo "[WARN] PUSH_NAMES 未設定或找不到對應 key 檔案" >&2; return 1; }

    local key
    local full_msg="${HOSTNAME}$msg"

    # 支援逗號、分號或空白分隔的多個 key
    local _keys_norm="${PUSH_KEYS//,/ }"
    _keys_norm="${_keys_norm//;/ }"
    for key in $_keys_norm; do
        # PushDeer key 偵測 (以 PD 開頭)
        if echo "$key" | grep -qE '^PD'; then
            curl -s --connect-timeout 5 --max-time 10 \
                -G "https://api2.pushdeer.com/message/push" \
                --data-urlencode "pushkey=${key}" \
                --data-urlencode "type=text" \
                --data-urlencode "text=${full_msg}" \
                >/dev/null 2>&1

        # LINE Notify Token 偵測 (40 字元以上)
        elif echo "$key" | grep -qE '^[0-9A-Za-z]{40,}$'; then
            curl -s --connect-timeout 5 --max-time 10 \
                -H "Authorization: Bearer ${key}" \
                -F "message=${full_msg}" \
                "https://notify-api.line.me/api/notify" \
                >/dev/null 2>&1

        else
            echo "[WARN] 未知通知 Key 格式: $key" >&2
        fi
    done
}


# -----------------------------
# 函數：queue_push <event> [reason] [detail]
#   在 reboot / 無網路情境下，把訊息寫成 JSON 檔進 .pushqueue/，
#   開機後由 push-queue.sh 逐筆送出後刪除。
#   JSON 欄位: ts / ts_iso / host / event / reason / detail
# -----------------------------
PUSH_QUEUE_DIR="${PUSH_QUEUE_DIR:-/etc/myscript/.pushqueue}"

queue_push() {
    local event="$1"
    local reason="$2"
    local detail="$3"
    [ -z "$event" ] && return 0

    mkdir -p "$PUSH_QUEUE_DIR" 2>/dev/null

    local ts ts_iso host fname tmp
    ts=$(date +%s)
    ts_iso=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
    host=$(uci get system.@system[0].hostname 2>/dev/null || hostname)
    fname="${PUSH_QUEUE_DIR}/$(date +%Y%m%d-%H%M%S)-$$-${event}.json"
    tmp="${fname}.tmp"

    # JSON 字串跳脫：反斜線、雙引號、換行
    _jesc() {
        printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
            | awk 'BEGIN{ORS=""} {if(NR>1)print "\\n"; print}'
    }

    {
        printf '{'
        printf '"ts":%s,'          "$ts"
        printf '"ts_iso":"%s",'    "$(_jesc "$ts_iso")"
        printf '"host":"%s",'      "$(_jesc "$host")"
        printf '"event":"%s",'     "$(_jesc "$event")"
        printf '"reason":"%s",'    "$(_jesc "$reason")"
        printf '"detail":"%s"'     "$(_jesc "$detail")"
        printf '}\n'
    } > "$tmp" && mv "$tmp" "$fname"

    sync 2>/dev/null
    echo "$fname"
}

