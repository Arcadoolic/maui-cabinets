set shell := ["bash", "-euo", "pipefail", "-c"]

# Ansible from the project's virtualenv (just setup), not a system-wide install.
venv := ".venv"
bin := venv / "bin"

# Your own cabinets (git-ignored), and the password of their vaulted host_vars when there is one.
inventory := "inventory"
vault_args := if path_exists(inventory / ".vault-pass") == "true" { "--vault-password-file " + inventory / ".vault-pass" } else { "" }

# Show the steps of a deployment, then the recipes
default:
    @echo "Deploy a MAUI cabinet, step by step (README.md has the details):"
    @echo "  1. just setup          once: Ansible in .venv/"
    @echo "  2. just add <host>     declare the cabinet, guided (SSH key, sound output)"
    @echo "  3. just check <host>   dry run, changes nothing"
    @echo "  4. just apply <host>   install MAME and MAUI on the cabinet"
    @echo
    @just --list

# Declare a new cabinet, guided: SSH key, then architecture and sound read from the machine
add host: _check-venv
    {{bin}}/python scripts/add_cabinet.py {{host}} --inventory {{inventory}} --ansible-bin {{bin}}

# Create the virtualenv with Ansible and the collections it needs (safe to run again)
setup:
    python3 -m venv {{venv}}
    {{bin}}/pip install --quiet --upgrade pip
    {{bin}}/pip install --quiet -r requirements.txt
    {{bin}}/ansible-galaxy collection install -r requirements.yml
    @echo "Ready: {{bin}}/ansible-playbook --version"

# Fail fast when just setup has not been run
_check-venv:
    @[ -x "{{bin}}/ansible-playbook" ] || { echo "error: no {{venv}}/. Run 'just setup' first." >&2; exit 1; }

# Create inventory/ from the example, to declare your own cabinets (never overwrites it)
init:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -e "{{inventory}}" ]; then
        echo "{{inventory}}/ already exists, left as is." >&2
        exit 1
    fi
    cp -r examples/inventory "{{inventory}}"
    echo "Created {{inventory}}/: rename arcade-pacman to your cabinet in inventory.yml and host_vars/."

# Fail fast on a host that has no inventory/host_vars/<host>.yml (or host_vars/<host>/
# directory, for a cabinet with vaulted settings) or is missing from inventory/inventory.yml
_check-host host:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f "{{inventory}}/inventory.yml" ]; then
        echo "error: no {{inventory}}/inventory.yml. Run 'just init' first." >&2
        exit 1
    fi
    # Plain file checks rather than ansible-inventory: no Ansible startup, works in any shell.
    if { [ -f "{{inventory}}/host_vars/{{host}}.yml" ] || [ -d "{{inventory}}/host_vars/{{host}}" ]; } && grep -Eq '^[[:space:]]+{{host}}:[[:space:]]*$' "{{inventory}}/inventory.yml"; then
        exit 0
    fi
    known=$(ls "{{inventory}}/host_vars" 2>/dev/null | sed 's/\.yml$//' | tr '\n' ' ')
    echo "error: unknown cabinet '{{host}}'. Known cabinets: $known" >&2
    exit 1

# Dry run against one cabinet (asks for the become password: root, or the kiosk user on a Pi)
check host: _check-venv (_check-host host)
    {{bin}}/ansible-playbook cabinet.yml --limit {{host}} --ask-become-pass {{vault_args}} --check --diff

# Apply the playbook to one cabinet (asks for confirmation, then the become password)
[confirm("This changes the cabinet's system and restarts its kiosk session. Continue? (y/N)")]
apply host: _check-venv (_check-host host)
    {{bin}}/ansible-playbook cabinet.yml --limit {{host}} --ask-become-pass {{vault_args}} --diff

# Create, then edit, the encrypted settings of one cabinet (inventory/host_vars/<host>/vault.yml)
vault host: _check-venv
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f "{{inventory}}/.vault-pass" ]; then
        echo "error: no {{inventory}}/.vault-pass. Create the vault password first (README, Secrets)." >&2
        exit 1
    fi
    if [ ! -d "{{inventory}}/host_vars/{{host}}" ]; then
        echo "error: no {{inventory}}/host_vars/{{host}}/ directory. Move {{host}}.yml to {{host}}/vars.yml first (README, Secrets)." >&2
        exit 1
    fi
    file="{{inventory}}/host_vars/{{host}}/vault.yml"
    action=edit
    [ -f "$file" ] || action=create
    "{{bin}}/ansible-vault" "$action" {{vault_args}} "$file"
