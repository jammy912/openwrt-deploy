#!/bin/sh
# AGH 對 DBR 網域改走 dnsmasq，讓 nftset 看得到 LAN client 的查詢
#
# 背景(2026-11-03 實證)：有 AGH 時 fw4 redirect adgh_l-a-n 把 LAN udp/53 直接導到
# AGH:53535，client 的查詢完全不經過 dnsmasq，dbroute-domains.conf 的 nftset= 只吃得到
# 路由器本機(dbroute-refresh 查 apex)的回答，所以 client 實際連的子網域 IP 從來沒進 set。
#
# 做法(C 案，保留 AGH 的 client 識別)：
#   1. AGH upstream_dns 加一行 '[/<全部 DBR 網域>/]127.0.0.1:53'：DBR 網域交給 dnsmasq 解析，
#      dnsmasq 回答時照 nftset= 把 IP 加進 route_<if>_v4。
#   2. persistent client dnsmasq-loopback(127.0.0.1、::1)設定自己的 upstreams(=一般上游)：
#      dnsmasq 轉回 AGH 的查詢走這組，不會再命中第 1 步的規則，迴圈就斷開了。
#
# 冪等：yaml 已經符合預期就直接 exit 0(只做 grep 比對)。只有需要改的時候才
# --check-config、停 AGH、換檔、啟動 AGH。
# 呼叫端：sync-googleconfig(DBR 變更後)、deploy.sh(AGH yaml 客製化後)。
# 用法：agh-dbr-upstream.sh [--no-restart]   (--no-restart：只改檔，不重啟 AGH，給 deploy 用)

PATH=/usr/sbin:/sbin:/usr/bin:/bin
export PATH

CONF=/etc/dnsmasq.d/dbroute-domains.conf
MARK="]127.0.0.1:53'"
CLIENT_NAME=dnsmasq-loopback
LOG_TAG=agh-dbr-upstream
NO_RESTART=0
[ "$1" = "--no-restart" ] && NO_RESTART=1

log() { logger -t "$LOG_TAG" "$*"; echo "$*"; }

AGH_YAML=$(uci -q get adguardhome.config.config_file)
[ -z "$AGH_YAML" ] && AGH_YAML=$(uci -q get adguardhome.config.config)
[ -z "$AGH_YAML" ] && AGH_YAML=/etc/adguardhome/adguardhome.yaml
AGH_BIN=$(command -v AdGuardHome 2>/dev/null)
[ -z "$AGH_BIN" ] && [ -x /usr/bin/AdGuardHome ] && AGH_BIN=/usr/bin/AdGuardHome

# 沒裝 AGH 就不需要(dnsmasq 本身就是 client 的 DNS，nftset 本來就有效)
[ -f "$AGH_YAML" ] && [ -n "$AGH_BIN" ] || exit 0

# 期望的網域規則行(conf 不存在或沒有網域 → 期望「沒有這行」)
DOMS=""
[ -f "$CONF" ] && DOMS=$(sed -n 's|^nftset=/\([^/]*\)/.*|\1|p' "$CONF" | sort -u | tr '\n' '/')
WANT_LINE=""
[ -n "$DOMS" ] && WANT_LINE="    - '[/${DOMS}${MARK}"

# 目前狀態
CUR_LINE=$(grep -F "$MARK" "$AGH_YAML" | head -1)
CUR_CNT=$(grep -cF "$MARK" "$AGH_YAML")
HAS_CLIENT=0
# AGH 重啟後會重新排序欄位(name 不一定在 "- " 那一行)，所以縮排不限
grep -qE "^ +(- )?name: ${CLIENT_NAME}$" "$AGH_YAML" && HAS_CLIENT=1

NEED=0
if [ -n "$WANT_LINE" ]; then
    { [ "$CUR_CNT" -ne 1 ] || [ "$CUR_LINE" != "$WANT_LINE" ]; } && NEED=1
    [ "$HAS_CLIENT" -eq 0 ] && NEED=1
else
    [ "$CUR_CNT" -gt 0 ] && NEED=1
fi
[ "$NEED" -eq 0 ] && exit 0

