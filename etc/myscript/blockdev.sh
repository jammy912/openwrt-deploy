#!/bin/sh
# blockdev.sh - 依 DHCP static host 名字封鎖/解封裝置上網
# 用法:
#   blockdev.sh <name>[,<name>...] add|del|status|allow|block [分鐘]
# 範例:
#   blockdev.sh TV_Apple add                    # 封鎖單一裝置
#   blockdev.sh TV_Apple,TV_Android add         # 一次封鎖多台 (逗號分隔)
#   blockdev.sh "TV_Apple TV_Android" add       # 多台也可用空白分隔 (需引號)
#   blockdev.sh TV_Apple,TV_Android del         # 一次解封多台
#   blockdev.sh '*tv*' add                      # 萬用字元: 名字含 tv 的裝置, 不分大小寫 (★引號必加)
#   blockdev.sh TV_Apple status                 # 查狀態
#   blockdev.sh "" status                       # 列出 set 內所有被封鎖的 IP
#   blockdev.sh "*TV*" allow 60                 # 限時放行 60 分鐘, 到期自動鎖回
#   blockdev.sh "*TV*" block 30                 # 限時封鎖 30 分鐘, 到期自動放開
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
usage() {
    echo "用法: $0 <name|pattern>[,...] <動作> [分鐘]"
    echo "  動作: add/del = 永久; allow/block = 限時(帶分鐘數); status = 查詢"
    echo "      $0 TV_Apple,TV_Android add   # 一次多台 (逗號分隔)"
    echo "      $0 '*tv*' add                # 萬用字元, 不分大小寫 (單/雙引號皆可, 必加)"
    echo "      $0 \"*tv*\" allow 60         # 限時放行 60 分鐘, 到期自動鎖回"
    echo "      $0 \"*tv*\" block 30         # 限時封鎖 30 分鐘, 到期自動放開"
    echo "      $0 \"\" status                # 列出所有被封鎖 IP"
    exit 1
}


# 參數配置: <name|pattern>... <動作> [分鐘]
#   最後一個參數為動作; 但若最後一個是純數字, 它是「限時分鐘數」,
#   動作則往前挪一位。
#
# ★ 限時動作 allow/block (2026-09-23 新增):
#   blockdev.sh "*TV*" allow 60  → 立刻放行, 60 分鐘後自動鎖回
#   blockdev.sh "*TV*" block 30  → 立刻封鎖, 30 分鐘後自動放開
#
#   ★ 為什麼另立動詞而不是沿用 `del 60`:
#     `del 60` 看不出 60 是「解封多久」還是「多久之後才解封」, 語義有歧義。
#     allow/block 是「限時」動作, add/del 是「永久」動作, 兩組並存互不干擾:
#       add/del     → 改了就不動, 由 cron 或人工負責還原
#       allow/block → 自帶計時器, 時間到自動回到反向狀態
#   allow 不帶分鐘數 = 等同 del; block 不帶 = 等同 add(仍可用, 只是沒計時)。
#
# ⚠️ 眉角:
#   1. 用 setsid 背景計時, **重開機/斷電就失效**(計時器只存在於 RAM),
#      自動還原永遠不會發生, 裝置會停在當下狀態。要防這點請另外掛一行
#      cron 當保險, 例如每天 02:00 固定 add 一次。
#      已於實機確認 setsid 能跨 SSH 斷線存活
#      (2026-09-23 於 .12: SSH 11:49:04 斷開, 背景任務 11:49:19 仍完成)。
#   2. status 不接受分鐘數(唯讀動作, 沒有東西要還原)。
#   3. 計時期間再下一次 allow/block 會「疊加」另一個計時器, 不會取消前一個。
#      兩個計時器到期時都會執行, 以較晚者為最終狀態。要取消只能用
#      add/del 手動覆蓋(計時器仍會跑, 但結果被後續動作蓋掉)。
REVERT_MIN=""
_last=$(eval echo "\${$#}")
_nargs=$#
case "$_last" in
    ''|*[!0-9]*) ;;                       # 非純數字 → 沒有計時器
    *) REVERT_MIN="$_last"; _nargs=$(( _nargs - 1 )) ;;
esac
[ "$_nargs" -lt 1 ] && usage
ACTION=$(eval echo "\${$_nargs}")
TARGETS=""
i=1
while [ $i -lt $_nargs ]; do
    TARGETS="$TARGETS $(eval echo "\${$i}")"
    i=$((i + 1))
done
# 正規化: 逗號→空白 (支援 TV_Apple,TV_Android), 去除多餘/前後空白;
# 全空 (如 blockdev.sh "" status) → 真空字串
TARGETS=$(echo "$TARGETS" | tr ',' ' ')
TARGETS=$(echo $TARGETS)


[ -z "$ACTION" ] && usage

# --- allow/block 映射成實際的 nft 動作, 並記錄到期要反轉成什麼 ---
# ★ 映射後 $ACTION 一律是 add/del/status, 下方 case 不必改。
#   REVERT_ACT 存「到期時要下的限時動作」, 讓 log 與訊息講人話。
REVERT_ACT=""
case "$ACTION" in
    allow) ACTION="del"; REVERT_ACT="block" ;;
    block) ACTION="add"; REVERT_ACT="allow" ;;
esac

if [ -n "$REVERT_MIN" ]; then
    if [ -z "$REVERT_ACT" ]; then
        echo "❌ 只有 allow/block 支援限時, $ACTION 不行"
        echo "   要限時放行 60 分鐘請用: $0 \"$TARGETS\" allow 60"
        exit 1
    fi
    # 0 分鐘沒有意義; 設上限避免手誤打成 6000 之類掛著好幾天不放
    if [ "$REVERT_MIN" -lt 1 ] || [ "$REVERT_MIN" -gt 1440 ]; then
        echo "❌ 分鐘數須介於 1-1440(24 小時): $REVERT_MIN"
        exit 1
    fi
