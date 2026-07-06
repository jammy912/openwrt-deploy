#!/bin/sh
# linecmd-handler.sh - LineCMD 白名單動作執行器
# 用法: linecmd-handler.sh <action> [arg]
#
# 由 sync-googleconfig.sh 解析 Sheet 的 `config linecmd` 段後呼叫。
# 安全模型: Sheet 只填「動作代號」,真正的指令由下方 case 白名單決定。
#   Sheet 就算被塞入任意字串,對應不到 case 就被忽略 → 無 RCE。
#   ⚠️ 嚴禁在此 eval/sh -c 任何來自 Sheet 的字串。arg 一律用 "$arg" 引用,不展開。
# 增修動作 = 改下方 case,透過 sync-deploy.sh 下發全機隊。
#
# 回傳: 0=成功執行(或已排程) 1=未知動作/失敗
# 呼叫端(sync-googleconfig)負責推播回報,本檔只 logger + 回傳碼。

PATH=/usr/sbin:/sbin:/usr/bin:/bin
export PATH

ACTION="$1"
ARG="$2"
TAG="linecmd"

[ -z "$ACTION" ] && { logger -t "$TAG" "空 action,忽略"; exit 1; }

logger -t "$TAG" "收到動作: action='$ACTION' arg='$ARG'"

case "$ACTION" in
    reboot)
        # 延遲 5s 讓 sync 收尾(推播、釋放鎖)後再重開
        logger -t "$TAG" "5s 後 reboot"
        ( sleep 5 && reboot ) &
        ;;

    sync-force)
        # 強制重套全部段(收斂本地多餘設定)。背景跑避免自我遞迴阻塞。
        logger -t "$TAG" "觸發 sync --apply --force"
        ( sleep 3 && /etc/myscript/sync-googleconfig.sh --apply --force ) &
        ;;

    wg-restart)
        # arg=介面名(wg0/wg2...);防呆:必須是 wg 開頭且介面存在
        case "$ARG" in
            wg[0-9]*) ;;
            *) logger -t "$TAG" "wg-restart 參數非法: '$ARG'"; exit 1 ;;
        esac
        if ! ip link show "$ARG" >/dev/null 2>&1; then
            logger -t "$TAG" "wg-restart: 介面 $ARG 不存在"; exit 1
        fi
        logger -t "$TAG" "重啟 $ARG"
        ifdown "$ARG"; sleep 2; ifup "$ARG"
        ;;

    dbr-refresh)
        logger -t "$TAG" "刷新 DBR nft set"
        /etc/myscript/dbroute-refresh.sh
        ;;

    dbr-setup)
        logger -t "$TAG" "重建 DBR ip rule/route"
        /etc/myscript/dbroute-setup.sh
        ;;

    pbr-reload)
        logger -t "$TAG" "重套 CustRule PBR"
        /etc/init.d/pbr-cust start
        ;;

    fw-reload)
        logger -t "$TAG" "firewall reload"
        /etc/init.d/firewall reload
        ;;

    dnsmasq-restart)
        logger -t "$TAG" "dnsmasq restart"
        /etc/init.d/dnsmasq restart
        ;;

    *)
        logger -t "$TAG" "未知動作(不在白名單): '$ACTION' → 忽略"
        exit 1
        ;;
esac

exit 0
