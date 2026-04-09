#!/bin/sh
# usteer 漫遊參數設定腳本
# 用法: wifi-usteer.sh <17個參數> [ssid1] [ssid2] [ssid3]
# 後面 3 個 SSID 可選，沒傳 = 管理所有 SSID
# 若所有值與目前相同，不做任何變更也不重啟

UCI="usteer.@usteer[0]"

if [ $# -lt 17 ]; then
    echo "用法: $0 signal_diff_threshold min_connect_snr min_snr roam_scan_snr roam_trigger_snr roam_trigger_interval roam_kick_delay roam_process_timeout initial_connect_delay band_steering_interval band_steering_min_snr assoc_steering probe_steering load_kick_enabled load_kick_threshold load_kick_min_clients load_kick_delay [ssid1] [ssid2] [ssid3]"
    echo "範例: $0 10 -65 -70 -60 -70 30000 2000 5000 200 120000 -60 1 1 1 40 5 10000 Portkey IOT Test"
    exit 1
fi

# 比對目前值與傳入值是否一致
changed=0

check_val() {
    local key="$1" want="$2"
    local cur
    cur=$(uci -q get $UCI."$key")
    [ "$cur" != "$want" ] && changed=1
}

check_val signal_diff_threshold "$1"
check_val min_connect_snr "$2"
check_val min_snr "$3"
check_val roam_scan_snr "$4"
check_val roam_trigger_snr "$5"
check_val roam_trigger_interval "$6"
check_val roam_kick_delay "$7"
check_val roam_process_timeout "$8"
check_val initial_connect_delay "$9"
check_val band_steering_interval "${10}"
check_val band_steering_min_snr "${11}"
check_val assoc_steering "${12}"
check_val probe_steering "${13}"
check_val load_kick_enabled "${14}"
check_val load_kick_threshold "${15}"
check_val load_kick_min_clients "${16}"
check_val load_kick_delay "${17}"
check_val remote_node_timeout "120"

# 比對 ssid_list
cur_ssids=$(uci -q get $UCI.ssid_list | tr ' ' '\n' | sort)
new_ssids=""
if [ $# -gt 17 ]; then
    new_ssids=$(echo "$@" | cut -d' ' -f18- | tr ' ' '\n' | grep -v '^$' | sort)
fi
[ "$cur_ssids" != "$new_ssids" ] && changed=1

# 沒有異動就跳過
if [ "$changed" = "0" ]; then
    logger -t wifi-usteer "參數無異動，跳過"
    echo "⏭️ usteer 參數無異動，不需重啟"
    exit 0
fi

# 套用參數
uci set $UCI.signal_diff_threshold="$1"
uci set $UCI.min_connect_snr="$2"
uci set $UCI.min_snr="$3"
uci set $UCI.roam_scan_snr="$4"
uci set $UCI.roam_trigger_snr="$5"
uci set $UCI.roam_trigger_interval="$6"
uci set $UCI.roam_kick_delay="$7"
uci set $UCI.roam_process_timeout="$8"
uci set $UCI.initial_connect_delay="$9"
uci set $UCI.band_steering_interval="${10}"
uci set $UCI.band_steering_min_snr="${11}"
uci set $UCI.assoc_steering="${12}"
uci set $UCI.probe_steering="${13}"
uci set $UCI.load_kick_enabled="${14}"
uci set $UCI.load_kick_threshold="${15}"
uci set $UCI.load_kick_min_clients="${16}"
uci set $UCI.load_kick_delay="${17}"
uci set $UCI.remote_node_timeout='120'

# ssid_list 處理：清除舊的，再設定新的
while uci -q delete $UCI.ssid_list; do :; done

has_ssid=0
if [ $# -gt 17 ]; then
    shift 17
    for ssid in "$@"; do
        [ -z "$ssid" ] && continue
        uci add_list $UCI.ssid_list="$ssid"
        logger -t wifi-usteer "ssid_list 加入: $ssid"
        has_ssid=1
    done
fi
[ "$has_ssid" = "0" ] && logger -t wifi-usteer "ssid_list 未指定，管理所有 SSID"

uci commit usteer
/etc/init.d/usteer restart

logger -t wifi-usteer "usteer 參數已更新並重啟"
echo "✅ usteer 參數已更新並重啟"
