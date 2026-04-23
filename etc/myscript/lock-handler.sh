#!/bin/sh

# 確保 Crontab 環境下能找到常用的指令
PATH=/usr/sbin:/sbin:/usr/bin:/bin
export PATH

# 函數: 檢查、創建或更新鎖定檔案
# 用法: lock_check_and_create <鎖定名稱> <過期時間_秒>
lock_check_and_create() {
    LOCK_NAME=$1
    EXPIRY_TIME=$2
    LOCKFILE="/tmp/$LOCK_NAME.lock"

    if [ -z "$LOCK_NAME" ] || [ -z "$EXPIRY_TIME" ]; then
        echo "錯誤: 必須傳入鎖定名稱和過期時間 (秒)。" >&2
        return 1
    fi

    # 檢查鎖定檔案是否存在
    if [ -f "$LOCKFILE" ]; then
        
        # 核心：直接從檔案讀取鎖定時間 (不再依賴 stat/gstat)
        LOCK_TIME=$(cat "$LOCKFILE" 2>/dev/null)
        
        # 驗證讀取到的時間是否為有效數字
        if ! echo "$LOCK_TIME" | grep -q '^[0-9]\+$'; then
            echo "警告: 鎖定檔案內容無效，移除舊鎖並繼續。" >&2
            rm -f "$LOCKFILE"
            # 繼續執行到 touch "$LOCKFILE" 創建新鎖
        else
            CURRENT_TIME=$(date +%s)
            TIME_DIFF=$((CURRENT_TIME - LOCK_TIME))
            
            # 判斷是否在有效期內
            if [ "$TIME_DIFF" -lt "$EXPIRY_TIME" ]; then
                echo "$LOCK_NAME 已在運行，鎖定仍有效 (剩餘 $((EXPIRY_TIME - TIME_DIFF)) 秒)。" >&2
                return 1 # 鎖定生效，不能運行
            else
                # 鎖定過期，移除舊鎖
                echo "舊鎖定檔案 ($LOCK_NAME) 已過期，移除舊鎖並繼續。"
                rm -f "$LOCKFILE"
            fi
        fi
    fi

 # 創建新的鎖定檔案，並將當前時間寫入檔案
    /bin/date +%s > "$LOCKFILE"
    
    # 設置檔案權限為只讀
    /bin/chmod 444 "$LOCKFILE"
    
    echo "鎖定成功。"
    return 0
}

# 函數: 檢查鎖定是否有效 (只看不搶)
# 用法: lock_is_active <鎖定名稱> <過期時間_秒>
# 返回: 0=鎖定有效, 1=無鎖定或已過期
lock_is_active() {
    _LK_NAME=$1
    _LK_EXPIRY=$2
    _LK_FILE="/tmp/$_LK_NAME.lock"

    [ ! -f "$_LK_FILE" ] && return 1

    _LK_TIME=$(cat "$_LK_FILE" 2>/dev/null)
    echo "$_LK_TIME" | grep -q '^[0-9]\+$' || return 1

    _LK_DIFF=$(( $(date +%s) - _LK_TIME ))
    [ "$_LK_DIFF" -lt "$_LK_EXPIRY" ] && return 0
    return 1
}

# 函數: 全域 cron 排隊鎖 (一次只跑一個 cron 腳本)
# 用法: cron_global_lock [超時秒數] (預設 60)
# 取得鎖後自動在 EXIT 時釋放
# 返回: 0=取得鎖, 1=超時放棄
_CRON_GLOBAL_LOCKFILE="/tmp/cron_global.lock"
cron_global_lock() {
    # 全域鎖暫時停用 (效能無虞，不需要序列化)
    # 要重新啟用: 把 CRON_GLOBAL_LOCK_ENABLED 設為 1
 #   rm -f "$_CRON_GLOBAL_LOCKFILE" 2>/dev/null
 #   return 0

    _CGL_TIMEOUT=${1:-60}
    _CGL_WAITED=0
    while [ -f "$_CRON_GLOBAL_LOCKFILE" ]; do
        _CGL_PID=$(cat "$_CRON_GLOBAL_LOCKFILE" 2>/dev/null)
        # 持有者已死，清掉 stale lock
        if [ -n "$_CGL_PID" ] && ! kill -0 "$_CGL_PID" 2>/dev/null; then
            rm -f "$_CRON_GLOBAL_LOCKFILE"
            break
        fi
        if [ "$_CGL_WAITED" -ge "$_CGL_TIMEOUT" ]; then
            logger -t cron-lock "$(basename "$0"): 等待全域鎖超時 (${_CGL_TIMEOUT}s)，放棄"
            return 1
        fi
        sleep 1
        _CGL_WAITED=$((_CGL_WAITED + 1))
    done
    echo $$ > "$_CRON_GLOBAL_LOCKFILE"
    # 注意: 呼叫端需自行在 trap EXIT 中加入 rm -f /tmp/cron_global.lock
    return 0
}

# 函數: 移除鎖定檔案 (不變)
lock_remove() {
    LOCK_NAME=$1
    LOCKFILE="/tmp/$LOCK_NAME.lock"
    
    if [ -f "$LOCKFILE" ]; then
        rm -f "$LOCKFILE"
        echo "$LOCK_NAME 鎖定已移除。"
        return 0
    else
        echo "$LOCK_NAME 鎖定檔案不存在。" >&2
        return 1
    fi
}