#!/bin/sh
# 推播目前系統狀態: CPU 溫度 / AdGuardHome 記憶體 / 可用記憶體 / 2.4G & 5G 頻道+頻寬+Tx-Power

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

# 取頻道號 (同 get_band 的 Channel: 行, 取括號前的數字)
get_ch() {
    iwinfo "$1" info 2>/dev/null | sed -n 's/.*Channel: \([0-9]*\) .*/\1/p' | head -1
}

# 取頻寬 MHz: HT Mode 值(HT20/HE80/VHT160/HT40+...) 去掉非數字即為寬度
get_width() {
    iwinfo "$1" info 2>/dev/null | sed -n 's/.*HT Mode: \([A-Za-z0-9+-]*\).*/\1/p' \
        | head -1 | sed 's/[^0-9]//g'
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
    ch=$(get_ch "$iface")
    width=$(get_width "$iface")
    [ -z "$band" ] && continue
    [ -z "$pwr" ] && continue
    label="$band"
    if [ "$band" = "5G" ]; then
        seen_5g=$((seen_5g + 1))
        [ "$seen_5g" -gt 1 ] && label="5G${seen_5g}"
    fi
    # 格式: 5G(CH149/80M)11dBm。頻道/頻寬任一查不到就省略該段,
    # 避免出現 "5G(CH/M)" 這種殘缺字串
    if [ -n "$ch" ] && [ -n "$width" ]; then
        label="${label}(CH${ch}/${width}M)"
    elif [ -n "$ch" ]; then
        label="${label}(CH${ch})"
    else
        # 連頻道都查不到時補冒號,否則會黏成 "5G11dBm" 看不懂
        label="${label}:"
    fi
    msg_radio="${msg_radio} ${label}${pwr}dBm"
done
[ -z "$msg_radio" ] && msg_radio=" (no radio)"

# =====================================================================
# WG 介面缺 metric 警示
#
# ⚠️ 真兇紀錄 2026-09-07 (.12 x60pro): wg8ts 是全機唯一沒設 metric 的 wg 介面。
#    沒 metric 的 default route 預設 metric=0, 與 WAN 的 default 同級, 後插入
#    者勝 —— 每次 pbr reload 重裝路由就把 WAN 擠掉, auto-role 每分鐘得修一次,
#    推播「default route 原走 wg8ts 已改 via ... dev eth1」轟炸。
#    對照組 wg2/wg3/wg4 同樣是 allowed_ips=0.0.0.0/0 + route_allowed_ips=1,
#    但因 metric 102/103/111 永遠排在 WAN 之後, 從沒出過事。
#    ★ 判定式: route_allowed_ips=1 且 allowed_ips 含 0.0.0.0/0 才會裝 default,
#      只有這種介面缺 metric 才危險; 純點對點 (如 wg1 各 peer) 不必警示。
# =====================================================================
wg_nometric=""
for _sec in $(uci show network 2>/dev/null \
              | sed -n 's/^network\.\([^.=]*\)=interface$/\1/p'); do
    [ "$(uci -q get network.$_sec.proto)" = "wireguard" ] || continue
    [ -n "$(uci -q get network.$_sec.metric)" ] && continue
    # 這個介面底下任一 peer 會裝 default 才算數
    _risky=0
    for _p in $(uci show network 2>/dev/null \
                | sed -n "s/^network\.\([^.=]*\)=wireguard_${_sec}$/\1/p"); do
        [ "$(uci -q get network.$_p.route_allowed_ips)" = "1" ] || continue
        case " $(uci -q get network.$_p.allowed_ips) " in
            *" 0.0.0.0/0 "*) _risky=1; break ;;
        esac
    done
    [ "$_risky" = "1" ] && wg_nometric="${wg_nometric} ${_sec}"
done
msg_wg=""
[ -n "$wg_nometric" ] && msg_wg=" | ⚠️WG缺metric:${wg_nometric} (會搶WAN default)"

push_notify "CPU: ${cpu_temp}°C Load: ${load} | AgH: ${agh_mem}MB Free: ${free_mem}MB |${msg_radio}${msg_wg}"
