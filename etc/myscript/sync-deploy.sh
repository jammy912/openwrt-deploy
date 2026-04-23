#!/bin/sh

# sync-deploy.sh - 從 GitHub 同步最新的部署腳本到路由器
# 放置位置：/etc/myscript/sync-deploy.sh
# 用法：
#   sync-deploy.sh          # 正常同步（有變動才更新）
#   sync-deploy.sh --check  # 只比對，有差異推播通知，不覆蓋
#   sync-deploy.sh --force  # 強制覆蓋

# 防止自我更新時 ash 逐行讀取出錯：複製到 /tmp 重新執行
if [ "$_SYNC_DEPLOY_RELAUNCHED" != "1" ]; then
    export _SYNC_DEPLOY_RELAUNCHED=1
    cp "$0" /tmp/_sync-deploy-run.sh
    exec sh /tmp/_sync-deploy-run.sh "$@"
fi

# 引入鎖定處理器
. /etc/myscript/lock-handler.sh
LOCK_NAME="sync-deploy"
EXPIRY_SEC=120

# 引入通知器
. /etc/myscript/push-notify.inc
PUSH_NAMES="admin"

# 執行鎖定檢查
lock_check_and_create "$LOCK_NAME" "$EXPIRY_SEC"
if [ $? -ne 0 ]; then
    exit 0
fi
trap "lock_remove $LOCK_NAME; rm -f /tmp/cron_global.lock" TERM INT EXIT

# 全域 cron 排隊鎖
cron_global_lock 60 || { lock_remove "$LOCK_NAME"; exit 0; }

# =====================================================
# 配置
# =====================================================
REPO_URL="https://github.com/jammy912/openwrt-deploy/archive/main.tar.gz"
TMP_DIR="/tmp/sync-deploy"
EXTRACT_DIR="$TMP_DIR/openwrt-deploy-main"
HASH_FILE="/tmp/.sync-deploy_hash"
FORCE=0
CHECK_ONLY=0

case "$1" in
    --force) FORCE=1 ;;
    --check) CHECK_ONLY=1 ;;
esac

# 要同步的目錄對應 (來源 → 目的)
# .secrets 目錄排除，避免覆蓋本機密鑰
SYNC_TARGETS="
etc/myscript:/etc/myscript
etc/init.d:/etc/init.d
etc/hotplug.d:/etc/hotplug.d
"

# 要同步的單一檔案 (來源 → 目的)
SYNC_FILES="
etc/rc.local:/etc/rc.local
"

# =====================================================
# 日誌函數
# =====================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# =====================================================
# 清理函數
# =====================================================
cleanup() {
    rm -rf "$TMP_DIR"
}

