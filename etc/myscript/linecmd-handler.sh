#!/bin/sh
# linecmd-handler.sh - LineCMD 白名單動作執行器
# 用法: linecmd-handler.sh <action> [arg1] [arg2] ...
#
# 由 sync-googleconfig.sh 解析 Sheet 的 `config linecmd` 段後呼叫。
# 安全模型: Sheet 只填「動作代號」,真正的指令由下方 case 白名單決定。
#   Sheet 就算被塞入任意字串,對應不到 case 就被忽略 → 無 RCE。
#   ⚠️ 嚴禁在此 eval/sh -c 任何來自 Sheet 的字串。arg 一律用 "$1"/"$@" 引用,不展開。
# 多參數: Sheet 用多個 list arg,依序成為 $2 $3 ...(這裡 shift 後的 $1 $2 ...)。
# 增修動作 = 改下方 case,透過 sync-deploy.sh 下發全機隊。
#
# 回傳: 0=成功執行(或已排程) 1=未知動作/失敗
# 呼叫端(sync-googleconfig)負責推播回報,本檔只 logger + 回傳碼。

PATH=/usr/sbin:/sbin:/usr/bin:/bin
export PATH

TAG="linecmd"
ACTION="$1"
[ -z "$ACTION" ] && { logger -t "$TAG" "空 action,忽略"; exit 1; }
shift   # 之後 "$@" = 動作參數(args), "$1" = 第一個 arg

logger -t "$TAG" "收到動作: action='$ACTION' args='$*'"

