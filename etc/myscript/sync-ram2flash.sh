
#!/bin/sh

# 腳本說明:
# 此腳本用於將 /tmp/config_ram 的設定檔同步回快閃記憶體的 /overlay。


# 引入通知器
. /etc/myscript/push_notify.inc
PUSH_NAMES="admin" # 多人用分號分隔，例如 "admin;ann"

push_notify "SyncRam2Flash"

# 檢查是否以 root 身份執行
if [ "$(id -u)" != "0" ]; then
   echo "此腳本需要以 root 權限執行。" 1>&2
   exit 1
fi

# 確保來源目錄存在
if [ ! -d "/tmp/config_ram" ]; then
    echo "錯誤：來源目錄 /tmp/config_ram 不存在。"
    exit 1
fi

# 確保目的目錄存在
#if [ ! -d "/overlay/upper/etc/config" ]; then
#    echo "錯誤：目的目錄 /overlay/upper/etc/config 不存在。"
#    exit 1
#fi

# 執行同步
echo "開始同步設定檔到快閃記憶體..."

# 使用 rsync 確保同步的效率與完整性
# 目標目錄
TARGET1="/overlay/upper/etc/config/"
TARGET2="/rom/overlay/upper/etc/config/"

# 檢查並同步
if [ -d "$TARGET1" ]; then
    rsync -av --delete --exclude '.*' /tmp/config_ram/ "$TARGET1"
else
    echo "目標目錄 $TARGET1 不存在，跳過同步"
fi

if [ -d "$TARGET2" ]; then
    rsync -av --delete --exclude '.*' /tmp/config_ram/ "$TARGET2"
else
    echo "目標目錄 $TARGET2 不存在，跳過同步"
fi

# 同步 crontabs
CRON_TARGET1="/overlay/upper/etc/crontabs/"
CRON_TARGET2="/rom/overlay/upper/etc/crontabs/"

if [ -d "/tmp/crontabs_ram" ]; then
    if [ -d "$CRON_TARGET1" ]; then
        rsync -av --delete /tmp/crontabs_ram/ "$CRON_TARGET1"
    else
        echo "目標目錄 $CRON_TARGET1 不存在，跳過 crontab 同步"
    fi

    if [ -d "$CRON_TARGET2" ]; then
        rsync -av --delete /tmp/crontabs_ram/ "$CRON_TARGET2"
    else
        echo "目標目錄 $CRON_TARGET2 不存在，跳過 crontab 同步"
    fi
else
    echo "來源目錄 /tmp/crontabs_ram 不存在，跳過 crontab 同步"
fi

if [ $? -eq 0 ]; then
    echo "設定檔同步完成。變更已寫入快閃記憶體。"
    # 觸發上傳加密設定（僅 gateway，client 不上傳）
    DEVICE_ROLE=$(cat /etc/myscript/.mesh_role 2>/dev/null)
    if [ "$DEVICE_ROLE" != "client" ] && [ -x /etc/myscript/sync-uploadconfig.sh ]; then
        /etc/myscript/sync-uploadconfig.sh &
    fi
else
    echo "同步失敗，請檢查 rsync 錯誤。"
    exit 1
fi

echo "請記得重啟相關服務以使新設定生效，例如：uci commit; wifi"

exit 0
