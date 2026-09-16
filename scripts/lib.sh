#!/usr/bin/env bash
# Shared helpers for the scripts in this directory (sourced, not executed).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Use the repository virtualenv when it exists (created by scripts/bootstrap.sh).
activate_venv() {
  if [[ -f "$REPO_ROOT/.venv/bin/activate" && -z "${VIRTUAL_ENV:-}" ]]; then
    # shellcheck source=/dev/null
    source "$REPO_ROOT/.venv/bin/activate"
  fi
}

list_envs() {
  find "$REPO_ROOT/environments" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
}

require_env() {
  local env_name="$1"
  [[ "$env_name" =~ ^[a-z][a-z0-9]*$ ]] || die "invalid environment name '$env_name'"
  [[ -f "$REPO_ROOT/environments/$env_name/hosts.yml" ]] || die "unknown environment '$env_name' (available: $(list_envs | paste -sd' '))"
}

# Quiet and side-effect free settings for static runs (no callbacks, hence no automatic support bundle).
# PYTHONHASHSEED makes rendering deterministic: cp-ansible builds some values from Python sets
# (e.g. sasl.enabled.mechanisms, rest.extension.classes) whose order would otherwise change between
# processes and show up as noise in scripts/config-diff.sh.
static_ansible_env() {
  export ANSIBLE_DISPLAY_SKIPPED_HOSTS=false ANSIBLE_CALLBACKS_ENABLED= ANSIBLE_HOST_PATTERN_MISMATCH=ignore
  export PYTHONHASHSEED=0
}

# run_parallel <jobs> <function> <argument>...
# Calls "<function> <argument>" for every argument, at most <jobs> at a time. Returns non-zero after all
# calls have finished if at least one of them failed.
run_parallel() {
  local jobs="$1" fn="$2" failed=0 running=0 arg
  shift 2
  for arg in "$@"; do
    "$fn" "$arg" &
    running=$((running + 1))
    if (( running >= jobs )); then
      wait -n || failed=1
      running=$((running - 1))
    fi
  done
  while (( running > 0 )); do
    wait -n || failed=1
    running=$((running - 1))
  done
  return "$failed"
}
