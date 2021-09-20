#!/bin/bash
set -e

tmpdir=$(mktemp -d 2>/dev/null || mktemp -d -t 'packer-ansible-tmpdir')
venvdir="$tmpdir/venv"

# Create venv for ansible
python3 -m venv "$venvdir"
source "$venvdir/bin/activate"
pip install -U pip
pip install ansible passlib cryptography

# Install galaxy roles
export ANSIBLE_COLLECTIONS_PATH="$tmpdir/collections"
export ANSIBLE_ROLES_PATH="$tmpdir/roles"
ansible-galaxy install -r ../ansible/requirements.yml

ANSIBLE_FORCE_COLOR=1 PYTHONUNBUFFERED=1 "$venvdir/bin/ansible-playbook" "$@"

deactivate
rm -rf "$tmpdir"
