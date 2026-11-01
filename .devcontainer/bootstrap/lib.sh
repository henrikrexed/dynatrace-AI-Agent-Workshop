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
# (WS2/WS3) template namespaces + OTel attribute values with it. An explicit,
# valid value is STRONGLY preferred — it is the friendly label facilitators filter
# telemetry by. But rather than fail-close into an empty cluster when it is unset
# or malformed (ISI-7005: attendees hit a broken Codespace with no kagent),
# resolve_workshop_prefix() below GRACEFULLY derives a valid, deterministic,
# per-attendee prefix from the Codespace identity so the stack ALWAYS deploys.
# Isolation is preserved: distinct attendees have distinct GitHub identities, so
# their derived prefixes differ. We only surface + export the raw value here;
# normalization lives in sanitize_workshop_prefix / resolve_workshop_prefix below.
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

# Coerce an arbitrary string into a valid WORKSHOP_PREFIX, or print nothing if it
# cannot be salvaged. Lowercase; map any non [a-z0-9-] run to '-'; collapse/trim
# dashes; guarantee a leading letter; cap at 19 chars (RFC-1123 label + the OTel
# attribute value constraint). Pure/deterministic — same input always maps to the
# same output, so every consumer (lib.sh, install.sh) derives an identical prefix.
sanitize_workshop_prefix() {
  local s
  s="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')"
  [[ "$s" =~ ^[a-z] ]] || s="w-${s}"          # guarantee a leading letter
  s="$(printf '%s' "${s:0:19}" | sed -E 's/-+$//')"   # cap length, retrim tail
  if [[ "$s" =~ $WORKSHOP_PREFIX_PATTERN ]]; then printf '%s' "$s"; fi
}

# Resolve WORKSHOP_PREFIX to a guaranteed-valid value and export it (ISI-7005).
# An explicit valid value always wins. Otherwise derive deterministically from the
# Codespace identity so the stack still deploys instead of fail-closing into an
# empty cluster. Always returns 0 — WORKSHOP_PREFIX is valid when this returns.
resolve_workshop_prefix() {
  if valid_workshop_prefix "${WORKSHOP_PREFIX:-}"; then
    export WORKSHOP_PREFIX
    return 0
  fi
  local had="${WORKSHOP_PREFIX:-}" src derived=""
  # Priority: salvage the given value, then GitHub login, then codespace name,
  # then a last-resort literal (single-tenant/local — isolation moot).
  for src in "${WORKSHOP_PREFIX:-}" "${GITHUB_USER:-}" "${CODESPACE_NAME:-}" "workshop"; do
    derived="$(sanitize_workshop_prefix "$src")"
    [ -n "$derived" ] && break
  done
  WORKSHOP_PREFIX="$derived"
  export WORKSHOP_PREFIX
  if [ -n "$had" ]; then
    warn "WORKSHOP_PREFIX='${had}' is invalid — using normalized '${WORKSHOP_PREFIX}' so the stack still deploys. Set a valid WORKSHOP_PREFIX (${WORKSHOP_PREFIX_PATTERN}) in Codespace secrets to pick your own isolation label."
  else
    warn "WORKSHOP_PREFIX was not set — auto-derived '${WORKSHOP_PREFIX}' from your Codespace identity so the stack still deploys. Set WORKSHOP_PREFIX in Codespace secrets to pick a friendly isolation label (e.g. team-alpha)."
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
