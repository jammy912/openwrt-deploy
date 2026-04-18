#!/bin/sh

LOCK="/tmp/wifi-monitor.lock"

# 已有實例在跑就跳過
if [ -f "$LOCK" ]; then
    kill -0 "$(cat "$LOCK")" 2>/dev/null && exit 0
    rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# 將所有參數原樣傳遞
/etc/myscript/wifi-signal.sh "$@"
sleep 13
/etc/myscript/wifi-signal.sh "$@"
sleep 13
/etc/myscript/wifi-signal.sh "$@"
sleep 13
/etc/myscript/wifi-signal.sh "$@"
