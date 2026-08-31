#!/bin/sh
# wifi-dtim.sh — 依頻段設定 DTIM period (for OpenWrt)
# 用法:
#   wifi-dtim.sh <band|radio> <dtim>
#     band : 2g / 5g / 6g (自動找對應 radio)，或直接給 radio0/radio1/...
#     dtim : 1-255
#
# 典型用法 (離峰省電 / 尖峰低延遲):
#   0 23 * * * /etc/myscript/wifi-dtim.sh 5g 5   # 離峰:省電
#   0  7 * * * /etc/myscript/wifi-dtim.sh 5g 1   # 尖峰:低延遲
#
# 為什麼 DTIM 會影響延遲:
#   AP 每 beacon_int(預設 100ms) 發一次 beacon,省電模式的 client 只在第 N 個
#   beacon(N=dtim_period)醒來收緩衝封包 → DTIM 間隔 = beacon_int × dtim。
#   dtim=5 → 500ms 才醒一次(省電,但延遲抖動大)
#   dtim=1 → 每 100ms 都醒(延遲最低,最耗電)
#   實測 2026-08-30 x60pro ping 閘道器最大延遲: dtim5=54ms → dtim2=32ms → dtim1=21ms
#
# ⚠️ 眉角:
#   1. 改 dtim 必須 wifi reload 才生效(uci commit 不夠)。
#   2. wifi reload 會讓 hostapd 重新初始化,usteer 隨之 "Disconnecting from
#      local node" → hearing map 短暫清空。故本腳本「值沒變就不動」,
#      避免 cron 重複觸發無謂的 reload。
#   3. /etc/config 在部分機型是 tmpfs(如 ax3000t),reboot 後會還原。
#      需持久化的機器請在 cron 內另接 sync-ram2flash.sh。

LOG_FILE="/tmp/wifi-dtim.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

if [ $# -ne 2 ]; then
    echo "用法: $0 <band|radio> <dtim>"
    echo "  band: 2g / 5g / 6g,或直接給 radio0/radio1/..."
    echo "  dtim: 1-255 (1=延遲最低, 值越大越省電)"
    echo "例: $0 5g 1"
    exit 1
fi

TARGET="$1"
DTIM="$2"

# --- 參數驗證 ---
case "$DTIM" in
    ''|*[!0-9]*) echo "❌ dtim 必須是數字: $DTIM"; exit 1 ;;
esac
if [ "$DTIM" -lt 1 ] || [ "$DTIM" -gt 255 ]; then
    echo "❌ dtim 必須介於 1-255: $DTIM"
    exit 1
fi

# --- 解析 band → radio (支援直接給 radioN) ---
case "$TARGET" in
    radio[0-9]*)
        RADIO="$TARGET"
        ;;
    *)
        RADIO=""
        for _r in radio0 radio1 radio2 radio3; do
            _b=$(uci -q get wireless.$_r.band 2>/dev/null)
            [ "$_b" = "$TARGET" ] && { RADIO="$_r"; break; }
        done
        if [ -z "$RADIO" ]; then
            echo "❌ 找不到 band=$TARGET 的 radio"
            log "❌ 找不到 band=$TARGET 的 radio"
            exit 1
        fi
        ;;
esac

if [ -z "$(uci -q get wireless.$RADIO.band 2>/dev/null)" ]; then
    echo "❌ $RADIO 不存在"
    log "❌ $RADIO 不存在"
    exit 1
fi

BAND=$(uci -q get wireless.$RADIO.band 2>/dev/null)

