#!/bin/sh
# OpenWrt 快速部署腳本
# 用法: 將 deploy/ 上傳到 /tmp/deploy/ 後執行此腳本
#
# 自動模式範本 (所有參數):
#   sh deploy.sh --auto \
#     --mode gateway \
#     --hostname HOME \
#     --root-pw "mypassword" \
#     --url "https://script.google.com/macros/s/.../exec?..." \
#     --key "12345678901234567890123456789012" \
#     --iv "1234567890123456" \
#     --wifi-key "mywifikey" \
#     --iot-key "myiotkey" \
#     --ssid "RAX3000Z" \
#     --country "TW" \
# 註: 5G 頻道由 auto-role.sh 依角色/mesh 狀態動態套用，不再由 CLI 指定
#     --encryption "psk2" \
#     --tdx-id "TDX_APP_ID" \
#     --tdx-key "TDX_APP_KEY"

DEPLOY_DIR="/tmp/deploy"
BACKUP_DIR="/tmp/deploy_backup_$(date +%Y%m%d%H%M%S)"

# 顏色定義
C_PROMPT='\033[1;33m'  # 黃色粗體 (輸入提示)
C_GREEN='\033[1;32m'   # 綠色粗體 (完成訊息)
C_RESET='\033[0m'

# =====================
# 參數解析
# =====================
AUTO_MODE=0
ARG_MODE=""
ARG_HOSTNAME=""
ARG_ROOT_PW=""
ARG_URL=""
ARG_KEY=""
ARG_IV=""
ARG_WIFI_KEY=""
ARG_IOT_KEY=""
ARG_SSID=""
ARG_COUNTRY=""
ARG_ENCRYPTION=""
ARG_TDX_ID=""
ARG_TDX_KEY=""
ARG_PRIORITY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --auto)       AUTO_MODE=1 ;;
        --mode)       ARG_MODE="$2"; shift ;;
        --hostname)   ARG_HOSTNAME="$2"; shift ;;
        --root-pw)    ARG_ROOT_PW="$2"; shift ;;
        --url)        ARG_URL="$2"; shift ;;
        --key)        ARG_KEY="$2"; shift ;;
        --iv)         ARG_IV="$2"; shift ;;
        --wifi-key)   ARG_WIFI_KEY="$2"; shift ;;
        --iot-key)    ARG_IOT_KEY="$2"; shift ;;
        --ssid)       ARG_SSID="$2"; shift ;;
        --country)    ARG_COUNTRY="$2"; shift ;;
        --encryption) ARG_ENCRYPTION="$2"; shift ;;
        --tdx-id)     ARG_TDX_ID="$2"; shift ;;
        --tdx-key)    ARG_TDX_KEY="$2"; shift ;;
        --priority)   ARG_PRIORITY="$2"; shift ;;
    esac
    shift
done

# auto 模式驗證必填參數
if [ "$AUTO_MODE" = "1" ]; then
    MISSING=""
    [ -z "$ARG_ROOT_PW" ] && MISSING="$MISSING --root-pw"
    [ -z "$ARG_URL" ] && MISSING="$MISSING --url"
    [ -z "$ARG_KEY" ] && MISSING="$MISSING --key"
    [ -z "$ARG_IV" ] && MISSING="$MISSING --iv"
    [ -z "$ARG_WIFI_KEY" ] && MISSING="$MISSING --wifi-key"
    if [ -n "$MISSING" ]; then
        echo "❌ --auto 模式缺少必填參數:$MISSING"
        exit 1
    fi
fi

echo "========================================"
echo " OpenWrt 快速部署"
echo "========================================"
echo ""
if [ "$AUTO_MODE" = "1" ]; then
    echo "  🤖 自動模式"
else
    echo "  提示: 選項中 [ ] 內的值為預設值"
    echo "        直接按 Enter 即可使用預設值"
fi

# 檢查是否以 root 執行
[ "$(id -u)" != "0" ] && { echo "需要 root 權限"; exit 1; }

# 偵測套件管理器
if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
else
    PKG_MGR="opkg"
fi

pkg_update() {
    case "$PKG_MGR" in
        apk)  apk update ;;
        opkg) opkg update ;;
    esac
}

pkg_install() {
    case "$PKG_MGR" in
        apk)  apk add "$@" ;;
        opkg) opkg install "$@" ;;
    esac
}

pkg_is_installed() {
    case "$PKG_MGR" in
        apk)  apk info --installed "$1" >/dev/null 2>&1 ;;
        opkg) opkg list-installed | grep -q "^$1 " ;;
    esac
}

# 檢查系統時間 (SSL 憑證驗證需要正確時間)
YEAR=$(date +%Y)
if [ "$YEAR" -lt 2025 ]; then
    echo ""
    echo "⚠️  系統時間不正確 ($(date))"
    echo "   SSL 憑證驗證需要正確時間，否則套件下載會失敗"
    echo ""
    echo "  方法1: 手動輸入目前時間 (格式: YYYY-MM-DD HH:MM:SS)"
    echo "  方法2: 直接按 Enter 嘗試 NTP 自動校時"
    echo ""
    if [ "$AUTO_MODE" = "1" ]; then
        echo "  ⏳ 系統時間不正確 ($(date))，嘗試 NTP 校時..."
        /etc/init.d/sysntpd restart 2>/dev/null
        sleep 5
        NEW_YEAR=$(date +%Y)
        if [ "$NEW_YEAR" -ge 2025 ]; then
            echo "  ✅ NTP 校時成功: $(date)"
        else
            echo "  ❌ NTP 校時失敗，請手動設定時間後重試"
            echo "     date -s \"2026-03-20 15:00:00\""
            exit 1
        fi
    else
        printf "${C_PROMPT}  輸入時間 (或 Enter 自動校時): ${C_RESET}"
        read -r INPUT_TIME < /dev/tty
    fi
    if [ -n "$INPUT_TIME" ]; then
        date -s "$INPUT_TIME" >/dev/null 2>&1
        echo "  ✅ 時間已設為: $(date)"
    else
        echo "  ⏳ 嘗試 NTP 校時..."
        /etc/init.d/sysntpd restart 2>/dev/null
        sleep 3
        NEW_YEAR=$(date +%Y)
        if [ "$NEW_YEAR" -ge 2025 ]; then
            echo "  ✅ NTP 校時成功: $(date)"
        else
            echo "  ❌ NTP 校時失敗，請手動設定時間後重試"
            echo "     date -s \"2026-03-18 15:00:00\""
            exit 1
        fi
    fi
fi

# 檢查網路連線 (套件安裝和同步都需要)
echo ""
echo "🌐 檢查網路連線..."
if ping -c 2 -W 5 8.8.8.8 >/dev/null 2>&1; then
    echo "  ✅ 網路正常"
else
    echo "  ❌ 無法連線到外部網路 (ping 8.8.8.8 失敗)"
    echo "     套件安裝和 Google Sheet 同步都需要網路"
    echo "     請先確認 WAN 連線後再執行部署"
    exit 1
fi

# 檢查部署目錄
[ ! -d "$DEPLOY_DIR/etc" ] && { echo "找不到 $DEPLOY_DIR/etc，請確認檔案已上傳"; exit 1; }

# 建立備份
echo "📦 備份現有設定到 $BACKUP_DIR ..."
mkdir -p "$BACKUP_DIR"
[ -f /etc/rc.local ] && cp /etc/rc.local "$BACKUP_DIR/"
[ -d /etc/myscript ] && cp -a /etc/myscript "$BACKUP_DIR/"

# =====================
# 0. Router 名稱
# =====================
echo ""
if [ "$AUTO_MODE" = "1" ]; then
    ROUTER_NAME="${ARG_HOSTNAME:-HOME}"
else
    printf "${C_PROMPT}  Router 名稱 [HOME]: ${C_RESET}"
    read -r ROUTER_NAME < /dev/tty
    ROUTER_NAME="${ROUTER_NAME:-HOME}"
fi
uci set system.@system[0].hostname="$ROUTER_NAME"
uci commit system
echo "  hostname: $ROUTER_NAME"

# =====================
# 0.1 選擇角色
# =====================
echo ""
echo "  請選擇這台路由器的角色："
echo ""
echo "  hybrid  = 雙模式，安裝完整套件 (預設)"
echo "            自動偵測 WAN 決定 gateway/client 角色"
echo ""
echo "  gateway = 主路由器，網路線直接接數據機/光纖"
echo "            會安裝完整套件 (PBR/DDNS/QoS/DNS 等)"
echo ""
echo "  client  = 延伸節點，透過 mesh 連回 gateway"
echo "            只安裝基礎套件，設定由 gateway 管理"
echo ""
if [ "$AUTO_MODE" = "1" ]; then
    MESH_ROLE="${ARG_MODE:-hybrid}"
