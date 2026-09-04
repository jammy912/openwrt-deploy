#!/bin/sh
# 推播 2.4G / 5G 各頻道的環境概況: 頻道 / 頻率 / AP 數 / 忙碌率
#
# 用途: 判斷該不該換頻道, 以及 2.4G 低頻端(WiFi ch1 區域)有多擠
#       —— Zigbee ch11-14 (2404-2425 MHz) 就疊在 WiFi ch1-3 上,
#          該區忙碌率高就會讓 Aqara 等 Zigbee 裝置一直重傳/離線。
#
# 資料來源都是本機 radio (不查 Zigbee 網關, Aqara M2 沒開任何查詢埠):
#   AP 數   = iwinfo scan   (被動掃描到的 BSS)
#   忙碌率  = iw survey dump (busy time / active time)
#
# ⚠️ 眉角一: 「非使用中」頻道的 survey 計數器會在每次 scan 時歸零重計,
#    不是開機以來的累計。實測 ch13 連讀三次 active=153 -> 123 -> 123,
#    值會變小。所以「兩次快照相減」是錯的做法(會算出負的忙碌率),
#    正確做法是每次 scan 後直接讀當次的值。
#    ★ 使用中的頻道(in use)則相反, 它是真正的累計值(數十小時),
#      每輪差異極小, 因此對它改用「首末相減」才有當下意義。
#
# ⚠️ 眉角二: 要拉長取樣就多跑幾輪 scan, 把各輪的 busy/active 累加後平均,
#    ROUNDS 越大越準(每輪約 3-5 秒)。單輪只有 70-150 ms 樣本, 誤差很大。
#
# ⚠️ 眉角三: 5G 若跑 HE160, scan 會失敗 —— 160MHz 聚合下無法離開通道做
#    off-channel scan。iw 會直接回 "Resource busy (-16)", 但 iwinfo 不會
#    回錯誤而是「無限卡住」(實測卡 15 分鐘以上, 程序停在 R 狀態,
#    還會擋住後續所有 iwinfo/iw 呼叫)。
#    ★ 故必須先用 `iw scan` 探測能力(它會立刻回錯誤), 不能直接跑 iwinfo scan。
#      探測失敗就整個 band 跳過掃描, 只取 survey 的使用中頻道值。

# 全域 cron 排隊鎖 (多輪掃描要跑數十秒, 鎖要夠久)
. /etc/myscript/lock-handler.sh
cron_global_lock 180 || exit 0

PUSH_NAMES="${PUSH_NAMES:-admin}"
. /etc/myscript/push-notify.inc

# 掃描輪數。每輪約 3-5 秒(2.4G), 輪數越多取樣越有代表性。
ROUNDS="${ROUNDS:-6}"

TMPD="/tmp/.wifistatus.$$"
mkdir -p "$TMPD"
trap 'rm -f /tmp/cron_global.lock; rm -rf "$TMPD"' EXIT

# 找出指定 band 的第一個 AP iface (同 radio 的多 BSS 只取一個)
# $1 = 2 或 5
find_iface() {
    for _i in $(iw dev 2>/dev/null | awk '/Interface /{print $2}'); do
        [ "$(iw dev "$_i" info 2>/dev/null | awk '/type /{print $2; exit}')" = "AP" ] || continue
        _f=$(iwinfo "$_i" info 2>/dev/null | sed -n 's/.*Channel: [0-9]* (\([0-9]*\)\..*/\1/p' | head -1)
        [ "$_f" = "$1" ] && { echo "$_i"; return 0; }
    done
    return 1
}

# 探測這個 iface 能不能掃描。用 iw 而非 iwinfo —— iw 會立刻回
# "Resource busy (-16)", iwinfo 則會無限卡住(見眉角三)。
can_scan() {
    iw dev "$1" scan trigger >/dev/null 2>&1
}

