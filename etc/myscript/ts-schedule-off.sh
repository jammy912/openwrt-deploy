#!/bin/sh
# ts-schedule-off.sh — 定時「關」Tailscale:tailscale down(整個斷線,走 WAN)
# watchdog 的 disable gate(WantRunning=false)會擋住,不會把它救回來。
PATH=/usr/sbin:/sbin:/usr/bin:/bin; export PATH

PUSH_NAMES="${PUSH_NAMES:-admin}"
[ -f /etc/myscript/push-notify.inc ] && . /etc/myscript/push-notify.inc
notify() { command -v push_notify >/dev/null 2>&1 && push_notify "$1"; }
log() { logger -t ts-schedule "$1"; }

log "排程關機:tailscale down(LAN 改走 WAN)"
tailscale down >/dev/null 2>&1
sleep 3
OUT=$(curl -4 -sS -m 12 https://api.ipify.org 2>/dev/null)
log "排程關機完成:WantRunning=false,出口=${OUT:-未知}(走 WAN)"
notify "⚫ Tailscale 排程關閉,LAN 改走家用 WAN(出口 ${OUT:-未知})"
