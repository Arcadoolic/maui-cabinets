"""Guided declaration of a new cabinet (just add <host>).

Asks for the cabinet's network address and kiosk account, sets up SSH key access, reads the
rest from the machine itself (architecture, Raspberry Pi or PC, Debian version, sound outputs)
and writes inventory/inventory.yml and inventory/host_vars/<host>.yml. Never touches a cabinet
that is already declared, and changes nothing on the machine besides adding the SSH key.

Run with the virtualenv's Python (PyYAML comes with ansible-core).
"""

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

HOST_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
USER_RE = re.compile(r"^[a-z_][a-z0-9_-]*$")

# Skeleton written when inventory/ does not exist yet: the groups cabinet.yml relies on, no host.
EMPTY_INVENTORY = """\
# Your cabinets, written by `just add <host>` (or by hand, see examples/inventory/).
# Every cabinet is declared once in `cabinets` (connection settings), then tagged with one
# group per axis below: architecture, hardware, operating system.
cabinets:
  hosts:

# --- Architecture (AppImage flavour), mandatory --------------------------------------------
x86_64:
  hosts:
arm64:
  hosts:

# --- Hardware (raspberry_pi: root is locked, become with sudo) -----------------------------
desktop_pc:
  hosts:
raspberry_pi:
  hosts:

# --- Operating system (package names) ------------------------------------------------------
debian_13:
  hosts:
"""

# What the machine reports, separated by markers. Read-only, no root needed.
PROBE = r"""
echo '--arch'; uname -m
echo '--os'; . /etc/os-release; echo "$ID $VERSION_ID"
echo '--model'; tr -d '\0' < /proc/device-tree/model 2>/dev/null \
  || echo "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
echo '--groups'; id -nG
echo '--cards'; cat /proc/asound/cards 2>/dev/null
echo '--pcm'; cat /proc/asound/pcm 2>/dev/null
"""


def say(text=""):
    print(text, flush=True)


def fail(text):
    print(f"\nerror: {text}", file=sys.stderr, flush=True)
    sys.exit(1)


def ask(question, default=None, check=None, hint=""):
    """Asks until the answer passes `check` (a regex); Enter keeps the default."""
    suffix = f" [{default}]" if default else ""
    while True:
        try:
            answer = input(f"{question}{suffix}: ").strip()
        except EOFError:
            fail("no answer, stopped.")
        answer = answer or (default or "")
        if answer and (check is None or check.match(answer)):
            return answer
        say(f"  {hint or 'Please answer.'}")


def confirm(question, default=True):
    answer = ask(f"{question} ({'Y/n' if default else 'y/N'})", check=re.compile(r"^(y|yes|n|no|)$", re.I),
                 default="y" if default else "n", hint="Answer y or n.")
    return answer.lower().startswith("y")


def ssh(target, command, batch=True):
    options = ["-o", "ConnectTimeout=10"]
    if batch:
        options += ["-o", "BatchMode=yes"]
    return subprocess.run(["ssh", *options, target, command], capture_output=True, text=True)


def sections(output):
    """Splits the probe output on its '--name' markers."""
    parts, name = {}, None
    for line in output.splitlines():
        if line.startswith("--") and line[2:].isalpha():
            name = line[2:]
            parts[name] = []
        elif name:
            parts[name].append(line)
    return {key: "\n".join(lines).strip() for key, lines in parts.items()}


def sound_outputs(cards, pcm):
    """Playback devices as (card id, device number, description), e.g. ('PCH', 3, 'HDMI 0')."""
    # /proc/asound/cards: " 0 [PCH            ]: HDA-Intel - HDA Intel PCH"
    card_ids = {int(m[1]): m[2] for m in re.finditer(r"^\s*(\d+)\s+\[(\S+)\s*\]", cards, re.M)}
    outputs = []
    # /proc/asound/pcm: "00-03: HDMI 0 : HDMI 0 : playback 1"
    for line in pcm.splitlines():
        match = re.match(r"^(\d+)-(\d+): ([^:]*):.*playback", line)
        if match and int(match[1]) in card_ids:
            outputs.append((card_ids[int(match[1])], int(match[2]), match[3].strip()))
    return outputs


def guess_kind(description):
    text = description.lower()
    if "hdmi" in text or "i2s" in text:
        return "HDMI (sound through the screen)"
    if "analog" in text or "headphones" in text:
        return "analog jack (speakers on the line out)"
    if "digital" in text or "iec958" in text or "spdif" in text:
        return "digital output (S/PDIF)"
    return "other output"


