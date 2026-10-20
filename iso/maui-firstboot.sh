#!/bin/bash
# First boot of a cabinet installed from the MAUI ISO (maui-firstboot.service): runs cabinet.yml
# on the machine itself, as `just apply` would from a workstation. Progress is shown on tty8 and
# kept in /var/log/maui-firstboot.log. On failure the service stays enabled and runs again at the
# next boot (or: systemctl start maui-firstboot); on success it disables itself.
set -euo pipefail

dir=/opt/maui-cabinets
done_flag=/var/lib/maui-cabinets/firstboot.done
log=/var/log/maui-firstboot.log
# Temporary rule: the playbook becomes root with sudo, like on a Raspberry Pi. Removed on exit,
# leaving only the kiosk-restart rule the playbook installs.
sudoers=/etc/sudoers.d/zz-maui-firstboot
# MAUI_KIOSK_USER, MAUI_SOUND
# shellcheck source=/dev/null
. "$dir/iso/build.env"
user=$MAUI_KIOSK_USER
host=$(hostname)

exec > >(tee -a "$log") 2>&1
chvt 8 2>/dev/null || true

finish() {
    local status=$?
    rm -f "$sudoers"
    if [ "$status" -ne 0 ]; then
        echo
        echo "*** The cabinet setup FAILED (see $log)."
        echo "*** It runs again at the next boot, or now: systemctl start maui-firstboot"
        echo "*** A console is on tty2 (Ctrl+Alt+F2)."
    fi
}
trap finish EXIT

step() { printf '\n=== %s\n' "$*"; }

step "MAUI cabinet setup of $host ($(date '+%F %T')): MAME and MAUI, a few minutes"

# --- Network: the MAUI release, PyPI and Ansible Galaxy (the .deb files are in the ISO) -------
step "Waiting for the Internet"
for _ in $(seq 60); do
    getent ahosts github.com > /dev/null && break
    sleep 5
done
getent ahosts github.com > /dev/null || { echo "No Internet access (github.com unknown)."; exit 1; }

# --- Ansible, same pinned versions as a workstation (just setup) -------------------------------
step "Installing Ansible in $dir/.venv"
export ANSIBLE_COLLECTIONS_PATH=$dir/.ansible/collections
python3 -m venv "$dir/.venv"
"$dir/.venv/bin/pip" install --quiet --upgrade pip
"$dir/.venv/bin/pip" install --quiet -r "$dir/requirements.txt"
"$dir/.venv/bin/ansible-galaxy" collection install -r "$dir/requirements.yml" -p "$ANSIBLE_COLLECTIONS_PATH"

# --- Sound output: the HDMI port a screen is plugged in, else the first one --------------------
# Prints "CARD DEVICE", CARD being the id the playbook expects (PCH, vc4hdmi...).
detect_sound() {
    local line num dev hdmi="" first=""
    # /proc/asound/pcm: "00-03: HDMI 0 : HDMI 0 : playback 1"
    while IFS= read -r line; do
        [[ $line == *playback* ]] || continue
        num=$((10#${line:0:2}))
        dev=$((10#${line:3:2}))
        local id
        id=$(< "/proc/asound/card$num/id")
        [ -n "$first" ] || first="$id $dev"
        [[ ${line,,} == *hdmi* ]] || continue
        [ -n "$hdmi" ] || hdmi="$id $dev"
        # Intel HDA / LPE: the jack control says whether a screen listens on this PCM. Its name
        # holds a comma: amixer needs it quoted, or it rejects the identifier.
        if amixer -c "$num" cget "iface=CARD,name='HDMI/DP,pcm=$dev Jack'" 2> /dev/null | grep -q ': values=on'; then
            echo "$id $dev"
            return
        fi
    done < /proc/asound/pcm
    echo "${hdmi:-$first}"
}

step "Choosing the sound output"
# A forced output stays put; a detected one may be wrong (screen not seen yet), so the kiosk
# session moves the sound to the screen's HDMI port (alsa_follow_screen, xinitrc.j2).
if [ -n "${MAUI_SOUND:-}" ]; then
    read -r card device <<< "${MAUI_SOUND/,/ }"
    follow=false
else
    read -r card device <<< "$(detect_sound)"
    follow=true
fi
[ -n "${card:-}" ] || { echo "No sound card found (/proc/asound/pcm is empty)."; exit 1; }
echo "ALSA card $card, device $device (change it later in /etc/asound.conf, or MAUI_SOUND in $dir/iso/build.env)"

# --- Inventory of this one cabinet, run on the machine itself ----------------------------------
step "Writing $dir/inventory/"
mkdir -p "$dir/inventory/host_vars"
cat > "$dir/inventory/inventory.yml" << EOF
# Written by iso/maui-firstboot.sh: this cabinet only, run on the machine itself.
cabinets:
  hosts:
    $host:
      ansible_user: $user
x86_64:
  hosts:
    $host:
desktop_pc:
  hosts:
    $host:
debian_13:
  hosts:
    $host:
EOF
cat > "$dir/inventory/host_vars/$host.yml" << EOF
# Written by iso/maui-firstboot.sh.
ansible_connection: local
ansible_become_method: sudo
kiosk_user: $user
alsa_hdmi_card: $card
alsa_hdmi_device: $device
alsa_follow_screen: $follow
EOF

# The ISO's repository (late-install.sh) is indexed now: the playbook's apt only updates its
# lists when they are more than an hour old, and the installer's are fresher than that.
step "Indexing the packages of the ISO"
apt-get update -qq

# --- The playbook, as the kiosk user (its tasks with become: false must run as that user) ------
step "Running cabinet.yml"
echo "$user ALL=(ALL) NOPASSWD: ALL" > "$sudoers"
chmod 0440 "$sudoers"
/usr/sbin/visudo -cf "$sudoers" > /dev/null
cd "$dir"
runuser -u "$user" -- env ANSIBLE_COLLECTIONS_PATH="$ANSIBLE_COLLECTIONS_PATH" ANSIBLE_FORCE_COLOR=1 \
    "$dir/.venv/bin/ansible-playbook" cabinet.yml --limit "$host"

# The ISO's repository has served: later upgrades come from the mirror.
rm -rf /etc/apt/sources.list.d/maui-iso.list /etc/apt/preferences.d/maui-iso "$dir/debs"
apt-get update -qq || true

mkdir -p "$(dirname "$done_flag")"
touch "$done_flag"
systemctl disable maui-firstboot.service
step "Cabinet ready: the back office answers on http://$host.local/"
sleep 5
chvt 1 2>/dev/null || true
