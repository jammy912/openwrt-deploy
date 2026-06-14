#!/bin/sh
# blockdev.sh - 依 DHCP static host 名字封鎖/解封裝置上網
# 用法:
#   blockdev.sh <name> add|del|status
# 範例:
#   blockdev.sh my-phone add      # 封鎖 my-phone
#   blockdev.sh my-phone del      # 解封 my-phone
#   blockdev.sh my-phone status   # 查目前是否封鎖
#   blockdev.sh "" status         # 列出 set 內所有被封鎖的 IP
#
# 原理:
#   從 /etc/config/dhcp static host 依 name 查出固定 IP,
#   把該 IP 加入 inet fw4 的 named set `blocked`,
#   並由 forward chain 的規則 drop 掉。cron 可定時 add/del 控制時段。
#
# 設計重點 (冪等, 重複 add/del 不會壞):
#   1. set 與 drop rule 不存在時自動建立 (nft add set/chain 對已存在者不報錯)。
#   2. add 前先 delete 同 IP,避免 element 已存在報 "File exists"。
#   3. del 時吞掉 "No such file" 之類錯誤,重複 del 安全。
#   4. firewall restart 會清掉整個 fw4 table,故每次執行都重新確保 set+rule 存在。

. /lib/functions.sh

TARGET="$1"
ACTION="$2"
LOG_TAG="blockdev"

TABLE="inet fw4"
SET_NAME="blocked"

usage() {
    echo "用法: $0 <name> add|del|status"
    echo "      $0 \"\" status   # 列出所有被封鎖 IP"
    exit 1
}

[ -z "$ACTION" ] && usage

# 依 name 從 uci dhcp 查固定 IP (status 且 name 為空時可略過)
IP=""
find_ip() {
    local _name _ip
    config_get _name "$1" name
    config_get _ip  "$1" ip
    [ "$_name" = "$TARGET" ] && [ -n "$_ip" ] && IP="$_ip"
}
if [ -n "$TARGET" ]; then
    config_load dhcp
    config_foreach find_ip host
fi

# 確保 set 與 drop rule 存在 (冪等; 已存在不報錯)
ensure_infra() {
    # named set: ipv4 位址集合
    nft add set $TABLE $SET_NAME '{ type ipv4_addr; flags interval; auto-merge; }' 2>/dev/null

    # drop rule 掛在 forward chain (fw4 內建)。先檢查是否已存在,避免重複堆疊。
    if ! nft list chain $TABLE forward 2>/dev/null | grep -q "@$SET_NAME"; then
        # 來源或目的命中 blocked 即 drop (雙向阻斷)
        nft insert rule $TABLE forward ip saddr @$SET_NAME counter drop 2>/dev/null
        nft insert rule $TABLE forward ip daddr @$SET_NAME counter drop 2>/dev/null
    fi
}

case "$ACTION" in
    add)
        [ -z "$IP" ] && { echo "找不到 DHCP static host: '$TARGET'"; exit 1; }
        ensure_infra
        # 先 delete 再 add → 冪等,重複 add 不會因 element 已存在而失敗
        nft delete element $TABLE $SET_NAME "{ $IP }" 2>/dev/null
        if nft add element $TABLE $SET_NAME "{ $IP }" 2>/dev/null; then
            logger -t $LOG_TAG "BLOCK $TARGET ($IP)"
            echo "已封鎖 $TARGET ($IP)"
        else
            echo "封鎖失敗 $TARGET ($IP)"
            exit 1
        fi
        ;;
    del)
        [ -z "$IP" ] && { echo "找不到 DHCP static host: '$TARGET'"; exit 1; }
        ensure_infra
        # 吞掉 element 不存在的錯誤 → 重複 del 安全
        nft delete element $TABLE $SET_NAME "{ $IP }" 2>/dev/null
        logger -t $LOG_TAG "UNBLOCK $TARGET ($IP)"
        echo "已解封 $TARGET ($IP)"
        ;;
    status)
        ensure_infra
        if [ -n "$TARGET" ]; then
            [ -z "$IP" ] && { echo "找不到 DHCP static host: '$TARGET'"; exit 1; }
            if nft get element $TABLE $SET_NAME "{ $IP }" >/dev/null 2>&1; then
                echo "$TARGET ($IP): 封鎖中"
            else
                echo "$TARGET ($IP): 未封鎖"
            fi
        else
            echo "目前 $SET_NAME set 內的 IP:"
            nft list set $TABLE $SET_NAME 2>/dev/null | grep -oE '([0-9]+\.){3}[0-9]+' | sed 's/^/  /'
        fi
        ;;
    *)
        usage
        ;;
esac
