#!/usr/bin/env bash
# Prepares an Ansible control node (developer machine or CI runner).
#
# Usage: scripts/bootstrap.sh [--dev] [--collections-only]
#   --dev               also install the linters (requirements-dev.txt)
#   --collections-only  skip the Python virtualenv, only install the pinned collections
#
# Air-gapped network: point pip to the Nexus PyPI proxy (PIP_INDEX_URL). Collections are downloaded from
# the URLs in collections/requirements.yml; nothing is resolved from public Galaxy (--no-deps).
# Set BOOTSTRAP_VENV=false to use an existing Python environment (e.g. a prepared runner image).
# ansible-core 2.18 needs Python >= 3.11 on the control node; on RHEL 9 use e.g. PYTHON=python3.12.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

dev=false collections_only=false
for arg in "$@"; do
  case "$arg" in
    --dev) dev=true ;;
    --collections-only) collections_only=true ;;
    *) die "unknown argument '$arg'" ;;
  esac
done

if [[ "$collections_only" == false ]]; then
  if [[ "${BOOTSTRAP_VENV:-true}" == true ]]; then
    [[ -d .venv ]] || { log "creating virtualenv .venv"; "${PYTHON:-python3}" -m venv .venv; }
    activate_venv
  fi
  log "installing Python requirements"
  python3 -m pip install --quiet --upgrade pip
  python3 -m pip install --quiet -r "$([[ "$dev" == true ]] && echo requirements-dev.txt || echo requirements.txt)"
fi

activate_venv
log "installing pinned collections into ./collections"
ansible-galaxy collection install -r collections/requirements.yml -p collections --no-deps
installed="$(ansible-galaxy collection list -p collections 2>/dev/null)"
for collection in confluent.platform ansible.posix community.general; do
  grep -q "^$collection " <<<"$installed" || die "collection $collection is missing"
done
grep -E '^(confluent\.platform|ansible\.posix|community\.general) ' <<<"$installed"
ansible --version | head -1
