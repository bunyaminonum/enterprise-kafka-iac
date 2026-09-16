#!/usr/bin/env bash
# "Plan" for configuration changes: renders the effective configuration for a base revision and for the
# working tree, and writes a unified diff (one file per host and component).
#
# Usage: scripts/config-diff.sh [--out <file>] [--reuse-head] <base-ref> [<environment>...]
#   --out <file>   default build/config-diff.patch
#   --reuse-head   use build/rendered written by scripts/validate.sh in the same job instead of rendering again
#   environments   default: all environments of the working tree
# Examples:
#   scripts/config-diff.sh origin/main
#   scripts/config-diff.sh origin/main production dr
# The base revision must be available locally (CI fetches it). The exit code is 0 whether or not there are
# differences; the diff is meant for reviewers.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

out="$REPO_ROOT/build/config-diff.patch" reuse=false base_ref="" envs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="${2:?--out needs a file}"; shift 2 ;;
    --reuse-head) reuse=true; shift ;;
    -*) die "unknown option '$1'" ;;
    *)
      if [[ -z "$base_ref" ]]; then base_ref="$1"; else require_env "$1"; envs+=("$1"); fi
      shift ;;
  esac
done
[[ -n "$base_ref" ]] || die "usage: $0 [--out <file>] [--reuse-head] <base-ref> [<environment>...]"
git rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null || die "unknown revision '$base_ref' (fetch it first)"
[[ ${#envs[@]} -gt 0 ]] || mapfile -t envs < <(list_envs)
mkdir -p "$(dirname "$out")"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

work="$(mktemp -d)"
cleanup() { git worktree remove --force "$work/base-src" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work/base" "$work/head"

if [[ "$reuse" == true ]]; then
  for env_name in "${envs[@]}"; do
    [[ -d "build/rendered/$env_name" ]] || die "build/rendered/$env_name is missing - run scripts/validate.sh first"
    cp -R "build/rendered/$env_name" "$work/head/"
  done
else
  log "rendering the working tree"
  scripts/render-config.sh --out "$work/head" "${envs[@]}"
fi

log "rendering $base_ref"
git worktree add --detach "$work/base-src" "$base_ref" >/dev/null 2>&1
base_envs=()
for env_name in "${envs[@]}"; do
  if [[ -f "$work/base-src/environments/$env_name/hosts.yml" ]]; then base_envs+=("$env_name"); else warn "$env_name is new - shown as added"; fi
done
if [[ ! -x "$work/base-src/scripts/render-config.sh" ]]; then
  warn "$base_ref has no render tooling - everything is shown as added"
elif [[ ${#base_envs[@]} -gt 0 ]]; then
  [[ -d .venv ]] && ln -sfn "$REPO_ROOT/.venv" "$work/base-src/.venv"
  if cmp -s collections/requirements.yml "$work/base-src/collections/requirements.yml"; then
    ln -sfn "$REPO_ROOT/collections/ansible_collections" "$work/base-src/collections/ansible_collections"
  else
    log "the change modifies collections/requirements.yml - installing the collections of $base_ref"
    (cd "$work/base-src" && scripts/bootstrap.sh --collections-only >/dev/null)
  fi
  (cd "$work/base-src" && scripts/render-config.sh --out "$work/base" "${base_envs[@]}") \
    || warn "rendering $base_ref failed - the diff is incomplete"
fi

# -F shows the header line of each file ("<env> | <host> | <component> | ...") in every hunk header.
if (cd "$work" && diff -ruN -F '^# ' base head) > "$out"; then
  log "no effective configuration change (${envs[*]})"
else
  log "effective configuration changes in $(grep -c '^+++ ' "$out") file(s) -> $out"
fi