else
    printf "${C_PROMPT}  角色 (hybrid/gateway/client) [hybrid]: ${C_RESET}"
    read -r MESH_ROLE < /dev/tty
    MESH_ROLE="${MESH_ROLE:-hybrid}"
fi
case "$MESH_ROLE" in
    gateway|client|hybrid) ;;
    *) echo "❌ 無效角色: $MESH_ROLE"; exit 1 ;;
esac
mkdir -p /etc/myscript
echo -n "$MESH_ROLE" > /etc/myscript/.mesh_role
echo "  角色: $MESH_ROLE"

# Mesh 優先權 (hybrid/gateway 才需要)
if [ "$MESH_ROLE" != "client" ]; then
    echo ""
    echo "  Mesh 優先權: 數字大的優先當主 gateway (開 DHCP, IP=.1)"
    echo "  相同時 MAC 小的優先。可由 Google Sheet 遠端更新。"
    if [ "$AUTO_MODE" = "1" ]; then
        MESH_PRIORITY="${ARG_PRIORITY:-100}"
    else
        printf "${C_PROMPT}  優先權 [100]: ${C_RESET}"
        read -r MESH_PRIORITY < /dev/tty
        MESH_PRIORITY="${MESH_PRIORITY:-100}"
    fi
    echo -n "$MESH_PRIORITY" > /etc/myscript/.mesh_priority
    echo "  優先權: $MESH_PRIORITY"
fi

# Mesh 啟停預設 (首次部署時寫入，之後由 Google Sheet 同步覆蓋)
[ ! -f /etc/myscript/.mesh_wireless ] && echo -n "Y" > /etc/myscript/.mesh_wireless
[ ! -f /etc/myscript/.mesh_wired ]    && echo -n "Y" > /etc/myscript/.mesh_wired

# =====================
# 1. 安裝必要套件
# =====================
echo ""
echo "📥 安裝必要套件..."
# 等待 opkg lock 釋放 (開機後可能有背景 opkg 在跑)
if [ "$PKG_MGR" = "opkg" ]; then
    WAIT=0
    while [ -f /var/lock/opkg.lock ] && [ "$WAIT" -lt 30 ]; do
        [ "$WAIT" -eq 0 ] && echo "  ⏳ 等待 opkg 解鎖..."
        sleep 1
        WAIT=$((WAIT + 1))
    done
    [ -f /var/lock/opkg.lock ] && rm -f /var/lock/opkg.lock
fi
# 確保 DNS 可用 (移除 dnsmasq 後 resolv.conf 可能失效)
if ! grep -q 'nameserver' /etc/resolv.conf 2>/dev/null || grep -q '127.0.0.1' /etc/resolv.conf; then
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    echo "  ✅ 已設定備用 DNS (8.8.8.8 / 1.1.1.1)"
fi
pkg_update
# 模組記錄檔
MODULES_FILE="/etc/myscript/.modules"
: > "$MODULES_FILE"

# --- 基礎套件 (所有節點) ---
pkg_install coreutils-base64 openssl-util curl rsync \
    zram-swap kmod-zram iperf3 \
    luci-i18n-base-zh-tw luci-i18n-firewall-zh-tw \
    luci-theme-material 2>/dev/null
echo "base" >> "$MODULES_FILE"

