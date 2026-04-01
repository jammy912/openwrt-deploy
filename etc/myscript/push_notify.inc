

#!/bin/sh
# push_notify.inc - 多通道通知模組 (PushDeer + LINE Notify)
# 放置位置：/etc/myscript/push_notify.inc

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

	urlencode() {
		local s="$1"
		local o=""
		local i c
		i=1
		while [ $i -le ${#s} ]; do
			c=$(echo "$s" | cut -c $i)
			case "$c" in
				[a-zA-Z0-9.~_-]) o="${o}${c}" ;;
				' ') o="${o}+" ;;
				*) 
					# 轉成 %XX
					o="${o}$(printf '%%%02X' "'$c")"
					;;
			esac
			i=$((i+1))
		done
		echo "$o"
	}

    local key
    local full_msg="$(urlencode "${HOSTNAME}$msg")"

    # 支援逗號或空白分隔的多個 key
    for key in ${PUSH_KEYS//,/ }; do
        # PushDeer key 偵測 (以 PD 開頭)
        if echo "$key" | grep -qE '^PD'; then
            echo "https://api2.pushdeer.com/message/push?pushkey=${key}&type=text&text=${full_msg}"
            curl --connect-timeout 5 --max-time 10 \
                "https://api2.pushdeer.com/message/push?pushkey=${key}&type=text&text=${full_msg}" \
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

