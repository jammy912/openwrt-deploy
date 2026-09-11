#!/bin/sh
# =====================================================================
# check-fserror.sh — ext4 檔案系統損壞監測(唯讀, 不卸載不修復)
#
# ★ 只監測不動手: 發現異常就推播, 由人決定何時停服務跑 e2fsck。
#   理由(2026-09-10 實測): e2fsck 必須卸載, 而卸載常被 smbd 子行程的 cwd
#   擋住; 半夜自動跑 `-y` 等於無人監督地自動決定「把壞東西丟進 lost+found」。
#   ★ 健康的 ext4 有 journal, 正常關機不會累積錯誤 —— 需要「定期 fsck」本身
#     就代表硬體或別處有問題, 該處理的是根因不是排程。
#
# 監測指標: tune2fs -l 的 FS Error count
#   - 記在超級區塊, **只增不減**, 重開機不歸零, 只有 e2fsck 修完才清零
#   - syslog 會被 128KB buffer 洗掉, 這個不會 -> 適合當長期告警指標
#   - ⚠️ 掛載中就能讀(實測 rc=0), 不需卸載
#   - ⚠️ 歸零後「整行會消失」, awk 取不到值會回空字串 -> 一律補預設 0
#     (今天已踩過同類坑: awk 空輸入不輸出 0 而是完全不輸出, 害
#      [ "$x" -gt 0 ] 噴 "sh: out of range")
#
# ⚠️ 不寫死 /dev/sdX: USB 列舉順序每次開機都可能不同(實測變過兩次),
#    改用 /proc/mounts 自動列舉所有 ext4 掛載點。
# =====================================================================

LOCK="/tmp/check-fserror.lock"
if [ -f "$LOCK" ]; then
    kill -0 "$(cat "$LOCK")" 2>/dev/null && exit 0
    rm -f "$LOCK"
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK" /tmp/cron_global.lock' EXIT

# 全域 cron 排隊鎖
. /etc/myscript/lock-handler.sh
cron_global_lock 60 || exit 0

# ---- 沒有 tune2fs 的機器安靜跳過(機隊防護) ----
# ⚠️ busybox 沒有 dumpe2fs; tune2fs 要另裝套件(apk add tune2fs)。
#    這支 cron 可能下發給整個機隊, 沒外接碟的機器要安靜退出不洗 log。
command -v tune2fs >/dev/null 2>&1 || exit 0

. /etc/myscript/push-notify.inc
PUSH_NAMES="${PUSH_NAMES:-admin}"

STATEDIR="/etc/myscript/.fserror"
mkdir -p "$STATEDIR" 2>/dev/null

log() { echo "$1"; logger -t check-fserror "$1"; }

# ⚠️ 這個 while 由管線餵食 = 跑在子 shell, 迴圈內設的變數帶不出來
#    (今天已在 stage_flush 踩過同樣的坑)。本迴圈刻意「不依賴任何值傳出去」:
#    推播與狀態檔都在迴圈「內」完成, 所以子 shell 不影響正確性。
# /proc/mounts 可能有重複行, 用 sort -u 去重
awk '$3=="ext4"{print $1" "$2}' /proc/mounts 2>/dev/null | sort -u | while read -r _dev _mnt; do
    [ -b "$_dev" ] || continue

    _info=$(tune2fs -l "$_dev" 2>/dev/null)
    [ -z "$_info" ] && continue          # 讀不到就跳過, 不誤報

    _state=$(echo "$_info" | awk -F: '/^Filesystem state/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
    _cnt=$(echo "$_info"   | awk -F: '/^FS Error count/{gsub(/[ \t]/,"",$2); print $2}')
    # ★ 歸零時該行不存在 -> 補預設 0(見檔頭說明)
    [ -z "$_cnt" ] && _cnt=0
    # Last checked: e2fsck 跑過就會更新 -> 用來偵測「掛載前被自動修復」。
    # ⚠️ 值含空白(如 "Fri Sep 11 11:07:11 2026"), 故狀態檔用 | 分隔不用空白。
    _chk=$(echo "$_info" | sed -n 's/^Last checked:[[:space:]]*//p')

    # 狀態檔以裝置名為 key(去掉 /dev/)
    _key=$(echo "$_dev" | tr -d '/' | sed 's/^dev//')
    _sf="$STATEDIR/.$_key"
    # 格式: <errcount>|<last checked>。⚠️ 舊版只存數字, 用 -F'|' 取第一欄仍相容。
    _raw=$(cat "$_sf" 2>/dev/null)
    _prev=$(echo "$_raw" | awk -F'|' '{print $1+0}')
    [ -z "$_prev" ] && _prev=0
    _prevchk=$(echo "$_raw" | awk -F'|' '{print $2}')

    # ★ Last checked 變了 = 這顆碟被 e2fsck 修過(多半是開機時 block 的
    #   check_fs=1 在 mount 前自動跑的)。★ 這個訊號不依賴 log ——
    #   實測開機時的 fsck 在 logread 裡抓不到(buffer 只有 128KB 早被沖掉),
    #   但 tune2fs 的 Last checked 會確實更新。
    # ⚠️ 首次執行(_prevchk 空)不推播, 否則剛部署就誤報一次。
    if [ -n "$_prevchk" ] && [ -n "$_chk" ] && [ "$_chk" != "$_prevchk" ]; then
        log "🔧 $_mnt ($_dev) 已被 e2fsck 檢查/修復: $_prevchk -> $_chk"
        push_notify "🔧檔案系統 $_mnt 已自動修復 (掛載前 e2fsck): 檢查時間 $_chk, 先前錯誤累計 $_prev, 目前 state=$_state"
    fi

    # ⚠️ 只在「有變化」時才寫檔: /etc/myscript 在 flash 上,
    #    每輪無條件寫 = 1440 次/天磨 flash(參見 flash-wear-audit 的教訓)。
    [ "$_cnt|$_chk" != "$_raw" ] && echo "$_cnt|$_chk" > "$_sf"

    case "$_state" in
        *"with errors"*)
            if [ "$_cnt" -gt "$_prev" ]; then
                _delta=$((_cnt - _prev))
                log "⚠️ $_mnt ($_dev) 錯誤增加 $_prev -> $_cnt"
                push_notify "⚠️檔案系統 $_mnt 損壞增加 (+$_delta, 累計 $_cnt): state=$_state; 建議停服務跑 e2fsck -f $_dev"
            elif [ "$_prev" = "0" ]; then
                # 第一次發現(可能是剛部署, 或 e2fsck 後又出錯)
                log "⚠️ $_mnt ($_dev) state=$_state count=$_cnt"
                push_notify "⚠️檔案系統 $_mnt 標記有錯 (累計 $_cnt): 建議停服務跑 e2fsck -f $_dev"
            fi
            ;;
        clean)
            # 從有錯變乾淨(表示剛修過) -> 回報一次
            [ "$_prev" -gt 0 ] && {
                log "✅ $_mnt ($_dev) 已恢復 clean (先前 $_prev)"
                push_notify "✅檔案系統 $_mnt 已修復, 錯誤計數歸零 (先前累計 $_prev)"
            }
            ;;
        *)
            [ -n "$_state" ] && log "$_mnt ($_dev) state=$_state count=$_cnt"
            ;;
    esac
done

exit 0