# --- 找出該 radio 底下的 AP 介面 ---
# ★ 只取 mode=ap:dtim_period 是給「省電模式的 client」用的,mesh(802.11s)/sta
#   介面沒有這個概念,設了無意義還會讓 mesh 設定多出無用欄位。
#   實測 2026-08-30 x60pro: 未過濾時會連 mesh0 一起設。
IFACES=$(uci show wireless 2>/dev/null | awk -F'[.=]' -v r="$RADIO" '
    /=wifi-iface/ { sec[$2]=1 }
    /\.device=/   { gsub(/'"'"'/, "", $4); dev[$2]=$4 }
    /\.mode=/     { gsub(/'"'"'/, "", $4); mode[$2]=$4 }
    END { for (s in sec) if (dev[s]==r && mode[s]=="ap") print s }
')

if [ -z "$IFACES" ]; then
    echo "❌ $RADIO ($BAND) 底下找不到 mode=ap 的 wifi-iface"
    log "❌ $RADIO ($BAND) 底下找不到 mode=ap 的 wifi-iface"
    exit 1
fi

# --- 逐一設定,記錄是否真的有變更 ---
CHANGED=0
for _if in $IFACES; do
    _cur=$(uci -q get wireless.$_if.dtim_period 2>/dev/null)
    [ -z "$_cur" ] && _cur="(未設)"
    if [ "$_cur" != "$DTIM" ]; then
        uci set wireless.$_if.dtim_period="$DTIM"
        CHANGED=1
        echo "  $_if: dtim_period $_cur -> $DTIM"
        log "$RADIO/$_if dtim_period: $_cur -> $DTIM"
    fi
done

# --- 值沒變就不 reload(避免無謂打斷 usteer) ---
if [ "$CHANGED" -eq 0 ]; then
    echo "[$RADIO/$BAND] dtim_period 已是 $DTIM,無需變更"
    log "[$RADIO/$BAND] dtim_period 已是 $DTIM,無需變更(跳過 reload)"
    exit 0
fi

uci commit wireless
echo "🔄 wifi reload 套用中..."
wifi reload
sleep 8

# --- 回讀 hostapd 實際值驗證(uci 寫了不代表生效) ---
_phy=$(echo "$RADIO" | sed 's/radio/phy/')
_conf="/var/run/hostapd-${_phy}.conf"
_actual=$(grep -E '^dtim_period=' "$_conf" 2>/dev/null | head -1 | cut -d= -f2)

if [ -z "$_actual" ]; then
    echo "⚠️ 無法回讀 $_conf 驗證(介面可能未啟用)"
    log "⚠️ $RADIO 無法回讀 hostapd conf 驗證"
elif [ "$_actual" = "$DTIM" ]; then
    echo "✅ [$RADIO/$BAND] dtim_period=$DTIM 已生效 (hostapd 已驗證)"
    log "✅ [$RADIO/$BAND] dtim_period=$DTIM 已生效"
else
    echo "⚠️ [$RADIO/$BAND] uci=$DTIM 但 hostapd 實際=$_actual"
    log "⚠️ [$RADIO/$BAND] uci=$DTIM 但 hostapd 實際=$_actual"
fi

# --- Channel 0 檢查(wifi reload 的已知風險) ---
# ★ 不可寫死 "${_phy}-ap0": AP 介面不保證叫 -ap0(可能 ap1，或該 radio 只有 mesh)。
#   名字不符時 iwinfo 查無介面 → grep 恆為 false → Channel 0 修復永遠不觸發,
#   而且完全沒有告警(靜默失效)。改列舉該 phy 底下實際介面逐一檢查。
_ap_ifs=$(iwinfo 2>/dev/null | awk -v p="$_phy" '$1 ~ "^"p"-" {print $1}')
if [ -z "$_ap_ifs" ]; then
    echo "⚠️ 找不到 ${_phy} 底下任何介面,略過 Channel 0 檢查"
    log "⚠️ 找不到 ${_phy} 底下任何介面,略過 Channel 0 檢查"
else
    for _ap in $_ap_ifs; do
        if iwinfo "$_ap" info 2>/dev/null | grep -q "Channel: 0"; then
            echo "❌ [嚴重] ${_ap} 出現 Channel 0,嘗試 wifi down/up 修復"
            log "❌ [嚴重] ${_ap} 出現 Channel 0,嘗試修復"
            wifi down; sleep 5; wifi up
            break
        fi
    done
fi
