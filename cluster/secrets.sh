#!/usr/bin/env bash
# Create the Kubernetes secrets the platform stack consumes, from Codespace
# environment variables (see .devcontainer/SECRETS.md). Values are NEVER printed
# and NEVER committed. Idempotent: secrets are upserted with apply.
#
#   DT_TENANT_URL   e.g. https://abc12345.live.dynatrace.com   (no trailing /api)
#   DT_API_TOKEN    One Dynatrace token reused for BOTH jobs (DynaKube operator
#                   apiToken + the OTel collector OTLP export), so it needs the
#                   UNION of scopes. Works as a classic (dt0c01) or platform
#                   (dt0s16) token:
#                     operator/ActiveGate —
#                       classic:  activeGateTokenManagement.create, entities.read,
#                                 settings.read, settings.write
#                       platform: fleet-management:activegate.tokens:create,
#                                 fleet-management:activegate.connection-info:read,
#                                 settings:objects:read, settings:objects:write
#                     ingest (collector) —
#                       classic:  openTelemetryTrace.ingest, metrics.ingest, logs.ingest
#                       platform: openpipeline:traces:ingest, openpipeline:logs:ingest,
#                                 data-acquisition:metrics:ingest (+ logs)
#                   A token with only the ingest scopes leaves the DynaKube in
#                   Error (ScopeMissing) — add the operator scopes to the SAME token.
#   LLM_API_KEY / OPENAI_API_KEY / ANTHROPIC_API_KEY  model-provider key for kagent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;34m[secrets]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[  ok  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ warn ]\033[0m %s\n' "$*" >&2; }

apply_secret() { kubectl apply -f - >/dev/null; }

# --- Dynatrace token secret -------------------------------------------------
# The operator convention: the secret name MUST match the DynaKube name ("dynakube").
if [ -n "${DT_API_TOKEN:-}" ]; then
  kubectl create secret generic dynakube -n dynatrace \
    --from-literal=apiToken="${DT_API_TOKEN}" \
    --from-literal=dataIngestToken="${DT_API_TOKEN}" \
    --dry-run=client -o yaml | apply_secret
  ok "secret/dynakube (dynatrace) upserted"
else
  warn "DT_API_TOKEN not set — skipping secret/dynakube (operator + OTLP export will not authenticate)"
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
