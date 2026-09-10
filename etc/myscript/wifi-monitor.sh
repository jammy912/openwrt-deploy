#!/bin/sh
# wifi-signal.sh 的外殼: 加鎖 + 依 hostname 決定這台跑不跑。
#
# 用法: wifi-monitor.sh <23個參數給 wifi-signal> [HOST_NAME]
#   第 24 個參數 HOST_NAME 可選:
#     - 留空/不傳 = 每台都跑 (與加此功能前行為完全一致)
#     - 有值      = 只有 hostname 在清單內的機器才跑, 其他安靜跳過
#   清單支援空白、逗號、分號混用, 例如 "RAX3000Z,x60pro" 或 "RAX3000Z; AX3000T"
#   比對不分大小寫 (與 sync-googleconfig.sh 的 hostname 比對同慣例)。
#
# ⚠️ wifi-signal.sh 只吃前 23 個參數(實查: 最後用到的是第 23 個 DEBUG_PUSH,
#    沒有 shift 到更後面, 也沒有 SSID 清單那種吃可變長度尾巴的設計)。
#    故第 24 個是安全的固定位置, 但轉發時「必須把它拿掉」—— 雖然現行
#    wifi-signal 會忽略多餘參數, 留著就等於預設它永遠不會用到第 24 個。

LOCK="/tmp/wifi-monitor.lock"

# 已有實例在跑就跳過
if [ -f "$LOCK" ]; then
    kill -0 "$(cat "$LOCK")" 2>/dev/null && exit 0
    rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# ---- 第 24 個參數: 限定只在指定 hostname 上執行 ----
# ⚠️ 這支 cron 由 Google Sheet 下發給整個機隊, 不符的機器要「安靜」跳過:
#    不 log 不推播, 否則每分鐘一筆噪音會洗掉 log buffer(只有 128KB)。
if [ $# -ge 24 ]; then
    # 取第 24 個參數(busybox ash 沒有陣列, 用 shift 取)
    _HOST_FILTER=$(shift 23; echo "$1")
    if [ -n "$_HOST_FILTER" ]; then
        _MY_HOST=$(uci get system.@system[0].hostname 2>/dev/null)
        [ -z "$_MY_HOST" ] && _MY_HOST=$(cat /proc/sys/kernel/hostname 2>/dev/null)
        # 逗號/分號一律轉成空白後逐一比對(不分大小寫)
        _MY_LC=$(echo "$_MY_HOST" | tr 'A-Z' 'a-z')
        _MATCH=0
        for _h in $(echo "$_HOST_FILTER" | tr ',;' '  '); do
            [ "$(echo "$_h" | tr 'A-Z' 'a-z')" = "$_MY_LC" ] && { _MATCH=1; break; }
        done
        [ "$_MATCH" = "0" ] && exit 0
    fi
    # 轉發時去掉第 24 個(HOST_NAME 不是 wifi-signal 的參數)
    set -- "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" \
           "${13}" "${14}" "${15}" "${16}" "${17}" "${18}" "${19}" "${20}" \
           "${21}" "${22}" "${23}"
fi

# 將參數原樣傳遞
/etc/myscript/wifi-signal.sh "$@"
