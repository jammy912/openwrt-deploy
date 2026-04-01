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