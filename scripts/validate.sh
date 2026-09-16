#!/usr/bin/env bash
# Static validation: needs no vault password and never connects to managed hosts.
#
# Usage: scripts/validate.sh [--env <environment>]... [--no-lint] [--jobs <n>]
#
#   1. yamllint / ansible-lint (when installed, see requirements-dev.txt)
#   2. variable names: every override must be known to the pinned collection (typos are silently ignored by Ansible)
#   3. syntax check of every wrapper playbook (resolves the pinned collection)
#   4. per environment, in parallel: inventory parsing, preflight in static mode and
#      rendering of the effective configuration into build/rendered/<environment>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

envs=() lint=true jobs="$(nproc)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) require_env "${2:-}"; envs+=("$2"); shift 2 ;;
    --no-lint) lint=false; shift ;;
    --jobs) jobs="${2:?--jobs needs a number}"; shift 2 ;;
    *) die "unknown argument '$1'" ;;
  esac
done
[[ ${#envs[@]} -gt 0 ]] || mapfile -t envs < <(list_envs)
render_dir="$REPO_ROOT/build/rendered"
mkdir -p "$render_dir" "$REPO_ROOT/build/logs"

activate_venv
static_ansible_env
no_bundle=(-e support_bundle_auto_collect_on_failure=false)

if [[ "$lint" == true ]]; then
  if command -v yamllint >/dev/null; then log "yamllint"; yamllint -s .; else warn "yamllint not installed, skipped"; fi
  if command -v ansible-lint >/dev/null; then log "ansible-lint"; ansible-lint; else warn "ansible-lint not installed, skipped"; fi
fi

log "variable names"
python3 scripts/check-vars.py

log "syntax check (playbooks/*.yml)"
ansible-playbook -i "environments/${envs[0]}" playbooks/*.yml --syntax-check "${no_bundle[@]}" >/dev/null \
  || die "syntax check failed"

validate_one() {
  local env_name="$1"
  local logfile="$REPO_ROOT/build/logs/validate-$env_name.log"
  rm -rf "${render_dir:?}/$env_name"
  # one ansible-playbook process for both playbooks: inventory and collection are loaded once
  if ansible-inventory -i "environments/$env_name" --graph >"$logfile" 2>&1 \
     && ansible-playbook -i "environments/$env_name" playbooks/preflight.yml playbooks/render_config.yml \
          -e iac_static_validation=true -e "iac_render_dir=$render_dir" "${no_bundle[@]}" >>"$logfile" 2>&1; then
    log "[$env_name] inventory, preflight (static) and rendering passed"
  else
    tail -n 40 "$logfile" >&2
    warn "[$env_name] FAILED (build/logs/validate-$env_name.log)"
    return 1
  fi
}

log "environments: ${envs[*]} (parallel jobs: $jobs)"
run_parallel "$jobs" validate_one "${envs[@]}" || die "validation failed"
log "validation passed for: ${envs[*]}"
