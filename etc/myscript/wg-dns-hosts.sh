#!/bin/sh
# wg-dns-hosts.sh - 用 .mesh_upstream_dns 解析 WireGuard peer 的 endpoint_host，
# 成功就寫入 /etc/hosts (避免啟動時 DNS 雞生蛋)。
# 排程用，每次重寫自己加的區塊，標記 "# WG-DNS" 方便辨識。

HOSTS_FILE=/etc/hosts
DNS_LIST=/etc/myscript/.mesh_upstream_dns
TAG="# WG-DNS"
LOG_TAG=wg-dns-hosts

log() { logger -t "$LOG_TAG" "$1"; }

[ -s "$DNS_LIST" ] || { log "no upstream_dns list, skip"; exit 0; }

# 從 uci network 取所有 wireguard_wg* peer 的 endpoint_host (只留非 IP 的)
HOSTS=$(uci show network 2>/dev/null \
    | awk -F'[.=]' '/\.endpoint_host=/{gsub(/'"'"'/,"",$0); sub(/.*=/,"",$0); print}' \
    | sort -u \
    | grep -vE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    | grep -vE '^[0-9a-fA-F:]+$')

[ -z "$HOSTS" ] && { log "no wg hostname endpoints, skip"; exit 0; }

# 移除舊的 WG-DNS 區塊
sed -i "/${TAG}\$/d" "$HOSTS_FILE"

UPDATED=0
for _h in $HOSTS; do
    _ip=""
    while IFS= read -r _dns; do
        [ -z "$_dns" ] && continue
        _ans=$(nslookup -timeout=3 "$_h" "$_dns" 2>/dev/null \
            | awk '/^Address/ && !/#/ {print $NF}' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
            | grep -vE '^(0\.|127\.)' \
            | head -1)
        if [ -n "$_ans" ]; then
            _ip=$_ans
            log "resolved $_h → $_ip via $_dns"
            break
        fi
    done < "$DNS_LIST"
    if [ -n "$_ip" ]; then
        echo "$_ip $_h $TAG" >> "$HOSTS_FILE"
        UPDATED=$((UPDATED + 1))
    else
        log "failed to resolve $_h (all DNS)"
    fi
done

log "updated $UPDATED hosts"
