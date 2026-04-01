#!/bin/sh
# OpenWrt 一鍵部署腳本
# 用法: sh -c "$(curl -fsSL https://raw.githubusercontent.com/jammy912/openwrt-deploy/main/install.sh)"

REPO="https://github.com/jammy912/openwrt-deploy/archive/main.tar.gz"
DEPLOY_DIR="/tmp/openwrt-deploy-main"

echo "========================================"
echo " OpenWrt 一鍵部署"
echo "========================================"

# 檢查系統時間，太舊的話 HTTPS 會失敗
# 用 wget 嘗試連 GitHub，如果失敗且時間看起來不對就提示
YEAR=$(date +%Y)
TIME_OK=1
if [ "$YEAR" -lt 2025 ] || [ "$YEAR" -gt 2030 ]; then
    TIME_OK=0
fi
# 額外測試: 嘗試 HTTPS 連線看是否 SSL 錯誤
if [ "$TIME_OK" = "1" ]; then
    wget -q --spider "https://github.com" 2>/dev/null
    if [ $? -ne 0 ]; then
        # wget 失敗，可能是時間問題導致 SSL 憑證驗證失敗
        TIME_OK=0
    fi
fi
if [ "$TIME_OK" = "0" ]; then
    echo ""
    echo "⚠️  系統時間可能不正確 (目前: $(date))"
    echo "   HTTPS 下載需要正確時間，否則 SSL 憑證驗證會失敗"
    echo ""
    echo "  方法1: 手動輸入目前時間 (格式: YYYY-MM-DD HH:MM:SS)"
    echo "  方法2: 直接按 Enter 跳過 SSL 驗證 (不建議，但可用)"
    echo ""
    printf "  輸入時間 (或 Enter 跳過): "
    read -r INPUT_TIME
    if [ -n "$INPUT_TIME" ]; then
        date -s "$INPUT_TIME" >/dev/null 2>&1
        echo "  ✅ 時間已設為: $(date)"
    else
        SSL_NO_CHECK=1
        echo "  ⚠️  將跳過 SSL 驗證"
    fi
fi

cd /tmp
echo ""
echo "📥 下載部署包..."
if [ "$SSL_NO_CHECK" = "1" ]; then
    wget --no-check-certificate -qO deploy.tar.gz "$REPO" || curl -kfsSL "$REPO" -o deploy.tar.gz
else
    wget -qO deploy.tar.gz "$REPO" || curl -fsSL "$REPO" -o deploy.tar.gz
fi
tar xzf deploy.tar.gz
rm -f deploy.tar.gz

if [ ! -f "$DEPLOY_DIR/deploy.sh" ]; then
    echo "❌ 下載失敗"
    echo "   可能原因: 系統時間不正確 (目前: $(date))，導致 SSL 憑證驗證失敗"
    echo "   請先用 date -s 'YYYY-MM-DD HH:MM:SS' 設定正確時間後重試"
    exit 1
fi

# 把檔案搬到 deploy.sh 預期的位置
mkdir -p /tmp/deploy
cp -a "$DEPLOY_DIR/"* /tmp/deploy/
rm -rf "$DEPLOY_DIR"

echo "🚀 開始部署..."
sh /tmp/deploy/deploy.sh "$@"

rm -rf /tmp/deploy
