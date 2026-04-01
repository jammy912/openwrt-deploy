#!/bin/sh
# batman-setup.sh - BATMAN mesh + 802.11r/k/v 漫遊設定 (支援 --auto 模式)
# 用法: batman-setup.sh [gateway|client]
#
# 環境變數 (由 deploy.sh export):
#   AUTO_MODE=1       啟用自動模式
#   ARG_WIFI_KEY      WiFi 密碼 (auto mode 用作 mesh 密碼預設值)

C_PROMPT='\033[1;33m'
C_RESET='\033[0m'

echo "========================================"
echo " BATMAN Mesh + 802.11r/k/v 漫遊設定"
echo "========================================"
echo ""
echo "  BATMAN mesh 讓多台路由器組成無縫網路"
echo "  802.11r/k/v 讓手機在路由器之間切換時不斷線"
echo ""
echo "  前提: 所有節點的 Mesh ID、密碼、Mobility Domain 必須一致"

# 偵測所有 5G radio
RADIOS_5G=""
RADIO_COUNT=0
for radio in radio0 radio1 radio2 radio3; do
    band=$(uci get wireless.$radio.band 2>/dev/null)
    if [ "$band" = "5g" ]; then
        RADIOS_5G="$RADIOS_5G $radio"
        RADIO_COUNT=$((RADIO_COUNT + 1))
    fi
done
RADIOS_5G=$(echo "$RADIOS_5G" | sed 's/^ //')

if [ "$RADIO_COUNT" -eq 0 ]; then
    echo "❌ 找不到 5GHz radio"
    exit 1
elif [ "$RADIO_COUNT" -eq 1 ]; then
    RADIO_5G="$RADIOS_5G"
    echo ""
    echo "偵測到 5GHz radio: $RADIO_5G"
else
    echo ""
    echo "偵測到多個 5GHz radio: $RADIOS_5G"
    if [ "$AUTO_MODE" = "1" ]; then
        # auto mode 選第一個 5G radio
        RADIO_5G=$(echo "$RADIOS_5G" | awk '{print $1}')
        echo "  自動選擇: $RADIO_5G"
    else
        echo "  Mesh 建議使用其中一個 5G radio，另一個留給用戶連線"
        printf "${C_PROMPT}選擇用於 Mesh 的 radio [$RADIOS_5G]: ${C_RESET}"
        read -r RADIO_5G < /dev/tty
        # 驗證輸入
        if ! echo "$RADIOS_5G" | grep -qw "$RADIO_5G"; then
            echo "❌ 無效選擇: $RADIO_5G"
            exit 1
        fi
    fi
fi

# =====================
# 角色偵測
# =====================
# 讀取 deploy.sh 已設定的角色
ROLE=$(cat /etc/myscript/.mesh_role 2>/dev/null)
ROLE="${ROLE:-${1:-gateway}}"

echo "  角色: $ROLE"

# =====================
# Mesh 參數
# =====================
# 取得 5G WiFi 密碼作為預設值
WIFI_5G_KEY=""
for iface in $(uci show wireless 2>/dev/null | grep "=wifi-iface" | cut -d'=' -f1 | cut -d'.' -f2); do
    iface_device=$(uci get wireless.$iface.device 2>/dev/null)
    iface_mode=$(uci get wireless.$iface.mode 2>/dev/null)
    if [ "$iface_mode" = "ap" ]; then
        iface_band=$(uci get wireless.$iface_device.band 2>/dev/null)
        if [ "$iface_band" = "5g" ]; then
            WIFI_5G_KEY=$(uci get wireless.$iface.key 2>/dev/null)
            break
        fi
    fi
done

if [ "$AUTO_MODE" = "1" ]; then
    MESH_ID="batmesh"
    MESH_KEY="${ARG_WIFI_KEY:-$WIFI_5G_KEY}"
    MOBILITY_DOMAIN="9797"
    echo ""
    echo "  Mesh ID: $MESH_ID"
    echo "  Mobility Domain: $MOBILITY_DOMAIN"
else
    echo ""
    echo "--- Mesh 網路設定 ---"
    echo "  Mesh ID 是 mesh 網路的名稱，所有節點必須相同"
    printf "${C_PROMPT}  Mesh ID [batmesh]: ${C_RESET}"
    read -r MESH_ID < /dev/tty
    MESH_ID="${MESH_ID:-batmesh}"

    echo ""
    echo "  Mesh 密碼用於加密 mesh 節點之間的通訊"
    echo "  所有節點必須使用相同密碼"
    if [ -n "$WIFI_5G_KEY" ]; then
        printf "${C_PROMPT}  Mesh 密碼 [與 5G WiFi 相同]: ${C_RESET}"
        read -r MESH_KEY < /dev/tty
        MESH_KEY="${MESH_KEY:-$WIFI_5G_KEY}"
    else
        printf "${C_PROMPT}  Mesh 密碼: ${C_RESET}"
        read -r MESH_KEY < /dev/tty
        [ -z "$MESH_KEY" ] && { echo "❌ 密碼不能為空"; exit 1; }
    fi

    # =====================
    # 802.11r/k/v 參數
    # =====================
    echo ""
    echo "--- 802.11r/k/v 快速漫遊設定 ---"
    echo ""
    echo "  Mobility Domain 是漫遊群組的識別碼 (4位 hex)"
    echo "  所有節點必須相同，手機才能在節點間快速切換"
    printf "${C_PROMPT}  Mobility Domain [9797]: ${C_RESET}"
    read -r MOBILITY_DOMAIN < /dev/tty
    MOBILITY_DOMAIN="${MOBILITY_DOMAIN:-9797}"
