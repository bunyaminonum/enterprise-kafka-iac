#!/usr/bin/env bash
# Single entry point for every playbook run against an environment (local shell and CI).
#
# Usage: scripts/run.sh <environment> <playbook> [additional ansible-playbook arguments]
#   <playbook>  site | health_check | restart | validate_hosts | support_bundle | preflight | render_config
#
# Optional environment variables:
#   CONFIRM_ENV                  confirmation for protected environments (must equal <environment>)
#   ANSIBLE_VAULT_PASSWORD       vault password of <environment> (CI secret)
#   ANSIBLE_VAULT_IDENTITY_LIST  alternative for interactive use, e.g. production@prompt
#   ANSIBLE_SSH_PRIVATE_KEY      SSH private key content (CI secret); otherwise the runner identity is used
#   IAC_SECRETS_DIR              control node secret files of <environment>: kafka-<inventory_hostname>.keytab
#                                for every controller and broker, and the Secret Protection security.properties
#   SSH_KNOWN_HOSTS              known_hosts content for the managed hosts (host keys stay verified)
#   IAC_SUPPORT_BUNDLE_DIR       where the failure callback writes support bundles
#   AUTO_SUPPORT_BUNDLE=false    do not collect a support bundle automatically when the run fails
#   PLAYBOOK_TAGS                passed as --tags  (e.g. kafka_broker)
#   PLAYBOOK_LIMIT               passed as --limit (e.g. site_ysl or a host name)
#
# Secrets are exported as environment variables (not passed as CLI flags) on purpose: the
# support_bundle_on_failure callback starts a new ansible-playbook process that does not inherit
# CLI flags such as --vault-id or -e, but does inherit the environment.
#
# The guard rails (playbooks/preflight.yml) run first in a separate process WITHOUT that callback:
# the callback reacts to any failed playbook, and a refused run must not start collecting diagnostics
# from the hosts. The requested playbook imports preflight again, which is cheap and keeps direct
# ansible-playbook runs safe as well.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

[[ $# -ge 2 ]] || die "usage: $0 <environment> <playbook> [ansible-playbook args...]"
env_name="$1" playbook="$2"
shift 2
require_env "$env_name"
[[ -f "playbooks/$playbook.yml" ]] || die "unknown playbook '$playbook' (see playbooks/)"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
umask 077

if [[ -n "${ANSIBLE_VAULT_PASSWORD:-}" ]]; then
  printf '%s\n' "$ANSIBLE_VAULT_PASSWORD" > "$workdir/vault-pass"
  export ANSIBLE_VAULT_IDENTITY_LIST="$env_name@$workdir/vault-pass"
  unset ANSIBLE_VAULT_PASSWORD
fi
if [[ -n "${SSH_KNOWN_HOSTS:-}" ]]; then
  printf '%s\n' "$SSH_KNOWN_HOSTS" > "$workdir/known_hosts"
  export ANSIBLE_SSH_COMMON_ARGS="${ANSIBLE_SSH_COMMON_ARGS:-} -o UserKnownHostsFile=$workdir/known_hosts"
fi
if [[ -n "${ANSIBLE_SSH_PRIVATE_KEY:-}" ]]; then
  printf '%s\n' "$ANSIBLE_SSH_PRIVATE_KEY" > "$workdir/ssh-key"
  export ANSIBLE_PRIVATE_KEY_FILE="$workdir/ssh-key"
  unset ANSIBLE_SSH_PRIVATE_KEY
fi

options=(-i "environments/$env_name")
if [[ -n "${CONFIRM_ENV:-}" ]]; then
  [[ "$CONFIRM_ENV" =~ ^[a-z][a-z0-9]*$ ]] || die "CONFIRM_ENV must be an environment name"
  options+=(-e "confirm_env=$CONFIRM_ENV")
fi
[[ -z "${PLAYBOOK_TAGS:-}" ]] || options+=(--tags "$PLAYBOOK_TAGS")
[[ -z "${PLAYBOOK_LIMIT:-}" ]] || options+=(--limit "$PLAYBOOK_LIMIT")
if [[ "${AUTO_SUPPORT_BUNDLE:-true}" == false ]]; then
  options+=(-e "support_bundle_auto_collect_on_failure=false")
fi

activate_venv

case "$playbook" in
  preflight | support_bundle | render_config) ;;
  *)
    guard=()
    if [[ "$playbook" == health_check || "$playbook" == validate_hosts ]]; then
      guard+=(-e iac_require_confirmation=false)   # read-only operations
    fi
    log "preflight for $env_name"
    ANSIBLE_CALLBACKS_ENABLED=ansible.posix.profile_tasks \
      ansible-playbook "${options[@]}" playbooks/preflight.yml "${guard[@]}" "$@" \
      || die "preflight refused the run on $env_name"
    ;;
esac

log "ansible-playbook ${options[*]} playbooks/$playbook.yml $*"
rc=0
ansible-playbook "${options[@]}" "playbooks/$playbook.yml" "$@" || rc=$?
exit "$rc"