# 一輪取樣: 先 scan(讓 radio 巡一遍各頻道並重置計數), 再讀 survey
# 輸出每行: "頻率 busy active 是否使用中"
# $3 = 1 表示可掃描; 0 則只讀 survey
sample_round() {
    _if="$1"; _b="$2"; _ok="$3"
    if [ "$_ok" = "1" ]; then
        iwinfo "$_if" scan 2>/dev/null > "$TMPD/scan.$_b.new"
        # scan 成功才更新 AP 清單(失敗時保留前一輪的, 避免整份變空)
        [ -s "$TMPD/scan.$_b.new" ] && mv "$TMPD/scan.$_b.new" "$TMPD/scan.$_b"
    fi
    iw dev "$_if" survey dump 2>/dev/null | awk '
        /frequency:/           { f=$2; inuse=($0 ~ /in use/) }
        /channel active time:/ { act=$4 }
        /channel busy time:/   { print f, $4, act, inuse }
    '
}

IF2=$(find_iface 2)
IF5=$(find_iface 5)

# 各 band 先探測掃描能力(只探一次, 不必每輪重試)
OK2=0; OK5=0
[ -n "$IF2" ] && can_scan "$IF2" && OK2=1
[ -n "$IF5" ] && can_scan "$IF5" && OK5=1

# 多輪取樣, 全部累積到同一個檔, 後面再由 awk 分組加總
: > "$TMPD/acc.2"; : > "$TMPD/acc.5"
_r=0
while [ "$_r" -lt "$ROUNDS" ]; do
    [ -n "$IF2" ] && sample_round "$IF2" 2 "$OK2" >> "$TMPD/acc.2"
    [ -n "$IF5" ] && sample_round "$IF5" 5 "$OK5" >> "$TMPD/acc.5"
    _r=$((_r + 1))
done

# 產生某個 band 的逐頻道報表
# $1 = band (2/5)
band_report() {
    _b="$1"
    _scan="$TMPD/scan.$_b"
    [ -f "$_scan" ] || : > "$_scan"
    _naps=$(grep -c "Address:" "$_scan" 2>/dev/null)
    [ -z "$_naps" ] && _naps=0

    {
        awk '/Channel:/ { print "AP", $NF }' "$_scan"
        awk '{ print "SV", $0 }' "$TMPD/acc.$_b"
    } | awk -v scanok="$_naps" -v band="$_b" '
        function f2ch(f) { return (f < 3000) ? (f-2407)/5 : (f-5000)/5 }

        # 印出「以 c 為控制頻道、半寬 w 個頻道」的區間統計。
        # tag: "" =20MHz, "+"/"-" =40MHz 的副頻方向(僅供標示)
        # 靠邊界時往內平移補滿 (2*w+1) 個, 否則各組涵蓋數不同,
        # AP 總數無法互相比較。
        function span(c, w, tag,   lo, hi, cc, tot, cnt, aps, need) {
            need = 2 * w + 1
            lo = c - w; hi = c + w
            if (lo < 1)  { lo = 1;  hi = need }
            if (hi > 13) { hi = 13; lo = 13 - need + 1 }
            if (lo < 1) lo = 1
            tot = 0; cnt = 0; aps = 0
            for (cc = lo; cc <= hi; cc++) {
                aps += gap[cc]
                if (gpct[cc] >= 0) { tot += gpct[cc]; cnt++ }
            }
            if (cnt > 0)
                printf "ch%-2d%s (%2d-%-2d) %3d支 平均%3.0f%%\n", c, tag, lo, hi, aps, tot/cnt
            else
                printf "ch%-2d%s (%2d-%-2d) %3d支 平均  - \n", c, tag, lo, hi, aps
        }
        $1 == "AP" { ap[$2]++ ; next }
        $1 == "SV" {
            f = $2
            # 使用中的頻道是累計值 -> 記首末, 用差值
            # 其他頻道每輪重置 -> 直接累加各輪
            if ($5 == 1) {
                if (!(f in first_a)) { first_b[f]=$3; first_a[f]=$4 }
                last_b[f]=$3; last_a[f]=$4; inuse[f]=1
            } else {
                sb[f] += $3; sa[f] += $4
            }
            seen[f] = 1
            next
        }
        END {
            n = 0
            for (f in seen) order[n++] = f + 0
            for (i = 0; i < n; i++)
                for (j = i+1; j < n; j++)
                    if (order[j] < order[i]) { t=order[i]; order[i]=order[j]; order[j]=t }

            for (i = 0; i < n; i++) {
                f = order[i]
                ch = f2ch(f)

                if (inuse[f] == 1) {
                    da = last_a[f] - first_a[f]
                    db = last_b[f] - first_b[f]
                } else {
                    da = sa[f]; db = sb[f]
                }

                if (da <= 0) {
                    pct = "  - "
                } else {
                    p = db * 100 / da
                    if (p < 0)   p = 0
                    if (p > 100) p = 100
                    pct = sprintf("%3.0f%%", p)
                }

                napp = (scanok > 0) ? sprintf("%2d支", ap[ch]+0) : " - "
                printf "ch%-3d %4d %s %s%s\n", ch, f, napp, pct, (inuse[f]==1 ? "*" : "")
                # 存起來給後面的 group 統計用
                gpct[ch] = (da > 0) ? db * 100 / da : -1
                gap[ch]  = ap[ch] + 0
            }

            # ---- 2.4G 候選頻道的「實際佔用區間」統計 ----
            # ★ 為什麼要這段: 逐行的單一中心頻率忙碌率會誤導 ——
            #   例如 ch13 中心點看起來只有 13%, 但 HE20 實際佔 ch11-13,
            #   跟 ch11 那群重疊超過一半, 換過去並沒有真的躲開。
            #   故對 1/6/11 這三個互不重疊的主頻道, 額外印出
            #   「中心 ±2 共 20MHz」範圍內的 AP 總數與平均忙碌率。
            if (band == "2") {
                printf "─ 20MHz 實際佔用 ─\n"
                split("1 6 11", cand, " ")
                for (k = 1; k <= 3; k++) span(cand[k]+0, 2, "")

                # ---- 40MHz ----
                # 控制頻道 ±4 = 40MHz, 共 9 個頻道。2.4G 只有 1-13,
                # 放得下的位置極少: 控制 ch1(佔1-9) 或 ch9/11(佔5-13)。
                # 兩者一定重疊(9 個 x2 = 18 > 13), 亦即 2.4G 開 40MHz
                # 必然吃掉整個頻段的大半, 沒有「互不干擾的兩組」可言。
                # ⚠️ 且 ch1 起跳的 40MHz 會蓋住 2401-2445, 正好壓到
                #    Zigbee ch11-15 —— 這是本機刻意用 HT20 的原因。
                printf "─ 40MHz 實際佔用 ─\n"
                span(1,  4, "+")     # 控制 ch1, 副頻在上 -> 佔 1-9
                span(11, 4, "-")     # 控制 ch11, 副頻在下 -> 佔 7-13(截)
            }
        }
    '
}

