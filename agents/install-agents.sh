#!/usr/bin/env bash
# Phase 3 — deploy the MCP tool servers and both agent sets into the kagent
# namespace. Run AFTER the Phase 2 platform install (cluster/install.sh), which
# brings up kagent with the built-in kagent-tool-server (default Kubernetes
# tooling) enabled.
#
#   bash agents/install-agents.sh
#
# Credentials (read from the environment, injected at apply time — never committed):
#   GH_PAT         fine-grained PAT scoped to the ONE demo repo
#                      (Contents RW · Issues RW · Pull requests RW; NO org/admin).
#                      Required for the BMAD crew to touch GitHub.
#
# Idempotent: every step is `kubectl apply`, so re-running reconciles.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../cluster/versions.env
source "${REPO_ROOT}/cluster/versions.env"

log()  { printf '\033[1;34m[agents]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[  ok  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ warn ]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ fail ]\033[0m %s\n' "$*" >&2; }

kubectl cluster-info >/dev/null 2>&1 || { err "cluster not reachable — run cluster/install.sh first"; exit 1; }
command -v envsubst >/dev/null || { err "envsubst not found (gettext) — needed to inject tokens at apply time"; exit 1; }
kubectl get ns kagent >/dev/null 2>&1 || { err "namespace kagent missing — run cluster/install.sh (Phase 2) first"; exit 1; }

# WORKSHOP_PREFIX — isolation prefix (ISI-6986 / ISI-7005). Agent/MCP manifests
# template OTel attributes (service.name etc.) with it via envsubst (SUBST_VARS).
# An explicit valid value wins; otherwise derive a deterministic, valid per-attendee
# prefix from the Codespace identity so this standalone Phase 3 step still renders
# instead of fail-closing. Self-contained copy of resolve_workshop_prefix from
# .devcontainer/bootstrap/lib.sh — keep in sync. Do NOT rename the kagent ns.
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
  warn "WORKSHOP_PREFIX unset/invalid ('${_raw_prefix}') — using '${WORKSHOP_PREFIX}' (auto-derived; set it in Codespace secrets to pick your own isolation label). Must match what cluster/install.sh used."
fi
export WORKSHOP_PREFIX

# --- preflight: default Kubernetes tooling must be present ------------------
if ! kubectl -n kagent get remotemcpserver kagent-tool-server >/dev/null 2>&1; then
  warn "kagent-tool-server not found — the SRE agent's k8s/networking tools need it."
  warn "Enable it: set kagent-tools.enabled=true in cluster/kagent/values.yaml and re-run cluster/install.sh."
fi

# --- cleanup: purge pre-removal Dynatrace MCP orphans -----------------------
# The Dynatrace MCP server was removed from the workshop (ISI-6935). This script
# is apply-only — it never deletes objects dropped from the manifest set — so a
# re-run on a cluster provisioned by a PRE-removal release leaves the old CRs
# behind: the `dynatrace-mcp` MCPServer (+ its backing Deployment/Service) and
# the `dynatrace-mcp-remote` RemoteMCPServer. Anything still referencing them
# (or the controller trying to extract their tools) then fails with
# `Post "http://dynatrace-mcp.kagent:3000/mcp": context deadline exceeded`.
# Purge them idempotently on every run so a redeploy from current main is clean.
log "cleanup  purging any pre-removal Dynatrace MCP orphans"
kubectl -n kagent delete remotemcpserver dynatrace-mcp-remote --ignore-not-found
kubectl -n kagent delete mcpserver       dynatrace-mcp        --ignore-not-found
# Backing workload the old MCPServer's deployment spec created — kagent usually
# garbage-collects these via owner refs when the MCPServer goes, but delete them
# explicitly in case the owner chain was already broken on an orphaned install.
kubectl -n kagent delete deployment      dynatrace-mcp        --ignore-not-found
kubectl -n kagent delete service         dynatrace-mcp        --ignore-not-found
ok "Dynatrace MCP orphans cleared (if any were present)"

# --- credentials ------------------------------------------------------------
export GITHUB_MCP_IMAGE
# Accept GITHUB_TOKEN (Codespaces injects one) as a fallback for GH_PAT. A
# fine-grained PAT scoped to the demo repo is strongly preferred for the write demo.
export GH_PAT="${GH_PAT:-${GITHUB_TOKEN:-}}"