# =====================================================
# 主程式
# =====================================================
main() {
    log "🚀 開始同步部署腳本..."

    # 清理舊的暫存
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"

    # -------------------------------------------------
    # 1. 下載 repo
    # -------------------------------------------------
    log "📥 下載最新版本..."
    wget -qO "$TMP_DIR/deploy.tar.gz" "$REPO_URL" 2>/dev/null
    if [ $? -ne 0 ]; then
        log "❌ 下載失敗"
        push_notify "SyncDeploy_DownloadFailed"
        cleanup
        exit 1
    fi

    # -------------------------------------------------
    # 2. Hash 比對（用 tar 檔算整體 hash）
    # -------------------------------------------------
    NEW_HASH=$(md5sum "$TMP_DIR/deploy.tar.gz" | awk '{print $1}')
    OLD_HASH=$(cat "$HASH_FILE" 2>/dev/null)

    if [ "$FORCE" = "0" ] && [ "$NEW_HASH" = "$OLD_HASH" ]; then
        log "⏭️ 腳本無變動 (hash: $NEW_HASH)，跳過更新"
        cleanup
        exit 0
    fi

    if [ "$FORCE" = "1" ]; then
        log "🔧 強制模式，略過 hash 比對"
    else
        log "🔄 偵測到變動 (old: ${OLD_HASH:-none} → new: $NEW_HASH)"
    fi

    # -------------------------------------------------
    # 3. 解壓
    # -------------------------------------------------
    tar xzf "$TMP_DIR/deploy.tar.gz" -C "$TMP_DIR" 2>/dev/null
    if [ $? -ne 0 ] || [ ! -d "$EXTRACT_DIR" ]; then
        log "❌ 解壓失敗"
        push_notify "SyncDeploy_ExtractFailed"
        cleanup
        exit 1
    fi
    rm -f "$TMP_DIR/deploy.tar.gz"

    # -------------------------------------------------
    # 4. 比對檔案差異
    # -------------------------------------------------
    DIFF_LIST=""
    DIFF_COUNT=0

    echo "$SYNC_TARGETS" | while IFS=: read -r SRC DEST; do
        [ -z "$SRC" ] && continue

        SRC_DIR="$EXTRACT_DIR/$SRC"
        [ ! -d "$SRC_DIR" ] && continue

        find "$SRC_DIR" -type f ! -path "*/.secrets/*" ! -name "dbroute.nft" | while read -r SRC_FILE; do
            REL_PATH="${SRC_FILE#$SRC_DIR/}"
            DEST_FILE="$DEST/$REL_PATH"

            if [ ! -f "$DEST_FILE" ]; then
                echo "NEW:$REL_PATH"
            else
                SRC_MD5=$(md5sum "$SRC_FILE" | awk '{print $1}')
                DEST_MD5=$(md5sum "$DEST_FILE" | awk '{print $1}')
                [ "$SRC_MD5" != "$DEST_MD5" ] && echo "MOD:$REL_PATH"
            fi
        done
    done > "$TMP_DIR/diff_list.txt"

    # 比對單一檔案
    echo "$SYNC_FILES" | while IFS=: read -r SRC DEST; do
        [ -z "$SRC" ] && continue
        SRC_FILE="$EXTRACT_DIR/$SRC"
        [ ! -f "$SRC_FILE" ] && continue
        if [ ! -f "$DEST" ]; then
            echo "NEW:$SRC"
        else
            SRC_MD5=$(md5sum "$SRC_FILE" | awk '{print $1}')
            DEST_MD5=$(md5sum "$DEST" | awk '{print $1}')
            [ "$SRC_MD5" != "$DEST_MD5" ] && echo "MOD:$SRC"
        fi
    done >> "$TMP_DIR/diff_list.txt"

    DIFF_COUNT=$(wc -l < "$TMP_DIR/diff_list.txt" | tr -d ' ')

    if [ "$DIFF_COUNT" = "0" ]; then
        log "⏭️ 所有檔案一致，無需更新"
        echo "$NEW_HASH" > "$HASH_FILE"
        cleanup
        exit 0
    fi

    # 列出差異
    DIFF_SUMMARY=$(cat "$TMP_DIR/diff_list.txt")
    log "📋 發現 $DIFF_COUNT 個差異:"
    echo "$DIFF_SUMMARY" | while read -r line; do
        log "  $line"
    done

    # 取出檔名（去掉 NEW:/MOD: 前綴），用逗號串接
    DIFF_FILES=$(sed 's/^[^:]*://' "$TMP_DIR/diff_list.txt" | tr '\n' ',' | sed 's/,$//')

    # --check 模式：只推播通知，不覆蓋
    if [ "$CHECK_ONLY" = "1" ]; then
        push_notify "SyncDeploy_Changed | ${DIFF_COUNT}個差異: ${DIFF_FILES}"
        log "🔔 已推播通知（--check 模式，不覆蓋）"
        cleanup
        exit 0
    fi

    # -------------------------------------------------
    # 5. 執行同步
    # -------------------------------------------------
    echo "$SYNC_TARGETS" | while IFS=: read -r SRC DEST; do
        [ -z "$SRC" ] && continue

        SRC_DIR="$EXTRACT_DIR/$SRC"
        [ ! -d "$SRC_DIR" ] && continue

        log "📂 同步 $SRC → $DEST"
        mkdir -p "$DEST"

        find "$SRC_DIR" -type f ! -path "*/.secrets/*" ! -name "dbroute.nft" | while read -r SRC_FILE; do
            REL_PATH="${SRC_FILE#$SRC_DIR/}"
            DEST_FILE="$DEST/$REL_PATH"

            SRC_MD5=$(md5sum "$SRC_FILE" | awk '{print $1}')
            DEST_MD5=$(md5sum "$DEST_FILE" 2>/dev/null | awk '{print $1}')

            if [ "$SRC_MD5" != "$DEST_MD5" ]; then
                mkdir -p "$(dirname "$DEST_FILE")"
                cp "$SRC_FILE" "$DEST_FILE"
                chmod +x "$DEST_FILE" 2>/dev/null
                log "  ✅ 更新: $REL_PATH"
            fi
        done
    done

    # 同步單一檔案
    echo "$SYNC_FILES" | while IFS=: read -r SRC DEST; do
        [ -z "$SRC" ] && continue
        SRC_FILE="$EXTRACT_DIR/$SRC"
        [ ! -f "$SRC_FILE" ] && continue
        SRC_MD5=$(md5sum "$SRC_FILE" | awk '{print $1}')
        DEST_MD5=$(md5sum "$DEST" 2>/dev/null | awk '{print $1}')
        if [ "$SRC_MD5" != "$DEST_MD5" ]; then
            cp "$SRC_FILE" "$DEST"
            log "  ✅ 更新: $SRC"
        fi
    done

    # -------------------------------------------------
    # 6. 保存 hash
    # -------------------------------------------------
    echo "$NEW_HASH" > "$HASH_FILE"

    log "📊 同步完成"
    push_notify "SyncDeploy_Done !! ${DIFF_COUNT}個已更新: ${DIFF_FILES}"

    # -------------------------------------------------
    # 6. 清理
    # -------------------------------------------------
    cleanup

    log "✅ 完成"
    exit 0
}

main "$@"
