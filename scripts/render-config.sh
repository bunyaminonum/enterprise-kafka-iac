#!/usr/bin/env bash
# Renders the effective configuration (final properties + systemd environment) of environments without a
# vault password and without connecting to any host.
#
# Usage: scripts/render-config.sh [--out <dir>] [--jobs <n>] [<environment>...]
#   defaults: every environment, output build/rendered, one job per CPU
#   output:   <dir>/<environment>/<host>/<component>.properties and <component>.env
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

out="$REPO_ROOT/build/rendered" jobs="$(nproc)" envs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="${2:?--out needs a directory}"; shift 2 ;;
    --jobs) jobs="${2:?--jobs needs a number}"; shift 2 ;;
    -*) die "unknown option '$1'" ;;
    *) require_env "$1"; envs+=("$1"); shift ;;
  esac
done
[[ ${#envs[@]} -gt 0 ]] || mapfile -t envs < <(list_envs)
mkdir -p "$out" "$REPO_ROOT/build/logs"
out="$(cd "$out" && pwd)"

activate_venv
static_ansible_env

render_one() {
  local env_name="$1"
  local logfile="$REPO_ROOT/build/logs/render-$env_name.log"
  rm -rf "${out:?}/$env_name"
  if ansible-playbook -i "environments/$env_name" playbooks/render_config.yml \
       -e iac_static_validation=true -e "iac_render_dir=$out" \
       -e support_bundle_auto_collect_on_failure=false >"$logfile" 2>&1; then
    log "rendered $env_name -> $out/$env_name"
  else
    tail -n 30 "$logfile" >&2
    warn "rendering $env_name failed (build/logs/render-$env_name.log)"
    return 1
  fi
}

run_parallel "$jobs" render_one "${envs[@]}" || die "rendering failed"
