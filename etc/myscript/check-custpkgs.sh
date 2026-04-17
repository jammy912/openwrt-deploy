#!/bin/sh
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# 引入通知器
. /etc/myscript/push_notify.inc
PUSH_NAMES="admin" # 多人用分號分隔，例如 "admin;ann"

# 基礎套件 (所有節點都裝)
REQUIRED_PKGS="coreutils-base64 openssl-util curl rsync zram-swap kmod-zram luci-i18n-base-zh-tw luci-i18n-firewall-zh-tw luci-theme-material usteer luci-app-usteer luci-i18n-usteer-zh-tw iperf3"

# gateway 額外套件 (必須明確為 gateway 才裝，未設定角色時不裝)
MESH_ROLE=$(cat /etc/myscript/.mesh_role 2>/dev/null)
if [ "$MESH_ROLE" = "gateway" ] || [ "$MESH_ROLE" = "hybrid" ]; then
    REQUIRED_PKGS="$REQUIRED_PKGS adguardhome bind-dig dnsmasq-full luci-proto-wireguard luci-app-pbr luci-i18n-pbr-zh-tw luci-app-ddns luci-i18n-ddns-zh-tw qosify jq iputils-arping"
fi

# 依 .modules 動態加入模組套件
MODULES_FILE="/etc/myscript/.modules"
if [ -f "$MODULES_FILE" ]; then
    grep -q "usb-samba" "$MODULES_FILE" && \
        REQUIRED_PKGS="$REQUIRED_PKGS kmod-usb3 kmod-usb-storage-uas usbutils block-mount mount-utils kmod-fs-ext4 kmod-fs-exfat kmod-fs-ntfs3 ntfs-3g samba4-server luci-app-samba4 luci-i18n-samba4-zh-tw"
    grep -q "batman" "$MODULES_FILE" && \
        REQUIRED_PKGS="$REQUIRED_PKGS kmod-batman-adv batctl-full luci-proto-batman-adv wpad-openssl"
    grep -q "android-tether" "$MODULES_FILE" && \
        REQUIRED_PKGS="$REQUIRED_PKGS kmod-usb-net kmod-usb-net-rndis kmod-usb-net-cdc-ether usb-modeswitch"
    grep -q "iphone-tether" "$MODULES_FILE" && \
        REQUIRED_PKGS="$REQUIRED_PKGS kmod-usb-net kmod-usb-net-ipheth usbmuxd libimobiledevice libimobiledevice-utils"
    grep -q "docker" "$MODULES_FILE" && \
        REQUIRED_PKGS="$REQUIRED_PKGS dockerd docker-compose luci-app-dockerman luci-i18n-dockerman-zh-tw fuse-overlayfs"
fi

MAX_RETRY=3
SLEEP_BETWEEN=30   # 每次重試之間的等待秒數
LOG_FILE="/tmp/pkgmgr_output.log"
INSTALLED_FLAG=""

# 偵測套件管理器：優先 apk（25.12+），否則 opkg（24.10）
if command -v apk >/dev/null 2>&1; then
    PKG_MGR="apk"
else
    PKG_MGR="opkg"
fi

pkg_update() {
    case "$PKG_MGR" in
        apk)  apk update >"$LOG_FILE" 2>&1 ;;
        opkg) opkg update >"$LOG_FILE" 2>&1 ;;
    esac
}

pkg_install() {
    case "$PKG_MGR" in
        apk)  apk add $@ >"$LOG_FILE" 2>&1 ;;
        opkg) opkg --force-checksum install $@ >"$LOG_FILE" 2>&1 ;;
    esac
}

pkg_is_installed() {
    case "$PKG_MGR" in
        apk)  apk info --installed "$1" >/dev/null 2>&1 ;;
        opkg) opkg list-installed | grep -q "^$1 " ;;
    esac
}