# --- gateway 額外套件 ---
if [ "$MESH_ROLE" != "client" ]; then
    # dnsmasq-full 與 dnsmasq 互斥，單獨處理
    if ! pkg_is_installed dnsmasq-full; then
        # 移除 dnsmasq 會導致 DNS 中斷，先確保 resolv.conf 直連外部 DNS
        echo "nameserver 8.8.8.8" > /etc/resolv.conf
        echo "nameserver 1.1.1.1" >> /etc/resolv.conf
        # 預先下載 dnsmasq-full 及所有依賴到 /tmp
        echo "  📦 預先下載 dnsmasq-full 及依賴..."
        if [ "$PKG_MGR" = "opkg" ]; then
            DL_DIR="/tmp/dnsmasq_pkgs"
            mkdir -p "$DL_DIR"
            # 用 --noaction 模擬安裝，從輸出抓出所有要下載的套件名
            ALL_DEPS=$(opkg install --noaction dnsmasq-full 2>/dev/null | grep "^Installing " | awk '{print $2}')
            for dep_pkg in $ALL_DEPS; do
                if ! pkg_is_installed "$dep_pkg"; then
                    echo "    下載: $dep_pkg"
                    cd "$DL_DIR" && opkg download "$dep_pkg" 2>/dev/null
                fi
            done
            cd /
            # 移除標準 dnsmasq
            opkg list-installed | grep -q "^dnsmasq " && opkg remove dnsmasq 2>/dev/null
            echo "  📦 安裝 dnsmasq-full (離線)..."
            # 用 --cache 指定本地快取，opkg 會先找快取再去遠端
            if ls "$DL_DIR"/*.ipk >/dev/null 2>&1; then
                opkg install --cache "$DL_DIR" dnsmasq-full
            else
                pkg_install dnsmasq-full
            fi
            rm -rf "$DL_DIR"
        else
            apk info --installed dnsmasq >/dev/null 2>&1 && apk del dnsmasq 2>/dev/null
            echo "  📦 安裝 dnsmasq-full..."
            pkg_install dnsmasq-full
        fi
        if ! pkg_is_installed dnsmasq-full; then
            echo "  ⚠️  dnsmasq-full 安裝失敗，裝回標準 dnsmasq 保底..."
            pkg_install dnsmasq
        else
            echo "  ✅ dnsmasq-full 安裝成功"
        fi
    fi
    # 其他 gateway 套件
    pkg_install bind-dig \
        luci-proto-wireguard \
        luci-app-pbr luci-i18n-pbr-zh-tw \
        luci-app-ddns luci-i18n-ddns-zh-tw \
        qosify 2>/dev/null
    # 啟用 PBR (安裝後預設 disabled)
    uci set pbr.config.enabled='1' 2>/dev/null
    uci commit pbr 2>/dev/null
fi

# --- 選裝模組 ---
echo ""
echo "--- 選裝模組 ---"

# USB 儲存 + Samba
echo ""
echo "  USB/Samba: USB 隨身碟/硬碟自動掛載 + 網路共享"
if [ "$AUTO_MODE" = "1" ]; then
    install_usb="n"
else
    printf "${C_PROMPT}  安裝 USB/Samba？(y/n) [n]: ${C_RESET}"
    read -r install_usb < /dev/tty
    install_usb="${install_usb:-n}"
fi
if [ "$install_usb" = "y" ]; then
    pkg_install kmod-usb3 kmod-usb-storage-uas usbutils block-mount mount-utils \
        kmod-fs-ext4 kmod-fs-exfat kmod-fs-ntfs3 ntfs-3g \
        samba4-server luci-app-samba4 luci-i18n-samba4-zh-tw 2>/dev/null
    uci set samba4.@samba[0].interface='lan'
    uci commit samba4
    echo "usb-samba" >> "$MODULES_FILE"
    echo "  ✅ USB/Samba 已安裝 (interface=lan)"
fi

# BATMAN mesh
echo ""
echo "  BATMAN: mesh 無線網路組網"
if [ "$AUTO_MODE" = "1" ]; then
    install_batman="y"
else
    printf "${C_PROMPT}  安裝 BATMAN？(y/n) [y]: ${C_RESET}"
    read -r install_batman < /dev/tty
    install_batman="${install_batman:-y}"
fi
if [ "$install_batman" = "y" ]; then
    pkg_install kmod-batman-adv batctl-full luci-proto-batman-adv 2>/dev/null
    # 替換 wpad 為支援 mesh SAE 的版本
    # 記住原本的 wpad 版本，萬一 wpad-openssl 安裝失敗可以裝回
    WPAD_ORIG=""
    if pkg_is_installed wpad-basic-wolfssl; then
        WPAD_ORIG="wpad-basic-wolfssl"
    elif pkg_is_installed wpad-basic-mbedtls; then
        WPAD_ORIG="wpad-basic-mbedtls"
    fi
    if [ -n "$WPAD_ORIG" ]; then
        echo "  📦 移除 $WPAD_ORIG..."
        case "$PKG_MGR" in
            apk)  apk del "$WPAD_ORIG" 2>/dev/null ;;
            opkg) opkg remove "$WPAD_ORIG" 2>/dev/null ;;
        esac
    fi
    pkg_install wpad-openssl 2>/dev/null
    if pkg_is_installed wpad-openssl; then
        echo "  ✅ wpad-openssl 安裝成功"
    elif [ -n "$WPAD_ORIG" ]; then
        echo "  ⚠️  wpad-openssl 安裝失敗，裝回 $WPAD_ORIG 保底..."
        pkg_install "$WPAD_ORIG" 2>/dev/null
        if pkg_is_installed "$WPAD_ORIG"; then
            echo "  ✅ 已裝回 $WPAD_ORIG (WiFi 可用但不支援 mesh SAE)"
        else
            echo "  🚨 無法裝回 wpad！WiFi 可能無法使用！"
        fi
    else
        echo "  ⚠️  wpad-openssl 安裝失敗"
    fi
    echo "batman" >> "$MODULES_FILE"
    echo "  ✅ BATMAN 已安裝"
fi

# Android USB 網路共享
echo ""
echo "  Android tethering: 手機 USB 分享網路給路由器"
if [ "$AUTO_MODE" = "1" ]; then
    install_android="n"
else
    printf "${C_PROMPT}  安裝 Android tethering？(y/n) [n]: ${C_RESET}"
    read -r install_android < /dev/tty
    install_android="${install_android:-n}"
fi
if [ "$install_android" = "y" ]; then
    pkg_install kmod-usb-net kmod-usb-net-rndis kmod-usb-net-cdc-ether usb-modeswitch 2>/dev/null
    echo "android-tether" >> "$MODULES_FILE"
    # 建立 wan_usb 介面 (USB 手機共享上網)
    uci set network.wan_usb=interface
    uci set network.wan_usb.proto='dhcp'
    uci set network.wan_usb.device='usb0'
    uci add_list firewall.@zone[1].network='wan_usb' 2>/dev/null
    echo "  ✅ Android tethering 已安裝 (wan_usb 介面已建立)"
fi

# iPhone USB 網路共享
echo ""
echo "  iPhone tethering: iPhone USB 分享網路給路由器"
if [ "$AUTO_MODE" = "1" ]; then
    install_iphone="n"
else
    printf "${C_PROMPT}  安裝 iPhone tethering？(y/n) [n]: ${C_RESET}"
    read -r install_iphone < /dev/tty
    install_iphone="${install_iphone:-n}"
fi
if [ "$install_iphone" = "y" ]; then
    pkg_install kmod-usb-net kmod-usb-net-ipheth usbmuxd \
        libimobiledevice libimobiledevice-utils 2>/dev/null
    echo "iphone-tether" >> "$MODULES_FILE"
    # 建立 wan_usb 介面 (若 Android tether 未建立)
    if ! uci get network.wan_usb >/dev/null 2>&1; then
        uci set network.wan_usb=interface
        uci set network.wan_usb.proto='dhcp'
        uci set network.wan_usb.device='usb0'
        uci add_list firewall.@zone[1].network='wan_usb' 2>/dev/null
    fi
    echo "  ✅ iPhone tethering 已安裝 (wan_usb 介面已建立)"
fi

# Docker
echo ""
echo "  Docker: 容器化服務 (AdGuard Home, etc.)"
echo "  需要足夠的儲存空間 (建議外接 USB 儲存)"
if [ "$AUTO_MODE" = "1" ]; then
    install_docker="n"
else
    printf "${C_PROMPT}  安裝 Docker？(y/n) [n]: ${C_RESET}"
    read -r install_docker < /dev/tty
    install_docker="${install_docker:-n}"
fi
if [ "$install_docker" = "y" ]; then
    pkg_install dockerd docker-compose luci-app-dockerman luci-i18n-dockerman-zh-tw \
        fuse-overlayfs 2>/dev/null
    echo "docker" >> "$MODULES_FILE"
    echo "  ✅ Docker 已安裝"
    echo ""
    echo "  Docker 根目錄用來存放映像檔和容器資料"
    echo "  空間不足可改到外接 USB (例如 /mnt/sda1/docker)"
    printf "${C_PROMPT}  Docker 根目錄 [/srv/docker]: ${C_RESET}"
    read -r docker_root < /dev/tty
    docker_root="${docker_root:-/srv/docker}"
    mkdir -p "$docker_root"
    uci set dockerd.globals.data_root="$docker_root"
    uci commit dockerd
    echo "  ✅ Docker 根目錄: $docker_root"
fi

# =====================
# 2. 部署腳本和設定檔
# =====================
echo ""
echo "📂 部署腳本和設定檔..."

# myscript 目錄
mkdir -p /etc/myscript
cp -a "$DEPLOY_DIR/etc/myscript/"*.sh /etc/myscript/ 2>/dev/null
cp -a "$DEPLOY_DIR/etc/myscript/"*.inc /etc/myscript/ 2>/dev/null
cp -a "$DEPLOY_DIR/etc/myscript/"*.nft /etc/myscript/ 2>/dev/null
chmod +x /etc/myscript/*.sh

# .secrets 目錄
if [ -d "$DEPLOY_DIR/etc/myscript/.secrets" ]; then
    mkdir -p /etc/myscript/.secrets
    cp -a "$DEPLOY_DIR/etc/myscript/.secrets/"* /etc/myscript/.secrets/ 2>/dev/null
    chmod 700 /etc/myscript/.secrets
    chmod 600 /etc/myscript/.secrets/*
    echo "  ✅ .secrets 已部署"
else
    echo "  ⚠️  .secrets 目錄不存在，需手動建立密鑰檔案："
    echo "      /etc/myscript/.secrets/secret.key"
    echo "      /etc/myscript/.secrets/secret.iv"
    echo "      /etc/myscript/.secrets/secret.url"
    echo "      /etc/myscript/.secrets/pushkey.<名稱>"
    mkdir -p /etc/myscript/.secrets
    chmod 700 /etc/myscript/.secrets
fi

# rc.local
cp "$DEPLOY_DIR/etc/rc.local" /etc/rc.local
echo "  ✅ rc.local"

# SSH 公鑰
mkdir -p /etc/dropbear
if [ -f "$DEPLOY_DIR/etc/dropbear/authorized_keys" ]; then
    cat "$DEPLOY_DIR/etc/dropbear/authorized_keys" >> /etc/dropbear/authorized_keys
    sort -u -o /etc/dropbear/authorized_keys /etc/dropbear/authorized_keys
    echo "  ✅ SSH authorized_keys"
fi

# hotplug.d
mkdir -p /etc/hotplug.d/block /etc/hotplug.d/iface
cp "$DEPLOY_DIR/etc/hotplug.d/block/99-samba-auto-share" /etc/hotplug.d/block/
cp "$DEPLOY_DIR/etc/hotplug.d/iface/99-pbr-cust" /etc/hotplug.d/iface/
chmod +x /etc/hotplug.d/block/99-samba-auto-share
chmod +x /etc/hotplug.d/iface/99-pbr-cust
echo "  ✅ hotplug.d"

# init.d
cp "$DEPLOY_DIR/etc/init.d/dbroute" /etc/init.d/
cp "$DEPLOY_DIR/etc/init.d/pbr-cust" /etc/init.d/
chmod +x /etc/init.d/dbroute
chmod +x /etc/init.d/pbr-cust
/etc/init.d/dbroute enable 2>/dev/null
/etc/init.d/pbr-cust enable 2>/dev/null
echo "  ✅ init.d (dbroute, pbr-cust)"

# firewall (UCI 補上新增的設定，不覆蓋預設)
echo ""
echo "🔧 設定 Firewall (UCI)..."

# helper: 檢查 zone 是否已存在
zone_exists() {
    local i=0
    while uci get firewall.@zone[$i].name >/dev/null 2>&1; do
        if [ "$(uci get firewall.@zone[$i].name)" = "$1" ]; then
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# helper: 檢查 forwarding 是否已存在
fwd_exists() {
    local i=0
    while uci get firewall.@forwarding[$i] >/dev/null 2>&1; do
        local s=$(uci get firewall.@forwarding[$i].src 2>/dev/null)
        local d=$(uci get firewall.@forwarding[$i].dest 2>/dev/null)
        if [ "$s" = "$1" ] && [ "$d" = "$2" ]; then
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# helper: 檢查 rule 是否已存在 (by name)
rule_exists() {
    local i=0
    while uci get firewall.@rule[$i] >/dev/null 2>&1; do
        if [ "$(uci get firewall.@rule[$i].name 2>/dev/null)" = "$1" ]; then
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# helper: 檢查 redirect 是否已存在 (by name)
redirect_exists() {
    local i=0
    while uci get firewall.@redirect[$i] >/dev/null 2>&1; do
        if [ "$(uci get firewall.@redirect[$i].name 2>/dev/null)" = "$1" ]; then
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# flow_offloading
uci set firewall.@defaults[0].flow_offloading='1'

# flow_offloading 以下不再預留 wan_usb/wwan，改由 tether 模組自行建立

# --- VPN zone (大寫，WireGuard 入站) ---
if ! zone_exists VPN; then
    uci add firewall zone >/dev/null
    uci set firewall.@zone[-1].name='VPN'
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='ACCEPT'
    uci set firewall.@zone[-1].masq='1'
fi

# VPN forwardings
fwd_exists VPN lan || { uci add firewall forwarding >/dev/null; uci set firewall.@forwarding[-1].src='VPN'; uci set firewall.@forwarding[-1].dest='lan'; }
fwd_exists lan VPN || { uci add firewall forwarding >/dev/null; uci set firewall.@forwarding[-1].src='lan'; uci set firewall.@forwarding[-1].dest='VPN'; }
fwd_exists wan VPN || { uci add firewall forwarding >/dev/null; uci set firewall.@forwarding[-1].src='wan'; uci set firewall.@forwarding[-1].dest='VPN'; }
fwd_exists VPN wan || { uci add firewall forwarding >/dev/null; uci set firewall.@forwarding[-1].src='VPN'; uci set firewall.@forwarding[-1].dest='wan'; }

# --- vpn zone (小寫，PBR 出站) ---
if ! zone_exists vpn; then
    uci add firewall zone >/dev/null
    uci set firewall.@zone[-1].name='vpn'
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='ACCEPT'
    uci set firewall.@zone[-1].masq='1'
    uci set firewall.@zone[-1].mtu_fix='1'
fi

# vpn forwardings
fwd_exists lan vpn || { uci add firewall forwarding >/dev/null; uci set firewall.@forwarding[-1].src='lan'; uci set firewall.@forwarding[-1].dest='vpn'; }
fwd_exists vpn wan || { uci add firewall forwarding >/dev/null; uci set firewall.@forwarding[-1].src='vpn'; uci set firewall.@forwarding[-1].dest='wan'; }
fwd_exists VPN vpn || { uci add firewall forwarding >/dev/null; uci set firewall.@forwarding[-1].src='VPN'; uci set firewall.@forwarding[-1].dest='vpn'; }
fwd_exists vpn VPN || { uci add firewall forwarding >/dev/null; uci set firewall.@forwarding[-1].src='vpn'; uci set firewall.@forwarding[-1].dest='VPN'; }
fwd_exists wan vpn || { uci add firewall forwarding >/dev/null; uci set firewall.@forwarding[-1].src='wan'; uci set firewall.@forwarding[-1].dest='vpn'; }

# vpn allow rule
rule_exists 'Allow-vpn-to-wan' || {
    uci add firewall rule >/dev/null
    uci set firewall.@rule[-1].name='Allow-vpn-to-wan'
    uci set firewall.@rule[-1].src='vpn'
    uci set firewall.@rule[-1].dest='wan'
    uci set firewall.@rule[-1].proto='all'
    uci set firewall.@rule[-1].target='ACCEPT'
}

# --- docker zone ---
if ! zone_exists docker; then
    uci add firewall zone >/dev/null
    uci set firewall.@zone[-1].name='docker'
    uci set firewall.@zone[-1].input='ACCEPT'
    uci set firewall.@zone[-1].output='ACCEPT'
    uci set firewall.@zone[-1].forward='ACCEPT'
    uci add_list firewall.@zone[-1].network='docker'
fi

# --- WireGuard port redirect + rules ---
# wg1 (port 51820)
redirect_exists 'wireguard_wg1' || {
    uci add firewall redirect >/dev/null
    uci set firewall.@redirect[-1].name='wireguard_wg1'
    uci set firewall.@redirect[-1].src='wan'
    uci set firewall.@redirect[-1].dest='lan'
    uci set firewall.@redirect[-1].target='DNAT'
    uci add_list firewall.@redirect[-1].proto='udp'
    uci set firewall.@redirect[-1].src_dport='51820'
    uci set firewall.@redirect[-1].dest_ip='192.168.1.1'
    uci set firewall.@redirect[-1].dest_port='51820'
}

rule_exists 'wireguard_wg1' || {
    uci add firewall rule >/dev/null
    uci set firewall.@rule[-1].name='wireguard_wg1'
    uci set firewall.@rule[-1].src='wan'
    uci add_list firewall.@rule[-1].proto='udp'
    uci set firewall.@rule[-1].dest_port='51820'
    uci set firewall.@rule[-1].target='ACCEPT'
}

# wg2 (port 51699)
redirect_exists 'wireguard_wg2' || {
    uci add firewall redirect >/dev/null
    uci set firewall.@redirect[-1].name='wireguard_wg2'
    uci set firewall.@redirect[-1].src='wan'
    uci set firewall.@redirect[-1].dest='lan'
    uci set firewall.@redirect[-1].target='DNAT'
    uci add_list firewall.@redirect[-1].proto='udp'
    uci set firewall.@redirect[-1].src_dport='51699'
    uci set firewall.@redirect[-1].dest_ip='192.168.1.1'
    uci set firewall.@redirect[-1].dest_port='51699'
}

rule_exists 'wireguard_wg2' || {
    uci add firewall rule >/dev/null
    uci set firewall.@rule[-1].name='wireguard_wg2'
    uci set firewall.@rule[-1].src='wan'
    uci add_list firewall.@rule[-1].proto='udp'
    uci set firewall.@rule[-1].dest_port='51699'
    uci set firewall.@rule[-1].target='ACCEPT'
}

# --- AdGuard DNS redirect ---
redirect_exists 'adgh_v-p-n' || {
    uci add firewall redirect >/dev/null
    uci set firewall.@redirect[-1].name='adgh_v-p-n'
    uci set firewall.@redirect[-1].target='DNAT'
    uci set firewall.@redirect[-1].src='VPN'
    uci add_list firewall.@redirect[-1].proto='udp'
    uci set firewall.@redirect[-1].src_dport='53'
    uci set firewall.@redirect[-1].dest_port='53535'
    uci set firewall.@redirect[-1].enabled='1'
}

redirect_exists 'adgh_l-a-n' || {
    uci add firewall redirect >/dev/null
    uci set firewall.@redirect[-1].name='adgh_l-a-n'
    uci set firewall.@redirect[-1].target='DNAT'
    uci set firewall.@redirect[-1].src='lan'
    uci add_list firewall.@redirect[-1].proto='udp'
    uci set firewall.@redirect[-1].src_dport='53'
    uci set firewall.@redirect[-1].dest_port='53535'
    uci set firewall.@redirect[-1].enabled='1'
}

# --- dbroute firewall include ---
uci set firewall.dbroute=include
uci set firewall.dbroute.type='script'
uci set firewall.dbroute.path='/etc/myscript/dbroute-fwinclude.sh'
uci set firewall.dbroute.fw4_compatible='1'

uci commit firewall
echo "  ✅ firewall (UCI)"

# sysupgrade.conf
cp "$DEPLOY_DIR/etc/sysupgrade.conf" /etc/sysupgrade.conf 2>/dev/null
echo "  ✅ sysupgrade.conf"

# dnsmasq.d
mkdir -p /etc/dnsmasq.d
cp "$DEPLOY_DIR/etc/dnsmasq.d/dbroute-domains.conf" /etc/dnsmasq.d/ 2>/dev/null
echo "  ✅ dnsmasq.d"

# dnsmasq 預設設定 (gateway: 先用上游 DNS，check-adguard.sh 會自動切到 AdGuard Home)
if [ "$MESH_ROLE" != "client" ]; then
    uci delete dhcp.@dnsmasq[0].server 2>/dev/null
    uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
    uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
    uci set dhcp.@dnsmasq[0].confdir='/etc/dnsmasq.d'
    uci delete dhcp.@dnsmasq[0].interface 2>/dev/null
    uci add_list dhcp.@dnsmasq[0].interface='lan'
    uci add_list dhcp.@dnsmasq[0].interface='wg1'
    uci commit dhcp
    echo "  ✅ dnsmasq DNS → 8.8.8.8 / 1.1.1.1 (AdGuard Home 啟動後由 check-adguard.sh 自動切換)"
fi

# qosify template (sync-googleconfig 需要)
cp "$DEPLOY_DIR/etc/config/qosify_template" /etc/config/ 2>/dev/null
echo "  ✅ qosify_template"

# qosify 預設分類規則
mkdir -p /etc/qosify
cp "$DEPLOY_DIR/etc/qosify/00-defaults.conf" /etc/qosify/ 2>/dev/null
echo "  ✅ qosify 00-defaults.conf"

# AdGuard Home — config 路徑 (安裝後由 uci 偵測)
AGH_YAML=""

# =====================
# 3. 設定 RAM overlay
# =====================
echo ""
echo "🔧 初始化 RAM overlay..."
mkdir -p /tmp/config_ram /tmp/crontabs_ram
cp -a /etc/config/* /tmp/config_ram/
cp -a /etc/crontabs/* /tmp/crontabs_ram/ 2>/dev/null

CRONTAB_FILE="/etc/crontabs/root"
# 固定排程: 每天 12:00 同步 Google Sheet (放最上面)
SYNC_CRON="0 12 * * * /etc/myscript/sync-googleconfig.sh --apply      # Google Sheet 同步"
if ! grep -qF "$SYNC_CRON" "$CRONTAB_FILE" 2>/dev/null; then
    TMP_CRON=$(mktemp)
    echo "$SYNC_CRON" > "$TMP_CRON"
    echo "" >> "$TMP_CRON"
    [ -f "$CRONTAB_FILE" ] && cat "$CRONTAB_FILE" >> "$TMP_CRON"
    mv "$TMP_CRON" "$CRONTAB_FILE"
    echo "  ✅ 已加入每日 12:00 同步排程"
fi
# 建立 SyncArea 區塊 (sync-googleconfig 會在此區塊內更新排程)
if ! grep -q "#SyncAreaStart" "$CRONTAB_FILE" 2>/dev/null; then
    echo "#SyncAreaStart" >> "$CRONTAB_FILE"
    echo "#SyncAreaEnd" >> "$CRONTAB_FILE"
    echo "  ✅ 已建立 SyncArea 區塊"
fi
/etc/init.d/cron restart 2>/dev/null

echo ""
echo "========================================"
echo " ✅ 部署完成"
echo "========================================"

# =====================
# 4. 設定 secrets
# =====================
SECRET_DIR="/etc/myscript/.secrets"
mkdir -p "$SECRET_DIR"
chmod 700 "$SECRET_DIR"

setup_secret() {
    local file="$1"
    local desc="$2"
    local required="$3"  # "required" = 必填, 或數字 = 必須剛好該長度
    # 刪掉舊的，每次重新輸入
    rm -f "$SECRET_DIR/$file"
    echo ""
    if [ "$required" = "required" ] || [ "$required" = "url" ] || echo "$required" | grep -qE '^[0-9]+$'; then
        local val=""
        while true; do
            printf "${C_PROMPT}請輸入 $desc: ${C_RESET}"
            read -r val < /dev/tty
            if [ -z "$val" ]; then
                echo "  ⚠️  此欄位為必填，請重新輸入"
            elif echo "$required" | grep -qE '^[0-9]+$' && [ ${#val} -ne "$required" ]; then
                echo "  ⚠️  長度必須為 $required 字元 (目前 ${#val} 字元)，請重新輸入"
            elif [ "$required" = "url" ] && ! echo "$val" | grep -q '^https://script\.google\.com/macros/s/'; then
                echo "  ⚠️  URL 必須以 https://script.google.com/macros/s/ 開頭，請重新輸入"
            else
                break
            fi
        done
        echo -n "$val" > "$SECRET_DIR/$file"
        chmod 600 "$SECRET_DIR/$file"
        echo "  ✅ $desc 已儲存"
    else
        printf "${C_PROMPT}請輸入 $desc (留空跳過): ${C_RESET}"
        read -r val < /dev/tty
        if [ -n "$val" ]; then
            echo -n "$val" > "$SECRET_DIR/$file"
            chmod 600 "$SECRET_DIR/$file"
            echo "  ✅ $desc 已儲存"
        else
            echo "  ⚠️  $desc 未設定，稍後需手動建立 $SECRET_DIR/$file"
        fi
    fi
}

if [ "$AUTO_MODE" = "1" ]; then
    echo ""
    echo "🔑 寫入密鑰 (auto)..."
    echo -n "$ARG_URL" > "$SECRET_DIR/secret.url"; chmod 600 "$SECRET_DIR/secret.url"
    echo -n "$ARG_KEY" > "$SECRET_DIR/secret.key"; chmod 600 "$SECRET_DIR/secret.key"
    echo -n "$ARG_IV"  > "$SECRET_DIR/secret.iv";  chmod 600 "$SECRET_DIR/secret.iv"
    echo "  ✅ Google Sheet URL/Key/IV 已寫入"
    [ -n "$ARG_TDX_ID" ] && { echo -n "$ARG_TDX_ID" > "$SECRET_DIR/tdx.appid"; chmod 600 "$SECRET_DIR/tdx.appid"; }
    [ -n "$ARG_TDX_KEY" ] && { echo -n "$ARG_TDX_KEY" > "$SECRET_DIR/tdx.appkey"; chmod 600 "$SECRET_DIR/tdx.appkey"; }

    # 測試同步 (dry-run)
    echo ""
    echo "🧪 測試同步 (dry-run)..."
    if /etc/myscript/sync-googleconfig.sh; then
        echo "  ✅ 測試同步成功，密鑰正確"
    else
        echo "  ❌ 測試同步失敗！請檢查 --url / --key / --iv"
        exit 1
    fi
else
    while true; do
        echo ""
        echo "🔑 設定 Google Sheet 同步密鑰..."
        echo "   sync-googleconfig 會定期從 Google Sheet 下載加密設定檔"
        echo "   來自動更新路由器的 Network/DHCP/PBR/QoS/Crontab 等設定"
        echo ""
        echo "   URL 格式: https://script.google.com/macros/s/xxxx.../exec?xxxx..."
        setup_secret "secret.url" "Google Sheet URL" url
        echo ""
        echo "   AES Key 用於解密從 Google Sheet 下載的設定，必須 32 字元"
        setup_secret "secret.key" "AES 加密金鑰 (32字元)" 32
        echo ""
        echo "   AES IV (初始向量) 用於 AES-256-CBC 解密，必須 16 字元"
        setup_secret "secret.iv"  "AES 初始向量 IV (16字元)" 16

        # 測試同步 (dry-run)：下載並解密，確認密鑰正確
        echo ""
        echo "🧪 測試同步 (dry-run)..."
        if /etc/myscript/sync-googleconfig.sh; then
            echo "  ✅ 測試同步成功，密鑰正確"
            break
        else
            echo ""
            echo "  ❌ 測試同步失敗！可能是 URL/Key/IV 輸入錯誤"
            echo "  請重新輸入 Google Sheet 同步密鑰"
        fi
    done

    echo ""
    echo "🔑 設定 TDX 公車 API 密鑰..."
    echo "   TDX (運輸資料流通服務) 用於查詢公車到站時間"
    echo "   申請網址: https://tdx.transportdata.tw/"
    echo ""
    setup_secret "tdx.appid"  "TDX APP ID"
    setup_secret "tdx.appkey" "TDX APP Key"
fi

echo ""
echo "📌 推播通知密鑰 (pushkey) 將由 Google Sheet 同步自動寫入"
echo "   pushkey 存放在 Google Sheet 的 PushKey 工作表"
echo "   同步時會自動寫入 /etc/myscript/.secrets/pushkey.<名稱>"

# =====================
# 5. WiFi 設定
# =====================
echo ""
if [ "$AUTO_MODE" = "1" ]; then
    export AUTO_MODE ARG_WIFI_KEY ARG_IOT_KEY ARG_SSID ARG_COUNTRY ARG_ENCRYPTION MESH_ROLE
    sh "$DEPLOY_DIR/wifi-setup.sh"
else
    printf "${C_PROMPT}是否設定 WiFi (SSID/密碼)？(y/n) [y]: ${C_RESET}"
    read -r setup_wifi < /dev/tty
    setup_wifi="${setup_wifi:-y}"
    case "$setup_wifi" in
        [Nn]) echo "  跳過 WiFi 設定" ;;
        *)    sh "$DEPLOY_DIR/wifi-setup.sh" ;;
    esac
fi

# =====================
# 6. BATMAN mesh + 802.11r/k/v
# =====================
if grep -q "batman" "$MODULES_FILE" 2>/dev/null; then
    echo ""
    if [ "$AUTO_MODE" = "1" ]; then
        export AUTO_MODE ARG_WIFI_KEY
        sh "$DEPLOY_DIR/batman-setup.sh"
    else
        printf "${C_PROMPT}是否設定 BATMAN mesh + 802.11r/k/v？(y/n) [y]: ${C_RESET}"
        read -r setup_batman < /dev/tty
        setup_batman="${setup_batman:-y}"
        case "$setup_batman" in
            [Nn]) echo "  跳過 BATMAN 設定" ;;
            *)    sh "$DEPLOY_DIR/batman-setup.sh" ;;
        esac
    fi
fi

# =====================
# 7. 首次 Google Sheet 同步
# =====================
clear
echo ""
echo "========================================================"
echo "  >>> 即將執行首次 Google Sheet 同步 <<<"
echo ""
echo "  同步會從 Google Sheet 下載並套用以下設定："
echo "    Network / DHCP / PBR / QoS / Crontab / DB Route"
echo ""
echo "  同步完成後路由器會自動重啟"
echo "  重啟後即可正常使用"
echo "========================================================"
echo ""

if [ -f /etc/myscript/.secrets/secret.url ] && [ -f /etc/myscript/.secrets/secret.key ] && [ -f /etc/myscript/.secrets/secret.iv ]; then
    if [ "$AUTO_MODE" != "1" ]; then
        printf "${C_PROMPT}按 Enter 開始同步...${C_RESET}"
        read -r _ < /dev/tty
    fi
    echo ""
    # 首次部署：清除 state 和 MD5 快取，確保完整套用
    rm -rf /tmp/sync-state /tmp/config_base64.md5
    /etc/myscript/sync-googleconfig.sh --apply --no-network-check
    echo ""
    echo "✅ 首次同步完成"
else
    echo "⚠️  密鑰未設定，跳過同步"
    echo "   設定完密鑰後手動執行: /etc/myscript/sync-googleconfig.sh --apply"
fi

echo ""
echo "========================================"
echo " ✅ 部署完成"
echo "========================================"
echo ""
echo "備份位於: $BACKUP_DIR"
echo ""
ROUTER_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
echo "  🌐 LuCI 管理介面: http://$ROUTER_IP"
echo "  🛡️  AdGuard Home:   http://$ROUTER_IP:3000"
echo ""

# =====================
# 時區設定
# =====================
echo ""
echo "🕐 設定時區為 Asia/Taipei (UTC+8)"
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Taipei'
uci commit system
echo "  ✅ 時區已設定為 Asia/Taipei"

# =====================
# LED 設定 (依機型關閉不需要的 LED)
# =====================
BOARD_NAME=$(cat /tmp/sysinfo/board_name 2>/dev/null)
case "$BOARD_NAME" in
    cmcc,rax3000m)
        # RAX3000Z 增強版: CMCC 白燈 GPIO 546 toggle 關閉
        echo 546 > /sys/class/gpio/export 2>/dev/null
        echo out > /sys/class/gpio/gpio546/direction 2>/dev/null
        echo 0 > /sys/class/gpio/gpio546/value 2>/dev/null
        sleep 1
        echo 1 > /sys/class/gpio/gpio546/value 2>/dev/null
        echo 546 > /sys/class/gpio/unexport 2>/dev/null
        echo "  ✅ LED 已關閉 (RAX3000Z GPIO 546)"
        ;;
    *)
        echo "  ℹ️  未知機型 ($BOARD_NAME)，跳過 LED 設定"
        ;;
esac

# zram swap 設定
uci set system.@system[0].zram_comp_algorithm='zstd'
case "$BOARD_NAME" in
    linksys,mx4200*)
        uci set system.@system[0].zram_size_mb='372'
        echo "  ✅ zram swap 設為 372MB zstd (MX4200)"
        ;;
    *)
        echo "  ✅ zram swap 壓縮演算法設為 zstd"
        ;;
esac

# NTP 時間同步伺服器
uci set system.ntp.enabled='1'
uci delete system.ntp.server 2>/dev/null
uci add_list system.ntp.server='time.stdtime.gov.tw'
uci add_list system.ntp.server='clock.stdtime.gov.tw'
uci add_list system.ntp.server='0.openwrt.pool.ntp.org'
uci add_list system.ntp.server='1.openwrt.pool.ntp.org'
uci commit system
/etc/init.d/sysntpd restart 2>/dev/null
echo "  ✅ NTP 伺服器已設定 (台灣 + OpenWrt)"

# =====================
# UPnP (gateway only)
# =====================
if [ "$MESH_ROLE" != "client" ]; then
    echo ""
    echo "  UPnP: 允許內網裝置自動開 port (遊戲/P2P)"
    echo "  ⚠️  有安全風險，惡意軟體也能利用"
    if [ "$AUTO_MODE" = "1" ]; then
        enable_upnp="n"
    else
        printf "${C_PROMPT}  啟用 UPnP？(y/n) [n]: ${C_RESET}"
        read -r enable_upnp < /dev/tty
    fi
    case "${enable_upnp:-n}" in
        [Yy])
            pkg_install miniupnpd luci-app-upnp 2>/dev/null
            uci set upnpd.config.enabled='1'
            uci commit upnpd
            /etc/init.d/miniupnpd enable 2>/dev/null
            echo "  ✅ UPnP 已啟用"
            ;;
        *) echo "  ⏭️  跳過 UPnP" ;;
    esac
fi

# =====================
# 修改 LAN IP
# =====================
CUR_IP=$(uci get network.lan.ipaddr 2>/dev/null || echo "192.168.1.1")
echo ""
if [ "$MESH_ROLE" = "client" ]; then
    echo "  📡 Client 節點 LAN IP 設定"
    if [ "$AUTO_MODE" = "1" ]; then
        # auto 模式預設 DHCP
        use_dhcp="y"
    else
        printf "${C_PROMPT}  使用 DHCP 自動取得 IP？(y/n) [y]: ${C_RESET}"
        read -r use_dhcp < /dev/tty
    fi
    case "${use_dhcp:-y}" in
        [Nn])
            echo "  多台 client 請依序編號: .2, .3, .4, .5 ..."
            printf "${C_PROMPT}  輸入 LAN IP [192.168.1.2]: ${C_RESET}"
            read -r new_ip < /dev/tty
            new_ip="${new_ip:-192.168.1.2}"
            printf "${C_PROMPT}  輸入 Netmask [255.255.255.0]: ${C_RESET}"
            read -r new_mask < /dev/tty
            new_mask="${new_mask:-255.255.255.0}"
            printf "${C_PROMPT}  輸入 Gateway [192.168.1.1]: ${C_RESET}"
            read -r new_gw < /dev/tty
            new_gw="${new_gw:-192.168.1.1}"
            uci set network.lan.proto='static'
            uci set network.lan.ipaddr="$new_ip"
            uci set network.lan.netmask="$new_mask"
            uci set network.lan.gateway="$new_gw"
            uci set network.lan.dns="$new_gw"
            uci commit network
            echo "  ✅ LAN 靜態 IP: $new_ip/$new_mask GW: $new_gw"
            ;;
        *)
            uci set network.lan.proto='dhcp'
            uci delete network.lan.ipaddr 2>/dev/null
            uci delete network.lan.netmask 2>/dev/null
            uci delete network.lan.gateway 2>/dev/null
            uci commit network
            echo "  ✅ LAN 已設定為 DHCP（重啟後自動取得 IP）"
            ;;
    esac
    # client 關閉 DHCP server (由 gateway 派發)
    uci set dhcp.lan.ignore='1'
    uci commit dhcp
else
    if [ "$AUTO_MODE" = "1" ]; then
        change_ip="y"
    else
        printf "${C_PROMPT}  修改 LAN IP 為 192.168.1.1？(目前: $CUR_IP) (y/n) [y]: ${C_RESET}"
        read -r change_ip < /dev/tty
    fi
    case "${change_ip:-y}" in
        [Nn]) ;;
        *)
            uci set network.lan.ipaddr='192.168.1.1'
            uci set network.lan.netmask='255.255.255.0'
            uci commit network
            # DHCP 派發範圍也對應 192.168.1.x
            uci set dhcp.lan.start='100'
            uci set dhcp.lan.limit='150'
            uci set dhcp.lan.leasetime='12h'
            uci commit dhcp
            echo "  ✅ LAN IP 已設定為 192.168.1.1，DHCP 範圍 192.168.1.100-249 (重啟後生效)"
            ;;
    esac
fi

# =====================
# 設定 root 密碼 (提前問，AGH install 要用)
# =====================
echo ""
echo "🔑 設定 root 密碼 (SSH/LuCI/AdGuard Home 共用)"
echo "   新刷的 OpenWrt 預設密碼為空，建議設定密碼"
if [ "$AUTO_MODE" = "1" ]; then
    root_pw="$ARG_ROOT_PW"
else
    root_pw=""
    while true; do
        printf "${C_PROMPT}  請輸入新的 root 密碼 (至少8字元): ${C_RESET}"
        read -r root_pw < /dev/tty
        if [ -z "$root_pw" ]; then
            echo "  ⚠️  密碼不能為空，請重新輸入"
        elif [ ${#root_pw} -lt 8 ]; then
        echo "  ⚠️  密碼至少需要 8 個字元 (AdGuard Home 要求)，請重新輸入"
        root_pw=""
    else
        break
    fi
done
fi
(echo "$root_pw"; echo "$root_pw") | passwd root >/dev/null 2>&1
echo "  ✅ root 密碼已設定 (SSH/LuCI)"

# =====================
# 確保所有套件已安裝 (含 AdGuard Home)
# =====================
echo ""
echo "📦 檢查並安裝所有必要套件..."
/etc/myscript/check-custpkgs.sh --now --no-reboot

# =====================
# AdGuard Home 客製化設定 (gateway only)
# =====================
if [ "$MESH_ROLE" != "client" ]; then
# 重新偵測 AGH 路徑 (check-custpkgs 可能剛裝完)
AGH_YAML=$(uci get adguardhome.config.config_file 2>/dev/null)
[ -z "$AGH_YAML" ] && AGH_YAML=$(uci get adguardhome.config.config 2>/dev/null)
[ -z "$AGH_YAML" ] && AGH_YAML="/etc/adguardhome/adguardhome.yaml"
AGH_DIR=$(dirname "$AGH_YAML")
mkdir -p "$AGH_DIR"
AGH_BIN=$(command -v AdGuardHome 2>/dev/null || which AdGuardHome 2>/dev/null || echo "")
[ -z "$AGH_BIN" ] && [ -x /usr/bin/AdGuardHome ] && AGH_BIN="/usr/bin/AdGuardHome"
echo "  AGH yaml 路徑: $AGH_YAML"
# AGH 首次安裝不會自動產生 yaml (會進入 setup wizard)
# 需要透過 install API 完成初始設定
if [ -n "$AGH_BIN" ]; then
    echo "  📝 初始化 AdGuard Home..."
    # 確保 AGH 完全停掉
    /etc/init.d/adguardhome stop 2>/dev/null || true
    killall AdGuardHome 2>/dev/null || true
    sleep 2
    # 刪除可能不完整的 yaml (setup wizard 狀態的 yaml)
    rm -f "$AGH_YAML"
    # 用 init.d 啟動 (確保路徑和 ujail 設定與正式運行一致)
    /etc/init.d/adguardhome start 2>/dev/null || true
    # 等待 AGH API ready
    AGH_READY=0
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:3000/control/install/get_addresses" 2>/dev/null | grep -q '200'; then
            AGH_READY=1
            break
        fi
        sleep 1
    done
    if [ "$AGH_READY" = "1" ]; then
        # 呼叫 install API 完成初始設定 (跳過 setup wizard)
        INSTALL_RESULT=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:3000/control/install/configure" \
            -H "Content-Type: application/json" \
            -d '{
                "web":{"ip":"0.0.0.0","port":3000},
                "dns":{"ip":"0.0.0.0","port":53535},
                "username":"root",
                "password":"'"$root_pw"'"
            }' 2>/dev/null)
        if [ "$INSTALL_RESULT" = "200" ]; then
            echo "  ✅ install API 成功，yaml 已產生 → $AGH_YAML"
        else
            echo "  ⚠️  install API 回應: $INSTALL_RESULT (可能需要手動設定)"
        fi
    else
        echo "  ⚠️  AGH 未在 10 秒內就緒，跳過 install API"
    fi
    # install 完成後停掉 AGH (稍後客製化 yaml 後再啟動)
    sleep 2
    /etc/init.d/adguardhome stop 2>/dev/null || true
    killall AdGuardHome 2>/dev/null || true
    sleep 1
fi
# 用 sed 客製化 AGH yaml (不依賴 API，版本無關)
if [ -f "$AGH_YAML" ] && [ -n "$AGH_BIN" ]; then
    echo ""
    echo "🛡️  AdGuard Home 客製化設定 (直接修改 yaml)"

    # --- DNS 設定 (必要，不詢問) ---
    sed -i '/^dns:/,/^[a-z]/{s/^  port: .*/  port: 53535/}' "$AGH_YAML"
    sed -i '/^dns:/,/^[a-z]/{s/^  ratelimit: .*/  ratelimit: 1000/}' "$AGH_YAML"
    sed -i '/^dns:/,/^[a-z]/{s/^  upstream_mode: .*/  upstream_mode: parallel/}' "$AGH_YAML"
    awk '
    /^  upstream_dns:/ { print "  upstream_dns:"; skip=1
        print "    - tls://dns10.quad9.net/dns-query"
        print "    - https://cloudflare-dns.com/dns-query"
        print "    - tls://dns.google/dns-query"
        next
    }
    /^  bootstrap_dns:/ { print "  bootstrap_dns:"; skip=1
        print "    - 1.1.1.1"
        print "    - 8.8.8.8"
        print "    - 9.9.9.10"
        print "    - 149.112.112.10"
        print "    - \"2620:fe::10\""
        print "    - \"2620:fe::fe:10\""
        next
    }
    /^  fallback_dns:/ { print "  fallback_dns:"; skip=1
        print "    - 168.95.1.1"
        next
    }
    skip && /^  [a-z]/ { skip=0 }
    skip { next }
    { print }
    ' "$AGH_YAML" > "${AGH_YAML}.tmp" && mv "${AGH_YAML}.tmp" "$AGH_YAML"
    echo "  ✅ DNS 設定已套用 (port=53535, parallel, DoT/DoH)"

    # --- 確保預設過濾清單啟用 (必要，不詢問) ---
    # filters 區塊格式: enabled/url/name 順序不固定且不相鄰
    # 收集每個 entry 的所有行，結束時判斷是否需要啟用
    awk '
    /^filters:/ { in_filters=1 }
    in_filters && /^[a-z]/ && !/^filters:/ { in_filters=0 }
    in_filters && /^  - / {
        # 輸出前一個 entry
        if(entry_count>0) {
            if(need_enable) {
                for(i=1;i<=entry_count;i++) sub(/enabled: false/, "enabled: true", entry[i])
            }
            for(i=1;i<=entry_count;i++) print entry[i]
        }
        entry_count=0; need_enable=0
    }
    in_filters && /^  / {
        entry_count++
        entry[entry_count]=$0
        if(/AdGuard DNS filter/ || /AdAway Default Blocklist/) need_enable=1
        next
    }
    {
        # 輸出殘留 entry
        if(entry_count>0) {
            if(need_enable) {
                for(i=1;i<=entry_count;i++) sub(/enabled: false/, "enabled: true", entry[i])
            }
            for(i=1;i<=entry_count;i++) print entry[i]
            entry_count=0; need_enable=0
        }
        print
    }
    END {
        if(entry_count>0) {
            if(need_enable) {
                for(i=1;i<=entry_count;i++) sub(/enabled: false/, "enabled: true", entry[i])
            }
            for(i=1;i<=entry_count;i++) print entry[i]
        }
    }
    ' "$AGH_YAML" > "${AGH_YAML}.tmp" && mv "${AGH_YAML}.tmp" "$AGH_YAML"
    echo "  ✅ 預設過濾清單已啟用 (AdGuard DNS + AdAway)"

    # --- 快取設定 ---
    if [ "$AUTO_MODE" != "1" ]; then
        printf "${C_PROMPT}  套用快取設定？(2MB, TTL 1800-7200, optimistic cache) (y/n) [y]: ${C_RESET}"
        read -r agh_cache < /dev/tty
    fi
    case "${agh_cache:-y}" in
        [Nn]) ;;
        *)
            sed -i '/^dns:/,/^[a-z]/{
                s/^  cache_size: .*/  cache_size: 2097152/
                s/^  cache_ttl_min: .*/  cache_ttl_min: 1800/
                s/^  cache_ttl_max: .*/  cache_ttl_max: 7200/
                s/^  cache_optimistic: .*/  cache_optimistic: true/
            }' "$AGH_YAML"
            echo "  ✅ 快取設定已套用"
            ;;
    esac

    # --- 日誌/統計 精簡 ---
    if [ "$AUTO_MODE" != "1" ]; then
        printf "${C_PROMPT}  精簡日誌/統計？(interval 12h，節省空間) (y/n) [y]: ${C_RESET}"
        read -r agh_log < /dev/tty
    fi
    case "${agh_log:-y}" in
        [Nn]) ;;
        *)
            sed -i '/^querylog:/,/^[a-z]/{s/^  interval: .*/  interval: 12h/}' "$AGH_YAML"
            sed -i '/^statistics:/,/^[a-z]/{s/^  interval: .*/  interval: 12h/}' "$AGH_YAML"
            echo "  ✅ 日誌/統計已精簡"
            ;;
    esac

    # --- 安全過濾 ---
    if [ "$AUTO_MODE" != "1" ]; then
        printf "${C_PROMPT}  啟用安全過濾？(safe_search + parental + safebrowsing) (y/n) [y]: ${C_RESET}"
        read -r agh_safe < /dev/tty
    fi
    case "${agh_safe:-y}" in
        [Nn]) ;;
        *)
            # safe_search (filtering 區塊下)
            sed -i '/^filtering:/,/^[a-z]/{
                /^  safe_search:$/,/^  [a-z]/{
                    s/^    enabled: .*/    enabled: true/
                    s/^    bing: .*/    bing: true/
                    s/^    duckduckgo: .*/    duckduckgo: true/
                    s/^    ecosia: .*/    ecosia: true/
                    s/^    google: .*/    google: true/
                    s/^    pixabay: .*/    pixabay: true/
                    s/^    yandex: .*/    yandex: true/
                    s/^    youtube: .*/    youtube: true/
                }
                s/^  parental_enabled: .*/  parental_enabled: true/
                s/^  safebrowsing_enabled: .*/  safebrowsing_enabled: true/
            }' "$AGH_YAML"
            echo "  ✅ 安全過濾已啟用"
            ;;
    esac

    # --- 額外 filter 清單 ---
    if [ "$AUTO_MODE" != "1" ]; then
        printf "${C_PROMPT}  加入額外過濾清單？(CHN: AdRules, anti-AD, uBlock Badware) (y/n) [y]: ${C_RESET}"
        read -r agh_filters < /dev/tty
    fi
    case "${agh_filters:-y}" in
        [Nn]) ;;
        *)
            # 在 filters: 區塊最後一個 id: 行後面追加新清單
            # 用 awk 找到 filters 區塊結尾並插入
            awk '
            /^filters:/ { in_filters=1 }
            in_filters && /^[a-z]/ && !/^filters:/ {
                # 到了 filters 區塊結束，插入新清單
                print "  - enabled: false"
                print "    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_29.txt"
                print "    name: \"CHN: AdRules DNS List\""
                print "    id: 1763618710"
                print "  - enabled: false"
                print "    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_21.txt"
                print "    name: \"CHN: anti-AD\""
                print "    id: 1763618711"
                print "  - enabled: true"
                print "    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_50.txt"
                print "    name: uBlock filters - Badware risks"
                print "    id: 1763618712"
                in_filters=0
            }
            { print }
            ' "$AGH_YAML" > "${AGH_YAML}.tmp" && mv "${AGH_YAML}.tmp" "$AGH_YAML"
            echo "  ✅ 額外過濾清單已加入"
            ;;
    esac

    # --- boss 客戶端 (不受 safe_search/parental 限制) ---
    if [ "$AUTO_MODE" != "1" ]; then
        printf "${C_PROMPT}  建立 boss 客戶端？(192.168.1.10-13 不受家長控制) (y/n) [y]: ${C_RESET}"
        read -r agh_boss < /dev/tty
    fi
    case "${agh_boss:-y}" in
        [Nn]) ;;
        *)
            # 在 clients.persistent: 後面追加 boss 客戶端
            # 處理 "persistent: []" 和 "persistent:" 兩種格式
            awk '
            /^  persistent:/ {
                print "  persistent:"
                print "    - safe_search:"
                print "        enabled: false"
                print "        bing: false"
                print "        duckduckgo: false"
                print "        ecosia: false"
                print "        google: false"
                print "        pixabay: false"
                print "        yandex: false"
                print "        youtube: false"
                print "      blocked_services:"
                print "        schedule:"
                print "          time_zone: UTC"
                print "        ids: []"
                print "      name: boss"
                print "      ids:"
                print "        - 192.168.1.10"
                print "        - 192.168.1.11"
                print "        - 192.168.1.12"
                print "        - 192.168.1.13"
                print "      tags:"
                print "        - device_phone"
                print "      upstreams: []"
                print "      upstreams_cache_size: 0"
                print "      upstreams_cache_enabled: false"
                print "      use_global_settings: false"
                print "      filtering_enabled: true"
                print "      parental_enabled: false"
                print "      safebrowsing_enabled: true"
                print "      use_global_blocked_services: true"
                print "      ignore_querylog: false"
                print "      ignore_statistics: false"
                next
            }
            { print }
            ' "$AGH_YAML" > "${AGH_YAML}.tmp" && mv "${AGH_YAML}.tmp" "$AGH_YAML"
            echo "  ✅ boss 客戶端已建立"
            ;;
    esac

    echo "  ✅ AdGuard Home yaml 客製化完成"

    # 最後才啟動 AGH
    /etc/init.d/adguardhome stop 2>/dev/null || true
    killall AdGuardHome 2>/dev/null || true
    sleep 1
    /etc/init.d/adguardhome start 2>/dev/null || true
    echo "  🚀 AdGuard Home 已啟動"
