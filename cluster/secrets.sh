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

# --- WORKSHOP_PREFIX guard (ISI-6986) ---------------------------------------
# REQUIRED + fail-closed. Secret names/labels get prefixed with it downstream
# (WS2/WS3) to isolate this attendee on the shared tenant. Validate + export here
# so a standalone run of this script fails fast instead of rendering an unresolved
# ${WORKSHOP_PREFIX}. No silent fallback, no auto-derive.
if ! [[ "${WORKSHOP_PREFIX:-}" =~ ^[a-z][a-z0-9-]{1,18}$ ]]; then
  warn "WORKSHOP_PREFIX unset or invalid ('${WORKSHOP_PREFIX:-}') — set it in the Codespace secrets (lowercase, start with a letter, 2-19 chars of a-z 0-9 '-', e.g. team-alpha) and re-run."
  exit 1
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
  warn "DT_TENANT_URL / DT_API_TOKEN not set — OTel gateway will export to Phoenix only (no Dynatrace)"
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
