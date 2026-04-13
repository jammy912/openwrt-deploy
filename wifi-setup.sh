#!/bin/sh
# wifi-setup.sh - WiFi 設定 (支援 --auto 模式)
# 自動偵測所有 radio，逐一設定 SSID/密碼/頻道
#
# 環境變數 (由 deploy.sh export):
#   AUTO_MODE=1       啟用自動模式
#   ARG_WIFI_KEY      WiFi 密碼
#   ARG_IOT_KEY       IOT WiFi 密碼 (未設定則用 ARG_WIFI_KEY)
#   ARG_SSID          SSID (預設 Portkey)
#   ARG_CHANNEL       頻道 (預設 5G=149, 2.4G=auto)
#   ARG_COUNTRY       國碼 (預設 TW)
#   ARG_ENCRYPTION    加密方式 (預設 psk2)
#   MESH_ROLE         角色 (gateway/client)

C_PROMPT='\033[1;33m'
C_RESET='\033[0m'

echo "========================================"
echo " WiFi 設定"
echo "========================================"
echo ""
echo "  此腳本會清除所有舊 WiFi 介面，重新建立"
echo "  偵測所有 radio (2.4GHz/5GHz/6GHz)，逐一設定 SSID、密碼、頻道"

# 清除所有現有 WiFi 介面
while uci get wireless.@wifi-iface[0] >/dev/null 2>&1; do
    uci delete wireless.@wifi-iface[0]
done
echo ""
echo "  ✅ 已清除所有舊 WiFi 介面"

# 偵測所有 radio (5G/6G 優先，2.4G 最後)
RADIO_LIST=""
for r in radio0 radio1 radio2 radio3; do
    b=$(uci get wireless.$r.band 2>/dev/null)
    [ -z "$b" ] && continue
    if [ "$b" = "2g" ]; then
        RADIO_LIST="$RADIO_LIST $r"
    else
        RADIO_LIST="$r $RADIO_LIST"
    fi
done

for radio in $RADIO_LIST; do
    band=$(uci get wireless.$radio.band 2>/dev/null)
    [ -z "$band" ] && continue

    case "$band" in
        2g) band_name="2.4GHz" ;;
        5g) band_name="5GHz" ;;
        6g) band_name="6GHz" ;;
        *)  band_name="$band" ;;
    esac

    echo ""
    echo "--- $radio ($band_name) ---"

    # 確保 radio 啟用
    uci set wireless.$radio.disabled='0'

    # 頻道: 先給安全預設 (非 DFS)；實際值由 auto-role.sh 依角色/mesh 狀態套用
    case "$band" in
        5g) uci set wireless.$radio.channel='149' ;;
        *)  uci set wireless.$radio.channel='auto' ;;
    esac

    # 發射功率
    uci set wireless.$radio.txpower='5'

    # 國碼
    cur_country=$(uci get wireless.$radio.country 2>/dev/null)
    if [ "$AUTO_MODE" = "1" ]; then
        country="${ARG_COUNTRY:-${cur_country:-TW}}"
    else
        printf "${C_PROMPT}  國碼 (TW=台灣, US=美國, JP=日本) [${cur_country:-TW}]: ${C_RESET}"
        read -r country < /dev/tty
        country="${country:-${cur_country:-TW}}"
    fi
    uci set wireless.$radio.country="$country"

    # 2.4G 不建主要 AP（留給 IOT WiFi），只有 5G/6G 建主要 AP
    if [ "$band" = "2g" ]; then
        echo "  ℹ️  2.4GHz 主要用於 IOT WiFi，將在下一階段設定"
        continue
    fi

    # 建立新的 AP 介面
    iface="default_${radio}"
    uci set wireless.$iface=wifi-iface
    uci set wireless.$iface.device="$radio"
    uci set wireless.$iface.mode='ap'
    uci set wireless.$iface.network='lan'

    if [ "$AUTO_MODE" = "1" ]; then
        ssid="${ARG_SSID:-Portkey}"
        key="$ARG_WIFI_KEY"
        enc="${ARG_ENCRYPTION:-psk2}"
    else
        echo ""
        printf "${C_PROMPT}  SSID (WiFi 名稱) [Portkey]: ${C_RESET}"
        read -r ssid < /dev/tty
        ssid="${ssid:-Portkey}"

        key=""
        while [ -z "$key" ]; do
            printf "${C_PROMPT}  密碼: ${C_RESET}"
            read -r key < /dev/tty
            [ -z "$key" ] && echo "  ⚠️  密碼不能為空，請重新輸入"
        done

        echo "  加密方式:"
        echo "    1) psk2      = WPA2 (建議，相容性最好)"
        echo "    2) sae-mixed = WPA2/WPA3 混合 (較新裝置)"
        printf "${C_PROMPT}  加密方式 [psk2]: ${C_RESET}"
        read -r enc < /dev/tty
        enc="${enc:-psk2}"
    fi
    uci set wireless.$iface.ssid="$ssid"
    uci set wireless.$iface.key="$key"
    uci set wireless.$iface.encryption="$enc"
    uci set wireless.$iface.dtim_period='5'

    # 802.11r/k/v 漫遊 (多台 AP 無縫切換)
    if [ "$AUTO_MODE" != "1" ]; then
        printf "${C_PROMPT}  啟用漫遊？(802.11r/k/v) (y/n) [y]: ${C_RESET}"
        read -r ap_roam < /dev/tty
    fi
    case "${ap_roam:-y}" in
        [Nn]) ;;
        *)
            nasid=$(cat /sys/class/net/br-lan/address 2>/dev/null | tr -d ':')
            uci set wireless.$iface.ieee80211r='1'
            uci set wireless.$iface.nasid="$nasid"
            uci set wireless.$iface.mobility_domain='9797'
            uci set wireless.$iface.ft_over_ds='0'
            uci set wireless.$iface.ft_psk_generate_local='1'
            uci set wireless.$iface.ieee80211k='1'
            uci set wireless.$iface.ieee80211v='1'
            uci set wireless.$iface.bss_transition='1'
            uci set wireless.$iface.wnm_sleep_mode='1'
            uci set wireless.$iface.wnm_sleep_mode_no_keys='1'
            uci set wireless.$iface.proxy_arp='1'
            echo "  ✅ 漫遊已啟用 (802.11r/k/v + nasid=$nasid)"
            ;;
    esac

    echo "  ✅ 已建立 $ssid ($iface on $radio)"