fi
fi  # end gateway-only AGH


# =====================
# 重啟前驗證 LAN 設定完整性
# =====================
LAN_PROTO=$(uci get network.lan.proto 2>/dev/null)
LAN_IP=$(uci get network.lan.ipaddr 2>/dev/null)
LAN_NETMASK=$(uci get network.lan.netmask 2>/dev/null)
LAN_DEVICE=$(uci get network.lan.device 2>/dev/null)
if [ "$LAN_PROTO" = "dhcp" ]; then
    # DHCP 模式只需要 device
    if [ -z "$LAN_DEVICE" ]; then
        echo "  ⚠️ LAN device 未設定，修復中..."
        uci set network.lan.device='br-lan'
        uci commit network
        echo "  ✅ LAN device 已修復"
    fi
elif [ -z "$LAN_PROTO" ] || [ -z "$LAN_IP" ] || [ -z "$LAN_DEVICE" ] || [ -z "$LAN_NETMASK" ]; then
    echo ""
    echo "⚠️  LAN 設定異常！"
    echo "  proto=$LAN_PROTO ip=$LAN_IP netmask=$LAN_NETMASK device=$LAN_DEVICE"
    echo "  正在修復..."
    [ -z "$LAN_PROTO" ] && uci set network.lan.proto='static'
    [ -z "$LAN_IP" ] && uci set network.lan.ipaddr='192.168.1.1'
    [ -z "$LAN_NETMASK" ] && uci set network.lan.netmask='255.255.255.0'
    [ -z "$LAN_DEVICE" ] && uci set network.lan.device='br-lan'
    uci commit network
    echo "  ✅ LAN 設定已修復"
