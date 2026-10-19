# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Ansible playbook (`cabinet.yml`) that turns a fresh Debian 13 machine (x86_64 PC or arm64 Raspberry Pi) into a MAUI arcade cabinet kiosk: Homebrew MAME, the MAUI AppImage extracted to `~/squashfs-root`, an X session autologged on tty1 (`startx` + matchbox + `AppRun`), ALSA output, the BO on port 80 and, for company cabinets, the Netskope client and a Wi-Fi profile. It is the Ansible translation of maui's `docs/RASPBERRY-PI-DEPLOY.md`: when a step changes there, change it here too. `README.md` holds the prerequisites and the deployment procedure for a person; keep it in step with the playbook.

## Commands

```
just setup             # .venv/ with requirements.txt (ansible-core) + requirements.yml collections in .ansible/collections
just add <host>        # guided: SSH key, probe of the machine, writes inventory/inventory.yml + host_vars/<host>.yml
just init              # create inventory/ from examples/inventory/ (never overwrites it)
just check <host>      # dry run: ansible-playbook cabinet.yml --limit <host> --ask-become-pass --check --diff
just apply <host>      # real run, asks for confirmation (changes the system, restarts the kiosk session)
just vault <host>      # ansible-vault create, then edit, inventory/host_vars/<host>/vault.yml
.venv/bin/ansible-playbook --syntax-check cabinet.yml
.venv/bin/ansible-inventory -i examples/inventory/inventory.yml --host arcade-pacman   # check the example
```

`check` and `apply` refuse a host missing from `inventory/inventory.yml` or without `inventory/host_vars/<host>.yml` / `inventory/host_vars/<host>/`. The recipes add `--vault-password-file inventory/.vault-pass` only when that file exists, so a clone without vaults works. Always use the virtualenv's Ansible (`.venv/bin/`), never a system-wide one: versions are pinned in `requirements.txt` / `requirements.yml`, and `ansible.cfg` reads collections from `.ansible/collections` only. Running them touches a real cabinet and asks for a password: leave that to the user unless asked.

## Layout

- `cabinet.yml` — two plays. The first installs `python3` / `python3-apt` with `raw` (a minimal Debian has neither; it runs in check mode too). The second asserts the target (Debian 13, `expected_architecture`, `kiosk_user == ansible_user`, the ALSA card exists), then installs packages, Homebrew (git clone, no `curl | bash`) and MAME, MAUI, audio, the kiosk session, the port 80 sysctl, then the optional Netskope and Wi-Fi blocks.
- `inventory/` — **the user's own cabinets, ignored by git** (it may be a plain local folder with no git history and no backup: never delete or move it). Never commit its content to this repository, never quote its hosts, tenants, MAC addresses or vault values in tracked files. `ansible.cfg` points at `inventory/inventory.yml`; Ansible loads `inventory/host_vars/` because it sits next to it.
- `examples/inventory/` — what this repository ships instead: `inventory.yml` with a sample `arcade-pacman` and `host_vars/arcade-pacman.yml`, every setting documented. A new host variable used by the playbook gets a commented line here.
- `inventory.yml` (in `inventory/` or the example) — each host once under `cabinets` (connection settings, reached by network name, not IP), then one group per axis: architecture (`x86_64` / `arm64`, mandatory), hardware (`desktop_pc` / `raspberry_pi`), OS (`debian_13`).
- `group_vars/` — `all.yml` (`kiosk_resolution`), `<arch>.yml` (`expected_architecture`, AppImage suffix and sha256), `raspberry_pi.yml` (`ansible_become_method: sudo`, root is locked on Raspberry Pi OS).
- `host_vars/<host>.yml` or `host_vars/<host>/{vars,vault}.yml` (in `inventory/` or the example) — `kiosk_user`, `alsa_hdmi_card` / `alsa_hdmi_device` (from `/proc/asound/pcm`), optional `kiosk_resolution`, `netskope_*`, `wifi_*`. Vault values are `vault_*` variables referenced from `vars.yml`; the password is in `inventory/.vault-pass`, never committed anywhere.
- `scripts/add_cabinet.py` — `just add`, for people who do not know Ansible. Runs with the venv's Python (PyYAML from ansible-core, stdlib otherwise). Asks for the address and kiosk account, `ssh-copy-id`, then one read-only SSH probe (`uname -m`, `/etc/os-release`, device-tree model or DMI, `id -nG`, `/proc/asound/{cards,pcm}`). Edits `inventory.yml` as text (`add_to_group`) to keep the user's comments, checks the result with PyYAML and `ansible-inventory --host`, and restores the previous files on failure. It must never change a declared cabinet nor anything on the machine but `authorized_keys`. A new host variable the playbook requires belongs here too (asked or detected).
- `templates/` — `xinitrc.j2`, `bash_profile.j2`, `getty-autologin.conf.j2`, `asound.conf.j2`, `sudoers-restart-kiosk.j2`, `mame-awesome-ui-config.json.j2`.

## Rules

- **Become is `su` with the root password** (`ansible.cfg`): the kiosk user has no general sudo rights. The only sudoers rule is the exact `systemctl restart/reset-failed getty@tty1` pair, which must match maui's `src/class/KioskRestart.ts`. Root reached with `su` has no `/usr/sbin` in its PATH: use absolute paths (`/usr/sbin/sysctl`, `/usr/sbin/visudo`).
- **Never replace what MAUI or the BO owns**: `~/squashfs-root` is extracted only when absent (`creates:`), and the MAUI config is templated with `force: false`. Updates of an installed cabinet go through the BO (MAUI > Update).
- **Bumping MAUI** for new cabinets: `maui_version` in `cabinet.yml` plus both `maui_appimage_sha256` in `group_vars/x86_64.yml` and `group_vars/arm64.yml`, from `gh api repos/Arcadoolic/maui/releases/tags/<version> -q '.assets[] | "\(.name) \(.digest)"'`. Update the version quoted in `README.md` too.
- **Check mode must work on a fresh machine**: tasks that need a tool apt only pretended to install are skipped with `when: not ansible_check_mode` (and say so in a comment); read-only probes use `check_mode: false` and `changed_when: false`.
- Every task is idempotent: `creates:`, `force: false`, status probes before installers (Netskope enrolment), `changed_when` on commands.
- Secrets never go in plain `host_vars` and tasks that handle them use `no_log: true`.
- Comments explain why (hardware quirk, upstream behaviour), in English, like the existing ones. Files written by `copy` start with `# Managed by Ansible (maui-cabinets, cabinet.yml)`; templates with `{{ ansible_managed }}`.