fi

# 依名字清單從 uci dhcp 查固定 IP, 結果存 RESULTS ("name ip" 每行一筆)
# 查無 IP 的名字存 MISSING
#
# ★ 支援萬用字元 (2026-09-23 新增):
#   名字含 * ? [ 時改走 glob 比對, 例如 `blockdev.sh '*tv*' add` 會命中
#   所有 name 含 tv 的 static host。比對「不分大小寫」(TV_Apple / mytv 都中),
#   作法是把兩邊都轉小寫再比, 因為 shell 的 case glob 本身區分大小寫。
# ⚠️ 眉角:
#   1. 在 shell 下 *tv* 會被自己展開成當前目錄的檔名 → 呼叫時務必加引號。
#      單引號雙引號皆可 (pattern 內沒有 $ 或反引號, 兩者傳入的字串相同):
#        blockdev.sh '*tv*' add      (對)
#        blockdev.sh "*tv*" add      (對)
#        blockdev.sh *tv* add        (錯, 可能變成檔名或原字串, 行為不可預期)
#   2. 萬用字元一個都沒命中時, 該 pattern 計入 MISSING (與精確比對一致),
#      全部沒命中仍會 exit 1, 不會靜默把「零台」當成功。
#   3. 同一台可能被多個 pattern 命中 (如 '*tv*' 與 'TV_Apple' 併用),
#      故收集後以 IP 去重, 避免 log 重複兩行。
RESULTS=""
MISSING=""

# 有無萬用字元
_has_glob() {
    case "$1" in
        *'*'*|*'?'*|*'['*) return 0 ;;
        *) return 1 ;;
    esac
}

_tolower() { echo "$1" | tr 'A-Z' 'a-z'; }

collect_ips() {
    local want="$1"     # 要找的名字/樣式 (可多個, 空白分隔)
    [ -z "$want" ] && return
    local found n
    for n in $want; do
        found=""
        if _has_glob "$n"; then
            _pat=$(_tolower "$n")
            find_one() {
                local _name _ip _lname
                config_get _name "$1" name
                config_get _ip  "$1" ip
                { [ -z "$_name" ] || [ -z "$_ip" ]; } && return
                _lname=$(_tolower "$_name")
                # shellcheck disable=SC2254  # 這裡就是要讓 $_pat 當 glob 展開
                case "$_lname" in
                    $_pat) RESULTS="$RESULTS
$_name $_ip"; found=1 ;;
                esac
            }
        else
            find_one() {
                local _name _ip
                config_get _name "$1" name
                config_get _ip  "$1" ip
                [ "$_name" = "$n" ] && [ -n "$_ip" ] && { RESULTS="$RESULTS
$_name $_ip"; found=1; }
            }
        fi
        config_load dhcp
        config_foreach find_one host
        [ -z "$found" ] && MISSING="$MISSING $n"
    done
    # 依 IP 去重 (多個 pattern 命中同一台時)
    RESULTS=$(echo "$RESULTS" | awk 'NF && !seen[$2]++')
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

# --- 排定到期自動還原 ---
# ★ 必須放在主動作之後: 主動作失敗會在上面 exit 1, 走不到這裡,
#   所以「放行失敗卻排了鎖回」不會發生。
# ⚠️ setsid 讓計時器脫離本次 session(SSH 斷線仍存活, 2026-09-23 實測),
#   但它只存在於 RAM — 重開機就沒了, 還原不會發生。
# ⚠️ 還原指令刻意「不」再帶分鐘數, 否則會無限遞迴排下去。
# ⚠️ 這裡用 "$TARGETS" 而非原始 $1: TARGETS 已把逗號正規化成空白,
#   重新傳入時要整個當一個參數, 故加引號。萬用字元原樣保留,
#   到期時才重新查一次 dhcp(期間若新增了 TV_xxx 也會一併處理)。
if [ -n "$REVERT_MIN" ]; then
    _secs=$(( REVERT_MIN * 60 ))
    _until=$(date -d "@$(( $(date +%s) + _secs ))" '+%H:%M' 2>/dev/null) \
        || _until="${REVERT_MIN} 分鐘後"
    setsid sh -c "sleep $_secs; /etc/myscript/blockdev.sh \"$TARGETS\" $REVERT_ACT" \
        >/dev/null 2>&1 &
    logger -t $LOG_TAG "限時 ${REVERT_MIN} 分鐘, ${_until} 自動 $REVERT_ACT: $TARGETS"
    echo "⏱  ${_until} 自動 ${REVERT_ACT}(限時 ${REVERT_MIN} 分鐘;重開機會失效)"
fi

# ★ 不可省略: add/del/status 三個分支的最後一句都是
#   `[ -n "$MISSING" ] && echo "警告: ..."`。MISSING 為空(全部命中)時
#   該測試回 false, 成為整支腳本的最後一個指令 → exit code = 1,
#   變成「全部成功卻回失敗」。
#   實測 2026-09-23 於 x60pro(.12): TV 四台全部命中仍 exit=1,
#   精確比對 blockdev.sh TV_Apple status 同樣 exit=1(非萬用字元改動造成)。
#   影響: LineCMD 的 sync-googleconfig.sh 用 if handler; then 推播✅ else ❌,
#   會推出假的失敗警報。cron 直接呼叫則無感(crond 不看 exit code)。
exit 0