# 一般上游(upstream_dns 區塊內、非 [/網域/] 開頭的項目)→ 給 dnsmasq-loopback 用
GEN_UP=$(awk '
    /^  upstream_dns:/ {inb=1; next}
    inb && /^    - / {v=$0; sub(/^    - /, "", v); gsub(/["'\'']/, "", v); if (v !~ /^\[/) print v; next}
    inb {inb=0}
' "$AGH_YAML" | tr '\n' ' ')
if [ -n "$WANT_LINE" ] && [ -z "$(echo $GEN_UP)" ]; then
    log "❌ 找不到 AGH 一般上游(upstream_dns 為空?)，不改 yaml(否則 dnsmasq-loopback 沒有上游會形成迴圈)"
    exit 1
fi

TMP=/tmp/agh-dbr-upstream.$$.yaml
CLIENT_UID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
awk -v want="$WANT_LINE" -v mark="$MARK" -v cname="$CLIENT_NAME" -v uid="$CLIENT_UID" \
    -v genup="$GEN_UP" -v hasclient="$HAS_CLIENT" '
    function emit_client(   n, i, a) {
        print "    - name: " cname
        print "      ids:"
        print "        - 127.0.0.1"
        print "        - ::1"
        print "      upstreams:"
        n = split(genup, a, " ")
        for (i = 1; i <= n; i++) if (a[i] != "") print "        - " a[i]
        print "      uid: " uid
        print "      use_global_settings: true"
        print "      use_global_blocked_services: true"
        print "      filtering_enabled: true"
        print "      ignore_querylog: false"
        print "      ignore_statistics: false"
    }
    index($0, mark) > 0 { next }                       # 舊的網域規則行一律先拿掉
    /^  upstream_dns:/ { print; if (want != "") print want; next }
    want != "" && !hasclient && /^  persistent: *\[\] *$/ { print "  persistent:"; emit_client(); next }
    want != "" && !hasclient && /^  persistent:/          { print; emit_client(); next }
    { print }
' "$AGH_YAML" > "$TMP"

if [ -n "$WANT_LINE" ] && ! grep -qE "^ +(- )?name: ${CLIENT_NAME}$" "$TMP"; then
    log "❌ yaml 裡找不到 clients.persistent，無法建立 ${CLIENT_NAME}，不改"
    rm -f "$TMP"; exit 1
fi

CHK_WD=/tmp/agh-dbr-chk.$$
mkdir -p "$CHK_WD"
if ! "$AGH_BIN" --check-config -c "$TMP" -w "$CHK_WD" --no-check-update >/dev/null 2>&1; then
    log "❌ 新 yaml 未通過 --check-config，不改"
    rm -rf "$TMP" "$CHK_WD"; exit 1
fi
rm -rf "$CHK_WD"

OWNER=$(stat -c '%U:%G' "$AGH_YAML" 2>/dev/null)
RUNNING=0
pidof AdGuardHome >/dev/null 2>&1 && RUNNING=1
# 先停再換檔：避免 AGH 執行中(例如 UI 存檔)同時寫 yaml 造成互蓋
[ "$RUNNING" -eq 1 ] && [ "$NO_RESTART" -eq 0 ] && /etc/init.d/adguardhome stop >/dev/null 2>&1
cat "$TMP" > "$AGH_YAML"
rm -f "$TMP"
[ -n "$OWNER" ] && chown "$OWNER" "$AGH_YAML" 2>/dev/null
chmod 600 "$AGH_YAML" 2>/dev/null
[ "$RUNNING" -eq 1 ] && [ "$NO_RESTART" -eq 0 ] && /etc/init.d/adguardhome start >/dev/null 2>&1

_n=$(printf '%s' "$DOMS" | tr '/' '\n' | grep -c .)
if [ -n "$WANT_LINE" ]; then
    log "✅ AGH DBR 網域改走 dnsmasq: ${_n} 個網域(client ${CLIENT_NAME}: $([ "$HAS_CLIENT" -eq 1 ] && echo 既有 || echo 新建))"
else
    log "✅ 已移除 AGH DBR 網域規則(沒有 DBR 網域)"
fi
exit 0
