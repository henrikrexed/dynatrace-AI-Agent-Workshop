#!/usr/bin/env bash
# Shared helpers for the devcontainer bootstrap scripts. Source this file.
# Everything here is written to be idempotent and safe to re-run.

# shellcheck disable=SC2034
CLUSTER_TOOL="${CLUSTER_TOOL:-kind}"
CLUSTER_NAME="${CLUSTER_NAME:-workshop}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG

# WORKSHOP_PREFIX — the per-attendee isolation prefix for a shared Dynatrace tenant
# (ISI-6986). Prompted in the Codespace create dialog; downstream workstreams
# (WS2/WS3) template namespaces + OTel attribute values with it. NO silent default:
# it is REQUIRED and fail-closed. We only surface + export it here; validation and
# enforcement live in valid_workshop_prefix / require_workshop_prefix below.
# Format: lowercase RFC-1123 label — a letter, then 1-18 of [a-z0-9-] (len 2-19),
# valid as a k8s name component AND an OTel attribute value.
WORKSHOP_PREFIX="${WORKSHOP_PREFIX:-}"
export WORKSHOP_PREFIX
WORKSHOP_PREFIX_PATTERN='^[a-z][a-z0-9-]{1,18}$'
export WORKSHOP_PREFIX_PATTERN

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[  ok  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ warn ]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ fail ]\033[0m %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

# True if $1 is a valid WORKSHOP_PREFIX (prints nothing — caller owns messaging).
valid_workshop_prefix() { [[ "${1:-}" =~ $WORKSHOP_PREFIX_PATTERN ]]; }

# Fail-closed guard for the install/render scripts. Returns non-zero (with a clear
# message) when WORKSHOP_PREFIX is unset or malformed, so nothing renders an
# unresolved ${WORKSHOP_PREFIX}. No silent fallback, no auto-derive (ISI-6986).
require_workshop_prefix() {
  if [ -z "${WORKSHOP_PREFIX:-}" ]; then
    err "WORKSHOP_PREFIX is not set — set it in the 'Create codespace with options…' dialog. It isolates this attendee's objects on the shared Dynatrace tenant (lowercase label, e.g. 'team-alpha')."
    return 1
  fi
  if ! valid_workshop_prefix "${WORKSHOP_PREFIX}"; then
    err "WORKSHOP_PREFIX='${WORKSHOP_PREFIX}' is invalid — must match ${WORKSHOP_PREFIX_PATTERN} (lowercase, start with a letter, 2-19 chars of a-z 0-9 '-')."
    return 1
  fi
  return 0
}

# Wait until the Docker daemon (Docker-in-Docker) answers, up to N seconds.
wait_for_docker() {
  local tries="${1:-60}"
  log "waiting for Docker daemon..."
  for ((i=0; i<tries; i++)); do
    if docker info >/dev/null 2>&1; then ok "Docker is up"; return 0; fi
    sleep 2
  done
  err "Docker daemon did not become ready in time"
  return 1
}

# True if the workshop kind cluster already exists.
cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"
}

# True if kubectl can reach the API server.
cluster_reachable() {
  kubectl cluster-info >/dev/null 2>&1
}