case "$ACTION" in
    reboot)
        # ⚠️ 防重開循環(2026-09-24): Sheet 端用「時間窗」過濾而非 D 欄狀態
        #    (D 欄是全域單一標記, 兩台 sync 差幾秒就會互相擋掉), 而 cmdid
        #    去重記錄放 /tmp —— 重開就清空, 正好是 reboot 最需要記住的時候。
        #    時序: 14:00:00 下指令 → 14:00:30 抓到並重開 → 14:01:20 開機完成
        #          → 14:01:30 sync 再跑, age=1.5 分鐘仍在 2 分鐘窗內 → 又重開。
        #    改用 uptime 判斷: 剛開機不到 5 分鐘就收到 reboot, 幾乎必然是
        #    上一輪那筆還在窗內被重複抓到, 直接略過。
        # ★ 代價: 開機後 5 分鐘內無法用 LINE 下 reboot, 需 SSH 手動執行。
        #    (剛重開完又要重開通常代表更嚴重的問題, 本來就該手動介入)
        _up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
        case "$_up" in
            ''|*[!0-9]*) _up=999999 ;;   # 讀不到就當正常運行, 不要擋掉真的 reboot
        esac
        if [ "$_up" -lt 300 ]; then
            logger -t "$TAG" "[略過] reboot: 開機才 ${_up}s, 判定為重開後重複抓到"
            exit 0
        fi
        # 延遲 5s 讓 sync 收尾(推播、釋放鎖)後再重開
        logger -t "$TAG" "5s 後 reboot (uptime=${_up}s)"
        ( sleep 5 && reboot ) &
        ;;

    sync-force)
        # 強制重套全部段(收斂本地多餘設定)。背景跑避免自我遞迴阻塞。
        logger -t "$TAG" "觸發 sync --apply --force"
        ( sleep 3 && /etc/myscript/sync-googleconfig.sh --apply --force ) &
        ;;

    wg-restart)
        # $1=介面名(wg0/wg2...);防呆:必須是 wg 開頭且介面存在
        _if="$1"
        case "$_if" in
            wg[0-9]*) ;;
            *) logger -t "$TAG" "wg-restart 參數非法: '$_if'"; exit 1 ;;
        esac
        if ! ip link show "$_if" >/dev/null 2>&1; then
            logger -t "$TAG" "wg-restart: 介面 $_if 不存在"; exit 1
        fi
        logger -t "$TAG" "重啟 $_if"
        ifdown "$_if"; sleep 2; ifup "$_if"
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

    blockdev)
        # 依 DHCP static host 名字封鎖/解封上網。
        #   $1 = 裝置名清單(逗號或空白分隔, blockdev.sh 自己會正規化)
        #   $2 = add | del | status
        # 例: action=blockdev arg1="TV_Apple,TV_Android,LGTV" arg2="add"
        #
        # ⚠️ blockdev.sh 的參數順序是「名字在前、動作在最後」($ACTION=${$#}),
        #    這裡照它的介面傳 "$_names" "$_act", 不要顛倒。
        _names="$1"
        _act="$2"
        # 動作白名單: 雖然 blockdev.sh 自己也有 case 擋(非法動作印 usage 後 exit 1),
        # 但這裡再擋一層, 免得 Sheet 打錯字時只留下一則難懂的 usage。
        case "$_act" in
            add|del|status) ;;
            *) logger -t "$TAG" "blockdev 動作非法: '$_act' (只允許 add/del/status)"; exit 1 ;;
        esac
        # 名字不做格式檢查: blockdev.sh 會去 /etc/config/dhcp 查 static host,
        # 查無的名字只警告略過, 不會被當成指令執行(全部查無才 exit 1)。
        # ★ 但空字串要擋: blockdev.sh "" status 是「列出所有被封鎖 IP」的合法用法,
        #   對 add/del 卻會變成「找不到任何 host」而 exit 1, 徒增誤會。
        if [ -z "$_names" ] && [ "$_act" != "status" ]; then
            logger -t "$TAG" "blockdev $_act 未指定裝置名, 忽略"; exit 1
        fi
        logger -t "$TAG" "blockdev $_act: $_names"
        /etc/myscript/blockdev.sh "$_names" "$_act"
        ;;

    # --- 圖文選單專用: 六條完整指令字串當代號 (2026-09-23) ---
    # ★ 為什麼長得像指令卻不是 RCE:
    #   這裡是「精確字串比對」, 字串只當查表的 key 用。比對命中後執行的是
    #   下面寫死的那一行, 跟 Sheet 傳來的內容無關。Sheet 改一個字元(空格、
    #   引號、分鐘數)就對不上任何一條 → 掉進 *) 被忽略。
    #   ⚠️ 嚴禁改成 eval "$ACTION" 或 sh -c "$ACTION" — 那才是 RCE,
    #      等於任何能寫入 Sheet 的人都能在全機隊以 root 執行任意指令。
    # ⚠️ 比對字串內的引號與空白必須與 Sheet 完全一致, 包括 .sh 副檔名。
    #   Sheet 若寫成 /etc/myscript/blockdev(少 .sh)就不會命中。
    '/etc/myscript/blockdev.sh "*TV*" allow 30')
        logger -t "$TAG" "電視 放行 30 分鐘"
        /etc/myscript/blockdev.sh "*TV*" allow 30
        ;;
    '/etc/myscript/blockdev.sh "*TV*" allow 60')
        logger -t "$TAG" "電視 放行 60 分鐘"
        /etc/myscript/blockdev.sh "*TV*" allow 60
        ;;
    '/etc/myscript/blockdev.sh "*TV*" allow 90')
        logger -t "$TAG" "電視 放行 90 分鐘"
        /etc/myscript/blockdev.sh "*TV*" allow 90
        ;;
    '/etc/myscript/blockdev.sh "*TV*" block 30')
        logger -t "$TAG" "電視 封鎖 30 分鐘"
        /etc/myscript/blockdev.sh "*TV*" block 30
        ;;
    '/etc/myscript/blockdev.sh "*TV*" block 60')
        logger -t "$TAG" "電視 封鎖 60 分鐘"
        /etc/myscript/blockdev.sh "*TV*" block 60
        ;;
    '/etc/myscript/blockdev.sh "*TV*" block 90')
        logger -t "$TAG" "電視 封鎖 90 分鐘"
        /etc/myscript/blockdev.sh "*TV*" block 90
        ;;

    *)
        logger -t "$TAG" "未知動作(不在白名單): '$ACTION' → 忽略"
        exit 1
        ;;
esac

exit 0
