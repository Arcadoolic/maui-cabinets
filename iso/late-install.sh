#!/bin/sh
# preseed/late_command (busybox sh of the Debian installer, the new system is in /target).
# Copies the playbook to /opt/maui-cabinets, enables the first boot service that runs it, names
# the machine and installs the workstation's SSH key.
set -eu

media=/cdrom/maui
target=/target
dest=/opt/maui-cabinets
# MAUI_KIOSK_USER, MAUI_HOSTNAME (empty: from the MAC address), MAUI_SOUND (empty: detected),
# MAUI_MAME_DEBS
. "$media/build.env"

# --- Playbook and first boot service -----------------------------------------------------------
mkdir -p "$target$dest"
cp -R "$media/cabinets/." "$target$dest/"
cp "$media/build.env" "$target$dest/iso/build.env"
# Files come from the read-only ISO 9660 image: give them ordinary permissions.
chmod -R u+w,go-w "$target$dest"
chmod 0755 "$target$dest/iso/maui-firstboot.sh"
cp "$target$dest/iso/maui-firstboot.service" "$target/etc/systemd/system/"
in-target systemctl enable maui-firstboot.service

# --- Packages of the ISO: local apt repository, preferred to the mirror ------------------------
# Same versions as the mirror's when the ISO was built: priority 600 makes apt take them from
# here. Newer ones on the mirror would win otherwise, and be downloaded. maui-firstboot.sh
# removes the repository once the playbook has run, so that later upgrades come from the mirror.
cp -R "$media/debs" "$target$dest/debs"
mkdir -p "$target$dest/files"
for deb in $MAUI_MAME_DEBS; do
    cp "$media/debs/$deb" "$target$dest/files/"
done
echo "deb [trusted=yes] file:$dest/debs ./" > "$target/etc/apt/sources.list.d/maui-iso.list"
cat > "$target/etc/apt/preferences.d/maui-iso" << EOF
Package: *
Pin: release o=maui-iso
Pin-Priority: 600
EOF

# --- Machine name: arcade-<last 4 hex digits of the wired MAC> unless one was given ------------
name=$MAUI_HOSTNAME
if [ -z "$name" ]; then
    iface=$(ip route show default | awk '{ print $5; exit }')
    mac=$(tr -d ':' < "/sys/class/net/$iface/address")
    name=arcade-$(echo "$mac" | cut -c9-12)
fi
echo "$name" > "$target/etc/hostname"
sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$name/" "$target/etc/hosts"

# --- SSH key of the workstation (just add then logs in without a password) ---------------------
if [ -s "$media/authorized_keys" ]; then
    ssh_dir=/home/$MAUI_KIOSK_USER/.ssh
    mkdir -p "$target$ssh_dir"
    cp "$media/authorized_keys" "$target$ssh_dir/authorized_keys"
    chmod 0700 "$target$ssh_dir"
    chmod 0600 "$target$ssh_dir/authorized_keys"
    in-target chown -R "$MAUI_KIOSK_USER:$MAUI_KIOSK_USER" "$ssh_dir"
fi

logger -t maui-late-install "cabinet $name prepared, MAUI and MAME are installed at the first boot"
