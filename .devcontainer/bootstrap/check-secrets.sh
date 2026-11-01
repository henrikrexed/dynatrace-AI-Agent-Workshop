#!/usr/bin/env bash
# Report which Codespace secrets are present WITHOUT printing their values.
# Mirrors the canonical contract in .devcontainer/SECRETS.md (ISI-6744 matrix).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# Presence check for a single variable (value never printed).
check() {
  local var="$1" required="$2" note="$3"
  if [ -n "${!var:-}" ]; then
    ok "${var} is set"
  elif [ "$required" = "required" ]; then
    warn "${var} is MISSING (required) — ${note}"
  else
    warn "${var} is not set (optional) — ${note}"
  fi
}

# Presence check for a "preferred / fallback" pair: satisfied if EITHER is set.
check_either() {
  local preferred="$1" fallback="$2" required="$3" note="$4"
  if [ -n "${!preferred:-}" ]; then
    ok "${preferred} is set (preferred)"
  elif [ -n "${!fallback:-}" ]; then
    ok "${fallback} is set (fallback for ${preferred})"
  elif [ "$required" = "required" ]; then
    warn "${preferred} / ${fallback} are MISSING (required) — ${note}"
  else
    warn "${preferred} / ${fallback} not set (optional) — ${note}"
  fi
}

echo "--- Codespace secrets contract (values never printed) ---"

# [Prefix] WORKSHOP_PREFIX — REQUIRED + fail-closed (ISI-6986). Unlike the secrets
# below (which degrade gracefully), a missing/invalid prefix stops the bootstrap:
# downstream namespaces + OTel attributes template with it to isolate this attendee
# on the shared tenant. No silent fallback, no auto-derive.
prefix_bad=0
echo "[Prefix] Shared-tenant isolation prefix"
if [ -z "${WORKSHOP_PREFIX:-}" ]; then
  err "WORKSHOP_PREFIX is MISSING (required) — set it in the 'Create codespace with options…' dialog (lowercase label, e.g. team-alpha)"
  prefix_bad=1
elif ! valid_workshop_prefix "${WORKSHOP_PREFIX}"; then
  err "WORKSHOP_PREFIX is INVALID (required) — must match ${WORKSHOP_PREFIX_PATTERN} (lowercase, start with a letter, 2-19 chars of a-z 0-9 '-')"
  prefix_bad=1
else
  ok "WORKSHOP_PREFIX is set and valid"
fi

echo "[Phase 2] Dynatrace operator + OTLP ingest"
check DT_TENANT_URL required "Dynatrace tenant, e.g. https://abc12345.live.dynatrace.com"
check DT_API_TOKEN  required "Dynatrace INGEST token (OTLP export + DynaKube dataIngestToken)"

echo "[Phase 3/5] Dynatrace platform — dtctl (platform token)"
check DT_PLATFORM_TOKEN required "Dynatrace platform token (dt0s16) for dtctl"
check DT_ENVIRONMENT    optional "platform apps URL (https://<env>.apps.dynatrace.com); derived from DT_TENANT_URL if unset"

echo "[Phase 3] Agents LLM access — room-password proxy (ISI-6996)"
check WORKSHOP_ROOM_PASSWORD required "the workshop room password — the ONLY model credential you supply; dispense-llm.sh exchanges it for a per-attendee LiteLLM-proxy endpoint + minted virtual key powering the kagent agents + Phoenix/dt-evals judge (no raw DeepSeek key needed)"
check_either DEEPSEEK_API_KEY LLM_API_KEY optional "direct DeepSeek key — ONLY if bypassing the room-password proxy (e.g. CI/self-host). Normally fetched at runtime from WORKSHOP_ROOM_PASSWORD; leave unset"

echo "[Phase 3] GitHub MCP (BMAD 'bad crew')"
check_either GH_PAT GITHUB_TOKEN       required "GitHub token for the GitHub MCP; fine-grained PAT for the write demo (Codespaces injects GITHUB_TOKEN)"
check GH_DEMO_REPO required "BMAD/'bad crew' demo repo (owner/repo) the GitHub MCP writes to"

echo "[Phase 4] dt-evals (trace-sourced LLM-as-judge)"
check_either DT_ENV_URL DT_ENVIRONMENT_URL optional "dt-evals tenant URL; derived from DT_TENANT_URL if unset"
check DYNATRACE_API_TOKEN optional "DynaKube OPERATOR token (apiToken, k8s-monitoring scopes) + dt-evals (storage:spans:read + storage:events:write)"
check DT_EVAL_SERVICE     optional "service.name of the agent to evaluate (defaults to \${WORKSHOP_PREFIX}-sre-agent; not a secret)"

echo "[Optional] alternate model providers"
check OPENAI_API_KEY    optional "used if agents/judge target OpenAI directly"
check ANTHROPIC_API_KEY optional "used if agents target Anthropic models"

echo "---------------------------------------------------------"
echo "Set/rotate these under: GitHub repo/user Settings > Codespaces > Secrets."
# Fail-closed ONLY on the required prefix; the secret presence checks above stay
# advisory (components skip cleanly when their secret is absent).
if [ "$prefix_bad" -ne 0 ]; then
  err "WORKSHOP_PREFIX is unset or invalid — fix it in the Codespace secrets and rebuild; the install chain will not render without it."
  exit 1
fi
exit 0
