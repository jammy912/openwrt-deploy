#!/bin/sh
# usb-init.inc - USB 自動初始化 + 掛載 (AGH work-dir)
# 放置位置: /etc/myscript/usb-init.inc
# 用法: rc.local 中以 `. /etc/myscript/usb-init.inc` source
# 依賴: push_notify (需先 source push_notify.inc)
# 僅用於有 USB 口的機型 (e.g. linksys,mx4200)
#
# 策略: 1) 找 label=adguard 的分區直接掛  2) 最小 ≤64GB USB 強制重新分割

_USB_PART=""
# 1) 找已初始化的 (label=adguard)
for _p in /dev/sd*1; do
    [ -b "$_p" ] || continue
    _lbl=$(block info "$_p" 2>/dev/null | sed -n 's/.*LABEL="\([^"]*\)".*/\1/p')
    if [ "$_lbl" = "adguard" ]; then
        _USB_PART="$_p"
        break
    fi
done
# 2) 沒找到 → 選最小 ≤64GB USB 強制分割 (不論是否已有分區)
if [ -z "$_USB_PART" ]; then
    _USB=""
    _MIN_SIZE=999999999
    for _dev in /sys/block/sd*; do
        _name=$(basename "$_dev")
        [ -b "/dev/$_name" ] || continue
        _sectors=$(cat "$_dev/size" 2>/dev/null)
        _sectors=${_sectors:-0}
        _gb=$((_sectors / 2 / 1024 / 1024))
        [ "$_gb" -eq 0 ] && continue
        if [ "$_gb" -le 64 ] && [ "$_sectors" -lt "$_MIN_SIZE" ]; then
            _MIN_SIZE=$_sectors
            _USB="/dev/$_name"
        fi
    done
    if [ -n "$_USB" ]; then
        _USB_GB=$((_MIN_SIZE / 2 / 1024 / 1024))
        logger -t rc.local "USB $_USB (${_USB_GB}GB) 無 adguard label，強制重新分割..."
        # 卸載可能已掛載的分區
        umount "${_USB}1" 2>/dev/null
        echo -e "o\nn\np\n1\n\n\nw" | fdisk "$_USB" >/dev/null 2>&1
        sleep 2
        if [ -b "${_USB}1" ]; then
            mkfs.ext4 -L adguard "${_USB}1" >/dev/null 2>&1
            logger -t rc.local "USB 分割完成 (${_USB}1=ext4)"
            push_notify "USB $_USB (${_USB_GB}GB) 已自動分割 (ext4)"
            _USB_PART="${_USB}1"
        fi
    fi
fi
# 掛載
if [ -n "$_USB_PART" ] && [ -b "$_USB_PART" ]; then
    mkdir -p /mnt/usb
    mount "$_USB_PART" /mnt/usb 2>/dev/null
    if grep -q " /mnt/usb " /proc/mounts; then
        chown adguardhome:adguardhome /mnt/usb 2>/dev/null
        logger -t rc.local "USB ext4 已掛載 /mnt/usb ($_USB_PART)"
        # USB → tmpfs (AGH work-dir 放 RAM，USB 只做持久備份)
        mkdir -p /tmp/agh_workdir
        if [ -d /mnt/usb/data ]; then
            cp -a /mnt/usb/data /tmp/agh_workdir/
            logger -t rc.local "AGH data 已從 USB 複製到 RAM"
        fi
        chown -R adguardhome:adguardhome /tmp/agh_workdir 2>/dev/null
        uci set adguardhome.config.work_dir='/tmp/agh_workdir'
        uci commit adguardhome 2>/dev/null
        push_notify "USB 已掛載 /mnt/usb ($_USB_PART) → AGH work-dir (RAM)"
    fi
fi
# 找不到可用 USB 時推播提醒
if ! grep -q " /mnt/usb " /proc/mounts; then
    logger -t rc.local "⚠️ 未偵測到可用 USB，AGH 將使用 NAND"
    push_notify "⚠️ 未偵測到可用 USB (≤64GB)，請插入 USB"
fi

# tmpfs work-dir 不存在時退回 NAND (USB 掛載失敗 = 沒複製 data)
_AGH_WD=$(uci get adguardhome.config.work_dir 2>/dev/null)
if [ "$_AGH_WD" = "/tmp/agh_workdir" ] && [ ! -d /tmp/agh_workdir ]; then
    logger -t rc.local "⚠️ AGH tmpfs work-dir 不存在，退回 /var/lib/adguardhome"
    push_notify "⚠️ USB 未掛載，AGH 退回 NAND"
    uci set adguardhome.config.work_dir='/var/lib/adguardhome'
    uci commit adguardhome
fi