done

# =====================
# IOT WiFi (2.4GHz)
# =====================
echo ""
echo "--- IOT WiFi ---"
echo "  建立獨立的 2.4GHz IOT WiFi，供智慧家電使用"
echo "  IOT 裝置通常只支援 2.4GHz"
echo ""

# 找 2.4G radio
IOT_RADIO=""
for radio in radio0 radio1 radio2 radio3; do
    band=$(uci get wireless.$radio.band 2>/dev/null)
    if [ "$band" = "2g" ]; then
        IOT_RADIO="$radio"
        break
    fi
done

# 讀取角色 (auto mode 已由 deploy.sh export MESH_ROLE)
[ -z "$MESH_ROLE" ] && MESH_ROLE=$(cat /etc/myscript/.mesh_role 2>/dev/null)

if [ -z "$IOT_RADIO" ]; then
    echo "  ⚠️  找不到 2.4GHz radio，跳過 IOT WiFi"
else
    # client 預設不建 IOT WiFi，gateway 預設建
    if [ "$MESH_ROLE" = "client" ]; then
        IOT_DEFAULT="n"
    else
        IOT_DEFAULT="y"
    fi

    if [ "$AUTO_MODE" = "1" ]; then
        setup_iot="$IOT_DEFAULT"
    else
        printf "${C_PROMPT}  是否建立 IOT WiFi？(y/n) [$IOT_DEFAULT]: ${C_RESET}"
        read -r setup_iot < /dev/tty
        setup_iot="${setup_iot:-$IOT_DEFAULT}"
    fi

    case "$setup_iot" in
        [Nn]) echo "  ⏭️  跳過 IOT WiFi" ;;
        *)
            IOT_IFACE="default_${IOT_RADIO}"
            uci set wireless.$IOT_IFACE=wifi-iface
            uci set wireless.$IOT_IFACE.device="$IOT_RADIO"
            uci set wireless.$IOT_IFACE.mode='ap'
            uci set wireless.$IOT_IFACE.ssid='IOT'
            uci set wireless.$IOT_IFACE.network='lan'
            uci set wireless.$IOT_IFACE.encryption='psk2'

            if [ "$AUTO_MODE" = "1" ]; then
                iot_key="${ARG_IOT_KEY:-$ARG_WIFI_KEY}"
            else
                echo "  SSID: IOT (on $IOT_RADIO)"
                iot_key=""
                while [ -z "$iot_key" ]; do
                    printf "${C_PROMPT}  IOT WiFi 密碼: ${C_RESET}"
                    read -r iot_key < /dev/tty
                    [ -z "$iot_key" ] && echo "  ⚠️  密碼不能為空，請重新輸入"
                done
            fi
            uci set wireless.$IOT_IFACE.key="$iot_key"
            uci set wireless.$IOT_IFACE.dtim_period='5'

            # 802.11r/k/v 漫遊 (多台 AP 無縫切換)
            if [ "$AUTO_MODE" != "1" ]; then
                printf "${C_PROMPT}  啟用 IOT WiFi 漫遊？(802.11r/k/v) (y/n) [y]: ${C_RESET}"
                read -r iot_roam < /dev/tty
            fi
            case "${iot_roam:-y}" in
                [Nn]) ;;
                *)
                    iot_nasid=$(cat /sys/class/net/br-lan/address 2>/dev/null | tr -d ':')
                    uci set wireless.$IOT_IFACE.ieee80211r='1'
                    uci set wireless.$IOT_IFACE.nasid="$iot_nasid"
                    uci set wireless.$IOT_IFACE.mobility_domain='9797'
                    uci set wireless.$IOT_IFACE.ft_over_ds='0'
                    uci set wireless.$IOT_IFACE.ft_psk_generate_local='1'
                    uci set wireless.$IOT_IFACE.ieee80211k='1'
                    uci set wireless.$IOT_IFACE.ieee80211v='1'
                    uci set wireless.$IOT_IFACE.bss_transition='1'
                    uci set wireless.$IOT_IFACE.wnm_sleep_mode='1'
                    uci set wireless.$IOT_IFACE.wnm_sleep_mode_no_keys='1'
                    uci set wireless.$IOT_IFACE.proxy_arp='1'
                    echo "  ✅ 漫遊已啟用 (802.11r/k/v + nasid=$iot_nasid)"
                    ;;
            esac

            echo "  ✅ IOT WiFi 已建立"
            ;;
    esac
fi

echo ""
echo "💾 儲存設定..."
uci commit wireless

echo "  WiFi 設定將在重啟後生效"