else
    echo ""
    echo "✅ LAN 驗證通過: $LAN_IP/$LAN_NETMASK ($LAN_DEVICE)"
fi

# 輸出關鍵設定供 debug
echo ""
echo "--- Debug: 關鍵設定 ---"
echo "[network.lan]"
uci show network.lan 2>/dev/null
echo ""
echo "[wireless]"
uci show wireless 2>/dev/null
echo ""
echo "[dhcp.lan]"
uci show dhcp.lan 2>/dev/null
echo ""
echo "[dhcp.@dnsmasq[0]]"
uci show dhcp.@dnsmasq[0] 2>/dev/null
echo ""
echo "[firewall zones]"
uci show firewall | grep -E '\.name=|\.input=|\.output=|\.forward=' 2>/dev/null
echo "--- Debug end ---"

echo ""
printf "${C_GREEN}========================================${C_RESET}\n"
printf "${C_GREEN} ✅ 安裝已完成！${C_RESET}\n"
printf "${C_GREEN}========================================${C_RESET}\n"
echo ""
# 重啟前確保 /tmp/config_ram 是最新的（首次安裝時尚未 mount --bind）
cp -a /etc/config/* /tmp/config_ram/ 2>/dev/null
cp -a /etc/crontabs/* /tmp/crontabs_ram/ 2>/dev/null
# 同步到 flash，避免重開機後設定遺失
echo "💾 同步設定到 flash..."
/etc/myscript/sync-ram2flash.sh

if [ "$AUTO_MODE" = "1" ]; then
    echo ""
    echo "🎉 自動部署完成！10 秒後自動重啟..."
    sleep 10
    reboot
else
    printf "${C_PROMPT}是否立即重啟路由器？(y/n) [y]: ${C_RESET}"
    read -r do_reboot < /dev/tty
    do_reboot="${do_reboot:-y}"
    case "$do_reboot" in
        [Nn]) echo "稍後手動執行: reboot" ;;
        *)    echo "🔄 重啟中..."; reboot ;;
    esac
fi
