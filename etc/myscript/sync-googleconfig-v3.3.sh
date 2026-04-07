#!/bin/sh

# 引入鎖定處理器
. /etc/myscript/lock_handler.sh
LOCK_NAME="sync-googleconfig"
EXPIRY_SEC=300 # 5 分鐘

# 引入通知器
. /etc/myscript/push_notify.inc
PUSH_NAMES="admin" # 多人用分號分隔，例如 "admin;ann"

# 執行鎖定檢查並創建鎖定檔案
lock_check_and_create "$LOCK_NAME" "$EXPIRY_SEC"
LOCK_STATUS=$?

if [ $LOCK_STATUS -ne 0 ]; then
    exit 0
fi

trap "lock_remove $LOCK_NAME" TERM INT EXIT

echo "鎖定檢查通過，開始執行同步任務..."

# =====================================================
# 配置參數
# =====================================================
DRY_RUN=1
SECRET_DIR="/etc/myscript/.secrets"
KEY_STRING=$(cat "$SECRET_DIR/secret.key" 2>/dev/null) || { echo "錯誤: 無法讀取 $SECRET_DIR/secret.key"; exit 1; }
IV_STRING=$(cat "$SECRET_DIR/secret.iv" 2>/dev/null) || { echo "錯誤: 無法讀取 $SECRET_DIR/secret.iv"; exit 1; }
URL=$(cat "$SECRET_DIR/secret.url" 2>/dev/null) || { echo "錯誤: 無法讀取 $SECRET_DIR/secret.url"; exit 1; }

# 臨時檔案
TMP_BASE64="/tmp/config_base64.txt"
TMP_BINARY="/tmp/config_encrypted.bin"
TMP_DECRYPTED="/tmp/config_decrypted.txt"

# 變更追蹤目錄
STATE_DIR="/tmp/sync-state"
mkdir -p "$STATE_DIR"

# 各組件的狀態檔案 (用於儲存上次成功同步的配置)
STATE_NETWORK="$STATE_DIR/network.state"
STATE_DHCP="$STATE_DIR/dhcp.state"
STATE_FIREWALL="$STATE_DIR/firewall.state"
STATE_PBR="$STATE_DIR/pbr.state"
STATE_QOS_RULES="$STATE_DIR/qos_rules.state"
STATE_QOS_INTERFACES="$STATE_DIR/qos_interfaces.state"
STATE_CRONTAB="$STATE_DIR/crontab.state"
STATE_DBROUTE="$STATE_DIR/dbroute.state"
STATE_ROUTERCONFIG="$STATE_DIR/routerconfig.state"

# 回滾備份檔案
ROLLBACK_NETWORK="/tmp/network.rollback"
ROLLBACK_DHCP="/tmp/dhcp.rollback"
ROLLBACK_FIREWALL="/tmp/firewall.rollback"
ROLLBACK_QOSIFY="/tmp/qosify.rollback"
ROLLBACK_QOS_DEFAULTS="/tmp/qosify_defaults.rollback"

# MD5 檢查檔案
MD5_FILE="/tmp/config_base64.md5"

# 變更追蹤標記
CHANGED_NETWORK=0
CHANGED_DHCP=0
CHANGED_FIREWALL=0
CHANGED_PBR=0
CHANGED_QOS_RULES=0
CHANGED_QOS_INTERFACES=0
CHANGED_CRONTAB=0
CHANGED_DBROUTE=0
CHANGED_ROUTERCONFIG=0

IV_HEX=$(echo -n "$IV_STRING" | hexdump -v -e '/1 "%02x"')
KEY_HEX=$(echo -n "$KEY_STRING" | hexdump -v -e '/1 "%02x"')

# =====================================================
# 執行模式檢查
# =====================================================
SATELLITE_MODE=0
NO_NETWORK_CHECK=0
DUMP_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --apply)
            DRY_RUN=0
            echo "⚠️ 警告: 使用 --apply 參數，將實際修改系統配置!"
            ;;
        --satellite)
            SATELLITE_MODE=1
            echo "📡 衛星模式: 只同步帶 _satellite 後綴的群組"
            ;;
        --no-network-check)
            NO_NETWORK_CHECK=1
            echo "⚠️ 跳過網路健康檢查"
            ;;
        --dump)
            DUMP_ONLY=1
            echo "📋 Dump 模式: 只下載解密並顯示設定內容"
            ;;
    esac
done

# 自動偵測身份: override 優先，再看 .mesh_role_active，最後 fallback .mesh_role
if [ "$SATELLITE_MODE" = "0" ]; then
    _override=$(cat /etc/myscript/.mesh_role_override 2>/dev/null | tr 'A-Z' 'a-z')
    if [ "$_override" = "gateway" ] || [ "$_override" = "client" ]; then
        _active_role="$_override"
    else
        _active_role=$(cat /etc/myscript/.mesh_role_active 2>/dev/null)
        [ -z "$_active_role" ] && _active_role=$(cat /etc/myscript/.mesh_role 2>/dev/null)
    fi
    if [ "$_active_role" = "client" ]; then
        SATELLITE_MODE=1
        log "📡 自動偵測: client 角色，啟用衛星模式"
    fi
fi

# =====================================================
# 日誌函數
# =====================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# =====================================================
# 檢查依賴
# =====================================================
check_dependencies() {
    for cmd in curl base64 openssl uci ping md5sum; do
        command -v "$cmd" >/dev/null 2>&1 || {
            log "錯誤: 缺少必要工具 $cmd"
            log "啟動安裝"
            /etc/myscript/check-custpkgs.sh
            exit 1
        }
    done
}

# =====================================================
# MD5 相關函數
# =====================================================
calculate_md5() {
    local file="$1"
    md5sum "$file" | awk '{print $1}'
}

check_md5_changed() {
    local current_md5="$1"
    local previous_md5=""

    if [ -f "$MD5_FILE" ]; then
        previous_md5=$(cat "$MD5_FILE")
    fi

    if [ "$current_md5" = "$previous_md5" ]; then
        log "ℹ️  配置文件未變化，跳過處理"
        return 1
    else
        log "🔄 配置文件已更新，繼續處理"
        return 0
    fi
}

save_current_md5() {
    local current_md5="$1"
    echo "$current_md5" > "$MD5_FILE"
    log "💾 保存當前配置 MD5: $current_md5"
}

# =====================================================
# 檢查內容是否有變更 (比較新內容與上次狀態)
# =====================================================
check_content_changed() {
    local new_content_file="$1"
    local state_file="$2"
    local component_name="$3"

    # 檢查新內容是否為空
    local new_is_empty=0
    if [ ! -s "$new_content_file" ]; then
        new_is_empty=1
    fi

    # 檢查狀態檔案是否存在且有內容
    local state_is_empty=1
    if [ -f "$state_file" ] && [ -s "$state_file" ]; then
        state_is_empty=0
    fi

    # 情況 1: 新內容為空，但之前有內容 -> 需要清空配置
    if [ $new_is_empty -eq 1 ] && [ $state_is_empty -eq 0 ]; then
        log "  [$component_name] 遠端配置已清空，需要移除現有配置"
        return 0
    fi

    # 情況 2: 新內容為空，之前也沒有內容 -> 無變更
    if [ $new_is_empty -eq 1 ] && [ $state_is_empty -eq 1 ]; then
        log "  [$component_name] 無新內容且之前也無配置，跳過"
        return 1
    fi

    # 情況 3: 新內容有值，但之前沒有內容 -> 首次配置
    if [ $new_is_empty -eq 0 ] && [ $state_is_empty -eq 1 ]; then
        log "  [$component_name] 首次執行，標記為有變更"
        return 0
    fi

    # 情況 4: 新內容有值，之前也有內容 -> 比較內容
    if cmp -s "$new_content_file" "$state_file"; then
        log "  [$component_name] 內容未變化，跳過更新"
        return 1
    else
        log "  [$component_name] 內容已變化，需要更新"
        return 0
    fi
}

# =====================================================
# 更新狀態檔案
# =====================================================
update_state_file() {
    local new_content_file="$1"
    local state_file="$2"
    local component_name="$3"

    # 如果新內容有資料，複製到狀態檔案
    if [ -s "$new_content_file" ]; then
        cp "$new_content_file" "$state_file"
        log "  [$component_name] 狀態檔案已更新"
    else
        # 如果新內容為空，清空狀態檔案（表示配置已被清空）
        > "$state_file"
        log "  [$component_name] 狀態檔案已清空"
    fi
}

