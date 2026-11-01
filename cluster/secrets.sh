#!/usr/bin/env bash
# Create the Kubernetes secrets the platform stack consumes, from Codespace
# environment variables (see .devcontainer/SECRETS.md). Values are NEVER printed
# and NEVER committed. Idempotent: secrets are upserted with apply.
#
#   DT_TENANT_URL   e.g. https://abc12345.live.dynatrace.com   (no trailing /api)
#   The DynaKube needs two tokens whose scopes are DISJOINT; the OTel collector
#   needs the ingest one. We map them onto the two existing token secrets so no new
#   Codespace secret is required:
#
#   DT_API_TOKEN         INGEST token -> DynaKube dataIngestToken + the OTel
#                        collector's OTLP export. Scopes (classic dt0c01 | platform
#                        dt0s16):
#                          openTelemetryTrace.ingest, metrics.ingest, logs.ingest |
#                          openpipeline:traces:ingest, openpipeline:logs:ingest,
#                          data-acquisition:metrics:ingest (+ logs)
#   DYNATRACE_API_TOKEN  OPERATOR token -> DynaKube apiToken (Kubernetes-monitoring /
#                        ActiveGate). This is also the Phase-4 dt-evals token, so it
#                        carries the operator scopes IN ADDITION to its dt-evals
#                        scopes (storage:spans:read, storage:events:write). Operator
#                        scopes (classic | platform):
#                          activeGateTokenManagement.create, entities.read,
#                          settings.read, settings.write |
#                          fleet-management:activegate.tokens:create,
#                          fleet-management:activegate.connection-info:read,
#                          settings:objects:read, settings:objects:write
#                        Falls back to DT_API_TOKEN if unset (single combined token).
#   LLM_API_KEY / OPENAI_API_KEY / ANTHROPIC_API_KEY  model-provider key for kagent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;34m[secrets]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[  ok  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ warn ]\033[0m %s\n' "$*" >&2; }

apply_secret() { kubectl apply -f - >/dev/null; }

# --- WORKSHOP_PREFIX resolve (ISI-6986 / ISI-7005) --------------------------
# Secret names/labels get prefixed with it downstream (WS2/WS3) to isolate this
# attendee on the shared tenant. An explicit valid value wins; otherwise derive a
# deterministic, valid per-attendee prefix from the Codespace identity so a
# standalone run still renders instead of fail-closing. Self-contained copy of
# resolve_workshop_prefix from .devcontainer/bootstrap/lib.sh — keep in sync.
WORKSHOP_PREFIX_PATTERN='^[a-z][a-z0-9-]{1,18}$'
if ! [[ "${WORKSHOP_PREFIX:-}" =~ $WORKSHOP_PREFIX_PATTERN ]]; then
  _raw_prefix="${WORKSHOP_PREFIX:-}"
  _sanitize_prefix() {
    local s
    s="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' \
          | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')"
    [[ "$s" =~ ^[a-z] ]] || s="w-${s}"
    s="$(printf '%s' "${s:0:19}" | sed -E 's/-+$//')"
    [[ "$s" =~ $WORKSHOP_PREFIX_PATTERN ]] && printf '%s' "$s"
  }
  WORKSHOP_PREFIX=""
  for _src in "${_raw_prefix}" "${GITHUB_USER:-}" "${CODESPACE_NAME:-}" "workshop"; do
    WORKSHOP_PREFIX="$(_sanitize_prefix "$_src")"
    [ -n "$WORKSHOP_PREFIX" ] && break
  done
  warn "WORKSHOP_PREFIX unset/invalid ('${_raw_prefix}') — using '${WORKSHOP_PREFIX}' (auto-derived; set it in Codespace secrets to pick your own isolation label)."
fi
export WORKSHOP_PREFIX

# --- Dynatrace token secret -------------------------------------------------
# The operator convention: the secret name MUST match the DynaKube name ("dynakube").
# apiToken = operator (DYNATRACE_API_TOKEN); dataIngestToken = ingest (DT_API_TOKEN).
operator_token="${DYNATRACE_API_TOKEN:-${DT_API_TOKEN:-}}"
if [ -z "${DYNATRACE_API_TOKEN:-}" ] && [ -n "${DT_API_TOKEN:-}" ]; then
  warn "DYNATRACE_API_TOKEN not set — reusing DT_API_TOKEN as the DynaKube operator token; it must then also carry the Kubernetes-monitoring scopes or the DynaKube will be in Error (ScopeMissing)"
fi
if [ -n "${DYNATRACE_API_TOKEN:-}" ] && [ "${DYNATRACE_API_TOKEN}" = "${DT_API_TOKEN:-}" ]; then
  warn "DYNATRACE_API_TOKEN equals DT_API_TOKEN — if that is an ingest-only token the DynaKube will be stuck in Error (ScopeMissing). The operator token needs settings:objects:write + activegate scopes."
fi
if [ -n "${operator_token}" ]; then
  kubectl create secret generic dynakube -n dynatrace \
    --from-literal=apiToken="${operator_token}" \
    --from-literal=dataIngestToken="${DT_API_TOKEN:-}" \
    --dry-run=client -o yaml | apply_secret
  ok "secret/dynakube (dynatrace) upserted — apiToken=DYNATRACE_API_TOKEN, dataIngestToken=DT_API_TOKEN"
else
  warn "neither DYNATRACE_API_TOKEN nor DT_API_TOKEN set — skipping secret/dynakube (the operator cannot authenticate)"
fi