check_and_install() {
    local missing=""

    # 找出缺少的套件
    for pkg in $REQUIRED_PKGS; do
        if ! pkg_is_installed "$pkg"; then
            missing="$missing $pkg"
        fi
    done

    if [ -n "$missing" ]; then
        local need_dnsmasq_swap=0
        if echo "$missing" | grep -qw "dnsmasq-full"; then
            if pkg_is_installed "dnsmasq"; then
                need_dnsmasq_swap=1
            fi
        fi

        local need_wpad_swap=0
        if echo "$missing" | grep -qw "wpad-openssl"; then
            need_wpad_swap=1
        fi

        log "⚠️ [$PKG_MGR] 缺少套件:$missing，開始安裝。"

        local try=1
        while [ $try -le $MAX_RETRY ]; do
            log "📦 嘗試第 $try 次安裝。先執行 $PKG_MGR update..."
            pkg_update
            if [ $? -eq 0 ]; then
                log "✅ $PKG_MGR update 成功。"
            else
                log "❌ $PKG_MGR update 失敗！錯誤訊息：$(cat "$LOG_FILE")"
                try=$((try + 1))
                log "❌ 安裝失敗，等待 $SLEEP_BETWEEN 秒後重試..."
                sleep $SLEEP_BETWEEN
                continue
            fi

            # update 成功後才移除互斥套件（避免移除後裝不回來）
            if [ "$need_dnsmasq_swap" = "1" ]; then
                log "📦 移除標準 dnsmasq 以安裝 dnsmasq-full..."
                case "$PKG_MGR" in
                    apk)  apk del dnsmasq >"$LOG_FILE" 2>&1 ;;
                    opkg) opkg remove dnsmasq >"$LOG_FILE" 2>&1 ;;
                esac
                need_dnsmasq_swap=0
            fi

            if [ "$need_wpad_swap" = "1" ]; then
                log "📦 移除所有 wpad-*/batctl-* 衝突套件以安裝 wpad-openssl..."
                case "$PKG_MGR" in
                    apk)
                        for wp in $(apk list --installed 2>/dev/null | grep -oE 'wpad-[^ ]+' | cut -d- -f1-3 | sort -u | grep -v '^wpad-openssl$'); do
                            apk del "$wp" >"$LOG_FILE" 2>&1 && log "    🗑️ 已移除 $wp"
                        done
                        # 移除 wpad 可能連帶裝入 batctl-default，與 batctl-full 衝突
                        if apk info --installed batctl-default >/dev/null 2>&1; then
                            apk del batctl-default >"$LOG_FILE" 2>&1 && log "    🗑️ 已移除 batctl-default"
                        fi ;;
                    opkg)
                        for wp in $(opkg list-installed 2>/dev/null | grep -oE '^wpad-[^ ]+' | grep -v '^wpad-openssl$'); do
                            opkg remove "$wp" >"$LOG_FILE" 2>&1 && log "    🗑️ 已移除 $wp"
                        done ;;
                esac
                need_wpad_swap=0
            fi

            log "📦 執行 $PKG_MGR install$missing..."
            pkg_install $missing
            if [ $? -eq 0 ]; then
                log "✅ 所有缺少的套件已成功安裝。"
                INSTALLED_FLAG="1"

                # 安裝 usteer 後，套用建議設定並啟用
                if echo "$missing" | grep -qw "usteer"; then
                    uci -q get usteer.@usteer[0] >/dev/null 2>&1 || uci add usteer usteer >/dev/null 2>&1
                    uci set usteer.@usteer[0].network='lan'
                    uci set usteer.@usteer[0].syslog='1'
                    uci set usteer.@usteer[0].local_mode='0'
                    uci set usteer.@usteer[0].ipv6='0'
                    uci set usteer.@usteer[0].debug_level='2'
                    uci set usteer.@usteer[0].signal_diff_threshold='10'
                    uci set usteer.@usteer[0].min_connect_snr='-65'
                    uci set usteer.@usteer[0].min_snr='-70'
                    uci set usteer.@usteer[0].roam_scan_snr='-60'
                    uci set usteer.@usteer[0].roam_trigger_snr='-70'
                    uci set usteer.@usteer[0].roam_trigger_interval='30000'
                    uci set usteer.@usteer[0].roam_kick_delay='2000'
                    uci set usteer.@usteer[0].roam_process_timeout='5000'
                    uci set usteer.@usteer[0].initial_connect_delay='200'
                    uci set usteer.@usteer[0].band_steering_interval='120000'
                    uci set usteer.@usteer[0].band_steering_min_snr='-60'
                    uci set usteer.@usteer[0].assoc_steering='1'
                    uci set usteer.@usteer[0].probe_steering='1'
                    uci set usteer.@usteer[0].load_kick_enabled='1'
                    uci set usteer.@usteer[0].load_kick_threshold='40'
                    uci set usteer.@usteer[0].load_kick_min_clients='5'
                    uci set usteer.@usteer[0].load_kick_delay='10000'

                    # 只管理 5G AP 的 SSID，排除 IOT / 訪客等非漫遊 SSID
                    while uci -q delete usteer.@usteer[0].ssid_list; do :; done
                    local idx=0
                    while uci -q get wireless.@wifi-iface[$idx] >/dev/null 2>&1; do
                        local dev=$(uci -q get wireless.@wifi-iface[$idx].device)
                        local band=$(uci -q get wireless."$dev".band)
                        local mode=$(uci -q get wireless.@wifi-iface[$idx].mode)
                        local ssid=$(uci -q get wireless.@wifi-iface[$idx].ssid)
                        local disabled=$(uci -q get wireless.@wifi-iface[$idx].disabled)
                        if [ "$band" = "5g" ] && [ "$mode" = "ap" ] && [ -n "$ssid" ] && [ "$disabled" != "1" ]; then
                            uci add_list usteer.@usteer[0].ssid_list="$ssid"
                            log "📡 usteer ssid_list 加入: $ssid"
                        fi
                        idx=$((idx + 1))
                    done

                    uci commit usteer
                    /etc/init.d/usteer enable
                    log "🎉 usteer 已安裝並套用漫遊設定。"
                fi

                # 安裝 samba4 後，設定 interface 為 lan
                if echo "$missing" | grep -qw "samba4-server"; then
                    uci set samba4.@samba[0].interface='lan'
                    uci commit samba4
                    log "🎉 samba4 已設定 interface=lan"
                fi

                # 安裝 AdGuardHome 後，啟用服務
                if echo "$missing" | grep -qw "adguardhome"; then
                    /etc/init.d/adguardhome enable
                    # --no-reboot 代表由 deploy.sh 呼叫，AGH 由 deploy.sh 負責初始化
                    if [ "$NO_REBOOT" = "0" ]; then
                        log "🎉 adguardhome 已安裝，啟動服務。"
                        . /etc/myscript/lock_handler.sh
                        lock_check_and_create "agh_startup" 300 >/dev/null 2>&1
                        /etc/init.d/adguardhome start
                    else
                        log "🎉 adguardhome 已安裝，由 deploy.sh 負責初始化。"
                    fi
                fi

                rm -f "$LOG_FILE"
                return 0
            else
                log "❌ $PKG_MGR install 失敗！錯誤訊息：$(cat "$LOG_FILE")"
                # dnsmasq-full 安裝失敗，裝回標準 dnsmasq 保底
                if ! pkg_is_installed "dnsmasq-full" && ! pkg_is_installed "dnsmasq"; then
                    log "🔄 dnsmasq-full 未裝成功，裝回標準 dnsmasq 保底..."
                    case "$PKG_MGR" in
                        apk)  apk add dnsmasq >"$LOG_FILE" 2>&1 ;;
                        opkg) opkg install dnsmasq >"$LOG_FILE" 2>&1 ;;
                    esac
                    if [ $? -eq 0 ]; then
                        log "✅ 已裝回標準 dnsmasq。"
                    else
                        log "🚨 無法裝回 dnsmasq！DNS/DHCP 可能中斷！"
                    fi
                fi
                try=$((try + 1))
                log "❌ 安裝失敗，等待 $SLEEP_BETWEEN 秒後重試..."
                sleep $SLEEP_BETWEEN
            fi
        done

        log "🚨 多次嘗試後仍無法安裝:$missing"
        rm -f "$LOG_FILE"
        return 1
    else
        log "✅ [$PKG_MGR] 所有必要套件已安裝"
    fi
}

