#!/bin/sh
# 定期將 AGH tmpfs work-dir 同步回 USB
# cron: 0 * * * * /etc/myscript/sync-agh-usb.sh

[ -d /tmp/agh_workdir/data ] || exit 0
grep -q " /mnt/usb " /proc/mounts || exit 0

rsync -a --delete /tmp/agh_workdir/data/ /mnt/usb/data/ 2>/dev/null
logger -t agh-sync "RAM → USB 同步完成"
