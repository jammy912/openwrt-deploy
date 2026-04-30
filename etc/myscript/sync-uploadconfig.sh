#!/bin/sh

# uploadconfig.sh - 從本機 /etc/config 提取 WG 介面與 DDNS 設定，加密後上傳至 Google Apps Script
# 放置位置：/etc/myscript/uploadconfig.sh

# 引入鎖定處理器
. /etc/myscript/lock-handler.sh
LOCK_NAME="uploadconfig"
EXPIRY_SEC=120

# 引入通知器
. /etc/myscript/push-notify.inc
PUSH_NAMES="admin"

# 執行鎖定檢查
lock_check_and_create "$LOCK_NAME" "$EXPIRY_SEC"
if [ $? -ne 0 ]; then
    exit 0
fi
trap "lock_remove $LOCK_NAME" TERM INT EXIT

# =====================================================
# 配置參數
# =====================================================
SECRET_DIR="/etc/myscript/.secrets"
URL=$(cat "$SECRET_DIR/secret.url" 2>/dev/null) || { echo "錯誤: 無法讀取 secret.url"; exit 1; }

# 從 URL 提取 token
TOKEN=$(echo "$URL" | grep -oE 'token=[^&]+' | cut -d'=' -f2)
if [ -z "$TOKEN" ]; then
    echo "錯誤: 無法從 URL 提取 token"
    exit 1
fi

# 從 token 的 sha256 推導 KEY 和 IV
# sha256 = 64 hex = 32 bytes
# KEY = 全部 64 hex (32 bytes = AES-256)
# IV  = 後 32 hex (16 bytes)
TOKEN_SHA256=$(echo -n "$TOKEN" | sha256sum | awk '{print $1}')
KEY_HEX="$TOKEN_SHA256"
IV_HEX=$(echo "$TOKEN_SHA256" | cut -c33-64)

# 構建上傳 URL (替換 action=Sync → action=UploadConfig)
UPLOAD_URL=$(echo "$URL" | sed 's/action=[^&]*/action=UploadConfig/')

# Hash 檢查檔案
HASH_FILE="/tmp/.uploadconfig_hash"
HASH_FILE_HITRON="/tmp/.uploadconfig_hitron_hash"

# 臨時檔案
TMP_PLAIN="/tmp/uploadconfig_plain.txt"
TMP_ENCRYPTED="/tmp/uploadconfig_encrypted.bin"
TMP_BASE64="/tmp/uploadconfig_base64.txt"
TMP_HITRON_PLAIN="/tmp/uploadconfig_hitron_plain.txt"
TMP_HITRON_ENCRYPTED="/tmp/uploadconfig_hitron_encrypted.bin"
TMP_HITRON_BASE64="/tmp/uploadconfig_hitron_base64.txt"

