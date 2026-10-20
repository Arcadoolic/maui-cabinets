#!/usr/bin/env bash
# just iso: a Debian 13 netinst ISO that installs a MAUI cabinet with no questions asked.
# The installer reads preseed.cfg (iso/preseed.cfg.in), wipes the first internal disk, copies
# this playbook to /opt/maui-cabinets, and the first boot runs cabinet.yml on the machine.
# Every .deb the playbook installs (MAME and its dependencies, X, the system packages) is in the
# ISO, as a local apt repository: the cabinet downloads none of them.
#
# Runs in a debian:trixie container (podman or docker): its apt resolves the packages exactly as
# the cabinet's will. Passwords are asked, or read from MAUI_ROOT_PASSWORD and
# MAUI_KIOSK_PASSWORD; only their SHA-512 hashes go into the ISO.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
maui_version=$(sed -n 's/^ *maui_version: *"\(.*\)"/\1/p' "$repo/cabinet.yml")
# The x86_64 MAME packages (group_vars/x86_64.yml), in install order.
mame_debs=$(sed -n 's/^ *- file: *//p' "$repo/group_vars/x86_64.yml")

usage() {
    cat << EOF
Usage: just iso [options]

  --source ISO        Debian 13 amd64 netinst ISO (default: the newest
                      debian-13.*-amd64-netinst.iso in your Downloads folder)
  --output ISO        default: build/maui-cabinet-$maui_version-<debian iso name>
  --user NAME         kiosk account (default: pacman)
  --hostname NAME     machine name (default: arcade-<end of its MAC address>, one ISO for all)
  --ssh-key FILE      public key put in the kiosk account (default: ~/.ssh/id_ed25519.pub or
                      ~/.ssh/id_rsa.pub when present), --no-ssh-key for none
  --sound CARD,DEV    ALSA output, e.g. PCH,3 (default: detected at the first boot, the HDMI
                      port a screen is plugged in)
  --locale LOCALE     default: fr_FR.UTF-8
  --keymap KEYMAP     default: fr
  --timezone ZONE     default: Europe/Paris
EOF
}

downloads=$(xdg-user-dir DOWNLOAD 2> /dev/null || echo "$HOME/Downloads")
source_iso=$(ls -1 "$downloads"/debian-13.*-amd64-netinst.iso 2> /dev/null | sort -V | tail -n 1 || true)
output=""
kiosk_user=pacman
hostname=""
ssh_key=""
for key in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    [ -f "$key" ] && { ssh_key=$key; break; }
done
sound=""
locale=fr_FR.UTF-8
keymap=fr
timezone=Europe/Paris
inside=false

while [ $# -gt 0 ]; do
    case "$1" in
        --source) source_iso=$2; shift ;;
        --output) output=$2; shift ;;
        --user) kiosk_user=$2; shift ;;
        --hostname) hostname=$2; shift ;;
        --ssh-key) ssh_key=$2; shift ;;
        --no-ssh-key) ssh_key="" ;;
        --sound) sound=$2; shift ;;
        --locale) locale=$2; shift ;;
        --keymap) keymap=$2; shift ;;
        --timezone) timezone=$2; shift ;;
        --inside) inside=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown option $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

fail() { echo "error: $*" >&2; exit 1; }

