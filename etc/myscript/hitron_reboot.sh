#!/bin/sh
# hitron_reboot.sh - 透過 Hitron Web API 將上層分享器 (192.168.168.1) 重開機
# 放置位置：/etc/myscript/hitron_reboot.sh
#
# 用法:
#   /etc/myscript/hitron_reboot.sh             # 互動,5 秒倒數
#   /etc/myscript/hitron_reboot.sh -y           # 直接執行,不倒數
#   /etc/myscript/hitron_reboot.sh --dry-run    # 只測登入,不送 reboot

. /etc/myscript/lock-handler.sh
LOCK_NAME="hitron_reboot"
EXPIRY_SEC=180

. /etc/myscript/push-notify.inc
PUSH_NAMES="admin"

lock_check_and_create "$LOCK_NAME" "$EXPIRY_SEC"
if [ $? -ne 0 ]; then
    echo "另一個 hitron_reboot 進行中,結束"
    exit 0
fi
trap "lock_remove $LOCK_NAME" TERM INT EXIT

# =====================================================
# 設定
# =====================================================
HITRON="http://192.168.168.1"
HUSER="admin"
HPASS="password"
HCK="/tmp/.hitron_reboot_ck.$$"

# Hitron CODA reboot endpoint: /goform/Reboot
# 由 js/admin_devreboot.js 反查得到 (Backbone model.urlRoot="goform/Reboot")
# 送 JSON body {"reboot":"1"}
REBOOT_URL="/goform/Reboot"

DRY_RUN=0
ASSUME_YES=0
for _arg in "$@"; do
    case "$_arg" in
        --dry-run) DRY_RUN=1 ;;
        -y|--yes)  ASSUME_YES=1 ;;
    esac
done

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

cleanup() {
    rm -f "$HCK"
}

# =====================================================
# 倒數確認(互動時)
# =====================================================
if [ "$ASSUME_YES" != "1" ] && [ "$DRY_RUN" != "1" ] && [ -t 0 ]; then
    log "⚠️ 即將重開上層分享器 $HITRON (5 秒後執行,Ctrl+C 取消)"
    _i=5
    while [ "$_i" -gt 0 ]; do
        printf "  %d... " "$_i"
        sleep 1
        _i=$((_i - 1))
    done
    echo ""
fi

# =====================================================
# 1. 取得 cookie
# =====================================================
log "🔑 取得 Hitron session cookie..."
if ! curl -s -c "$HCK" "$HITRON/login.html" -o /dev/null \
        --connect-timeout 5 --max-time 10; then
    log "❌ 無法連線到 $HITRON"
    push_notify "HitronReboot_ConnFailed"
    cleanup
    exit 1
fi

# =====================================================
# 2. 登入
# =====================================================
log "🔐 登入 Hitron..."
RESP=$(curl -s -b "$HCK" -c "$HCK" -X POST "$HITRON/goform/login" \
    -d "usr=$HUSER&pwd=$HPASS&preSession=" --max-time 10)

if [ "$RESP" != "success" ]; then
    log "❌ Hitron 登入失敗: $RESP"
    push_notify "HitronReboot_LoginFailed | $RESP"
    cleanup
    exit 1
fi
log "  ✅ 登入成功"

# =====================================================
# 3. dry-run: 只登入再登出
# =====================================================
if [ "$DRY_RUN" = "1" ]; then
    log "🧪 dry-run: 僅測試登入,不送 reboot"
    curl -s -b "$HCK" -X POST "$HITRON/goform/logout" \
        -d "data=byebye" -o /dev/null --max-time 5
    cleanup
    exit 0
fi

# =====================================================
# 4. 送 reboot
#   Backbone.js model.save("reboot","1") → POST JSON {"reboot":"1"} 到 /goform/Reboot
#   reboot 成功後分享器會立刻斷,curl 通常回 000 (連線中斷)
# =====================================================
log "🔁 送 reboot 指令到 $REBOOT_URL ..."
HTTP_CODE=$(curl -s -b "$HCK" -o /tmp/.hitron_reboot_resp.$$ \
    -w "%{http_code}" \
    -X POST "$HITRON$REBOOT_URL" \
    -H "Content-Type: application/json" \
    --data-binary '{"reboot":"1"}' \
    --connect-timeout 5 --max-time 8 2>/dev/null)
RESP=$(head -c 300 /tmp/.hitron_reboot_resp.$$ 2>/dev/null | tr -d '\r\n')
rm -f /tmp/.hitron_reboot_resp.$$

log "  HTTP=$HTTP_CODE RESP=${RESP:-<empty>}"

# 成功判定:
#   000 = 連線中斷(分享器真的開始重開,正常結果)
#   HTTP 2xx 且 body 不含 "not defined" / "Access Error" / "Error" 等錯誤字串
_ok=0
if [ "$HTTP_CODE" = "000" ]; then
    _ok=1
elif echo "$HTTP_CODE" | grep -qE '^2[0-9][0-9]$'; then
    if echo "$RESP" | grep -qiE 'not defined|access error|document error'; then
        _ok=0
    else
        _ok=1
    fi
fi

if [ "$_ok" != "1" ]; then
    log "❌ reboot 失敗 (HTTP=$HTTP_CODE)"
    curl -s -b "$HCK" -X POST "$HITRON/goform/logout" \
        -d "data=byebye" -o /dev/null --max-time 5 2>/dev/null
    push_notify "HitronReboot_Failed | HTTP=$HTTP_CODE"
    cleanup
    exit 1
fi

log "  ✅ reboot 指令已下達"

# =====================================================
# 5. 通知 + 收尾
#   不需 logout,分享器已開始重開
# =====================================================
push_notify "HitronReboot_Sent | 上層分享器重開中"
cleanup
log "✅ 完成,上層分享器將在數十秒內恢復"
exit 0