# =====================================================
# 日誌函數
# =====================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# =====================================================
# 主程式
# =====================================================
main() {
    log "🚀 開始提取並上傳設定..."

    # 清空暫存
    > "$TMP_PLAIN"

    # -------------------------------------------------
    # 1. 提取 WG 介面 (wg0, wg1, wg2... 不含 wg_ 開頭)
    #    包含 config interface 'wgN' 和 config wireguard_wgN
    # -------------------------------------------------
    log "📡 提取 WireGuard 介面設定..."

    NETWORK_FILE="/etc/config/network"
    if [ -f "$NETWORK_FILE" ]; then
        # 提取 config interface 'wgN' 區塊 (wg 後接數字，不含 wg_)
        awk '
        /^config interface/ {
            # 取得介面名稱
            name = $3
            gsub(/'\''/, "", name)
            # wg 開頭 + 數字，但不是 wg_ 開頭
            if (name ~ /^wg[0-9]/) {
                printing = 1
                print
                next
            } else {
                printing = 0
            }
        }
        /^config wireguard_wg[0-9]/ {
            # wireguard peer 區塊 (wireguard_wg0, wireguard_wg1...)
            # 但不是 wireguard_wg_ (如 wireguard_wg_tw)
            type = $2
            if (type ~ /^wireguard_wg[0-9]+$/) {
                printing = 1
                print
                next
            } else {
                printing = 0
            }
        }
        /^config / && !/^config interface/ && !/^config wireguard_wg[0-9]/ {
            printing = 0
        }
        printing { print }
        /^$/ && printing { printing = 0 }
        ' "$NETWORK_FILE" >> "$TMP_PLAIN"

        WG_COUNT=$(grep -c "^config interface 'wg[0-9]" "$TMP_PLAIN" 2>/dev/null || echo "0")
        WG_PEER_COUNT=$(grep -c "^config wireguard_wg[0-9]" "$TMP_PLAIN" 2>/dev/null || echo "0")
        log "  ✅ WG 介面: ${WG_COUNT} 個, Peer: ${WG_PEER_COUNT} 個"
    else
        log "  ⚠️ $NETWORK_FILE 不存在，跳過 WG 提取"
    fi

    # -------------------------------------------------
    # 2. 提取 DDNS 設定 (ddns* 開頭的 service)
    # -------------------------------------------------
    log "🌐 提取 DDNS 設定..."

    DDNS_FILE="/etc/config/ddns"
    if [ -f "$DDNS_FILE" ]; then
        # 加入分隔空行
        [ -s "$TMP_PLAIN" ] && echo "" >> "$TMP_PLAIN"

        # 提取 config service 'ddnsN' 區塊
        awk '
        /^config service/ {
            name = $3
            gsub(/'\''/, "", name)
            if (name ~ /^ddns/) {
                printing = 1
                print
                next
            } else {
                printing = 0
            }
        }
        /^config / && !/^config service/ {
            printing = 0
        }
        printing { print }
        /^$/ && printing { printing = 0 }
        ' "$DDNS_FILE" >> "$TMP_PLAIN"

        DDNS_COUNT=$(grep -c "^config service 'ddns" "$TMP_PLAIN" 2>/dev/null || echo "0")
        log "  ✅ DDNS 服務: ${DDNS_COUNT} 個"
    else
        log "  ⚠️ $DDNS_FILE 不存在，跳過 DDNS 提取"
    fi

    # -------------------------------------------------
    # 2.6 提取 TDX API 憑證 (tdx.appid / tdx.appkey)
    # -------------------------------------------------
    TDX_COUNT=0
    _tdx_id=$(cat "$SECRET_DIR/tdx.appid" 2>/dev/null)
    _tdx_key=$(cat "$SECRET_DIR/tdx.appkey" 2>/dev/null)
    if [ -n "$_tdx_id" ] && [ -n "$_tdx_key" ]; then
        [ -s "$TMP_PLAIN" ] && echo "" >> "$TMP_PLAIN"
        echo "config TDX 'credentials'" >> "$TMP_PLAIN"
        echo "        option appid '$_tdx_id'" >> "$TMP_PLAIN"
        echo "        option appkey '$_tdx_key'" >> "$TMP_PLAIN"
        TDX_COUNT=1
        log "  ✅ TDX 憑證已納入"
    fi

    # -------------------------------------------------
    # 3. 驗證提取結果
    # -------------------------------------------------
    if [ ! -s "$TMP_PLAIN" ]; then
        log "⚠️ 沒有提取到任何設定，跳過上傳"
        rm -f "$TMP_PLAIN"
        exit 0
    fi

    TOTAL_LINES=$(wc -l < "$TMP_PLAIN")
    TOTAL_SIZE=$(wc -c < "$TMP_PLAIN")
    log "📊 提取完成: ${TOTAL_LINES} 行, ${TOTAL_SIZE} bytes"

    # -------------------------------------------------
    # 3.5 Hash 比對，無變動則跳過上傳
    # -------------------------------------------------
    NEW_HASH=$(md5sum "$TMP_PLAIN" | awk '{print $1}')
    OLD_HASH=$(cat "$HASH_FILE" 2>/dev/null)

    # --hash-only: 只產生 hash 不上傳（供 sync-googleconfig 無變化時使用）
    if [ "$1" = "--hash-only" ]; then
        log "💾 僅保存 hash: $NEW_HASH (不上傳)"
        echo "$NEW_HASH" > "$HASH_FILE"
        rm -f "$TMP_PLAIN"
        exit 0
    fi

    if [ "$NEW_HASH" = "$OLD_HASH" ]; then
        log "⏭️ 設定無變動 (hash: $NEW_HASH)，跳過上傳"
        rm -f "$TMP_PLAIN"
        exit 0
    fi
    log "🔄 偵測到變動 (old: ${OLD_HASH:-none} → new: $NEW_HASH)"

    # -------------------------------------------------
    # 4. AES-256-CBC 加密 + Base64 編碼
    # -------------------------------------------------
    log "🔐 加密中..."

    openssl enc -aes-256-cbc -e -K "$KEY_HEX" -iv "$IV_HEX" \
        -in "$TMP_PLAIN" -out "$TMP_ENCRYPTED" 2>/dev/null
    if [ $? -ne 0 ]; then
        log "❌ AES 加密失敗"
        push_notify "UploadConfig_EncryptFailed"
        rm -f "$TMP_PLAIN" "$TMP_ENCRYPTED"
        exit 1
    fi

    base64 "$TMP_ENCRYPTED" | tr -d '\n' > "$TMP_BASE64" 2>/dev/null
    if [ $? -ne 0 ] || [ ! -s "$TMP_BASE64" ]; then
        log "❌ Base64 編碼失敗"
        push_notify "UploadConfig_EncodeFailed"
        rm -f "$TMP_PLAIN" "$TMP_ENCRYPTED" "$TMP_BASE64"
        exit 1
    fi

    ENC_SIZE=$(wc -c < "$TMP_BASE64")
    log "  ✅ 加密完成: ${ENC_SIZE} bytes (base64)"

    # -------------------------------------------------
    # 5. 上傳到 Google Apps Script
    # -------------------------------------------------
    log "📤 上傳至 Google Apps Script..."

    PAYLOAD=$(cat "$TMP_BASE64")

    HTTP_CODE=$(curl -s -o /tmp/uploadconfig_resp.txt -w "%{http_code}" \
        --connect-timeout 15 --max-time 60 \
        -X POST "$UPLOAD_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "data=${PAYLOAD}" 2>/dev/null)

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
        RESP=$(cat /tmp/uploadconfig_resp.txt 2>/dev/null)
        log "  ✅ 上傳成功 (HTTP $HTTP_CODE)"
        log "  📝 回應: $RESP"
        echo "$NEW_HASH" > "$HASH_FILE"
        push_notify "UploadConfig_Done | WG:${WG_COUNT} Peer:${WG_PEER_COUNT} DDNS:${DDNS_COUNT} TDX:${TDX_COUNT}"
    else
        RESP=$(cat /tmp/uploadconfig_resp.txt 2>/dev/null)
        log "  ❌ 上傳失敗 (HTTP $HTTP_CODE)"
        log "  📝 回應: $RESP"
        push_notify "UploadConfig_Failed | HTTP:${HTTP_CODE}"
    fi

    # -------------------------------------------------
    # 6. Hitron port forward 獨立上傳（失敗不影響主流程，雲端 F2 保留上次值）
    # -------------------------------------------------
    upload_hitron_pf

    # -------------------------------------------------
    # 7. 清理
    # -------------------------------------------------
    rm -f "$TMP_PLAIN" "$TMP_ENCRYPTED" "$TMP_BASE64" /tmp/uploadconfig_resp.txt
    rm -f "$TMP_HITRON_PLAIN" "$TMP_HITRON_ENCRYPTED" "$TMP_HITRON_BASE64" /tmp/uploadconfig_hitron_resp.txt

    log "✅ 完成"
    exit 0
}

# =====================================================
# Hitron port forward 獨立上傳
#   抓 PF → 包 UCI → AES → base64 → action=UploadConfigHitron
#   抓不到就直接 return（不送，雲端 F2 保留上次成功的值）
#   抓到順手寫 /etc/myscript/.hitron-pf.json，gw 不用等下載
# =====================================================
upload_hitron_pf() {
    local _role _hcool _age _hck _hitron _huser _hpass _ok _resp _pf _b64
    local _pf_count _new_hash _old_hash _http_code _enc_size

    _role=$(cat /etc/myscript/.mesh_role_active 2>/dev/null)
    [ "$_role" = "client" ] && return 0

    _hcool=/tmp/.hitron_cooldown
    if [ -f "$_hcool" ]; then
        _age=$(( $(date +%s) - $(date -r "$_hcool" +%s 2>/dev/null || echo 0) ))
        if [ "$_age" -lt 300 ]; then
            log "⏭️ Hitron cooldown (${_age}s < 300s)，跳過"
            return 0
        fi
        rm -f "$_hcool"
    fi

    log "🔁 抓取 Hitron port forward..."
    _hck=/tmp/.hitron_up_ck.$$
    _hitron=http://192.168.168.1
    _huser=admin
    _hpass=password
    _ok=0
    _pf=""
    if curl -s -c "$_hck" "$_hitron/login.html" -o /dev/null --connect-timeout 5 --max-time 10; then
        _resp=$(curl -s -b "$_hck" -c "$_hck" -X POST "$_hitron/goform/login" \
            -d "usr=$_huser&pwd=$_hpass&preSession=" --max-time 10)
        if [ "$_resp" = "success" ]; then
            _pf=$(curl -s -b "$_hck" "$_hitron/data/getForwardingRules.asp" --max-time 10)
            if echo "$_pf" | grep -q '^\['; then
                _ok=1
            else
                log "  ❌ Hitron PF 讀取失敗: $_pf"
            fi
            curl -s -b "$_hck" -X POST "$_hitron/goform/logout" -d "data=byebye" -o /dev/null --max-time 5
        else
            log "  ❌ Hitron 登入失敗: $_resp"
        fi
    else
        log "  ❌ Hitron 連線失敗"
    fi
    rm -f "$_hck"

    if [ "$_ok" != "1" ]; then
        touch "$_hcool"
        push_notify "UploadConfig_HitronFailed"
        return 0
    fi

    # 抓到 → 順手寫本地 .hitron-pf.json（gw 直接有檔，不必繞雲端）
    printf '%s' "$_pf" > /etc/myscript/.hitron-pf.json
    chmod 600 /etc/myscript/.hitron-pf.json

    _pf_count=$(echo "$_pf" | tr ',' '\n' | grep -c '"appName"')
    _b64=$(printf '%s' "$_pf" | base64 -w0 2>/dev/null || printf '%s' "$_pf" | base64 | tr -d '\n')
    log "  ✅ Hitron PF: ${_pf_count} 條 (base64: ${#_b64} bytes)"

    # 包成 UCI 格式（與 RouterConfig 同樣結構，方便下載端複用 awk）
    {
        echo "config HITRON 'port_forward'"
        echo "        option data '$_b64'"
    } > "$TMP_HITRON_PLAIN"

    # Hash 比對：和上次成功上傳相同就跳過
    _new_hash=$(md5sum "$TMP_HITRON_PLAIN" | awk '{print $1}')
    _old_hash=$(cat "$HASH_FILE_HITRON" 2>/dev/null)
    if [ "$_new_hash" = "$_old_hash" ]; then
        log "  ⏭️ Hitron PF 無變動 (hash: $_new_hash)，跳過上傳"
        return 0
    fi
    log "  🔄 Hitron PF 變動 (old: ${_old_hash:-none} → new: $_new_hash)"

    # AES + base64
    openssl enc -aes-256-cbc -e -K "$KEY_HEX" -iv "$IV_HEX" \
        -in "$TMP_HITRON_PLAIN" -out "$TMP_HITRON_ENCRYPTED" 2>/dev/null
    if [ $? -ne 0 ]; then
        log "  ❌ Hitron AES 加密失敗"
        return 0
    fi
    base64 "$TMP_HITRON_ENCRYPTED" | tr -d '\n' > "$TMP_HITRON_BASE64" 2>/dev/null
    if [ ! -s "$TMP_HITRON_BASE64" ]; then
        log "  ❌ Hitron base64 編碼失敗"
        return 0
    fi
    _enc_size=$(wc -c < "$TMP_HITRON_BASE64")

    # 上傳 (action=UploadConfigHitron → 雲端 F2)
    log "  📤 上傳 Hitron PF (${_enc_size} bytes)..."
    local _hitron_url
    _hitron_url=$(echo "$URL" | sed 's/action=[^&]*/action=UploadConfigHitron/')
    _http_code=$(curl -s -o /tmp/uploadconfig_hitron_resp.txt -w "%{http_code}" \
        --connect-timeout 15 --max-time 60 \
        -X POST "$_hitron_url" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "data=$(cat "$TMP_HITRON_BASE64")" 2>/dev/null)

    if [ "$_http_code" = "200" ] || [ "$_http_code" = "302" ]; then
        log "  ✅ Hitron PF 上傳成功 (HTTP $_http_code)"
        echo "$_new_hash" > "$HASH_FILE_HITRON"
        push_notify "UploadConfigHitron_Done | PF:${_pf_count}"
    else
        log "  ❌ Hitron PF 上傳失敗 (HTTP $_http_code)"
        push_notify "UploadConfigHitron_Failed | HTTP:${_http_code}"
    fi
}

main "$@"