fi

# =====================
# 設定 Mesh 介面
# =====================
echo ""
echo "🔧 設定 BATMAN mesh..."

# 找到或建立 mesh 介面
MESH_IFACE=""
for iface in $(uci show wireless | grep "=wifi-iface" | cut -d'=' -f1 | cut -d'.' -f2); do
    if [ "$(uci get wireless.$iface.mode 2>/dev/null)" = "mesh" ]; then
        MESH_IFACE="$iface"
        break
    fi
done

if [ -z "$MESH_IFACE" ]; then
    MESH_IFACE="mesh0"
    uci set wireless.$MESH_IFACE=wifi-iface
fi

uci set wireless.$MESH_IFACE.device="$RADIO_5G"
uci set wireless.$MESH_IFACE.mode='mesh'
uci set wireless.$MESH_IFACE.mesh_id="$MESH_ID"
uci set wireless.$MESH_IFACE.mesh_fwding='0'
uci set wireless.$MESH_IFACE.encryption='sae'
uci set wireless.$MESH_IFACE.key="$MESH_KEY"
uci set wireless.$MESH_IFACE.network='batmesh'

# mesh 不支援 160MHz/320MHz，自動降為 80MHz
CUR_HTMODE=$(uci get wireless.$RADIO_5G.htmode 2>/dev/null)
if echo "$CUR_HTMODE" | grep -qE '160|320'; then
    NEW_HTMODE=$(echo "$CUR_HTMODE" | sed 's/160/80/;s/320/80/')
    uci set wireless.$RADIO_5G.htmode="$NEW_HTMODE"
    echo "  ⚠️  $RADIO_5G htmode 從 $CUR_HTMODE 降為 $NEW_HTMODE (mesh 不支援 160/320MHz)"
fi

echo "  ✅ Mesh 介面: $MESH_IFACE (on $RADIO_5G)"

# =====================
# 設定 BATMAN 網路
# =====================
uci set network.bat0=interface
uci set network.bat0.proto='batadv'
uci set network.bat0.routing_algo='BATMAN_IV'

# batmesh: 將 mesh 無線介面掛到 bat0
uci set network.batmesh=interface
uci set network.batmesh.proto='batadv_hardif'
uci set network.batmesh.master='bat0'

case "$ROLE" in
    gateway)
        uci set network.bat0.gw_mode='server'
        ;;
    client)
        uci set network.bat0.gw_mode='client'
        ;;
esac

# bat0 加入 LAN bridge
BR_DEVICE=$(uci show network | grep "=device" | head -1 | cut -d'.' -f2 | cut -d'=' -f1)
if [ -n "$BR_DEVICE" ]; then
    # 檢查是否已加入
    if ! uci get network.$BR_DEVICE.ports 2>/dev/null | grep -q "bat0"; then
        uci add_list network.$BR_DEVICE.ports='bat0'
    fi
fi
echo "  ✅ BATMAN 網路: $ROLE 模式"

# =====================
# 設定 802.11r/k/v 漫遊
# =====================
echo ""
echo "🔧 設定 802.11r/k/v..."

for iface in $(uci show wireless | grep "=wifi-iface" | cut -d'=' -f1 | cut -d'.' -f2); do
    mode=$(uci get wireless.$iface.mode 2>/dev/null)
    # 只對 AP 模式設定漫遊，跳過 mesh
    if [ "$mode" = "ap" ]; then
        ssid=$(uci get wireless.$iface.ssid 2>/dev/null)

        # 802.11r (Fast Transition) - 快速切換，減少斷線時間
        uci set wireless.$iface.ieee80211r='1'
        uci set wireless.$iface.ft_over_ds='0'
        uci set wireless.$iface.ft_psk_generate_local='1'
        uci set wireless.$iface.mobility_domain="$MOBILITY_DOMAIN"

        # 802.11k (Radio Resource Management) - 提供鄰居 AP 資訊
        uci set wireless.$iface.ieee80211k='1'

        # 802.11v (BSS Transition) - 建議客戶端切換 AP
        uci set wireless.$iface.ieee80211v='1'

        echo "  ✅ $ssid ($iface): 802.11r/k/v 已啟用"
    fi
done

# =====================
# 套用設定
# =====================
echo ""
echo "💾 儲存設定..."
uci commit wireless
uci commit network

echo ""
echo "========================================"
echo " ✅ BATMAN mesh + 802.11r/k/v 設定完成"
echo "========================================"
echo ""
echo " 角色: $ROLE"
echo " Mesh ID: $MESH_ID"
echo " Mobility Domain: $MOBILITY_DOMAIN"
echo ""
echo " 重啟網路生效: /etc/init.d/network restart && wifi reload"
echo ""
echo " ⚠️  所有 mesh 節點的 Mesh ID、密碼、Mobility Domain 必須一致"