def add_to_group(text, group, entry):
    """Adds `entry` (lines indented under `hosts:`) to a top-level group of the inventory text,
    keeping its comments. Creates the group at the end when it is missing."""
    lines = text.splitlines(keepends=True)
    start = next((i for i, line in enumerate(lines) if line.rstrip() == f"{group}:"), None)
    if start is None:
        return text.rstrip("\n") + f"\n{group}:\n  hosts:\n{entry}"
    end = next((i for i in range(start + 1, len(lines)) if re.match(r"^[^\s#]", lines[i])), len(lines))
    hosts = next((i for i in range(start + 1, end) if re.match(r"^  hosts:\s*(#.*)?$", lines[i])), None)
    if hosts is None:
        if any(re.match(r"^  hosts:", lines[i]) for i in range(start + 1, end)):
            fail(f"group '{group}' in inventory.yml has an inline hosts value: add the cabinet by hand.")
        lines.insert(start + 1, "  hosts:\n")
        hosts = start + 1
    lines.insert(hosts + 1, entry)
    return "".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("host", help="name of the cabinet in the inventory, e.g. arcade-pacman")
    parser.add_argument("--inventory", default="inventory", help="inventory directory")
    parser.add_argument("--ansible-bin", default=".venv/bin", help="directory of the Ansible commands")
    args = parser.parse_args()

    host = args.host
    inventory_dir = Path(args.inventory)
    inventory_file = inventory_dir / "inventory.yml"
    host_vars_dir = inventory_dir / "host_vars"

    if not HOST_RE.match(host):
        fail(f"'{host}' is not a valid cabinet name: lowercase letters, digits and '-', e.g. arcade-pacman.")

    say(f"New cabinet: {host}")
    say("Before going on, the machine must run Debian 13 (or Raspberry Pi OS Lite), with the SSH")
    say("server on, a screen and speakers plugged in (README, Prerequisites).")
    say()

    # --- Inventory state ------------------------------------------------------------------
    if inventory_file.exists():
        inventory_text = inventory_file.read_text()
        inventory = yaml.safe_load(inventory_text) or {}
        declared = set()
        for group in inventory.values():
            declared |= set(((group or {}).get("hosts") or {}).keys())
        if host in declared:
            fail(f"{host} is already in {inventory_file}. Edit it there, or pick another name.")
    else:
        inventory_text = EMPTY_INVENTORY
    if (host_vars_dir / f"{host}.yml").exists() or (host_vars_dir / host).exists():
        fail(f"{host_vars_dir / host}(.yml) already exists. Remove it first, or pick another name.")

    # --- Connection -----------------------------------------------------------------------
    say("1/4 Connection")
    address = ask("  Network address of the machine (name, name.local or IP)", default=host,
                  check=re.compile(r"^[A-Za-z0-9.:-]+$"), hint="A host name, name.local or an IP address.")
    user = ask("  Kiosk account (the user created at install, it will run MAUI)",
               check=USER_RE, hint="A Linux user name, e.g. pacman.")
    target = f"{user}@{address}"

    if ssh(target, "true").returncode != 0:
        say(f"  No key access to {target} yet: copying your SSH key (asks for {user}'s password).")
        if not any(Path.home().glob(".ssh/id_*.pub")):
            if not confirm("  You have no SSH key. Create one now (ssh-keygen)?"):
                fail("an SSH key is needed: create one with ssh-keygen, then run just add again.")
            subprocess.run(["ssh-keygen", "-t", "ed25519"], check=True)
        if not shutil.which("ssh-copy-id"):
            fail(f"ssh-copy-id is missing: add your public key to ~{user}/.ssh/authorized_keys on the machine.")
        if subprocess.run(["ssh-copy-id", target]).returncode != 0 or ssh(target, "true").returncode != 0:
            fail(f"cannot log in to {target} with your key. Check the address, the account and that the SSH server runs.")
    say(f"  OK: {target} answers with your key.")
    say()

    # --- What the machine is --------------------------------------------------------------
    say("2/4 Machine")
    probe = ssh(target, PROBE)
    if probe.returncode != 0:
        fail(f"could not read the machine's details: {probe.stderr.strip()}")
    info = sections(probe.stdout)

    arch = {"x86_64": "x86_64", "aarch64": "arm64"}.get(info.get("arch", ""))
    if arch is None:
        fail(f"architecture '{info.get('arch')}' is not supported: x86_64 PC or 64-bit Raspberry Pi only.")
    os_id, _, os_version = info.get("os", "").partition(" ")
    if os_id != "debian" or os_version.strip('"') != "13":
        fail(f"the machine runs '{info.get('os')}', Debian 13 is required (Raspberry Pi OS 64-bit on a Pi).")
    model = info.get("model", "")
    hardware = "raspberry_pi" if "Raspberry Pi" in model else "desktop_pc"
    say(f"  {model or 'PC'}, {info['arch']}, Debian 13.")

    # Debian locks root when its password is left empty at install, and puts the first user in
    # the sudo group instead: su would then never work.
    become_sudo = False
    if hardware == "desktop_pc" and "sudo" in info.get("groups", "").split():
        say(f"  {user} is in the sudo group: root probably has no password (left empty at install).")
        become_sudo = confirm(f"  Become root with sudo and {user}'s password instead of su and root's?")
    say()

    # --- Sound ----------------------------------------------------------------------------
    say("3/4 Sound")
    outputs = sound_outputs(info.get("cards", ""), info.get("pcm", ""))
    if not outputs:
        fail("no sound output found on the machine. Plug in the screen (HDMI) or speakers, then run just add again.")
    say("  Where are the speakers? Sound outputs of the machine:")
    for number, (card, device, description) in enumerate(outputs, 1):
        say(f"    {number}. {description} — {guess_kind(description)} (card {card}, device {device})")
    hdmi = [i for i, output in enumerate(outputs, 1) if "hdmi" in guess_kind(output[2]).lower()]
    choice = ask("  Number of the output wired to the speakers", default=str(hdmi[0] if hdmi else 1),
                 check=re.compile(rf"^([1-9]|[1-9][0-9])$"), hint=f"A number from 1 to {len(outputs)}.")
    if int(choice) > len(outputs):
        fail(f"no output {choice}.")
    card, device, description = outputs[int(choice) - 1]
    say()

    # --- Files ----------------------------------------------------------------------------
    say("4/4 Files")
    host_vars = [
        f"# {model or 'PC'} ({info['arch']}), declared by just add.",
        "",
        "# Account that autologs on tty1 and runs the kiosk session.",
        f"kiosk_user: {user}",
        "",
        "# ALSA device of the sound output wired to the speakers (cat /proc/asound/pcm):",
        f"# {description}, {guess_kind(description)}.",
        f"alsa_hdmi_card: {card}",
        f"alsa_hdmi_device: {device}",
        "",
        "# Display mode of the kiosk session (WIDTHxHEIGHT), default in group_vars/all.yml.",
        "# An empty string keeps the screen's native mode.",
        '# kiosk_resolution: "1920x1080"',
    ]
    if become_sudo:
        host_vars += ["", "# Root has no password on this machine: become root with sudo and the kiosk account's.",
                      "ansible_become_method: sudo"]

    entry = f"    {host}:\n      ansible_user: {user}\n"
    if address != host:
        entry += f"      ansible_host: {address}\n"
    new_text = add_to_group(inventory_text, "cabinets", entry)
    for group in (arch, hardware, "debian_13"):
        new_text = add_to_group(new_text, group, f"    {host}:\n")

    # Check the result before writing anything.
    parsed = yaml.safe_load(new_text)
    for group in ("cabinets", arch, hardware, "debian_13"):
        if host not in ((parsed.get(group) or {}).get("hosts") or {}):
            fail(f"could not add {host} to group '{group}' of inventory.yml: add it by hand (see examples/inventory/).")

    previous = inventory_file.read_text() if inventory_file.exists() else None
    host_vars_dir.mkdir(parents=True, exist_ok=True)
    inventory_file.write_text(new_text)
    host_vars_file = host_vars_dir / f"{host}.yml"
    host_vars_file.write_text("\n".join(host_vars) + "\n")

    vault_pass = inventory_dir / ".vault-pass"
    command = [str(Path(args.ansible_bin) / "ansible-inventory"), "-i", str(inventory_file), "--host", host]
    if vault_pass.exists():
        command += ["--vault-password-file", str(vault_pass)]
    check = subprocess.run(command, capture_output=True, text=True)
    if check.returncode != 0 or f'"kiosk_user": "{user}"' not in check.stdout:
        host_vars_file.unlink()
        if previous is None:
            inventory_file.unlink()
        else:
            inventory_file.write_text(previous)
        fail(f"Ansible does not read the new cabinet back, nothing was kept:\n{check.stderr.strip()}")

    say(f"  {inventory_file}: {host} added to cabinets, {arch}, {hardware}, debian_13.")
    say(f"  {host_vars_file}: kiosk account and sound output.")
    say()
    password = f"{user}'s password" if hardware == "raspberry_pi" or become_sudo else "the root password"
    say("Next steps (each asks for " + password + "):")
    say(f"  just check {host}    # dry run: shows what would change, changes nothing")
    say(f"  just apply {host}    # installs MAME and MAUI, then restarts the screen on MAUI")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        fail("stopped, nothing was written.")