# --- OTLP export secret (collector -> Dynatrace tenant) ---------------------
# The OTel gateway reads the tenant URL + token from this secret (ns opentelemetry-operator-system).
if [ -n "${DT_TENANT_URL:-}" ] && [ -n "${DT_API_TOKEN:-}" ]; then
  # Normalise: ensure the OTLP endpoint is <tenant>/api/v2/otlp on the ingest
  # (.live.) domain. The platform/apps domain (.apps.dynatrace.com) does NOT
  # serve /api/v2/otlp — exporting there returns HTTP 404 and every span is
  # dropped (ISI-6937). Auto-correct a mis-set .apps. tenant so standalone runs
  # of this script are protected too (install.sh applies the same swap).
  dt_tenant="${DT_TENANT_URL}"
  if [[ "${dt_tenant}" == *".apps.dynatrace.com"* ]]; then
    dt_tenant="${dt_tenant/.apps.dynatrace.com/.live.dynatrace.com}"
    warn "DT_TENANT_URL pointed at the .apps. (platform) domain — using ${dt_tenant} for OTLP ingest (the .apps. URL belongs to DT_ENVIRONMENT for MCP/dtctl)"
  fi
  endpoint="${dt_tenant%/}/api/v2/otlp"
  kubectl create secret generic dynatrace-otlp -n opentelemetry-operator-system \
    --from-literal=endpoint="${endpoint}" \
    --from-literal=apiToken="${DT_API_TOKEN}" \
    --dry-run=client -o yaml | apply_secret
  ok "secret/dynatrace-otlp (opentelemetry-operator-system) upserted"
else
  # No Dynatrace creds: the gateway must still come up and export to Phoenix.
  # The collector config references ${env:DT_OTLP_ENDPOINT} / ${env:DT_API_TOKEN}
  # (sourced from this secret); OTel's env-substitution HARD-FAILS at startup on
  # an UNSET variable, so a missing secret crash-loops the whole collector — not
  # the "Phoenix export keeps working regardless" the manifest promises
  # (ISI-6869; surfaces as live-acceptance L3). Upsert a placeholder secret with
  # an inert .invalid endpoint so the Dynatrace exporter initialises and simply
  # drops (DNS-fails, logged, non-fatal) while the Phoenix pipeline runs. Real
  # creds take the branch above and overwrite this. Zero effect on the
  # authenticated path.
  kubectl create secret generic dynatrace-otlp -n opentelemetry-operator-system \
    --from-literal=endpoint="https://dynatrace-otlp-not-configured.invalid/api/v2/otlp" \
    --from-literal=apiToken="OTLP-EXPORT-DISABLED-no-dt-credentials" \
    --dry-run=client -o yaml | apply_secret
  warn "DT_TENANT_URL / DT_API_TOKEN not set — OTel gateway exports to Phoenix only (placeholder dynatrace-otlp secret keeps the collector running; Dynatrace export disabled)"
fi

# --- kagent model-provider secret -------------------------------------------
# Phase 3 default provider is DeepSeek (OpenAI-API compatible). LLM_API_KEY is the
# generic model-provider key — when DeepSeek is the provider it holds the DeepSeek
# key. Create whichever secret matches the key(s) actually present.
# DeepSeek (default): secret/kagent-deepseek, key DEEPSEEK_API_KEY.
DEEPSEEK_KEY="${DEEPSEEK_API_KEY:-${LLM_API_KEY:-}}"
if [ -n "${DEEPSEEK_KEY}" ]; then
  kubectl create secret generic kagent-deepseek -n kagent \
    --from-literal=DEEPSEEK_API_KEY="${DEEPSEEK_KEY}" \
    --dry-run=client -o yaml | apply_secret
  ok "secret/kagent-deepseek (kagent) upserted"
  # Phoenix preconfigures DeepSeek as its playground/eval provider (ISI-6959) so
  # attendees never hand-enter a key. Phoenix runs in its own namespace, so it
  # needs its own copy of the key — dedicated secret for clean ownership, reusing
  # the SAME Codespace DEEPSEEK_API_KEY/LLM_API_KEY (no new attendee secret).
  kubectl create secret generic phoenix-deepseek -n phoenix \
    --from-literal=DEEPSEEK_API_KEY="${DEEPSEEK_KEY}" \
    --dry-run=client -o yaml | apply_secret
  ok "secret/phoenix-deepseek (phoenix) upserted"
fi
# OpenAI alternative: secret/kagent-openai, key OPENAI_API_KEY.
if [ -n "${OPENAI_API_KEY:-}" ]; then
  kubectl create secret generic kagent-openai -n kagent \
    --from-literal=OPENAI_API_KEY="${OPENAI_API_KEY}" \
    --dry-run=client -o yaml | apply_secret
  ok "secret/kagent-openai (kagent) upserted"
fi
# Anthropic alternative: secret/kagent-anthropic, key ANTHROPIC_API_KEY.
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  kubectl create secret generic kagent-anthropic -n kagent \
    --from-literal=ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}" \
    --dry-run=client -o yaml | apply_secret
  ok "secret/kagent-anthropic (kagent) upserted"
fi
[ -n "${DEEPSEEK_KEY}${OPENAI_API_KEY:-}${ANTHROPIC_API_KEY:-}" ] || \
  warn "no model key (DEEPSEEK_API_KEY/LLM_API_KEY/OPENAI_API_KEY/ANTHROPIC_API_KEY) — kagent installs clean but agents need a key for Phase 3"

ok "secret provisioning complete"
