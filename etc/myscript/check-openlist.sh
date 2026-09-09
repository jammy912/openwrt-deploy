#!/bin/sh
# =====================================================================
# check-openlist.sh — OpenList 容器健檢，掛了就叫起來
#
# ★ 判斷條件刻意「從嚴」，只處理「容器真的死了」:
#     1. 容器不存在 running 狀態      -> docker start
#     2. HTTP 埠連續 N 輪不回應        -> docker restart
#
# ⚠️ 絕對不要用「下載沒進度」當重啟條件! 實測 2026-09-09 夸克限制大檔下載時,
#    容器完全正常(docker logs 無異常、API 回 200、容器內連得到阿里雲 CDN),
#    重啟它不但沒用, 還會把正在進行的下載整個打斷。★ 兩層要分清楚:
#      容器掛掉        -> 這支處理
#      容器活著抓不到檔 -> openlist-sync.sh 自己的 max-time/卡死偵測處理
#
# ⚠️ 判別「是不是網盤端的問題」的順序(實測有效):
#    curl google 確認對外通 -> /api/fs/list 確認 Cookie 有效(storage=work)
#    -> 抓一個小檔。三關都過還是抓不到大檔 = 網盤端限速, 腳本改不了。
# =====================================================================

LOCK="/tmp/check-openlist.lock"
if [ -f "$LOCK" ]; then
    kill -0 "$(cat "$LOCK")" 2>/dev/null && exit 0
    rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK" /tmp/cron_global.lock' EXIT

# 全域 cron 排隊鎖
. /etc/myscript/lock-handler.sh
cron_global_lock 60 || exit 0

# ---- 沒裝 Docker/OpenList 的機器安靜跳過 ----
# ⚠️ 這支 cron 可能由 Google Sheet 下發給整個機隊, 只有 .4 跑 OpenList。
#    不加這道會在其他機器每 10 分鐘寫一筆噪音(log buffer 只有 128KB)。
command -v docker >/dev/null 2>&1 || exit 0
docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx openlist || exit 0

. /etc/myscript/push-notify.inc
PUSH_NAMES="${PUSH_NAMES:-admin}"

OL_URL="http://127.0.0.1:5244"
STATE="/etc/myscript/.openlist-sync/.health"
FAIL_MAX=2          # 連續幾輪連不上才重啟(*/10 的 cron = 20 分鐘)

log() { echo "$1"; logger -t check-openlist "$1"; }

mkdir -p "$(dirname "$STATE")" 2>/dev/null

# ---- 1. 容器有在跑嗎 ----
_state=$(docker inspect -f '{{.State.Status}}' openlist 2>/dev/null)
if [ "$_state" != "running" ]; then
    log "容器狀態 $_state, 嘗試啟動"
    if docker start openlist >/dev/null 2>&1; then
        push_notify "OpenList: 容器原本是 $_state, 已重新啟動"
        echo 0 > "$STATE"
    else
        push_notify "⚠️OpenList: 容器 $_state 且啟動失敗, 需人工處理"
    fi
    exit 0
fi

# ---- 2. HTTP 埠有回應嗎 ----
# ⚠️ 只看 docker ps 不夠: 行程還在但服務卡死(OOM 後半死不活)是常見狀況。
_code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$OL_URL/" 2>/dev/null)
_fail=$(cat "$STATE" 2>/dev/null | awk '{print $1+0}')
# ⚠️ awk 對「空輸入」不會輸出 0 而是完全不輸出 -> _fail 變空字串 -> 後面
#    [ "$_fail" -gt 0 ] 直接噴 "sh: out of range"(實測)。一律補預設值。
[ -z "$_fail" ] && _fail=0

case "$_code" in
    2*|3*|401|403)
        # 有回應就算活著(401/403 代表服務在跑, 只是要驗證)
        [ "$_fail" -gt 0 ] && log "已恢復 (HTTP $_code)"
        echo 0 > "$STATE"
        exit 0
        ;;
esac

_fail=$(( _fail + 1 ))
echo "$_fail" > "$STATE"
log "HTTP 無回應 (code=$_code), 連續 $_fail 輪"

if [ "$_fail" -ge "$FAIL_MAX" ]; then
    # ⚠️ 重啟會打斷正在進行的下載。但走到這裡代表服務已經連續 FAIL_MAX 輪
    #    完全不回應, 下載本來就不可能還在動。
    log "連續 $_fail 輪無回應, 重啟容器"
    if docker restart openlist >/dev/null 2>&1; then
        push_notify "OpenList: 服務連續 $_fail 輪無回應已重啟容器"
    else
        push_notify "⚠️OpenList: 服務無回應且重啟失敗, 需人工處理"
    fi
    echo 0 > "$STATE"
fi

exit 0
