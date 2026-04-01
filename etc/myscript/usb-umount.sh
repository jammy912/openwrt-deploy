
#!/bin/sh
# USB 全部卸載腳本（含重試與 push_notify）

# 1️⃣ 載入推播功能
. /etc/myscript/push_notify.inc
PUSH_NAMES="admin" # 多人用分號分隔，例如 "admin;ann"

# 2️⃣ 設定 USB 掛載目錄
USB_BASE="/srv/share/USB"
result=""

# 3️⃣ 遍歷每個子目錄
for d in "$USB_BASE"/*; do
    [ -d "$d" ] || continue
    sync
    success=0

    # 4️⃣ 嘗試卸載最多 5 次
    for i in 1 2 3 4 5; do
        if umount "$d" 2>/dev/null; then
            success=1
            break
        else
            sleep 5
        fi
    done

    # 5️⃣ 如果仍失敗，嘗試 lazy unmount
    if [ $success -eq 0 ]; then
        if umount -l "$d" 2>/dev/null; then
            result="${result}⚠️ Lazy unmount: $(basename "$d") "
            continue
        else
            result="${result}❌ Failed after 5 tries: $(basename "$d") "
            continue
        fi
    fi

    # 6️⃣ 成功
    result="${result}✓ Unmounted: $(basename "$d") "
done

# 7️⃣ 推播結果
push_notify "USB Unmount Result:\n${result}"