# --- Checks and passwords (on the workstation) -------------------------------------------------
if ! $inside; then
    [ -n "$source_iso" ] && [ -f "$source_iso" ] \
        || fail "no Debian 13 netinst ISO found, download debian-13.*-amd64-netinst.iso and pass --source"
    [[ $(basename "$source_iso") == debian-13.*-amd64-netinst.iso ]] \
        || fail "$source_iso is not a Debian 13 amd64 netinst ISO (the playbook expects Debian 13 x86_64)"
    [[ $kiosk_user =~ ^[a-z][a-z0-9-]*$ ]] || fail "--user must be a lowercase account name, got '$kiosk_user'"
    [ -z "$hostname" ] || [[ $hostname =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "--hostname must be a host name, got '$hostname'"
    [ -z "$sound" ] || [[ $sound =~ ^[A-Za-z0-9_]+,[0-9]+$ ]] || fail "--sound must be CARD,DEVICE (e.g. PCH,3), got '$sound'"
    [ -z "$ssh_key" ] || [ -f "$ssh_key" ] || fail "no SSH key $ssh_key"
    for deb in $mame_debs; do
        [ -f "$repo/files/$deb" ] || fail "no files/$deb: run just fetch-mame first"
    done
    [ -n "$output" ] || output=$repo/build/maui-cabinet-$maui_version-$(basename "$source_iso")

    ask_password() { # variable, label
        local first second
        [ -n "${!1:-}" ] && return
        [ -t 0 ] || fail "no terminal to ask the passwords: run just iso in a terminal, or set $1"
        read -rsp "$2: " first; echo
        read -rsp "$2 (again): " second; echo
        [ -n "$first" ] || fail "empty password"
        [ "$first" = "$second" ] || fail "the two passwords differ"
        export "$1=$first"
    }
    echo "The ISO installs Debian with these passwords (only their hashes are stored in it)."
    ask_password MAUI_ROOT_PASSWORD "Root password"
    ask_password MAUI_KIOSK_PASSWORD "Password of the kiosk account '$kiosk_user'"
    export MAUI_ROOT_PASSWORD MAUI_KIOSK_PASSWORD

    mkdir -p "$(dirname "$output")"
    output=$(cd "$(dirname "$output")" && pwd)/$(basename "$output")
    source_iso=$(cd "$(dirname "$source_iso")" && pwd)/$(basename "$source_iso")
    [ -z "$ssh_key" ] || ssh_key=$(cd "$(dirname "$ssh_key")" && pwd)/$(basename "$ssh_key")

    args=(--user "$kiosk_user" --locale "$locale" --keymap "$keymap" --timezone "$timezone")
    [ -z "$hostname" ] || args+=(--hostname "$hostname")
    [ -z "$sound" ] || args+=(--sound "$sound")

    runtime=$(command -v podman || command -v docker || true)
    [ -n "$runtime" ] || fail "podman or docker is needed (the build runs in a debian:trixie container)"
    echo "Building in a debian:trixie container ($(basename "$runtime"))."
    mounts=(-v "$repo:/src:ro,z" -v "$source_iso:/in/source.iso:ro,z" -v "$(dirname "$output"):/out:z")
    [ -z "$ssh_key" ] || mounts+=(-v "$ssh_key:/in/ssh-key.pub:ro,z")
    exec "$runtime" run --rm "${mounts[@]}" -e MAUI_ROOT_PASSWORD -e MAUI_KIOSK_PASSWORD \
        -e MAUI_SHOWN_OUTPUT="$output" -e MAUI_SHOWN_SSH_KEY="$ssh_key" \
        docker.io/library/debian:trixie-slim bash -euo pipefail -c '
            export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq --no-install-recommends xorriso openssl python3-yaml apt-utils > /dev/null
            exec /src/scripts/build_iso.sh --inside "$@"' build \
        --source /in/source.iso --output "/out/$(basename "$output")" \
        ${ssh_key:+--ssh-key /in/ssh-key.pub} "${args[@]}"
fi

# --- Build (in the container) ------------------------------------------------------------------
stage=$(mktemp -d)
# apt downloads as the _apt user: it must reach the repository folder.
chmod 0755 "$stage"
trap 'rm -rf "$stage"' EXIT

extract() {
    xorriso -osirrox on -indev "$source_iso" -extract "$1" "$stage$1" 2> /dev/null \
        || fail "no $1 in $source_iso"
    chmod u+w "$stage$1"
}
extract /boot/grub/grub.cfg
extract /isolinux/menu.cfg
extract /isolinux/gtk.cfg
extract /isolinux/spkgtk.cfg
extract /md5sum.txt

# Hashes only: the plain passwords never reach the ISO.
root_hash=$(openssl passwd -6 -stdin <<< "$MAUI_ROOT_PASSWORD")
kiosk_hash=$(openssl passwd -6 -stdin <<< "$MAUI_KIOSK_PASSWORD")
sed_escape() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }
sed -e "s|@LOCALE@|$(sed_escape "$locale")|" \
    -e "s|@KEYMAP@|$(sed_escape "$keymap")|" \
    -e "s|@TIMEZONE@|$(sed_escape "$timezone")|" \
    -e "s|@KIOSK_USER@|$kiosk_user|" \
    -e "s|@ROOT_PASSWORD_HASH@|$(sed_escape "$root_hash")|" \
    -e "s|@KIOSK_PASSWORD_HASH@|$(sed_escape "$kiosk_hash")|" \
    "$repo/iso/preseed.cfg.in" > "$stage/preseed.cfg"
! grep -q '@[A-Z_]*@' "$stage/preseed.cfg" || fail "unfilled value in preseed.cfg"

# /maui on the ISO: the installer's scripts, the playbook (what cabinet.yml needs, no inventory),
# the build settings and the SSH key.
mkdir -p "$stage/maui/cabinets"
cp "$repo/iso/pick-disk.sh" "$repo/iso/late-install.sh" "$stage/maui/"
cp -R "$repo/cabinet.yml" "$repo/ansible.cfg" "$repo/requirements.txt" "$repo/requirements.yml" \
    "$repo/group_vars" "$repo/templates" "$repo/iso" "$stage/maui/cabinets/"

# /maui/debs: local apt repository with the MAME packages and every package apt would download
# for them and the playbook's system_packages, recommends included as on the cabinet. This
# container is a minimal Debian 13 with the cabinet's sources: what it lacks, the cabinet lacks.
echo "Downloading the packages of the cabinet into the ISO"
debs=$stage/maui/debs
mkdir -p "$debs/partial"
system_packages=$(python3 -c 'import sys, yaml
play = yaml.safe_load(open(sys.argv[1]))[1]
print(" ".join(play["vars"]["system_packages"]))' "$repo/cabinet.yml")
local_debs=()
for deb in $mame_debs; do
    cp "$repo/files/$deb" "$debs/"
    local_debs+=("$debs/$deb")
done
# shellcheck disable=SC2086 # one word per package
apt-get install -y -qq --download-only -o Dir::Cache::archives="$debs" "${local_debs[@]}" $system_packages > /dev/null
rm -rf "$debs/partial" "$debs/lock"
(cd "$debs" && apt-ftparchive packages . > Packages \
    && apt-ftparchive -o APT::FTPArchive::Release::Origin=maui-iso -o APT::FTPArchive::Release::Label=maui-iso release . > Release)
echo "  $(ls "$debs"/*.deb | wc -l) packages, $(du -sh "$debs" | cut -f1)"

cat > "$stage/maui/build.env" << EOF
# Settings of just iso (scripts/build_iso.sh), read by iso/late-install.sh and iso/maui-firstboot.sh.
MAUI_KIOSK_USER=$kiosk_user
MAUI_HOSTNAME=$hostname
MAUI_SOUND=$sound
MAUI_MAME_DEBS="$(echo $mame_debs)"
EOF
[ -z "$ssh_key" ] || cp "$ssh_key" "$stage/maui/authorized_keys"

# Boot menus: the automated install first and selected, never started without a key press (a
# cabinet that boots the stick again must not reinstall itself).
boot_args="auto=true priority=critical preseed/file=/cdrom/preseed.cfg locale=$locale keymap=$keymap vga=788"
label="MAUI cabinet - ERASES the internal disk"
awk -v label="$label" -v args="$boot_args" '
    /^menuentry --hotkey=g / && !done {
        print "menuentry --hotkey=m \x27" label "\x27 {"
        print "    set background_color=black"
        print "    linux    /install.amd/vmlinuz " args " --- quiet"
        print "    initrd   /install.amd/initrd.gz"
        print "}"
        done = 1
    }
    { print }' "$stage/boot/grub/grub.cfg" > "$stage/grub.cfg.new"
mv "$stage/grub.cfg.new" "$stage/boot/grub/grub.cfg"
grep -q 'preseed/file' "$stage/boot/grub/grub.cfg" || fail "could not add the GRUB menu entry"

sed -i '/menu default/d' "$stage/isolinux/gtk.cfg"
# Debian starts the speech synthesis install after 30 s without a key press: removed, the menu waits.
sed -i '/^timeout /d; /^ontimeout /d; /^menu autoboot /d' "$stage/isolinux/spkgtk.cfg"
awk -v label="$label" -v args="$boot_args" '
    /^include gtk.cfg/ && !done {
        print "label maui"
        print "\tmenu label ^" label
        print "\tmenu default"
        print "\tkernel /install.amd/vmlinuz"
        print "\tappend initrd=/install.amd/initrd.gz " args " --- quiet"
        done = 1
    }
    { print }' "$stage/isolinux/menu.cfg" > "$stage/menu.cfg.new"
mv "$stage/menu.cfg.new" "$stage/isolinux/menu.cfg"
grep -q 'preseed/file' "$stage/isolinux/menu.cfg" || fail "could not add the isolinux menu entry"

# md5sum.txt (the installer's integrity check): new digest of grub.cfg, plus the new files.
grub_md5=$(md5sum < "$stage/boot/grub/grub.cfg" | cut -d' ' -f1)
sed -i "s|^[0-9a-f]*  \./boot/grub/grub\.cfg$|$grub_md5  ./boot/grub/grub.cfg|" "$stage/md5sum.txt"
(cd "$stage" && find preseed.cfg maui -type f | sort | while read -r f; do md5sum "$f" | sed 's|  |  ./|'; done) \
    >> "$stage/md5sum.txt"

rm -f "$output"
xorriso -indev "$source_iso" -outdev "$output" \
    -map "$stage/preseed.cfg" /preseed.cfg \
    -map "$stage/maui" /maui \
    -map "$stage/boot/grub/grub.cfg" /boot/grub/grub.cfg \
    -map "$stage/isolinux/menu.cfg" /isolinux/menu.cfg \
    -map "$stage/isolinux/gtk.cfg" /isolinux/gtk.cfg \
    -map "$stage/isolinux/spkgtk.cfg" /isolinux/spkgtk.cfg \
    -map "$stage/md5sum.txt" /md5sum.txt \
    -boot_image any replay 2>&1 | grep -E '^(xorriso : (FAILURE|SORRY)|Writing to)' || true
[ -s "$output" ] || fail "xorriso wrote no ISO"
chmod 0644 "$output"

echo
shown_key=${MAUI_SHOWN_SSH_KEY-$ssh_key}
echo "ISO ready: ${MAUI_SHOWN_OUTPUT:-$output}"
echo "  kiosk account $kiosk_user, machine name ${hostname:-arcade-<end of its MAC address>}," \
    "sound ${sound:-detected at the first boot}, SSH key ${shown_key:-none}"
echo "  Write it as is to a USB stick (dd, Raspberry Pi Imager, balenaEtcher), boot the cabinet on"
echo "  it with an Ethernet cable, choose 'MAUI cabinet'. It holds the password hashes:"
echo "  keep it to yourself."