log() {
    logger -t checkpkgs "$1"
    [ "$VERBOSE" = "1" ] && echo "$1"
}

main() {
    VERBOSE=0
    NO_REBOOT=0
    for arg in "$@"; do
        case "$arg" in
            --now) VERBOSE=1 ;;
            --no-reboot) NO_REBOOT=1 ;;
        esac
    done
    if [ "$VERBOSE" = "0" ]; then
        sleep 30   # 延遲 30 秒再檢查
    fi
    # 等待網路就緒（retry 5 次，每次等 30 秒）
    NET_OK=0
    for i in 1 2 3 4 5; do
        if ping -c 2 -W 5 8.8.8.8 >/dev/null 2>&1; then
            NET_OK=1
            break
        fi
        log "⏳ 網路未就緒，等待 30 秒... ($i/5)"
        sleep 30
    done
    if [ "$NET_OK" = "0" ]; then
        log "❌ 網路連線失敗，無法檢查套件"
        push_notify "checkcustpkgs_NetworkFailed"
        return 1
    fi
    log "腳本啟動 [$PKG_MGR]，檢查套件..."
    check_and_install
    local result=$?
    DEV_IP=$(ip -4 addr show br-lan 2>/dev/null | grep -oE '([0-9]+\.){3}[0-9]+' | head -1)
    DEV_IP="${DEV_IP:-$(uci get network.lan.ipaddr 2>/dev/null || echo '?')}"
    WAN_MAC=$(cat /sys/class/net/$(uci get network.wan.device 2>/dev/null || echo eth0)/address 2>/dev/null || echo "?")
    LAN_MAC=$(cat /sys/class/net/br-lan/address 2>/dev/null || echo "?")
    NOTIFY_MSG="checkcustpkgs_Done | IP:${DEV_IP} LAN:${LAN_MAC} (可在Google Sheet DHCP綁定固定IP)"
    if [ "$MESH_ROLE" != "client" ]; then
        WAN_IP=$(ip -4 addr show $(uci get network.wan.device 2>/dev/null || echo eth0) 2>/dev/null | grep -oE '([0-9]+\.){3}[0-9]+' | head -1)
        WAN_IP="${WAN_IP:-?}"
        NOTIFY_MSG="${NOTIFY_MSG} | WAN_IP:${WAN_IP} WAN:${WAN_MAC} (如需轉外部Port進來請在上游分享器綁定IP及Port)"
    fi
    push_notify "$NOTIFY_MSG"

    # 有安裝過套件，同步 RAM 設定回 flash
    if [ $result -eq 0 ] && [ -n "$INSTALLED_FLAG" ]; then
        log "💾 同步設定到 flash..."
        /etc/myscript/sync-ram2flash.sh
    fi

    # 有安裝過套件（return 0 且確實有缺少）才重開機
    if [ $result -eq 0 ] && [ -n "$INSTALLED_FLAG" ] && [ "$NO_REBOOT" = "0" ]; then
        log "🔄 套件安裝完成，10 秒後重新開機..."
        sleep 10
        reboot
    fi
}

main "$@"
