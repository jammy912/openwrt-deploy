#!/bin/sh

#================================================================
# PBR WireGuard Interface Health Check Script (V2)
#
# 功能:
#   - 檢查所有 PBR 規則中，以 'wg' 開頭的介面。
#   - 透過指定的介面對外 PING 測試。
#   - 如果 PING 失敗，則停用該 PBR 規則。
#   - 如果 PING 成功，則確保該 PBR 規則是啟用的。
#   - (新增) 如果 PING 失敗且時間為整點，則嘗試重啟該介面。
#================================================================

# 非主gw 不需要檢查 PBR/WG 狀態
GW_TYPE=$(cat /etc/myscript/.mesh_gw_type 2>/dev/null)
[ "$GW_TYPE" != "主gw" ] && exit 0

# 引入通知器
. /etc/myscript/push_notify.inc
PUSH_NAMES="admin" # 多人用分號分隔，例如 "admin;ann"

# --- 設定 ---
# PING 測試的目標 IP
TARGET_IP="8.8.8.8"

# PING 參數: -c = 發送的封包數, -W = 等待回應的秒數
PING_COUNT=3
PING_TIMEOUT=5

# 追蹤是否有設定被變更
CHANGES_MADE=0

# 預設啟用日誌 (0 = false, 1 = true)
QUIET_MODE=0
 

# 檢查第一個參數是否為 quiet 模式旗標
if [ "$1" = "--quiet" ] || [ "$1" = "-q" ]; then
  QUIET_MODE=1
fi

# --- 主程式 ---
log() {
    # 如果是 quiet 模式，則不記錄任何日誌
    if [ "$QUIET_MODE" -eq 1 ]; then
        return
    fi

    # 將日誌訊息同時輸出到 console 和系統日誌 (logread)
    logger -t PBR_HealthCheck "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log "開始檢查 PBR WireGuard 介面連線狀態..."

# 使用 uci show 指令找出所有 dest_addr 以 'wg' 開頭的 PBR 策略區段
SECTIONS=$(uci show pbr | grep ".dest_addr='wg" | cut -d'.' -f2)

if [ -z "$SECTIONS" ]; then
    log "找不到任何 dest_addr 以 'wg' 開頭的 PBR 策略。"
    exit 0
fi

# 逐一處理每個找到的區段
for SECTION in $SECTIONS; do
    # 取得介面名稱 (dest_addr) 和規則名稱 (name)
    INTERFACE=$(uci get pbr.${SECTION}.dest_addr)
    POLICY_NAME=$(uci get pbr.${SECTION}.name 2>/dev/null || echo "$SECTION")

    log " -> 正在檢查策略 '$POLICY_NAME' (介面: $INTERFACE)..."

    # 使用指定的介面執行 PING 測試
    if ping -c $PING_COUNT -W $PING_TIMEOUT -I $INTERFACE $TARGET_IP >/dev/null 2>&1; then
        # --- PING 成功 ---
        log "    狀態: 連線正常 (UP)。確保規則為啟用狀態。"

        # 檢查目前是否被手動設定為 '0' (停用)
        CURRENT_STATUS=$(uci get pbr.${SECTION}.enabled 2>/dev/null)
        if [ "$CURRENT_STATUS" = "0" ]; then
            log "    動作: 偵測到 'option enabled 0'，將其移除以啟用規則。"
            uci delete pbr.${SECTION}.enabled
            CHANGES_MADE=1 
			push_notify "'$INTERFACE'UP"
        else
            log "    動作: 無需變更。"
        fi
    else
        # --- PING 失敗 ---
        log "    狀態: 連線中斷 (DOWN)。確保規則為停用狀態。"
        
        # 檢查是否已經被停用，若未被停用則停用它
        CURRENT_STATUS=$(uci get pbr.${SECTION}.enabled 2>/dev/null)
        if [ "$CURRENT_STATUS" != "0" ]; then
            log "    動作: 新增 'option enabled 0' 以停用規則。"
            uci set pbr.${SECTION}.enabled='0'
            CHANGES_MADE=1            
			push_notify "'$INTERFACE'_Down"
        else
            log "    動作: 規則已停用，無需變更。"
        fi

        # ==================== 新增的檢查邏輯 ====================
        # 取得目前的分鐘數 (00-59)
        CURRENT_MINUTE=$(date '+%M')

        # 如果分鐘數是 '00'，代表是整點
        if [ "$CURRENT_MINUTE" = "00" ]; then
            log "    *** 偵測到整點時間且介面不通，正在嘗試重啟介面 '$INTERFACE'..."
            # 執行介面重啟指令
            ifdown $INTERFACE && ifup $INTERFACE
            log "    *** 介面 '$INTERFACE' 重啟指令已執行。"
        fi
        # =========================================================
    fi
done

# 如果有任何變更，則提交設定並重載服務
if [ "$CHANGES_MADE" -eq 1 ]; then
    log "偵測到設定變更，正在儲存並套用..."
    uci commit pbr
    log "重新載入 PBR 服務..."
    /etc/init.d/pbr reload
    /etc/init.d/pbr-cust start
    log "PBR 服務已重載。"
else
    log "所有規則狀態皆正確，無需變更。"
fi

# === 域名路由健康檢查（動態，所有 route_*_v4 介面） ===
RT_TABLES="/etc/iproute2/rt_tables"
DBR_CONF="/etc/dnsmasq.d/dbroute-domains.conf"
DBR_NFT="/etc/myscript/dbroute.nft"

if [ -f "$DBR_CONF" ]; then
    # 確保 nft table 存在（可能被 firewall restart 清掉）
    if ! nft list table inet fw4 >/dev/null 2>&1; then
        if [ -f "$DBR_NFT" ]; then
            nft -f "$DBR_NFT" && log "nft table fw4 重建成功" || log "nft table fw4 重建失敗"
            service dnsmasq restart
            push_notify "dbroute_nft_rebuilt"
        fi
    fi

    DR_IFACES=$(sed -n 's/.*#inet#fw4#route_\(.*\)_v4$/\1/p' "$DBR_CONF" | sort -u)

    for DR_IFACE in $DR_IFACES; do
        if ! ip link show "$DR_IFACE" >/dev/null 2>&1; then
            continue
        fi

        DR_TABLE=$(awk -v name="pbr_${DR_IFACE}" '$2 == name {print $1}' "$RT_TABLES")
        [ -z "$DR_TABLE" ] && continue
        DR_FWMARK=$(printf "0x%x" "$DR_TABLE")

        if ping -c $PING_COUNT -W $PING_TIMEOUT -I "$DR_IFACE" $TARGET_IP >/dev/null 2>&1; then
            # 介面正常，確保 ip rule 存在
            if ! ip rule show | grep -q "fwmark $DR_FWMARK"; then
                /etc/myscript/dbroute-setup.sh
                log "${DR_IFACE} UP → 恢復 domain routing"
                push_notify "${DR_IFACE}_DomainRoute_UP"
            fi
        else
            # 介面掛了，移除 fwmark 規則
            if ip rule show | grep -q "fwmark $DR_FWMARK"; then
                ip rule del fwmark "$DR_FWMARK" lookup "$DR_TABLE" 2>/dev/null
                log "${DR_IFACE} DOWN → 移除 domain routing"
                push_notify "${DR_IFACE}_DomainRoute_Down"
            fi
            CURRENT_MINUTE=$(date '+%M')
            if [ "$CURRENT_MINUTE" = "00" ]; then
                ifdown "$DR_IFACE" && ifup "$DR_IFACE"
            fi
        fi
    done
fi

log "檢查完畢。"
