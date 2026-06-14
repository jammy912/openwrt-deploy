#!/bin/sh
# blockdev.sh - 依 DHCP static host 名字封鎖/解封裝置上網
# 用法:
#   blockdev.sh <name>[,<name>...] add|del|status
# 範例:
#   blockdev.sh TV_Apple add                    # 封鎖單一裝置
#   blockdev.sh TV_Apple,TV_Android add         # 一次封鎖多台 (逗號分隔)
#   blockdev.sh "TV_Apple TV_Android" add       # 多台也可用空白分隔 (需引號)
#   blockdev.sh TV_Apple,TV_Android del         # 一次解封多台
#   blockdev.sh TV_Apple status                 # 查狀態
#   blockdev.sh "" status                       # 列出 set 內所有被封鎖的 IP
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
#   5. 多裝置: 任一台查無 IP 會警告但不中斷其他台; 全部查無才回 exit 1。

. /lib/functions.sh

LOG_TAG="blockdev"
TABLE="inet fw4"
SET_NAME="blocked"

# 最後一個參數為動作, 其餘 (可多個, 空白分隔) 為裝置名稱
ACTION=$(eval echo "\${$#}")
TARGETS=""
i=1
while [ $i -lt $# ]; do
    TARGETS="$TARGETS $(eval echo "\${$i}")"
    i=$((i + 1))
done
# 正規化: 逗號→空白 (支援 TV_Apple,TV_Android), 去除多餘/前後空白;
# 全空 (如 blockdev.sh "" status) → 真空字串
TARGETS=$(echo "$TARGETS" | tr ',' ' ')
TARGETS=$(echo $TARGETS)

usage() {
    echo "用法: $0 <name>[,<name>...] add|del|status"
    echo "      $0 TV_Apple,TV_Android add   # 一次多台 (逗號分隔)"
    echo "      $0 \"\" status                # 列出所有被封鎖 IP"
    exit 1
}

[ -z "$ACTION" ] && usage

# 依名字清單從 uci dhcp 查固定 IP, 結果存 RESULTS ("name ip" 每行一筆)
# 查無 IP 的名字存 MISSING
RESULTS=""
MISSING=""
collect_ips() {
    local want="$1"     # 要找的名字 (可多個, 空白分隔)
    [ -z "$want" ] && return
    local found name ip n
    for n in $want; do
        found=""
        find_one() {
            local _name _ip
            config_get _name "$1" name
            config_get _ip  "$1" ip
            [ "$_name" = "$n" ] && [ -n "$_ip" ] && found="$_ip"
        }
        config_load dhcp
        config_foreach find_one host
        if [ -n "$found" ]; then
            RESULTS="$RESULTS
$n $found"
        else
            MISSING="$MISSING $n"
        fi
    done
}

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
        ensure_infra
        collect_ips "$TARGETS"
        [ -z "$RESULTS" ] && { echo "找不到任何 DHCP static host:$TARGETS"; exit 1; }
        echo "$RESULTS" | while read -r name ip; do
            [ -z "$ip" ] && continue
            # 先 delete 再 add → 冪等,重複 add 不會因 element 已存在而失敗
            nft delete element $TABLE $SET_NAME "{ $ip }" 2>/dev/null
            if nft add element $TABLE $SET_NAME "{ $ip }" 2>/dev/null; then
                logger -t $LOG_TAG "BLOCK $name ($ip)"
                echo "已封鎖 $name ($ip)"
            else
                echo "封鎖失敗 $name ($ip)"
            fi
        done
        [ -n "$MISSING" ] && echo "警告: 查無 IP, 略過:$MISSING"
        ;;
    del)
        ensure_infra
        collect_ips "$TARGETS"
        [ -z "$RESULTS" ] && { echo "找不到任何 DHCP static host:$TARGETS"; exit 1; }
        echo "$RESULTS" | while read -r name ip; do
            [ -z "$ip" ] && continue
            # 吞掉 element 不存在的錯誤 → 重複 del 安全
            nft delete element $TABLE $SET_NAME "{ $ip }" 2>/dev/null
            logger -t $LOG_TAG "UNBLOCK $name ($ip)"
            echo "已解封 $name ($ip)"
        done
        [ -n "$MISSING" ] && echo "警告: 查無 IP, 略過:$MISSING"
        ;;
    status)
        ensure_infra
        if [ -n "$TARGETS" ]; then
            collect_ips "$TARGETS"
            [ -z "$RESULTS" ] && { echo "找不到任何 DHCP static host:$TARGETS"; exit 1; }
            echo "$RESULTS" | while read -r name ip; do
                [ -z "$ip" ] && continue
                if nft get element $TABLE $SET_NAME "{ $ip }" >/dev/null 2>&1; then
                    echo "$name ($ip): 封鎖中"
                else
                    echo "$name ($ip): 未封鎖"
                fi
            done
            [ -n "$MISSING" ] && echo "警告: 查無 IP, 略過:$MISSING"
        else
            echo "目前 $SET_NAME set 內的 IP (相鄰 IP 會被 auto-merge 成 CIDR/範圍):"
            nft list set $TABLE $SET_NAME 2>/dev/null \
                | sed -n 's/.*elements = {\(.*\)}.*/\1/p' \
                | tr ',' '\n' | sed 's/^[[:space:]]*/  /'
        fi
        ;;
    *)
        usage
        ;;
esac