msg=""
for _b in 2 5; do
    eval "_iface=\$IF$_b"
    [ -z "$_iface" ] && continue

    _rep=$(band_report "$_b")
    [ -z "$_rep" ] && continue

    _cur=$(iwinfo "$_iface" info 2>/dev/null | sed -n 's/.*Channel: \([0-9]*\) .*/\1/p' | head -1)
    _ht=$(iwinfo "$_iface" info 2>/dev/null | sed -n 's/.*HT Mode: \([A-Za-z0-9+-]*\).*/\1/p' | head -1)

    # 目前「佔用範圍」內有沒有 DFS 頻道?
    # ★ 不能只看控制頻道: ch36 本身非 DFS, 但 HE160 從 36 起算佔 36-64,
    #   把 DFS 的 52-64 一起吃進來, 整段就受 DFS 管制(實測 hostapd 確實
    #   對 chan=36 發出 DFS-CAC-START)。故要用 center1 + 寬度推算涵蓋範圍。
    _phy=$(iw dev "$_iface" info 2>/dev/null | awk '/wiphy /{print "phy"$2; exit}')
    _isdfs=0
    if [ -n "$_phy" ]; then
        # 取實際佔用: center1 頻率與頻寬(MHz)
        _cf=$(iw dev "$_iface" info 2>/dev/null | sed -n 's/.*center1: \([0-9]*\) MHz.*/\1/p' | head -1)
        _bw=$(iw dev "$_iface" info 2>/dev/null | sed -n 's/.*width: \([0-9]*\) MHz.*/\1/p' | head -1)
        if [ -n "$_cf" ] && [ -n "$_bw" ]; then
            _lo=$(( _cf - _bw / 2 ))
            _hi=$(( _cf + _bw / 2 ))
            # 列出所有 DFS 頻率, 有任一支落在佔用範圍內就算 DFS
            for _df in $(iw phy "$_phy" info 2>/dev/null \
                    | grep "radar detection" \
                    | sed -n 's/.*\* \([0-9]*\)\.0 MHz.*/\1/p'); do
                [ "$_df" -gt "$_lo" ] && [ "$_df" -lt "$_hi" ] && { _isdfs=1; break; }
            done
        fi
    fi

    if [ "$_b" = "2" ]; then
        _title="📶 2.4G ch${_cur}/${_ht}"
    else
        _title="📡 5G ch${_cur}/${_ht}"
        # scan 失敗時要講原因, 否則會被誤讀成「附近沒有 AP」。
        # ★ 真兇是 DFS 不是頻寬: 離開 DFS 頻道等於作廢已完成的 CAC,
        #   驅動直接拒絕 scan。同一顆 phy 在非 DFS 頻道就掃得動。
        if [ "$OK5" = "0" ]; then
            if [ "$_isdfs" = "1" ]; then
                _title="${_title} (DFS 佔用中,無法掃描)"
            else
                _title="${_title} (無法掃描)"
            fi
        fi
    fi

    msg="${msg}
