#!/bin/sh
# partman/early_command of preseed.cfg (busybox sh of the Debian installer). Chooses the disk the
# installer wipes: the first internal disk that is not the installation media. Removable disks
# (USB sticks, card readers) are never chosen. Without a candidate nothing is preseeded, and the
# installer asks which disk to use.
set -u

# /cdrom is mounted from the media: /dev/sdb1 (USB stick), /dev/sr0 (DVD), /dev/nvme0n1p1...
media=$(awk '$2 == "/cdrom" { print $1; exit }' /proc/mounts)
case "$media" in
    /dev/nvme*|/dev/mmcblk*|/dev/loop*) media_disk=${media%p[0-9]*} ;;
    *) media_disk=$(echo "$media" | sed 's/[0-9]*$//') ;;
esac

disk=
for candidate in $(list-devices disk); do
    name=${candidate#/dev/}
    [ "$candidate" = "$media_disk" ] && continue
    [ "$(cat "/sys/block/$name/removable" 2>/dev/null)" = 1 ] && continue
    [ "$(cat "/sys/block/$name/size" 2>/dev/null || echo 0)" -gt 0 ] || continue
    disk=$candidate
    break
done

logger -t maui-pick-disk "media $media ($media_disk), disk chosen: ${disk:-none}"
[ -n "$disk" ] || exit 0
debconf-set partman-auto/disk "$disk"
debconf-set grub-installer/bootdev "$disk"
