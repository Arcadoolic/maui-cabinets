# maui-cabinets

Ansible playbook for the dedicated MAUI arcade cabinets. `cabinet.yml` turns a fresh Debian 13
install (x86_64 or arm64) into a MAUI kiosk: MAME, the MAUI AppImage, a minimal X session that
starts on boot, sound, and the back office (BO) on port 80. It automates the steps of
[`docs/RASPBERRY-PI-DEPLOY.md`](https://github.com/Arcadoolic/maui/blob/develop/docs/RASPBERRY-PI-DEPLOY.md)
from the [maui](https://github.com/Arcadoolic/maui) repository; read that document for the
reasoning behind each step.

New cabinets get **MAUI 2.16.1** (`maui_version` in `cabinet.yml`).

## Prerequisites

### On the workstation

- Linux or macOS, with `git`, `ssh` and Python 3.12 or later with its `venv` module
  (`sudo apt install python3-venv` on Debian and Ubuntu).
- [just](https://github.com/casey/just), to run the recipes of the `justfile`
  (`sudo apt install just`, `brew install just`).
- An SSH key (`just add` offers to create one if you have none).

Ansible itself is not needed: `just setup` installs the pinned version (`requirements.txt`) and
its collections (`requirements.yml`) in the project, in `.venv/` and `.ansible/collections/`,
both ignored by git. The recipes always use that copy, never a system-wide Ansible.

### On the cabinet

- **Hardware**: an x86_64 PC (tested on Intel graphics and sound: NUC, small desktop PC) or an
  arm64 Raspberry Pi (Pi 4, Pi 3 tested). A screen, and speakers on the output you will choose
  for sound (HDMI or analog jack), plugged in before the first run: the playbook checks the
  sound card exists.
- **Operating system**: Debian 13 (trixie) netinst, 64-bit, **no desktop environment**, with
  the *SSH server* task selected. On a Raspberry Pi, Raspberry Pi OS Lite 64-bit (Debian 13
  based) does the job.
- **Accounts**:
  - the kiosk account (e.g. `pacman`), created by the installer. It autologs on the screen and
    runs MAUI. Its name is `kiosk_user` and must be the SSH user (`ansible_user`).
  - a root password, set in the installer. The kiosk account gets no general sudo rights, so
    Ansible becomes root with `su` and asks for that password on every run. Better not leave
    it empty: the Debian installer then locks root, and the cabinet has to use `sudo` with the
    kiosk account's password instead (`just add` detects it and sets it up).
    Exception: on Raspberry Pi OS root is locked, so the `raspberry_pi` group uses `sudo` and the
    password asked is the kiosk account's own.
- **Network**: the cabinet reachable from the workstation by its network name (DHCP leases
  move, so the inventory uses names, not IPs), and Internet access during the run (Debian
  mirrors for the MAME dependencies, GitHub for the MAUI release).

`python3` and `sudo` are missing on a minimal install. The first play installs `python3` and
`python3-apt` (needed by `--check`) with a raw command, the rest comes from the main play.

## Your cabinets: `inventory/`

The repository ships the playbook and an example; your own cabinets live in `inventory/`,
which git ignores:

```
maui-cabinets/
├── cabinet.yml, templates/
├── group_vars/             project settings by architecture and hardware (do not edit)
├── examples/inventory/     the example, copied by `just init`
└── inventory/              yours (just add, or just init), ignored by git
    ├── inventory.yml
    ├── host_vars/<host>.yml or host_vars/<host>/{vars,vault}.yml
    └── .vault-pass         only with vaulted settings
```

`inventory/` stays on your workstation: back it up, it may hold Wi-Fi keys and enrolment
tokens. If you want it versioned, make it a private git repository of its own.

Ansible reads `inventory/host_vars/` because it sits next to the inventory file
(`ansible.cfg`: `inventory = inventory/inventory.yml`). Change a project default, such as
`kiosk_resolution`, in `inventory/host_vars/`: Ansible gives the project's `group_vars/`
precedence over an `inventory/group_vars/`, but `host_vars` win over both.

## Deployment procedure

### 1. Prepare the workstation (once)

```bash
git clone https://github.com/Arcadoolic/maui-cabinets.git
cd maui-cabinets
just setup      # .venv/ with Ansible + the collections, MAME packages in files/; run it again after a pull
```

`just setup` ends with `just fetch-mame`: it downloads the MAME packages from the
`mame-<version>` release of this repository into `files/` (git-ignored, about 100 MB per
architecture) with the [GitHub CLI](https://cli.github.com) (`gh auth login` first), and checks
their sha256. See [MAME packages](#mame-packages).

`just` alone prints these steps.

### 2. Install the operating system

Install Debian 13 as described above (hostname e.g. `arcade-pacman`, kiosk account, root
password, SSH server, no desktop). Note the hostname and the kiosk account's name. Plug in the
screen and the speakers.

### 3. Declare the cabinet: `just add`

```bash
just add arcade-pacman
```

The recipe guides you through it, no Ansible knowledge needed:

1. it asks for the machine's network address (the hostname, `<hostname>.local` or an IP) and
   the kiosk account;
2. it copies your SSH key to the machine (asking for the account's password once), creating a
   key first if you have none;
3. it reads the rest from the machine: architecture, Raspberry Pi or PC, Debian version (and
   stops if it is not 13), whether root has a password;
4. it lists the sound outputs and asks which one the speakers are on;
5. it writes the cabinet into `inventory/inventory.yml` and `inventory/host_vars/<name>.yml`,
   checks that Ansible reads them back, and prints the next commands.

It only adds the SSH key on the machine, and never changes a cabinet already declared.

#### By hand

What `just add` writes, if you prefer to do it yourself. Start from the example with
`just init`, which copies `examples/inventory/` to `inventory/`.

Give the workstation SSH access:

```bash
ssh-copy-id pacman@arcade-pacman        # or <user>@<hostname>.local over mDNS
ssh pacman@arcade-pacman true           # must log in without a password prompt
```

Find the sound output: over SSH, list the outputs and keep the card and device of the one
wired to the speakers:

```bash
cat /proc/asound/pcm
# 00-03: HDMI 0 : HDMI 0 : playback 1   -> card PCH, device 3 (Intel HDMI)
# 00-00: CX20641 Analog : ...           -> card PCH, device 0 (analog jack)
# 01-00: MAI PCM i2s-hifi-0 : ...       -> card vc4hdmi, device 0 (Raspberry Pi HDMI)
ls /proc/asound                         # card names (PCH, vc4hdmi, ...)
```

In `inventory/inventory.yml`, declare the host once in `cabinets` (connection settings), then
tag it with one group per axis:

| Axis | Groups | What it picks |
|---|---|---|
| Architecture (**mandatory**) | `x86_64`, `arm64` | AppImage flavour and its sha256 (`group_vars/<arch>.yml`) |
| Hardware | `desktop_pc`, `raspberry_pi` | `raspberry_pi`: become with `sudo` instead of `su` |
| Operating system | `debian_13` | package names |

```yaml
cabinets:
  hosts:
    arcade-pacman: # what the machine is
      ansible_user: pacman
x86_64:
  hosts:
    arcade-pacman:
desktop_pc:
  hosts:
    arcade-pacman:
debian_13:
  hosts:
    arcade-pacman:
```

Then create `inventory/host_vars/<name>.yml` (or an `inventory/host_vars/<name>/` directory
when it has secrets, see [Secrets](#secrets-ansible-vault)):

```yaml
# Account that autologs on tty1 and runs the kiosk session.
kiosk_user: pacman

# ALSA device of the sound output (cat /proc/asound/pcm).
alsa_hdmi_card: PCH
alsa_hdmi_device: 3

# Optional: display mode of the kiosk session (see Screen resolution).
# kiosk_resolution: "1920x1080"

# Only on a PC whose root has no password (left empty at install): become with sudo.
# ansible_become_method: sudo
```

### 4. Dry run, then real run

```bash
just check arcade-pacman # dry run (--check --diff), asks for the become password
just apply arcade-pacman # real run, asks for confirmation, then the become password
```

On a first dry run, the MAME and Wi-Fi steps are skipped: the packages and tools they rely on
are not on the cabinet yet. The real run takes a few minutes: MAME is copied from `files/`, its
dependencies (SDL2, Qt...) come from the Debian mirror. It is safe to run again: every step
checks the current state first.

### 5. After the first run

The kiosk session restarts at the end of the run and MAUI shows up on the screen, with its
setup guide. The screen shows the back office address, `http://<address of the cabinet>`.
Open it from any machine on the network and follow the guide: BO account, MAME path (already
filled in), MAME plugins, ONLINE configuration, conf pack, starter pack (ROMs).

Then check the sound:

```bash
aplay /usr/share/sounds/alsa/Front_Center.wav   # sound on the chosen output
```

On Intel, when the output set in `host_vars` is an HDMI port, each kiosk session moves the
sound to the HDMI port a screen is plugged in (`~/.asoundrc`, written by `~/.xinitrc`); with no
screen detected `/etc/asound.conf` applies. `alsa_follow_screen: false` in `host_vars` keeps
the configured output, e.g. speakers on another HDMI port than the screen.

A screen switched on after the kiosk session started gets its picture within 3 seconds:
`~/.xinitrc` watches the outputs and lights up a connected one when none is.

Intel HDA sometimes boots with the HDMI output (`IEC958`) muted: `alsamixer -c PCH`, unmute,
then `su -c "alsactl store"` to keep it.

A rescue console stays on tty2 (Ctrl+Alt+F2) if the kiosk session does not come up.

## Without a workstation: the installation ISO (`just iso`, x86_64 PC only)

`just iso` turns the Debian 13 netinst ISO into a USB installer that does steps 2 to 4 by
itself: it installs Debian with no questions, then the first boot runs `cabinet.yml` on the
cabinet itself. Needs `podman` or `docker` (the build runs in a `debian:trixie` container) and
the x86_64 MAME packages in `files/` (`just fetch-mame`).

```bash
just iso                        # asks for the root and kiosk passwords
just iso --hostname arcade-pacman --sound PCH,3
just iso --help                 # every option
```

By default it takes the newest `debian-13.*-amd64-netinst.iso` of your Downloads folder and
writes `build/maui-cabinet-<MAUI version>-<Debian ISO name>` (git-ignored). The ISO holds:

- `preseed.cfg` (from `iso/preseed.cfg.in`): language `fr_FR.UTF-8`, keyboard `fr`, time zone
  `Europe/Paris` (`--locale`, `--keymap`, `--timezone`), wired DHCP, the root password and the
  kiosk account `pacman` (`--user`) without sudo, SSH server, no desktop. Only the passwords'
  SHA-512 hashes are stored, still: keep the ISO to yourself.
- every `.deb` the playbook installs: the MAME packages and all the packages apt would
  download for them and for the playbook (X, Qt, SDL2, Mesa...), about 360 packages and 300 MB,
  as a local apt repository. The ISO weighs about 1.1 GB, and the cabinet downloads no `.deb`.
- the playbook, without any inventory, and your SSH public key (`~/.ssh/id_ed25519.pub` by
  default, `--ssh-key FILE`, `--no-ssh-key`), so `just add` can reach the cabinet afterwards.

Write the ISO as is to a USB stick or SD card (`dd`, Raspberry Pi Imager, balenaEtcher), plug
the cabinet into Ethernet, the screen and the speakers, and boot on the stick. Choose
**MAUI cabinet - ERASES the internal disk**: the menu waits for that key press, so a cabinet
that boots on the stick again never reinstalls itself.

- **Disk**: the first internal disk is wiped without asking (`iso/pick-disk.sh`): never the
  stick itself nor a removable disk. With no candidate the installer asks.
- **Name**: `arcade-<last 4 hex digits of the wired MAC address>` (`--hostname` to fix it), so
  one ISO serves every cabinet. It answers as `<name>.local` (avahi).
- **First boot** (`maui-firstboot.service`, `iso/maui-firstboot.sh`, about a minute): shown
  on tty8 and logged in `/var/log/maui-firstboot.log`. It still needs the Internet for the MAUI
  AppImage (GitHub), Ansible (PyPI) and its collection (Galaxy). It installs the pinned Ansible in
  `/opt/maui-cabinets/.venv`, picks the sound output (the HDMI port a screen is plugged in,
  else the first output, then followed by each session; `--sound CARD,DEVICE` to force it), writes the one-cabinet inventory
  `/opt/maui-cabinets/inventory/`, then runs `cabinet.yml` locally as the kiosk account, with a
  temporary sudo rule removed at the end, as is the ISO's apt repository (later upgrades come
  from the mirror). On failure (no Internet...) it runs again at the
  next boot, or with `systemctl start maui-firstboot`. Then MAUI shows its setup guide (step 5).

Later runs go through the workstation as usual: `just add <name>`, `just apply <name>`.

## Updating MAUI

Once installed, a cabinet updates MAUI from its BO (MAUI > Update); the playbook never replaces
an existing installation. To make **new** cabinets start on a newer release, change
`maui_version` in `cabinet.yml` and the two `maui_appimage_sha256` in `group_vars/x86_64.yml`
and `group_vars/arm64.yml`, with the digests of the release:

```bash
gh api repos/Arcadoolic/maui/releases/tags/<version> -q '.assets[] | "\(.name) \(.digest)"'
```

## What depends on the target

| Topic | Raspberry Pi (arm64) | x86_64 PC |
|---|---|---|
| MAME | `mame_0.289-1_arm64.deb` (upstream build) | `mame` + `mame-data` 0.289 (Debian sid, rebuilt for trixie) |
| AppImage | `-linux-arm64`, sha256 checked | `-linux-x86_64`, sha256 checked |
| Sound | `hw:vc4hdmi,0` (HDMI) | `hw:PCH,3` (Intel HDMI) or `hw:PCH,0` (jack), set in `host_vars` |
| GPU | vc4 | Intel, `libgl1-mesa-dri` + `render` group |
| Root | locked, `sudo` with the kiosk password | `su` with the root password |

## MAME packages

MAME is installed from `.deb` packages, listed per architecture with their sha256 in
`mame_debs` (`group_vars/x86_64.yml`, `group_vars/arm64.yml`): `/usr/games/mame`, plugins in
`/usr/share/games/mame/plugins`, the user's MAME folder `~/.mame`. ROMs, samples and artwork go to
`~/mame/roms`, `~/mame/samples`... (created by the playbook: they come first in Debian's `mame.ini`,
before folders of `/usr/local` and `/usr/share` that the kiosk user cannot write). Debian 13 only ships MAME
0.276, so:

- **x86_64**: Debian sid's `mame` and `mame-data` source, rebuilt on Debian 13 with
  `just build-mame` (about 20 minutes on 16 cores, in a `debian:trixie` container). The binary of sid itself
  cannot be used: it needs sid's libc6 and Qt, and would pull 300 packages from sid.
- **arm64**: an upstream `mame0289` build in a single package with the same layout.

A new MAME version: build the packages, publish them as a `mame-<version>` release
(`gh release create mame-<version> files/<packages>`), then update `mame_release`
(`group_vars/all.yml`) and `mame_debs` (file names and `sha256sum`).

Cabinets installed with Homebrew before keep it: their MAUI config still points at the
Homebrew MAME (the playbook never overwrites it). To switch, set the MAME folder to
`/usr/games` and the plugins folder to `/usr/share/games/mame/plugins` in the BO (MAME tab);
`/home/linuxbrew` can then be removed.

## Screen resolution

`.xinitrc` forces the display to `kiosk_resolution` (default `1920x1080`, set in
`group_vars/all.yml`) with `xrandr` on the first connected output, so a 4K screen does not run
Electron and MAME at its native 3840x2160. MAME fullscreen follows the desktop mode.
Override it in `inventory/host_vars/<name>.yml`; an empty string keeps the screen's native
mode. If the screen does not offer the requested mode, the native one is kept. The tty console
is not affected. Check the active mode (marked `*`) over SSH with `DISPLAY=:0 xrandr --query`.

## What the playbook leaves alone

- `~/squashfs-root` is extracted only when absent. Later versions are installed from
  the BO (MAUI > Update), the playbook never replaces them.
- `~/.mame-awesome-ui/mame-awesome-ui-config.json` is written only when absent, so settings
  made in the BO survive a re-run.

## Secrets (Ansible Vault)

Passwords and tokens (Wi-Fi key, enrolment tokens) never go in plain text. They live in an
encrypted file per cabinet, `inventory/host_vars/<name>/vault.yml`, unlocked by one password
kept in `inventory/.vault-pass`. Only a cabinet that has secrets needs this.

**1. Create the vault password**, once for all your cabinets. Keep a copy of it somewhere
safe (a password manager): without it the vaults cannot be read back.

```bash
openssl rand -base64 32 > inventory/.vault-pass
chmod 600 inventory/.vault-pass
```

**2. Turn the cabinet's settings file into a directory**: Ansible reads every file of
`host_vars/<name>/`.

```bash
mkdir inventory/host_vars/arcade-pacman
mv inventory/host_vars/arcade-pacman.yml inventory/host_vars/arcade-pacman/vars.yml
```

**3. Write the secrets in the vault**. `just vault` creates it on first use, then edits it;
your `$EDITOR` opens the decrypted content and the file is encrypted again on save.

```bash
just vault arcade-pacman
```

```yaml
# inventory/host_vars/arcade-pacman/vault.yml, as shown in the editor
vault_wifi_psk: "the Wi-Fi key"
```

**4. Refer to them from `vars.yml`**, by name. Keeping the `vault_` prefix shows where a value
comes from, and `vars.yml` stays readable without the password.

```yaml
# inventory/host_vars/arcade-pacman/vars.yml
wifi_psk: "{{ vault_wifi_psk }}"
```

`just check` and `just apply` unlock the vaults with `inventory/.vault-pass` when that file
exists. Other commands, from the virtualenv:

```bash
.venv/bin/ansible-vault view --vault-password-file inventory/.vault-pass inventory/host_vars/arcade-pacman/vault.yml
.venv/bin/ansible-vault rekey --vault-password-file inventory/.vault-pass inventory/host_vars/*/vault.yml  # change the password
```

## Company network (optional)

Two blocks of the playbook only run on the hosts that define their variables:

- `netskope_tenant_host`: installs the Netskope client and enrols the cabinet in the tenant,
  by email (`netskope_enroll_email`), with three values of the tenant to keep in the vault:
  `netskope_org_key`, `netskope_enroll_auth_token`, `netskope_enroll_encryption_token`. The installer runs once; the `stagentd` service it sets up
  starts at every boot. Check with `/opt/netskope/stagent/nsdiag -f`.
- `wifi_ssid`: declares the Wi-Fi network in NetworkManager on `wifi_interface`, with
  `wifi_psk` if it has a key. The real MAC address of the interface is always used, for
  networks that filter on it. The network need not be in range when the playbook runs.

## Back office address

The cabinet's screen shows where its back office is: `http://<address of the cabinet>`, on
port 80. The playbook lets the kiosk user open that port (`net.ipv4.ip_unprivileged_port_start`
in `/etc/sysctl.d/`); port 3131 keeps answering as before.