${_title}
${_rep}"
done

if [ -z "$msg" ]; then
    push_notify "⚠️ WiFi 狀態: 找不到任何 AP 介面"
    exit 0
fi

# ---- DFS / 雷達狀況 ----
# 只在 5G 目前待在 DFS 頻道時才印(非 DFS 頻道講這些沒意義)。
# 資料來自 logread 的 hostapd DFS 事件:
#   DFS-CAC-START      開始 60s 通道可用性檢查, 這段期間不能發射
#   DFS-CAC-COMPLETED  success=1 表示通過; radar_detected=1 表示偵測到雷達
#   DFS-RADAR-DETECTED 運作中偵測到雷達 -> 強制換頻道, 客戶端會斷線
# ⚠️ logread 是 RAM ring buffer, 重開機或訊息量大就會被沖掉,
#    所以「查無紀錄」不等於「沒發生過」。
if [ "$_isdfs" = "1" ]; then
    _dfs=""
    # 最近一次 CAC 結果
    _cac=$(logread 2>/dev/null | grep "DFS-CAC-COMPLETED" | tail -1)
    if [ -n "$_cac" ]; then
        _ok=$(echo "$_cac" | sed -n 's/.*success=\([0-9]*\).*/\1/p')
        _rd=$(echo "$_cac" | sed -n 's/.*radar_detected=\([0-9]*\).*/\1/p')
        _tm=$(echo "$_cac" | awk '{print $4}')
        if [ "$_ok" = "1" ]; then
            _dfs="${_dfs}CAC ${_tm} 通過"
        else
            _dfs="${_dfs}CAC ${_tm} 失敗"
        fi
        [ "$_rd" = "1" ] && _dfs="${_dfs} ⚠️偵測到雷達"
    else
        # 還在跑 CAC(有 START 沒 COMPLETED) 或紀錄已被沖掉
        if logread 2>/dev/null | grep -q "DFS-CAC-START"; then
            _dfs="CAC 進行中或紀錄不全"
        else
            _dfs="無 CAC 紀錄"
        fi
    fi

    # 歷史雷達事件次數(CAC 中偵測到 + 運作中偵測到)
    _radar=$(logread 2>/dev/null | grep -cE "DFS-RADAR-DETECTED|radar_detected=1")
    [ -z "$_radar" ] && _radar=0
    if [ "$_radar" -gt 0 ]; then
        _dfs="${_dfs}, 雷達事件 ${_radar} 次"
    else
        _dfs="${_dfs}, 無雷達事件"
    fi

    msg="${msg}
📡 DFS: ${_dfs}"
fi

push_notify "WiFi 環境 (${ROUNDS}輪取樣)${msg}
(* =使用中, - =無資料)"