# =====================================================
# QoS 介面合併函數
# =====================================================
merge_qosify_config() {
    local remote_interfaces="$1"
    local dry_run="$2"
    local TEMPLATE_FILE="/etc/config/qosify_template"

    log "🔄 正在從模板合併遠端值，重建 QoS 介面配置..."

    TMP_QOS_FINAL="/tmp/qos_final_merged.uci"
    > "$TMP_QOS_FINAL"

    # 讀取模板內容
    TEMPLATE_CONTENT=$(awk '
        BEGIN { RS="\n\n"; template_loaded=0 }
        {
            if ($0 ~ /^config interface/ && template_loaded == 0) {
                print $0
                template_loaded = 1
                exit
            }
        }' "$TEMPLATE_FILE" | sed 's/config interface template/config interface/g')

    if [ -z "$TEMPLATE_CONTENT" ]; then
        log "❌ 錯誤: 無法從 $TEMPLATE_FILE 中讀取到有效的 interface template 區塊。"
        return 1
    fi

    # 提取介面名稱
    interfaces=$(cat "$remote_interfaces" | sed -n 's/^\s*option\s\+name\s\+\(.*\)/\1/p' | tr -d '"')

    # 處理每個介面
    echo "$interfaces" | while IFS= read -r name; do

        if [ -z "$name" ]; then
            continue
        fi

        # 提取介面配置區塊
        block_start=$(grep -n "option name $name" "$remote_interfaces" | cut -d: -f1)
        if [ -z "$block_start" ]; then
            log "   -> 警告: 無法找到介面 $name 的區塊，跳過。"
            continue
        fi

        remote_block=$(awk "NR>=$block_start && /option name $name/{
            print; start=1; next
        } start && /^config qosinterface/{
            exit
        } start{
            print
        }" "$remote_interfaces")

        # 提取 bandwidth 值
        up=$(echo "$remote_block" | sed -n 's/^\s*option\s\+bandwidth_up\s\+\(.*\)/\1/p' | tr -d '"' | tr -d '\r\n')
        down=$(echo "$remote_block" | sed -n 's/^\s*option\s\+bandwidth_down\s\+\(.*\)/\1/p' | tr -d '"' | tr -d '\r\n')

        log "   -> 正在處理介面: ${name} (上傳: ${up} / 下載: ${down})"

        # 使用模板和 AWK 進行替換
        echo "$TEMPLATE_CONTENT" | awk -v name="$name" -v up="$up" -v down="$down" '
            {
                if ($0 ~ /option\s+name\s+/) {
                    print "\toption name " name
                    next
                }
                if ($0 ~ /option\s+bandwidth_up\s+/) {
                    print "\toption bandwidth_up " up
                    next
                }
                if ($0 ~ /option\s+bandwidth_down\s+/) {
                    print "\toption bandwidth_down " down
                    next
                }
                print $0
            }
        ' >> "$TMP_QOS_FINAL"

        echo "" >> "$TMP_QOS_FINAL"

    done

    if [ ! -s "$TMP_QOS_FINAL" ]; then
        log "🔥🔥 警告: 合併後的 QoS 配置檔案 ($TMP_QOS_FINAL) 為空！"
        return 0
    fi

    if [ "$dry_run" -eq 1 ]; then
        log "最終輸出內容 (DRY-RUN) 如下："
        cat "$TMP_QOS_FINAL"
    fi

    if [ "$dry_run" -eq 0 ]; then

        # 清理舊介面區塊
        log "   -> 正在從 /etc/config/qosify 移除所有舊 interface 區塊..."
        awk -v RS='\n\n' -v ORS='\n\n' '!/^config interface/' /etc/config/qosify > /tmp/qosify_clean
        sed -i -e :a -e '/^\n*$/{$d;N;};/\n$/b a' /tmp/qosify_clean
        mv /tmp/qosify_clean /etc/config/qosify

        log "   -> 正在寫入合併後的新 interface 配置..."
        sed -i -e :a -e '/^\n*$/{$d;N;};/\n$/b a' "$TMP_QOS_FINAL"
        echo "" >> /etc/config/qosify
        cat "$TMP_QOS_FINAL" >> /etc/config/qosify
        log "✅ QoS 介面配置更新完成。"
    else
        log "   -> [DRY-RUN] 模擬寫入完成，未實際修改配置。"
    fi

    rm -f "$TMP_QOS_FINAL"

    return 0
}

# =====================================================
# 主程式
# =====================================================
main() {
    echo "🚀 開始配置更新 (Dry-run: $DRY_RUN)"
    echo "================================================================"

    echo none > /sys/class/leds/blue:status/trigger 2>/dev/null

    check_dependencies

    # 下載並解密
    log "下載並解密配置..."
    if [ "$DUMP_ONLY" = "1" ]; then
        local dl_url="$URL"
    else
        local dl_url="$URL&md5=$(cat "$MD5_FILE" 2>/dev/null)"
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$TMP_BASE64" "$dl_url" || { log "下載失敗 (curl)"; exit 1; }
    else
        wget -qO "$TMP_BASE64" "$dl_url" || { log "下載失敗 (wget)"; exit 1; }
    fi

    if [ "$(cat "$TMP_BASE64")" = "" ]; then
       log "base64回傳空白/md5未變更"
       exit 0
    fi

    # 計算下載文件的 MD5
    current_md5=$(calculate_md5 "$TMP_BASE64")
    log "📊 當前配置 MD5: $current_md5"

    # 檢查 MD5 是否變化（--dump 模式跳過，強制下載解密）
    if [ "$DUMP_ONLY" != "1" ] && ! check_md5_changed "$current_md5"; then
        if [ $DRY_RUN -eq 0 ]; then
            save_current_md5 "$current_md5"
        fi
        rm -f "$TMP_BASE64"
        echo "✅ 無需更新，退出腳本"
        exit 0
    fi

    echo default-on > /sys/class/leds/blue:status/trigger 2>/dev/null

    push_notify "ConfigSync_Start"

    base64 -d "$TMP_BASE64" > "$TMP_BINARY" 2>/dev/null || { log "Base64解碼失敗"; exit 1; }
    openssl enc -aes-256-cbc -d -K "$KEY_HEX" -iv "$IV_HEX" -in "$TMP_BINARY" -out "$TMP_DECRYPTED" 2>/dev/null || { log "AES解密失敗"; exit 1; }

    # =====================================================
    # 資料驗證 (防呆)
    # =====================================================
    log "🔍 驗證解密資料..."
    VALIDATE_ERRORS=""

    # 1. 檢查解密後檔案是否為空或過小
    if [ ! -s "$TMP_DECRYPTED" ]; then
        VALIDATE_ERRORS="${VALIDATE_ERRORS}\n  - 解密後檔案為空"
    else
        DECRYPTED_SIZE=$(wc -c < "$TMP_DECRYPTED")
        DECRYPTED_LINES=$(wc -l < "$TMP_DECRYPTED")
        if [ "$DECRYPTED_SIZE" -lt 50 ]; then
            VALIDATE_ERRORS="${VALIDATE_ERRORS}\n  - 解密後檔案過小 (${DECRYPTED_SIZE} bytes)，可能解密失敗"
        fi
        if [ "$DECRYPTED_LINES" -lt 3 ]; then
            VALIDATE_ERRORS="${VALIDATE_ERRORS}\n  - 解密後僅 ${DECRYPTED_LINES} 行，資料量異常少"
        fi
    fi

    # 2. 檢查 Google Sheet 公式錯誤
    FORMULA_ERRORS=$(grep -nE '#REF!|#N/A|#VALUE!|#ERROR!|#NAME\?|#NULL!|#DIV/0!' "$TMP_DECRYPTED" 2>/dev/null)
    if [ -n "$FORMULA_ERRORS" ]; then
        ERROR_COUNT=$(echo "$FORMULA_ERRORS" | wc -l)
        ERROR_SAMPLE=$(echo "$FORMULA_ERRORS" | head -5 | sed 's/^/    L/')
        VALIDATE_ERRORS="${VALIDATE_ERRORS}\n  - 偵測到 ${ERROR_COUNT} 筆 Google Sheet 公式錯誤:\n${ERROR_SAMPLE}"
        log "⚠️ 公式錯誤明細:"
        echo "$FORMULA_ERRORS" | head -10 | sed 's/^/    L/' | while IFS= read -r errline; do
            log "$errline"
        done
    fi

    # 3. 檢查空的 option 值 (option name 後面沒有值或只有引號)
    EMPTY_OPTIONS=$(grep -nE "^\s*option\s+\S+\s*(''|\"\"|\s*)$" "$TMP_DECRYPTED" 2>/dev/null | grep -v 'option gw_mode')
    if [ -n "$EMPTY_OPTIONS" ]; then
        EMPTY_COUNT=$(echo "$EMPTY_OPTIONS" | wc -l)
        EMPTY_SAMPLE=$(echo "$EMPTY_OPTIONS" | head -5 | sed 's/^/    L/')
        VALIDATE_ERRORS="${VALIDATE_ERRORS}\n  - 偵測到 ${EMPTY_COUNT} 個空值 option:\n${EMPTY_SAMPLE}"
        log "⚠️ 空值 option 明細:"
        echo "$EMPTY_OPTIONS" | head -10 | sed 's/^/    L/' | while IFS= read -r emptyline; do
            log "$emptyline"
        done
    fi

    # 4. 檢查是否包含至少一個 config 區塊 (基本結構驗證)
    CONFIG_COUNT=$(grep -c '^config ' "$TMP_DECRYPTED" 2>/dev/null)
    if [ "$CONFIG_COUNT" -eq 0 ]; then
        VALIDATE_ERRORS="${VALIDATE_ERRORS}\n  - 找不到任何 config 區塊，檔案格式可能錯誤"
    fi

    # 5. 檢查是否有 NUL 字元 (解密失敗/金鑰錯誤時常見)
    GARBAGE_COUNT=$(tr -cd '\000' < "$TMP_DECRYPTED" | wc -c)
    if [ "$GARBAGE_COUNT" -gt 0 ]; then
        VALIDATE_ERRORS="${VALIDATE_ERRORS}\n  - 偵測到 ${GARBAGE_COUNT} 個 NUL 字元，解密可能不完整"
    fi

    # 6. 檢查非法 config type (解密金鑰錯誤時會產生亂碼如 0config, 0onfig)
    #    合法前綴: policy, interface, wireguard_wg, host, qosrule, qosinterface,
    #    crontab, dbroute, pushkey (後面可接任意後綴如 _tw, _satellite 等)
    BAD_CONFIG=$(grep '^config ' "$TMP_DECRYPTED" 2>/dev/null | grep -vE "^config (policy|interface|wireguard_wg|host|qosrule|qosinterface|crontab|dbroute|pushkey|routerconfig|batmanmesh)")
    if [ -n "$BAD_CONFIG" ]; then
        BAD_COUNT=$(echo "$BAD_CONFIG" | wc -l)
        BAD_SAMPLE=$(echo "$BAD_CONFIG" | head -3 | tr '\n' '; ')
        VALIDATE_ERRORS="${VALIDATE_ERRORS}\n  - 偵測到 ${BAD_COUNT} 個非法 config type (解密可能不完整): ${BAD_SAMPLE}"
    fi

    # 7. 檢查非 config/option/list 開頭的異常行 (排除空行、tab 開頭、# 註解)
    BAD_LINES=$(grep -vE '^\s*$|^\s*(config |option |list |#)|^\t' "$TMP_DECRYPTED" 2>/dev/null)
    if [ -n "$BAD_LINES" ]; then
        BAD_LINE_COUNT=$(echo "$BAD_LINES" | wc -l)
        BAD_LINE_SAMPLE=$(echo "$BAD_LINES" | head -3 | tr '\n' '; ')
        VALIDATE_ERRORS="${VALIDATE_ERRORS}\n  - 偵測到 ${BAD_LINE_COUNT} 行非法格式 (非 config/option/list/#): ${BAD_LINE_SAMPLE}"
    fi

    # 驗證結果處理
    if [ -n "$VALIDATE_ERRORS" ]; then
        log "🚨 資料驗證失敗！"
        VALIDATE_DETAIL=$(printf "$VALIDATE_ERRORS")
        log "$VALIDATE_DETAIL"
        # 公式錯誤明細
        if [ -n "$FORMULA_ERRORS" ]; then
            FORMULA_DETAIL=" | 公式錯誤: $(echo "$FORMULA_ERRORS" | head -3 | tr '\n' '; ')"
        else
            FORMULA_DETAIL=""
        fi
        # 空值明細
        if [ -n "$EMPTY_OPTIONS" ]; then
            EMPTY_DETAIL=" | 空值: $(echo "$EMPTY_OPTIONS" | head -3 | tr '\n' '; ')"
        else
            EMPTY_DETAIL=""
        fi
        push_notify "ConfigSync_ValidateError${FORMULA_DETAIL}${EMPTY_DETAIL} | $(echo "$VALIDATE_DETAIL" | tr '\n' ' ')"
        echo "🚨 資料驗證失敗，已通知管理員。中止同步。"
        rm -f "$TMP_BASE64" "$TMP_BINARY" "$TMP_DECRYPTED"
        exit 1
    fi
    log "✅ 資料驗證通過 (${CONFIG_COUNT} 個 config 區塊, ${DECRYPTED_LINES} 行)"

    # --dump 模式：印出解密內容後結束
    if [ "$DUMP_ONLY" = "1" ]; then
        echo ""
        echo "================================================================"
        cat "$TMP_DECRYPTED"
        echo "================================================================"
        rm -f "$TMP_BASE64" "$TMP_BINARY" "$TMP_DECRYPTED"
        exit 0
    fi

    echo ""
    echo "📋 解析並檢查各組件變更..."
    echo "================================================================"

    # 解析各組件配置到臨時檔案
    TMP_PBR="/tmp/pbr_new.uci"
    TMP_NETWORK="/tmp/network_new.uci"
    TMP_DHCP="/tmp/dhcp_new.uci"
    TMP_QOS_RULES="/tmp/qos_rules.uci"
    TMP_QOS_INTERFACES="/tmp/qos_interfaces.uci"
    TMP_CRONTAB="/tmp/crontab_new.uci"
    TMP_DBROUTE="/tmp/dbroute_new.uci"
    TMP_ROUTERCONFIG="/tmp/routerconfig_new.uci"

    # 清空暫存檔案
    > "$TMP_PBR"
    > "$TMP_NETWORK"
    > "$TMP_DHCP"
    > "$TMP_QOS_RULES"
    > "$TMP_QOS_INTERFACES"
    > "$TMP_CRONTAB"
    > "$TMP_DBROUTE"
    > "$TMP_ROUTERCONFIG"

    log "解析並分類配置..."

    if [ $SATELLITE_MODE -eq 1 ]; then
        # 衛星模式: 只同步帶 _satellite 後綴的群組，解析時去掉後綴還原為標準 config type
        log "📡 衛星模式: 只解析 _satellite 群組"

        sed -n '/^config policy_satellite/,/^$/p' "$TMP_DECRYPTED" | sed '/^$/d' | sed 's/^config policy_satellite/config policy/' >> "$TMP_PBR"

        sed -n '/^config interface_satellite/,/^$/p' "$TMP_DECRYPTED" | sed '/^$/d' | sed 's/^config interface_satellite/config interface/' > "$TMP_NETWORK"
        sed -n '/^config wireguard_wg_satellite/,/^$/p' "$TMP_DECRYPTED" | sed '/^$/d' | sed 's/^config wireguard_wg_satellite/config wireguard_wg/' >> "$TMP_NETWORK"

        sed -n '/^config host_satellite/,/^$/p' "$TMP_DECRYPTED" | sed '/^$/d' | sed 's/^config host_satellite/config host/' >> "$TMP_DHCP"
        awk '/^config qosrule_satellite/,/^$/ {if (!/^config qosrule_satellite/ && NF) print}' "$TMP_DECRYPTED" > "$TMP_QOS_RULES"
        sed -n '/^config qosinterface_satellite/,/^$/p' "$TMP_DECRYPTED" | sed '/^$/d' | sed 's/^config qosinterface_satellite/config qosinterface/' >> "$TMP_QOS_INTERFACES"
        sed -n '/^config crontab_satellite/,/^$/p' "$TMP_DECRYPTED" | sed '/^$/d' | sed 's/^config crontab_satellite/config crontab/' >> "$TMP_CRONTAB"
        sed -n '/^config dbroute_satellite/,/^$/p' "$TMP_DECRYPTED" | sed '/^$/d' | sed 's/^config dbroute_satellite/config dbroute/' >> "$TMP_DBROUTE"
    else
        # 標準模式: 先過濾掉 _satellite 群組，再正常解析
        grep -v '_satellite' "$TMP_DECRYPTED" > "$TMP_DECRYPTED.std"

        sed -n '/^config policy/,/^$/p' "$TMP_DECRYPTED.std" | sed '/^$/d' >> "$TMP_PBR"

        # Network: 同時包含 interface 和 wireguard_wg
        sed -n '/^config interface/,/^$/p' "$TMP_DECRYPTED.std" | sed '/^$/d' > "$TMP_NETWORK"
        sed -n '/^config wireguard_wg/,/^$/p' "$TMP_DECRYPTED.std" | sed '/^$/d' >> "$TMP_NETWORK"

        sed -n '/^config host/,/^$/p' "$TMP_DECRYPTED.std" | sed '/^$/d' >> "$TMP_DHCP"
        awk '/^config qosrule/,/^$/ {if (!/^config qosrule/ && NF) print}' "$TMP_DECRYPTED.std" > "$TMP_QOS_RULES"
        sed -n '/^config qosinterface/,/^$/p' "$TMP_DECRYPTED.std" | sed '/^$/d' >> "$TMP_QOS_INTERFACES"
        sed -n '/^config crontab/,/^$/p' "$TMP_DECRYPTED.std" | sed '/^$/d' >> "$TMP_CRONTAB"
        sed -n '/^config dbroute/,/^$/p' "$TMP_DECRYPTED.std" | sed '/^$/d' >> "$TMP_DBROUTE"

        rm -f "$TMP_DECRYPTED.std"
    fi

    # routerconfig 不分模式，兩邊都提取
    sed -n '/^config routerconfig/,/^$/p' "$TMP_DECRYPTED" | sed '/^$/d' >> "$TMP_ROUTERCONFIG"

    # batmanmesh: 比對 hostname，更新 .batmanmesh
    MY_HOSTNAME=$(uci get system.@system[0].hostname 2>/dev/null)
    if [ -n "$MY_HOSTNAME" ]; then
        eval $(awk -v host="$MY_HOSTNAME" '
            BEGIN { RS=""; FS="\n" }
            /^config batmanmesh/ {
                h=""; p=""; wl=""; wr=""; gw=""
                for (i=1; i<=NF; i++) {
                    if ($i ~ /option hostname/) { n=split($i, a, " "); gsub(/'"'"'/, "", a[n]); h=a[n] }
                    if ($i ~ /option priority/) { n=split($i, a, " "); gsub(/'"'"'/, "", a[n]); p=a[n] }
                    if ($i ~ /option wireless_mesh/) { n=split($i, a, " "); gsub(/'"'"'/, "", a[n]); wl=a[n] }
                    if ($i ~ /option wired_mesh/) { n=split($i, a, " "); gsub(/'"'"'/, "", a[n]); wr=a[n] }
                    if ($i ~ /option gw_mode/) { n=split($i, a, " "); gsub(/'"'"'/, "", a[n]); gw=a[n] }
                }
                if (h == host) { print "NEW_PRI=" p " NEW_WIRELESS=" wl " NEW_WIRED=" wr " NEW_GWMODE=" gw; exit }
            }
        ' "$TMP_DECRYPTED")
        [ -z "$NEW_PRI" ] && NEW_PRI=50
        # TRUE/FALSE → Y/N 轉換 (Google Sheet checkbox)
        case "$NEW_WIRELESS" in
            TRUE|true|1|Y|y) NEW_WIRELESS=Y ;;
            FALSE|false|0|N|n) NEW_WIRELESS=N ;;
            "") NEW_WIRELESS=Y ;;
        esac
        case "$NEW_WIRED" in
            TRUE|true|1|Y|y) NEW_WIRED=Y ;;
            FALSE|false|0|N|n) NEW_WIRED=N ;;
            "") NEW_WIRED=N ;;
        esac
        # 更新 .mesh_priority
        CUR_PRI=$(cat /etc/myscript/.mesh_priority 2>/dev/null)
        if [ "$NEW_PRI" != "$CUR_PRI" ]; then
            echo -n "$NEW_PRI" > /etc/myscript/.mesh_priority
            log "🔧 mesh_priority: $CUR_PRI → $NEW_PRI (hostname=$MY_HOSTNAME)"
        fi
        # 更新 .mesh_wireless
        CUR_WL=$(cat /etc/myscript/.mesh_wireless 2>/dev/null)
        if [ "$NEW_WIRELESS" != "$CUR_WL" ]; then
            echo -n "$NEW_WIRELESS" > /etc/myscript/.mesh_wireless
            log "🔧 mesh_wireless: $CUR_WL → $NEW_WIRELESS (hostname=$MY_HOSTNAME)"
        fi
        # 更新 .mesh_wired
        CUR_WR=$(cat /etc/myscript/.mesh_wired 2>/dev/null)
        if [ "$NEW_WIRED" != "$CUR_WR" ]; then
            echo -n "$NEW_WIRED" > /etc/myscript/.mesh_wired
            log "🔧 mesh_wired: $CUR_WR → $NEW_WIRED (hostname=$MY_HOSTNAME)"
        fi
        # 更新 .mesh_role_override (GW Mode 強制覆蓋)
        # Auto 或空白 = 清除 override，回到自動偵測
        GWMODE_LOWER=$(echo "$NEW_GWMODE" | tr 'A-Z' 'a-z')
        [ "$GWMODE_LOWER" = "auto" ] && NEW_GWMODE=""
        CUR_OVERRIDE=$(cat /etc/myscript/.mesh_role_override 2>/dev/null)
        if [ "$NEW_GWMODE" != "$CUR_OVERRIDE" ]; then
            echo -n "$NEW_GWMODE" > /etc/myscript/.mesh_role_override
            if [ -n "$NEW_GWMODE" ]; then
                log "🔧 mesh_role_override: $CUR_OVERRIDE → $NEW_GWMODE (hostname=$MY_HOSTNAME)"
            else
                log "🔧 mesh_role_override: 已清除 (hostname=$MY_HOSTNAME)"
            fi
        fi
    fi

    # =====================================================
    # 各組件欄位驗證 (防呆 - 逐筆檢查必要欄位)
    # =====================================================
    log "🔍 驗證各組件必要欄位..."
    COMPONENT_ERRORS=""

    # --- PBR policy: 每筆需要 name, dest_addr 或 src_addr ---
    if [ -s "$TMP_PBR" ]; then
        PBR_BLOCKS=$(grep -c '^config policy' "$TMP_PBR")
        PBR_NO_NAME=$(awk 'BEGIN{RS=""; FS="\n"} /^config policy/{has_name=0; for(i=1;i<=NF;i++){if($i~/option name/)has_name=1} if(!has_name)count++} END{print count+0}' "$TMP_PBR")
        PBR_NO_ADDR=$(awk 'BEGIN{RS=""; FS="\n"} /^config policy/{has_addr=0; for(i=1;i<=NF;i++){if($i~/option (dest_addr|src_addr)/)has_addr=1} if(!has_addr)count++} END{print count+0}' "$TMP_PBR")
        [ "$PBR_NO_NAME" -gt 0 ] && COMPONENT_ERRORS="${COMPONENT_ERRORS}\n  - PBR: ${PBR_NO_NAME}/${PBR_BLOCKS} 筆缺少 name"
        [ "$PBR_NO_ADDR" -gt 0 ] && COMPONENT_ERRORS="${COMPONENT_ERRORS}\n  - PBR: ${PBR_NO_ADDR}/${PBR_BLOCKS} 筆缺少 dest_addr/src_addr"
    fi

    # --- Network interface: 每筆需要 proto ---
    if [ -s "$TMP_NETWORK" ]; then
        NET_IF_BLOCKS=$(grep -c '^config interface' "$TMP_NETWORK")
        NET_NO_PROTO=$(awk 'BEGIN{RS=""; FS="\n"} /^config interface/{has=0; for(i=1;i<=NF;i++){if($i~/option proto/)has=1} if(!has)count++} END{print count+0}' "$TMP_NETWORK")
        [ "$NET_NO_PROTO" -gt 0 ] && COMPONENT_ERRORS="${COMPONENT_ERRORS}\n  - Network: ${NET_NO_PROTO}/${NET_IF_BLOCKS} 個 interface 缺少 proto"

        # wireguard_wg peer: 每筆需要 public_key, endpoint_host
        WG_BLOCKS=$(grep -c '^config wireguard_wg' "$TMP_NETWORK" 2>/dev/null || echo "0")
        if [ "$WG_BLOCKS" -gt 0 ]; then
            WG_NO_PUBKEY=$(awk 'BEGIN{RS=""; FS="\n"} /^config wireguard_wg/{has=0; for(i=1;i<=NF;i++){if($i~/option public_key/)has=1} if(!has)count++} END{print count+0}' "$TMP_NETWORK")
            WG_NO_EP=$(awk 'BEGIN{RS=""; FS="\n"} /^config wireguard_wg/{has=0; for(i=1;i<=NF;i++){if($i~/option endpoint_host/)has=1} if(!has)count++} END{print count+0}' "$TMP_NETWORK")
            [ "$WG_NO_PUBKEY" -gt 0 ] && COMPONENT_ERRORS="${COMPONENT_ERRORS}\n  - WireGuard: ${WG_NO_PUBKEY}/${WG_BLOCKS} 個 peer 缺少 public_key"
            [ "$WG_NO_EP" -gt 0 ] && COMPONENT_ERRORS="${COMPONENT_ERRORS}\n  - WireGuard: ${WG_NO_EP}/${WG_BLOCKS} 個 peer 缺少 endpoint_host"
        fi
    fi

    # --- DHCP host: 每筆需要 name, mac, ip ---
    if [ -s "$TMP_DHCP" ]; then
        DHCP_BLOCKS=$(grep -c '^config host' "$TMP_DHCP")
        DHCP_NO_NAME=$(awk 'BEGIN{RS=""; FS="\n"} /^config host/{has=0; for(i=1;i<=NF;i++){if($i~/option name/)has=1} if(!has)count++} END{print count+0}' "$TMP_DHCP")
        DHCP_NO_MAC=$(awk 'BEGIN{RS=""; FS="\n"} /^config host/{has=0; for(i=1;i<=NF;i++){if($i~/option mac/)has=1} if(!has)count++} END{print count+0}' "$TMP_DHCP")
        DHCP_NO_IP=$(awk 'BEGIN{RS=""; FS="\n"} /^config host/{has=0; for(i=1;i<=NF;i++){if($i~/option ip/)has=1} if(!has)count++} END{print count+0}' "$TMP_DHCP")
        [ "$DHCP_NO_NAME" -gt 0 ] && COMPONENT_ERRORS="${COMPONENT_ERRORS}\n  - DHCP: ${DHCP_NO_NAME}/${DHCP_BLOCKS} 筆缺少 name"
        [ "$DHCP_NO_MAC" -gt 0 ] && COMPONENT_ERRORS="${COMPONENT_ERRORS}\n  - DHCP: ${DHCP_NO_MAC}/${DHCP_BLOCKS} 筆缺少 mac"
        [ "$DHCP_NO_IP" -gt 0 ] && COMPONENT_ERRORS="${COMPONENT_ERRORS}\n  - DHCP: ${DHCP_NO_IP}/${DHCP_BLOCKS} 筆缺少 ip"
    fi

    # --- QoS interface: 每筆需要 name, bandwidth_up, bandwidth_down ---
    if [ -s "$TMP_QOS_INTERFACES" ]; then
        QOS_IF_BLOCKS=$(grep -c '^config qosinterface' "$TMP_QOS_INTERFACES")
        QOS_NO_NAME=$(awk 'BEGIN{RS=""; FS="\n"} /^config qosinterface/{has=0; for(i=1;i<=NF;i++){if($i~/option name/)has=1} if(!has)count++} END{print count+0}' "$TMP_QOS_INTERFACES")
        QOS_NO_BW_UP=$(awk 'BEGIN{RS=""; FS="\n"} /^config qosinterface/{has=0; for(i=1;i<=NF;i++){if($i~/option bandwidth_up/)has=1} if(!has)count++} END{print count+0}' "$TMP_QOS_INTERFACES")
        QOS_NO_BW_DN=$(awk 'BEGIN{RS=""; FS="\n"} /^config qosinterface/{has=0; for(i=1;i<=NF;i++){if($i~/option bandwidth_down/)has=1} if(!has)count++} END{print count+0}' "$TMP_QOS_INTERFACES")
        [ "$QOS_NO_NAME" -gt 0 ] && COMPONENT_ERRORS="${COMPONENT_ERRORS}\n  - QoS Interface: ${QOS_NO_NAME}/${QOS_IF_BLOCKS} 筆缺少 name"
        [ "$QOS_NO_BW_UP" -gt 0 ] && COMPONENT_ERRORS="${COMPONENT_ERRORS}\n  - QoS Interface: ${QOS_NO_BW_UP}/${QOS_IF_BLOCKS} 筆缺少 bandwidth_up"
        [ "$QOS_NO_BW_DN" -gt 0 ] && COMPONENT_ERRORS="${COMPONENT_ERRORS}\n  - QoS Interface: ${QOS_NO_BW_DN}/${QOS_IF_BLOCKS} 筆缺少 bandwidth_down"
    fi

    # --- DB Route: 每筆需要 domain, interface ---
    if [ -s "$TMP_DBROUTE" ]; then
        DBR_BLOCKS=$(grep -c '^config dbroute' "$TMP_DBROUTE")
        DBR_NO_DOMAIN=$(awk 'BEGIN{RS=""; FS="\n"} /^config dbroute/{has=0; for(i=1;i<=NF;i++){if($i~/option domain/)has=1} if(!has)count++} END{print count+0}' "$TMP_DBROUTE")
        DBR_NO_IFACE=$(awk 'BEGIN{RS=""; FS="\n"} /^config dbroute/{has=0; for(i=1;i<=NF;i++){if($i~/option interface/)has=1} if(!has)count++} END{print count+0}' "$TMP_DBROUTE")
        [ "$DBR_NO_DOMAIN" -gt 0 ] && COMPONENT_ERRORS="${COMPONENT_ERRORS}\n  - DB Route: ${DBR_NO_DOMAIN}/${DBR_BLOCKS} 筆缺少 domain"
        [ "$DBR_NO_IFACE" -gt 0 ] && COMPONENT_ERRORS="${COMPONENT_ERRORS}\n  - DB Route: ${DBR_NO_IFACE}/${DBR_BLOCKS} 筆缺少 interface"
    fi

    # --- Pushkey: 每筆需要 name, key ---
    PUSHKEY_BLOCKS=$(grep -c '^config pushkey' "$TMP_DECRYPTED" 2>/dev/null || echo "0")
    if [ "$PUSHKEY_BLOCKS" -gt 0 ]; then
        PK_NO_NAME=$(awk 'BEGIN{RS=""; FS="\n"} /^config pushkey/{has=0; for(i=1;i<=NF;i++){if($i~/option name/)has=1} if(!has)count++} END{print count+0}' "$TMP_DECRYPTED")
        PK_NO_KEY=$(awk 'BEGIN{RS=""; FS="\n"} /^config pushkey/{has=0; for(i=1;i<=NF;i++){if($i~/option key/)has=1} if(!has)count++} END{print count+0}' "$TMP_DECRYPTED")
        [ "$PK_NO_NAME" -gt 0 ] && COMPONENT_ERRORS="${COMPONENT_ERRORS}\n  - Pushkey: ${PK_NO_NAME}/${PUSHKEY_BLOCKS} 筆缺少 name"
        [ "$PK_NO_KEY" -gt 0 ] && COMPONENT_ERRORS="${COMPONENT_ERRORS}\n  - Pushkey: ${PK_NO_KEY}/${PUSHKEY_BLOCKS} 筆缺少 key"
    fi

    # --- RouterConfig: 每筆需要 payload ---
    if [ -s "$TMP_ROUTERCONFIG" ]; then
        RC_BLOCKS=$(grep -c '^config routerconfig' "$TMP_ROUTERCONFIG")
        RC_NO_PAYLOAD=$(awk 'BEGIN{RS=""; FS="\n"} /^config routerconfig/{has=0; for(i=1;i<=NF;i++){if($i~/option payload/)has=1} if(!has)count++} END{print count+0}' "$TMP_ROUTERCONFIG")
        [ "$RC_NO_PAYLOAD" -gt 0 ] && COMPONENT_ERRORS="${COMPONENT_ERRORS}\n  - RouterConfig: ${RC_NO_PAYLOAD}/${RC_BLOCKS} 筆缺少 payload"
    fi

    # 組件驗證結果
    if [ -n "$COMPONENT_ERRORS" ]; then
        log "🚨 組件欄位驗證失敗！"
        FIELD_DETAIL=$(printf "$COMPONENT_ERRORS")
        log "$FIELD_DETAIL"
        push_notify "ConfigSync_FieldError | $(echo "$FIELD_DETAIL" | tr '\n' ' ')"
        echo "🚨 組件欄位驗證失敗，已通知管理員。中止同步。"
        rm -f "$TMP_BASE64" "$TMP_BINARY" "$TMP_DECRYPTED" "$TMP_PBR" "$TMP_NETWORK" "$TMP_DHCP" \
              "$TMP_QOS_RULES" "$TMP_QOS_INTERFACES" "$TMP_CRONTAB" "$TMP_DBROUTE" "$TMP_ROUTERCONFIG"
        exit 1
    fi
    log "✅ 組件欄位驗證通過"

    # 同步 pushkey 到 .secrets (不分 satellite/標準，兩邊都同步)
    # 格式: option name xxx 或 option name 'xxx'
    local _pk_name="" _pk_key=""
    sed -n '/^config pushkey/,/^$/p' "$TMP_DECRYPTED" | while read line; do
        case "$line" in
            *"option name"*)
                _pk_name=$(echo "$line" | sed "s/.*option name *//; s/^'//; s/'$//")
                ;;
            *"option key"*)
                _pk_key=$(echo "$line" | sed "s/.*option key *//; s/^'//; s/'$//")
                if [ -n "$_pk_name" ] && [ -n "$_pk_key" ]; then
                    local _old_key=$(cat "$SECRET_DIR/pushkey.${_pk_name}" 2>/dev/null)
                    if [ "$_old_key" != "$_pk_key" ]; then
                        echo -n "$_pk_key" > "$SECRET_DIR/pushkey.${_pk_name}"
                        chmod 600 "$SECRET_DIR/pushkey.${_pk_name}"
                        log "🔑 pushkey.${_pk_name} 已更新"
                    fi
                    _pk_name="" _pk_key=""
                fi
                ;;
        esac
    done

    # 檢查各組件是否有變更
    log "檢查 Network 配置..."
    if check_content_changed "$TMP_NETWORK" "$STATE_NETWORK" "Network"; then
        CHANGED_NETWORK=1
    fi

    log "檢查 DHCP 配置..."
    if check_content_changed "$TMP_DHCP" "$STATE_DHCP" "DHCP"; then
        CHANGED_DHCP=1
    fi

    log "檢查 PBR 配置..."
    if check_content_changed "$TMP_PBR" "$STATE_PBR" "PBR"; then
        CHANGED_PBR=1
    fi

    log "檢查 QoS Rules 配置..."
    if check_content_changed "$TMP_QOS_RULES" "$STATE_QOS_RULES" "QoS Rules"; then
        CHANGED_QOS_RULES=1
    fi

    log "檢查 QoS Interfaces 配置..."
    if check_content_changed "$TMP_QOS_INTERFACES" "$STATE_QOS_INTERFACES" "QoS Interfaces"; then
        CHANGED_QOS_INTERFACES=1
    fi

    log "檢查 Crontab 配置..."
    if check_content_changed "$TMP_CRONTAB" "$STATE_CRONTAB" "Crontab"; then
        CHANGED_CRONTAB=1
    fi

    log "檢查 DB Route 配置..."
    if check_content_changed "$TMP_DBROUTE" "$STATE_DBROUTE" "DB Route"; then
        CHANGED_DBROUTE=1
    fi

    log "檢查 RouterConfig 配置..."
    if check_content_changed "$TMP_ROUTERCONFIG" "$STATE_ROUTERCONFIG" "RouterConfig"; then
        CHANGED_ROUTERCONFIG=1
    fi

    # 如果沒有任何變更，退出
    if [ $CHANGED_NETWORK -eq 0 ] && [ $CHANGED_DHCP -eq 0 ] && [ $CHANGED_PBR -eq 0 ] && \
       [ $CHANGED_QOS_RULES -eq 0 ] && [ $CHANGED_QOS_INTERFACES -eq 0 ] && [ $CHANGED_CRONTAB -eq 0 ] && \
       [ $CHANGED_DBROUTE -eq 0 ] && [ $CHANGED_ROUTERCONFIG -eq 0 ]; then
        log "✅ 所有配置均無變化，無需更新"
        save_current_md5 "$current_md5"
        # 產生 uploadconfig hash（確保後續 ram2flash 不會重複上傳，但不觸發上傳；僅 gateway）
        [ "$(cat /etc/myscript/.mesh_role 2>/dev/null)" != "client" ] && \
            [ -x /etc/myscript/sync-uploadconfig.sh ] && /etc/myscript/sync-uploadconfig.sh --hash-only
        rm -f "$TMP_BASE64" "$TMP_BINARY" "$TMP_DECRYPTED" "$TMP_PBR" "$TMP_NETWORK" "$TMP_DHCP" \
              "$TMP_QOS_RULES" "$TMP_QOS_INTERFACES" "$TMP_CRONTAB" "$TMP_DBROUTE" "$TMP_ROUTERCONFIG"
        exit 0
    fi

    echo ""
    echo "🛠️  執行配置更新..."
    echo "================================================================"

    # =====================================================
    # Network 配置處理
    # =====================================================
    if [ $CHANGED_NETWORK -eq 1 ]; then
        log "📝 處理 Network 配置變更..."

        # 建立備份
        if [ -f "/etc/config/network" ]; then
            if [ $DRY_RUN -eq 1 ]; then
                echo "📦 [DRY-RUN] 建立 network 回滾備份"
            else
                cp /etc/config/network "$ROLLBACK_NETWORK"
            fi
        fi

        # 無論新配置是否為空，都先清理舊有 WG 介面
        log "  檢查並清理舊有 WG 介面和 Peer..."

        # 刪除 WG 介面
        wg_sections=$(uci show network 2>/dev/null | grep "network.wg_" | cut -d'.' -f2 | cut -d'=' -f1 | sort -u)
        if [ -n "$wg_sections" ]; then
            echo "$wg_sections" | while read -r section; do
                if [ $DRY_RUN -eq 1 ]; then
                    echo "🗑️  [DRY-RUN] uci delete network.$section"
                else
                    uci delete "network.$section"
                    log "  🗑️  已刪除 WG 介面: $section"
                fi
            done
        fi

        # 刪除 WG Peer
        wg_peers=$(uci show network 2>/dev/null | grep "network.@wireguard_wg_" | awk -F'=' '{print $1}')
        if [ -n "$wg_peers" ]; then
            echo "$wg_peers" | while read -r line; do
                if [ $DRY_RUN -eq 1 ]; then
                    echo "🗑️  [DRY-RUN] uci delete $line"
                else
                    uci delete "$line"
                    log "  🗑️  已刪除 WG Peer: $line"
                fi
            done
        fi

        [ $DRY_RUN -eq 1 ] && echo "💾 [DRY-RUN] uci commit network" || uci commit network

        # 同時清理 firewall 中的 WG 介面
        log "  清理 firewall 中的 WG 介面..."
        zone_sections=$(uci show firewall 2>/dev/null | grep "=zone" | cut -d'=' -f1 | cut -d'.' -f2)

        for section in $zone_sections; do
            networks=$(uci get firewall.$section.network 2>/dev/null)
            if [ -n "$networks" ]; then
                for net in $networks; do
                    if echo "$net" | grep -q "^wg_"; then
                        if [ $DRY_RUN -eq 1 ]; then
                            echo "🗑️  [DRY-RUN] uci del_list firewall.$section.network=$net"
                        else
                            uci del_list firewall.$section.network="$net"
                            log "  🗑️  已從 firewall zone $section 移除 network: $net"
                        fi
                    fi
                done
            fi

            devices=$(uci get firewall.$section.device 2>/dev/null)
            if [ -n "$devices" ]; then
                for dev in $devices; do
                    if echo "$dev" | grep -q "^wg_"; then
                        if [ $DRY_RUN -eq 1 ]; then
                            echo "🗑️  [DRY-RUN] uci del_list firewall.$section.device=$dev"
                        else
                            uci del_list firewall.$section.device="$dev"
                            log "  🗑️  已從 firewall zone $section 移除 device: $dev"
                        fi
                    fi
                done
            fi
        done

        [ $DRY_RUN -eq 1 ] && echo "💾 [DRY-RUN] uci commit firewall" || uci commit firewall
        CHANGED_FIREWALL=1  # 標記 firewall 也需要重啟

        # 檢查是否有新配置需要合併
        if [ -s "$TMP_NETWORK" ]; then
            # 有新配置，執行合併
            if [ $DRY_RUN -eq 0 ]; then
                cat "$TMP_NETWORK" >> "/etc/config/network"
                log "  ✅ Network 配置已更新"

                # 將新的 WG 介面加入 firewall
                VPN_SECTION=$(uci show firewall | grep 'vpn' | head -n 1 | awk -F'=' '{print $1}')
                if [ -n "$VPN_SECTION" ]; then
                    VPN_SECTION=${VPN_SECTION%.name}
                    wg_interfaces=$(grep -E "^config interface ['\"]?wg_" "$TMP_NETWORK" | awk '{gsub(/'\''/,"",$3); gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}')

                    if [ -n "$wg_interfaces" ]; then
                        echo "$wg_interfaces" | while IFS= read -r iface; do
                            [ -z "$iface" ] && continue

                            network_list=$(uci -q get firewall.$VPN_SECTION.network 2>/dev/null || echo "")
                            if ! echo "$network_list" | grep -qw "$iface"; then
                                uci add_list $VPN_SECTION.network="$iface"
                                log "  ✅ 已添加 $iface 到 firewall network 列表"
                            fi

                            device_list=$(uci -q get firewall.$VPN_SECTION.device 2>/dev/null || echo "")
                            if ! echo "$device_list" | grep -qw "$iface"; then
                                uci add_list $VPN_SECTION.device="$iface"
                                log "  ✅ 已添加 $iface 到 firewall device 列表"
                            fi
                        done

                        uci commit firewall
                    fi
                fi
            else
                log "  [DRY-RUN] 模擬合併 Network 配置"
            fi
        else
            # 無新配置
            log "  ✅ 所有 WG 介面已清除（遠端配置為空）"
        fi

        update_state_file "$TMP_NETWORK" "$STATE_NETWORK" "Network"
    fi

    # =====================================================
    # DHCP 配置處理
    # =====================================================
    if [ $CHANGED_DHCP -eq 1 ]; then
        log "📝 處理 DHCP 配置變更..."

        # 建立備份
        if [ -f "/etc/config/dhcp" ]; then
            if [ $DRY_RUN -eq 1 ]; then
                echo "📦 [DRY-RUN] 建立 dhcp 回滾備份"
            else
                cp /etc/config/dhcp "$ROLLBACK_DHCP"
            fi
        fi

        # 清理舊有 DHCP host（無論新配置是否為空都要清理）
        if [ $DRY_RUN -eq 0 ]; then
            log "  清理舊有 DHCP Host 區塊..."
            awk -v RS='\n\n' -v ORS='\n\n' '/^config host/ {next} {print}' /etc/config/dhcp > /tmp/dhcp_clean && \
            mv /tmp/dhcp_clean /etc/config/dhcp

            # 如果有新配置才合併
            if [ -s "$TMP_DHCP" ]; then
                cat "$TMP_DHCP" >> "/etc/config/dhcp"
                log "  ✅ DHCP 配置已更新"
            else
                log "  ✅ DHCP Host 已全部清除（遠端配置為空）"
            fi
        else
            log "  [DRY-RUN] 模擬清理並合併 DHCP 配置"
        fi

        update_state_file "$TMP_DHCP" "$STATE_DHCP" "DHCP"
    fi

    # =====================================================
    # PBR 配置處理
    # =====================================================
    if [ $CHANGED_PBR -eq 1 ]; then
        log "📝 處理 PBR 配置變更..."

        # 清理舊有 CustRule（無論新配置是否為空都要清理）
        if [ $DRY_RUN -eq 1 ]; then
            echo "📝 [DRY-RUN] 模擬從 PBR 配置中移除包含 'CustRule' 的 policy 規則"
        else
            log "  清理 PBR 規則，移除含 'CustRule' 的 policy..."
            awk -v RS='\n\n' -v ORS='\n\n' '!(/^config policy/ && /option name .*CustRule/)' /etc/config/pbr > /tmp/pbr_new && \
            mv /tmp/pbr_new /etc/config/pbr

            # 如果有新配置才合併
            if [ -s "$TMP_PBR" ]; then
                cat "$TMP_PBR" >> "/etc/config/pbr"
                log "  ✅ PBR 配置已更新"
            else
                log "  ✅ PBR CustRule 已全部清除（遠端配置為空）"
            fi

            uci commit pbr
        fi

        update_state_file "$TMP_PBR" "$STATE_PBR" "PBR"
    fi

    # =====================================================
    # QoS Rules 配置處理
    # =====================================================
    if [ $CHANGED_QOS_RULES -eq 1 ]; then
        log "📝 處理 QoS Rules 配置變更..."

        TMP_QOS_DEFAULTS="/tmp/00-defaults.conf.new"
        > "$TMP_QOS_DEFAULTS"

        # 如果有新內容才寫入
        if [ -s "$TMP_QOS_RULES" ]; then
            cat "$TMP_QOS_RULES" > "$TMP_QOS_DEFAULTS"
        fi

        # 檢查是否為清空操作
        if [ ! -s "$TMP_QOS_RULES" ]; then
            log "  遠端 QoS Rules 配置為空，清空本地 QoS 規則..."

            if [ "$DRY_RUN" -eq 1 ]; then
                log "  [DRY-RUN] 模擬清空 /etc/qosify/00-defaults.conf"
            else
                if [ -f "/etc/qosify/00-defaults.conf" ]; then
                    cp /etc/qosify/00-defaults.conf "$ROLLBACK_QOS_DEFAULTS"
                fi
                > "/etc/qosify/00-defaults.conf"
                log "  ✅ QoS Rules 已清空"
            fi
        else
            # 有內容時檢查是否需要更新
            if [ -f "/etc/qosify/00-defaults.conf" ] && cmp -s "$TMP_QOS_DEFAULTS" "/etc/qosify/00-defaults.conf"; then
                log "  /etc/qosify/00-defaults.conf 內容未變化，跳過覆寫"
            else
                if [ "$DRY_RUN" -eq 1 ]; then
                    log "  [DRY-RUN] 模擬覆寫 /etc/qosify/00-defaults.conf"
                else
                    if [ -f "/etc/qosify/00-defaults.conf" ]; then
                        cp /etc/qosify/00-defaults.conf "$ROLLBACK_QOS_DEFAULTS"
                    fi
                    mv "$TMP_QOS_DEFAULTS" "/etc/qosify/00-defaults.conf"
                    log "  ✅ QoS Rules 已更新"
                fi
            fi
        fi

        update_state_file "$TMP_QOS_RULES" "$STATE_QOS_RULES" "QoS Rules"
    fi

    # =====================================================
    # QoS Interfaces 配置處理
    # =====================================================
    if [ $CHANGED_QOS_INTERFACES -eq 1 ]; then
        log "📝 處理 QoS Interfaces 配置變更..."

        if [ $DRY_RUN -eq 0 ] && [ -f "/etc/config/qosify" ]; then
            cp /etc/config/qosify "$ROLLBACK_QOSIFY"
        fi

        # 檢查是否為清空操作
        if [ ! -s "$TMP_QOS_INTERFACES" ]; then
            log "  遠端 QoS Interfaces 配置為空，清除本地所有 interface 區塊..."

            if [ $DRY_RUN -eq 1 ]; then
                log "  [DRY-RUN] 模擬清除所有 QoS interface 區塊"
            else
                # 清除所有 interface 區塊
                awk -v RS='\n\n' -v ORS='\n\n' '!/^config interface/' /etc/config/qosify > /tmp/qosify_clean
                sed -i -e :a -e '/^\n*$/{$d;N;};/\n$/b a' /tmp/qosify_clean
                mv /tmp/qosify_clean /etc/config/qosify
                log "  ✅ 已清除所有 QoS interface 區塊"
            fi
        else
            # 有新配置，執行合併
            merge_qosify_config "$TMP_QOS_INTERFACES" "$DRY_RUN"
        fi

        update_state_file "$TMP_QOS_INTERFACES" "$STATE_QOS_INTERFACES" "QoS Interfaces"
    fi

    # =====================================================
    # Crontab 配置處理
    # =====================================================
    if [ $CHANGED_CRONTAB -eq 1 ]; then
        log "📝 處理 Crontab 配置變更..."

        new_crontab_entries=$(awk '!/^config/{print}' "$TMP_CRONTAB")
        crontab -l 2>/dev/null | sed '/#SyncAreaStart/,/#SyncAreaEnd/d' > /tmp/current_crontab

        {
            echo "#SyncAreaStart"
            echo "$new_crontab_entries"
            echo "#SyncAreaEnd"
        } >> /tmp/current_crontab

        if [ "$DRY_RUN" -eq 1 ]; then
            log "  [DRY-RUN] 模擬更新 crontab"
        else
            crontab /tmp/current_crontab
            log "  ✅ Crontab 已更新"
        fi

        update_state_file "$TMP_CRONTAB" "$STATE_CRONTAB" "Crontab"
    fi

    # =====================================================
    # DB Route 域名路由配置處理
    # =====================================================
    if [ $CHANGED_DBROUTE -eq 1 ]; then
        log "📝 處理 DB Route 域名路由配置變更..."

        RT_TABLES="/etc/iproute2/rt_tables"
        CNROUTE_DNSMASQ="/etc/dnsmasq.d/dbroute-domains.conf"
        CNROUTE_NFT="/etc/myscript/dbroute.nft"

        if [ $DRY_RUN -eq 0 ]; then
            # 生成 dnsmasq conf 和 nft 規則
            > "$CNROUTE_DNSMASQ"
            > "$CNROUTE_NFT"

            echo "# 域名路由 — 由 sync-googleconfig 自動生成，請勿手動修改" > "$CNROUTE_DNSMASQ"
            echo "# 域名路由 nft — 由 sync-googleconfig 自動生成，請勿手動修改" > "$CNROUTE_NFT"
            echo "table inet fw4 {" >> "$CNROUTE_NFT"

            # 從 dbroute 配置中提取所有不重複的介面
            ROUTE_IFACES=$(awk '/option interface/ {gsub(/'\''/, "", $3); print $3}' "$TMP_DBROUTE" | sort -u)

            # NFT chain 開頭
            NFT_CHAIN_RULES=""

            for RIFACE in $ROUTE_IFACES; do
                SET_NAME="route_${RIFACE}_v4"

                # wan 使用固定 table/fwmark（走 main 路由表）
                if [ "$RIFACE" = "wan" ]; then
                    RTABLE_ID=254
                    RFWMARK="0xfe"
                else
                    # 從 rt_tables 找 table ID，不存在則自動建立
                    RTABLE_ID=$(awk -v name="pbr_${RIFACE}" '$2 == name {print $1}' "$RT_TABLES")
                    if [ -z "$RTABLE_ID" ]; then
                        # 找目前最大的 table ID，+1 作為新 ID
                        RTABLE_ID=$(awk '/^[0-9]+ pbr_/ {if($1>max) max=$1} END{print max+1}' "$RT_TABLES")
                        [ -z "$RTABLE_ID" ] && RTABLE_ID=256
                        echo "$RTABLE_ID pbr_${RIFACE}" >> "$RT_TABLES"
                        log "  自動建立 rt_table: $RTABLE_ID pbr_${RIFACE}"
                    fi
                    RFWMARK=$(printf "0x%x" "$RTABLE_ID")
                fi

                # 收集該介面的所有域名
                DOMAINS=$(awk -v iface="$RIFACE" '
                    /^config dbroute/ { domain=""; ifc="" }
                    /option domain/ { gsub(/'\''/, "", $3); domain=$3 }
                    /option interface/ { gsub(/'\''/, "", $3); ifc=$3 }
                    ifc == iface && domain != "" { print domain; domain=""; ifc="" }
                ' "$TMP_DBROUTE")

                if [ -z "$DOMAINS" ]; then
                    continue
                fi

                # 寫 dnsmasq conf — 每行一個域名
                echo "# === $RIFACE ===" >> "$CNROUTE_DNSMASQ"
                echo "$DOMAINS" | while read -r dom; do
                    [ -z "$dom" ] && continue
                    echo "nftset=/${dom}/4#inet#fw4#${SET_NAME}" >> "$CNROUTE_DNSMASQ"
                done

                # 寫 nft set
                cat >> "$CNROUTE_NFT" << NFTEOF

    # === $RIFACE (table $RTABLE_ID, fwmark $RFWMARK) ===
    set ${SET_NAME} {
        type ipv4_addr
        flags interval,timeout
        timeout 3h
        auto-merge
    }
NFTEOF

                # 累積 chain 規則
                NFT_CHAIN_RULES="${NFT_CHAIN_RULES}
        ip daddr @${SET_NAME} meta mark set ${RFWMARK}"

            done

            # 寫 nft chain（所有介面共用一個 prerouting chain）
            if [ -n "$NFT_CHAIN_RULES" ]; then
                cat >> "$CNROUTE_NFT" << NFTEOF

    chain domain_prerouting {
        type filter hook prerouting priority -150; policy accept;${NFT_CHAIN_RULES}
    }
}
NFTEOF
            fi

            log "  ✅ DB Route 配置已生成 ($CNROUTE_DNSMASQ, $CNROUTE_NFT)"

            # 重啟 dnsmasq 讓 nftset 指令生效
            CHANGED_DHCP=1

            # 載入 nft 規則（先清除 dbroute 的 chain/set 再載入新的）
            nft delete chain inet fw4 domain_prerouting 2>/dev/null
            for _set in $(nft list sets inet fw4 2>/dev/null | grep -o 'route_.*_v4'); do
                nft delete set inet fw4 "$_set" 2>/dev/null
            done
            nft -f "$CNROUTE_NFT" && log "  ✅ nft 規則已載入" || log "  ❌ nft 規則載入失敗"
        else
            log "  [DRY-RUN] 模擬生成 DB Route 配置"

            # DRY-RUN 顯示會生成的介面
            ROUTE_IFACES=$(awk '/option interface/ {gsub(/'\''/, "", $3); print $3}' "$TMP_DBROUTE" | sort -u)
            for RIFACE in $ROUTE_IFACES; do
                DOMAIN_COUNT=$(awk -v iface="$RIFACE" '
                    /^config dbroute/ { domain=""; ifc="" }
                    /option domain/ { gsub(/'\''/, "", $3); domain=$3 }
                    /option interface/ { gsub(/'\''/, "", $3); ifc=$3 }
                    ifc == iface && domain != "" { count++; domain=""; ifc="" }
                    END { print count+0 }
                ' "$TMP_DBROUTE")
                log "  [DRY-RUN] $RIFACE: $DOMAIN_COUNT 個域名"
            done
        fi

        update_state_file "$TMP_DBROUTE" "$STATE_DBROUTE" "DB Route"
    fi

    # =====================================================
    # RouterConfig 處理 (解密 payload → 還原 wg0-9 + ddns*)
    # client 不處理 RouterConfig（WG/DDNS 是 gateway 專屬）
    # =====================================================
    DEVICE_ROLE=$(cat /etc/myscript/.mesh_role 2>/dev/null)
    if [ "$DEVICE_ROLE" = "client" ]; then
        log "  ℹ️ Client 角色，跳過 RouterConfig"
    elif [ $CHANGED_ROUTERCONFIG -eq 1 ]; then
        log "📝 處理 RouterConfig 配置變更..."

        # 提取 payload (base64 加密字串)
        RC_PAYLOAD=$(awk '/^config routerconfig/,/^$/' "$TMP_ROUTERCONFIG" | sed -n "s/.*option payload *//p" | sed "s/^'//; s/'$//")

        if [ -n "$RC_PAYLOAD" ]; then
            # 從 token 推導 KEY/IV (與 uploadconfig.sh 一致)
            RC_TOKEN=$(echo "$URL" | grep -oE 'token=[^&]+' | cut -d'=' -f2)
            RC_SHA256=$(echo -n "$RC_TOKEN" | sha256sum | awk '{print $1}')
            RC_KEY_HEX="$RC_SHA256"
            RC_IV_HEX=$(echo "$RC_SHA256" | cut -c33-64)

            # 解密
            TMP_RC_BIN="/tmp/routerconfig_dec.bin"
            TMP_RC_PLAIN="/tmp/routerconfig_plain.txt"
            echo -n "$RC_PAYLOAD" | base64 -d > "$TMP_RC_BIN" 2>/dev/null
            openssl enc -aes-256-cbc -d -K "$RC_KEY_HEX" -iv "$RC_IV_HEX" \
                -in "$TMP_RC_BIN" -out "$TMP_RC_PLAIN" 2>/dev/null

            if [ $? -ne 0 ] || [ ! -s "$TMP_RC_PLAIN" ]; then
                log "  ❌ RouterConfig payload 解密失敗"
                push_notify "ConfigSync_RouterConfigDecryptFailed"
            else
                RC_LINES=$(wc -l < "$TMP_RC_PLAIN")
                log "  ✅ payload 解密成功 (${RC_LINES} 行)"

                if [ $DRY_RUN -eq 0 ]; then
                    # --- 還原 WG 介面 (wg0, wg1... 不含 wg_) ---
                    # 先刪除現有 wg0-9 介面和 peer
                    log "  清理舊有 wg0-9 介面..."
                    for sec in $(uci show network 2>/dev/null | grep -oE 'network\.wg[0-9]+' | sort -u); do
                        uci delete "$sec" 2>/dev/null
                        log "    🗑️ 已刪除 $sec"
                    done
                    # 刪除 wireguard_wg0-9 peer（反向刪除避免 index 偏移）
                    for peer_type in $(uci show network 2>/dev/null | grep -oE 'wireguard_wg[0-9]+' | sort -u); do
                        while uci delete "network.@${peer_type}[0]" 2>/dev/null; do
                            log "    🗑️ 已刪除 peer @${peer_type}"
                        done
                    done
                    uci commit network

                    # 提取並寫入 wg 介面 + peer
                    TMP_RC_WG="/tmp/rc_wg.uci"
                    awk '
                    /^config interface/ {
                        name = $3; gsub(/'\''/, "", name)
                        if (name ~ /^wg[0-9]/) { printing=1; print; next } else { printing=0 }
                    }
                    /^config wireguard_wg[0-9]/ {
                        type = $2
                        if (type ~ /^wireguard_wg[0-9]+$/) { printing=1; print; next } else { printing=0 }
                    }
                    /^config / && !/^config interface/ && !/^config wireguard_wg[0-9]/ { printing=0 }
                    printing { print }
                    /^$/ && printing { printing=0 }
                    ' "$TMP_RC_PLAIN" > "$TMP_RC_WG"

                    if [ -s "$TMP_RC_WG" ]; then
                        cat "$TMP_RC_WG" >> /etc/config/network
                        uci commit network
                        WG_RESTORED=$(grep -c "^config interface 'wg[0-9]" "$TMP_RC_WG" 2>/dev/null || echo "0")
                        log "  ✅ WG 介面已還原 (${WG_RESTORED} 個)"
                        CHANGED_NETWORK=1

                        # 把還原的 WG 介面加回 firewall zone
                        # wg0 → vpn (小寫，PBR 出站)
                        # wg1-9 → VPN (大寫，入站)
                        log "  🔥 還原 WG firewall zone..."
                        for wg_name in $(grep -oE "wg[0-9]+" "$TMP_RC_WG" | sort -u); do
                            case "$wg_name" in
                                wg0)  FW_ZONE="vpn" ;;
                                *)    FW_ZONE="VPN" ;;
                            esac
                            # 找到對應 zone 的 index
                            FW_IDX=""
                            zi=0
                            while uci get firewall.@zone[$zi].name >/dev/null 2>&1; do
                                if [ "$(uci get firewall.@zone[$zi].name)" = "$FW_ZONE" ]; then
                                    FW_IDX=$zi
                                    break
                                fi
                                zi=$((zi + 1))
                            done
                            if [ -n "$FW_IDX" ]; then
                                # 檢查是否已加入
                                if ! uci get firewall.@zone[$FW_IDX].network 2>/dev/null | grep -qw "$wg_name"; then
                                    uci add_list firewall.@zone[$FW_IDX].network="$wg_name"
                                    log "    ✅ $wg_name → $FW_ZONE zone"
                                fi
                            else
                                log "    ⚠️ 找不到 $FW_ZONE zone，跳過 $wg_name"
                            fi
                        done
                        uci commit firewall
                    fi
                    rm -f "$TMP_RC_WG"

                    # --- 還原 DDNS 設定 (ddns*) ---
                    log "  清理舊有 ddns* 服務..."
                    for sec in $(uci show ddns 2>/dev/null | grep -oE "ddns\.ddns[0-9]+" | sort -u); do
                        uci delete "$sec" 2>/dev/null
                        log "    🗑️ 已刪除 $sec"
                    done
                    uci commit ddns

                    TMP_RC_DDNS="/tmp/rc_ddns.uci"
                    awk '
                    /^config service/ {
                        name = $3; gsub(/'\''/, "", name)
                        if (name ~ /^ddns/) { printing=1; print; next } else { printing=0 }
                    }
                    /^config / && !/^config service/ { printing=0 }
                    printing { print }
                    /^$/ && printing { printing=0 }
                    ' "$TMP_RC_PLAIN" > "$TMP_RC_DDNS"

                    if [ -s "$TMP_RC_DDNS" ]; then
                        cat "$TMP_RC_DDNS" >> /etc/config/ddns
                        uci commit ddns
                        DDNS_RESTORED=$(grep -c "^config service 'ddns" "$TMP_RC_DDNS" 2>/dev/null || echo "0")
                        log "  ✅ DDNS 服務已還原 (${DDNS_RESTORED} 個)"
                    fi
                    rm -f "$TMP_RC_DDNS"
                else
                    log "  [DRY-RUN] 模擬還原 WG 介面和 DDNS 設定"
                    _wg_cnt=$(grep -c "^config interface 'wg[0-9]" "$TMP_RC_PLAIN" 2>/dev/null || echo 0)
                    log "    WG 介面: $_wg_cnt 個"
                    _ddns_cnt=$(grep -c "^config service 'ddns" "$TMP_RC_PLAIN" 2>/dev/null || echo 0)
                    log "    DDNS 服務: $_ddns_cnt 個"
                fi
            fi

            rm -f "$TMP_RC_BIN" "$TMP_RC_PLAIN"
        else
            log "  ⚠️ RouterConfig payload 為空，跳過"
        fi

        update_state_file "$TMP_ROUTERCONFIG" "$STATE_ROUTERCONFIG" "RouterConfig"
    fi

    echo ""
    echo "🔄 重啟受影響的服務..."
    echo "================================================================"

    if [ $DRY_RUN -eq 1 ]; then
        echo "✅ Dry-run 完成"
        echo "👉 使用: $0 --apply 來實際執行"

        [ $CHANGED_NETWORK -eq 1 ] && echo "  - Network 需要重啟"
        [ $CHANGED_DHCP -eq 1 ] && echo "  - DHCP/DNS 需要重啟"
        [ $CHANGED_FIREWALL -eq 1 ] && echo "  - Firewall 需要重啟"
        [ $CHANGED_PBR -eq 1 ] && echo "  - PBR 需要重啟"
        [ $CHANGED_QOS_RULES -eq 1 ] || [ $CHANGED_QOS_INTERFACES -eq 1 ] && echo "  - QoSify 需要重啟"
    else
        # 只重啟有變更的服務
        if [ $CHANGED_NETWORK -eq 1 ]; then
            log "🔄 重啟 Network 服務..."
            /etc/init.d/network reload
        fi

        if [ $CHANGED_DHCP -eq 1 ]; then
            if [ -x /etc/init.d/dnsmasq ]; then
                log "🔄 重啟 DNSMasq 服務..."
                /etc/init.d/dnsmasq restart
            else
                log "⚠️  dnsmasq 未安裝，跳過重啟"
            fi
        fi

        if [ $CHANGED_FIREWALL -eq 1 ]; then
            log "🔄 重啟 Firewall 服務..."
            /etc/init.d/firewall restart
        fi

        if [ $CHANGED_PBR -eq 1 ]; then
            if [ -x /etc/init.d/pbr ]; then
                log "🔄 重啟 PBR 服務..."
                /etc/init.d/pbr reload
            else
                log "⚠️  pbr 未安裝，跳過重啟"
            fi
            [ -x /etc/init.d/pbr-cust ] && /etc/init.d/pbr-cust start
        fi

        if [ $CHANGED_QOS_RULES -eq 1 ] || [ $CHANGED_QOS_INTERFACES -eq 1 ]; then
            if [ -x /etc/init.d/qosify ]; then
                log "🔄 重啟 QoSify 服務..."
                /etc/init.d/qosify restart
            else
                log "⚠️  qosify 未安裝，跳過重啟"
            fi
        fi

        if [ $CHANGED_DBROUTE -eq 1 ]; then
            log "🔄 設定域名路由 ip rule..."
            /etc/myscript/dbroute-setup.sh
            log "🔄 填充域名路由 nft set..."
            /etc/myscript/dbroute-refresh.sh
        fi

        echo none > /sys/class/leds/blue:status/trigger 2>/dev/null

        push_notify "ConfigSync_Done"

        # 網路健康檢查 (重啟服務後等待網路恢復)
        if [ "$NO_NETWORK_CHECK" = "1" ]; then
            log "⚠️ 跳過網路健康檢查 (--no-network-check)"
            echo "🎉 配置更新完成!"
            save_current_md5 "$current_md5"
            # 設定有變動，上傳加密設定到 Google Sheet（僅 gateway）
            [ "$(cat /etc/myscript/.mesh_role 2>/dev/null)" != "client" ] && \
                [ -x /etc/myscript/sync-uploadconfig.sh ] && /etc/myscript/sync-uploadconfig.sh
        else
            log "🩺 執行網路連接健康檢查..."
            HEALTH_OK=0
            for i in 1 2 3; do
                if ping -c 2 -W 5 8.8.8.8 >/dev/null 2>&1; then
                    HEALTH_OK=1
                    break
                fi
                log "  ⏳ 等待網路恢復... ($i/3)"
                sleep 10
            done
            if [ "$HEALTH_OK" = "1" ]; then
                log "✅ 網路連接正常。"
                echo "🎉 配置更新完成!"
                save_current_md5 "$current_md5"
                # 設定有變動，上傳加密設定到 Google Sheet（僅 gateway）
                [ "$(cat /etc/myscript/.mesh_role 2>/dev/null)" != "client" ] && \
                    [ -x /etc/myscript/sync-uploadconfig.sh ] && /etc/myscript/sync-uploadconfig.sh
            else
                log "❌ 錯誤: 網路連接測試失敗! 正在回滾配置..."

                # 回滾所有變更的配置
                [ $CHANGED_NETWORK -eq 1 ] && [ -f "$ROLLBACK_NETWORK" ] && mv "$ROLLBACK_NETWORK" "/etc/config/network"
                [ $CHANGED_DHCP -eq 1 ] && [ -f "$ROLLBACK_DHCP" ] && mv "$ROLLBACK_DHCP" "/etc/config/dhcp"
                [ $CHANGED_FIREWALL -eq 1 ] && [ -f "$ROLLBACK_FIREWALL" ] && mv "$ROLLBACK_FIREWALL" "/etc/config/firewall"
                [ $CHANGED_QOS_INTERFACES -eq 1 ] && [ -f "$ROLLBACK_QOSIFY" ] && mv "$ROLLBACK_QOSIFY" "/etc/config/qosify"
                [ $CHANGED_QOS_RULES -eq 1 ] && [ -f "$ROLLBACK_QOS_DEFAULTS" ] && mv "$ROLLBACK_QOS_DEFAULTS" "/etc/qosify/00-defaults.conf"

                log "🔄 重新啟動服務以應用回滾..."
                [ -x /etc/init.d/network ] && /etc/init.d/network reload
                [ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart
                /etc/init.d/firewall restart
                [ -x /etc/init.d/qosify ] && /etc/init.d/qosify restart
                [ -x /etc/init.d/pbr ] && /etc/init.d/pbr reload
                [ -x /etc/init.d/pbr-cust ] && /etc/init.d/pbr-cust start

                push_notify "ConfigSync_Rollback"

                log "🔥 配置已回滾。請檢查遠端設定檔。"
            fi
        fi
    fi

    # 清理臨時檔案
    rm -f "$TMP_BASE64" "$TMP_BINARY" "$TMP_DECRYPTED" "$TMP_PBR" "$TMP_NETWORK" "$TMP_DHCP" \
          "$TMP_QOS_RULES" "$TMP_QOS_INTERFACES" "$TMP_CRONTAB" "$TMP_DBROUTE" "$TMP_ROUTERCONFIG" \
          "$TMP_QOS_DEFAULTS" \
          "$ROLLBACK_NETWORK" "$ROLLBACK_DHCP" "$ROLLBACK_FIREWALL" "$ROLLBACK_QOSIFY" "$ROLLBACK_QOS_DEFAULTS"

    exit 0
}

main "$@"