[ -n "${GH_PAT}" ]        || warn "GH_PAT unset — BMAD crew installs but GitHub tools will not authenticate."

# WORKSHOP_LLM_BASE_URL — the agent LLM endpoint (DeepSeek by default, or the
# per-attendee LiteLLM-proxy endpoint when a room password dispensed one; ISI-6996).
# Exported by cluster/versions.env (sourced above); injected into the ModelConfig's
# openAI.baseUrl via envsubst so NO raw endpoint/key is committed.
export WORKSHOP_LLM_BASE_URL

# Only these vars are substituted; every other $ in the manifests is left intact.
SUBST_VARS='${GITHUB_MCP_IMAGE} ${GH_PAT} ${WORKSHOP_PREFIX} ${WORKSHOP_LLM_BASE_URL}'

# --- 1/3  MCP layer: shared ModelConfig + GitHub tool server -----------------
# Applied file-by-file (NOT via kustomize) so envsubst can inject the ${...}
# token/image placeholders on the raw files before apply.
log "1/3  MCP wiring (workshop-llm ModelConfig + GitHub MCP server)"
for f in 00-modelconfig.yaml 10-github-mcp.yaml; do
  envsubst "${SUBST_VARS}" < "${SCRIPT_DIR}/mcp/${f}" | kubectl apply -f -
done
ok "MCP layer applied"

# --- 2/3  SRE agent ----------------------------------------------------------
# Rendered through envsubst so ${WORKSHOP_PREFIX} in the Agent name/modelConfig
# resolves (kustomize alone does not expand env vars). `kubectl kustomize` builds
# the overlay (namespace injection) first, then envsubst substitutes only the
# whitelisted vars, then apply.
log "2/3  SRE agent"
kubectl kustomize "${SCRIPT_DIR}/sre" | envsubst "${SUBST_VARS}" | kubectl apply -f -
ok "SRE agent applied"

# --- 3/3  BMAD crew ----------------------------------------------------------
log "3/3  BMAD crew (analyst, pm, architect, developer, qa, orchestrator)"
kubectl kustomize "${SCRIPT_DIR}/bmad-crew" | envsubst "${SUBST_VARS}" | kubectl apply -f -
ok "BMAD crew applied"

# Names below carry your ${WORKSHOP_PREFIX}; envsubst resolves them so the printed
# commands are copy-pasteable as-is (kagent-tool-server is the Helm built-in — never prefixed).
envsubst "${SUBST_VARS}" <<'EOF'

================================================================
 Phase 3 agents & MCP wiring applied.

 Verify the tool servers registered their tools:
   kubectl -n kagent get mcpserver,remotemcpserver
   kubectl -n kagent get remotemcpserver kagent-tool-server                -o jsonpath='{.status.discoveredTools[*].name}'; echo
   kubectl -n kagent get remotemcpserver ${WORKSHOP_PREFIX}-github-mcp-remote -o jsonpath='{.status.discoveredTools[*].name}'; echo

 Verify the agents are Accepted:
   kubectl -n kagent get agents

 Sample prompts over A2A (controller on :8083) — SRE agent:
   kubectl run a2a --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n kagent \
     --command -- curl -s -m 300 -X POST -H 'Content-Type: application/json' \
     --data '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","messageId":"m1","kind":"message","parts":[{"kind":"text","text":"List the pods in the kagent namespace and tell me if any are unhealthy."}]}}}' \
     http://kagent-controller.kagent:8083/api/a2a/kagent/${WORKSHOP_PREFIX}-sre-agent

 BMAD orchestrator (swap the text for your demo repo + task):
   ... http://kagent-controller.kagent:8083/api/a2a/kagent/${WORKSHOP_PREFIX}-bmad-orchestrator

 Or use the kagent UI:  kubectl -n kagent port-forward svc/kagent-ui 8080:8080

 Traces: kagent otel.tracing (Phase 2) fans agent LLM/tool spans to Dynatrace +
 Phoenix via otel-gateway-collector.opentelemetry-operator-system.svc:4317.
================================================================
EOF
