#!/bin/sh
# 推播目前系統狀態: CPU 溫度 / AdGuardHome 記憶體 / 可用記憶體 / 2.4G & 5G Tx-Power

PUSH_NAMES="${PUSH_NAMES:-jammy}"
. /etc/myscript/push_notify.inc

cpu_temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null \
    || cat /sys/class/hwmon/hwmon*/temp*_input 2>/dev/null | sort -rn | head -1)
cpu_temp=$(( cpu_temp / 1000 ))

agh_pid=$(pgrep AdGuardHome | head -1)
agh_mem=$(awk '/VmRSS/{print int($2/1024)}' "/proc/${agh_pid}/status" 2>/dev/null)
[ -z "$agh_mem" ] && agh_mem=0

free_mem=$(free | awk 'NR==2{print int($4/1024)}')

# 依 phy 的 frequency 判斷 band: 2=2.4G, 5=5G, 6=6G
get_band() {
    f=$(iwinfo "$1" info 2>/dev/null | awk '/Frequency/{print $2; exit}')
    case "$f" in
        2*) echo "2G"  ;;
        5*) echo "5G"  ;;
        6*) echo "6G"  ;;
        *)  echo ""    ;;
    esac
}

get_pwr() {
    iwinfo "$1" info 2>/dev/null | awk '/Tx-Power/{print $2; exit}'
}

# 收集所有 AP iface 的 band/power
msg_radio=""
seen_5g=0
for iface in $(iwinfo 2>/dev/null | awk '/ESSID/{print $1}'); do
    band=$(get_band "$iface")
    pwr=$(get_pwr "$iface")
    [ -z "$band" ] || [ -z "$pwr" ] && continue
    label="$band"
    if [ "$band" = "5G" ]; then
        seen_5g=$((seen_5g + 1))
        [ "$seen_5g" -gt 1 ] && label="5G${seen_5g}"
    fi
    msg_radio="${msg_radio} ${label}:${pwr}dBm"
done

push_notify "CPU: ${cpu_temp}°C AgH: ${agh_mem}MB | Free: ${free_mem}MB |${msg_radio}"
