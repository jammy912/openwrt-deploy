#!/bin/sh
# 推播目前系統狀態: CPU 溫度 / AdGuardHome 記憶體 / 可用記憶體 / 2.4G & 5G Tx-Power

# 全域 cron 排隊鎖
. /etc/myscript/lock-handler.sh
cron_global_lock 60 || exit 0
trap 'rm -f /tmp/cron_global.lock' EXIT

PUSH_NAMES="${PUSH_NAMES:-admin}"
. /etc/myscript/push-notify.inc

cpu_temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null \
    || cat /sys/class/hwmon/hwmon*/temp*_input 2>/dev/null | sort -rn | head -1)
cpu_temp=$(( cpu_temp / 1000 ))

agh_pid=$(pgrep AdGuardHome | head -1)
agh_mem=$(awk '/VmRSS/{print int($2/1024)}' "/proc/${agh_pid}/status" 2>/dev/null)
[ -z "$agh_mem" ] && agh_mem=0

free_mem=$(free | awk 'NR==2{print int($4/1024)}')

load=$(awk '{printf "%.1f %.1f %.1f", $1, $2, $3}' /proc/loadavg)

# 依 channel frequency 判斷 band: 2.xxx=2.4G, 5.xxx=5G, 6.xxx=6G
get_band() {
    f=$(iwinfo "$1" info 2>/dev/null | sed -n 's/.*Channel:.*(\([0-9]*\.[0-9]*\) GHz).*/\1/p' | head -1)
    case "$f" in
        2.*) echo "2G" ;;
        5.*) echo "5G" ;;
        6.*) echo "6G" ;;
        *)   echo ""   ;;
    esac
}

get_pwr() {
    iwinfo "$1" info 2>/dev/null | awk '/Tx-Power/{print $2; exit}'
}

# 每個 phy 只取一個 AP iface (避免重複)
msg_radio=""
seen_5g=0
seen_phy=""
for iface in $(iw dev 2>/dev/null | awk '/Interface /{print $2}'); do
    mode=$(iw dev "$iface" info 2>/dev/null | awk '/type /{print $2; exit}')
    [ "$mode" = "AP" ] || continue
    phy=$(iw dev "$iface" info 2>/dev/null | awk '/wiphy /{print $2; exit}')
    case " $seen_phy " in *" $phy "*) continue ;; esac
    seen_phy="$seen_phy $phy"
    band=$(get_band "$iface")
    pwr=$(get_pwr "$iface")
    [ -z "$band" ] && continue
    [ -z "$pwr" ] && continue
    label="$band"
    if [ "$band" = "5G" ]; then
        seen_5g=$((seen_5g + 1))
        [ "$seen_5g" -gt 1 ] && label="5G${seen_5g}"
    fi
    msg_radio="${msg_radio} ${label}:${pwr}dBm"
done
[ -z "$msg_radio" ] && msg_radio=" (no radio)"

push_notify "CPU: ${cpu_temp}°C Load: ${load} | AgH: ${agh_mem}MB Free: ${free_mem}MB |${msg_radio}"
