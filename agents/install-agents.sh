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

# Only these vars are substituted; every other $ in the manifests is left intact.
SUBST_VARS='${GITHUB_MCP_IMAGE} ${GH_PAT}'

# --- 1/3  MCP layer: shared ModelConfig + GitHub tool server -----------------
# Applied file-by-file (NOT via kustomize) so envsubst can inject the ${...}
# token/image placeholders on the raw files before apply.
log "1/3  MCP wiring (workshop-llm ModelConfig + GitHub MCP server)"
for f in 00-modelconfig.yaml 10-github-mcp.yaml; do
  envsubst "${SUBST_VARS}" < "${SCRIPT_DIR}/mcp/${f}" | kubectl apply -f -
done
ok "MCP layer applied"

# --- 2/3  SRE agent ----------------------------------------------------------
log "2/3  SRE agent"
kubectl apply -k "${SCRIPT_DIR}/sre"
ok "SRE agent applied"

# --- 3/3  BMAD crew ----------------------------------------------------------
log "3/3  BMAD crew (analyst, pm, architect, developer, qa, orchestrator)"
kubectl apply -k "${SCRIPT_DIR}/bmad-crew"
ok "BMAD crew applied"

cat <<'EOF'

================================================================
 Phase 3 agents & MCP wiring applied.

 Verify the tool servers registered their tools:
   kubectl -n kagent get mcpserver,remotemcpserver
   kubectl -n kagent get remotemcpserver kagent-tool-server   -o jsonpath='{.status.discoveredTools[*].name}'; echo
   kubectl -n kagent get remotemcpserver github-mcp-remote     -o jsonpath='{.status.discoveredTools[*].name}'; echo

 Verify the agents are Accepted:
   kubectl -n kagent get agents

 Sample prompts over A2A (controller on :8083) — SRE agent:
   kubectl run a2a --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n kagent \
     --command -- curl -s -m 300 -X POST -H 'Content-Type: application/json' \
     --data '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","messageId":"m1","kind":"message","parts":[{"kind":"text","text":"List the pods in the kagent namespace and tell me if any are unhealthy."}]}}}' \
     http://kagent-controller.kagent:8083/api/a2a/kagent/sre-agent

 BMAD orchestrator (swap the text for your demo repo + task):
   ... http://kagent-controller.kagent:8083/api/a2a/kagent/bmad-orchestrator

 Or use the kagent UI:  kubectl -n kagent port-forward svc/kagent-ui 8080:8080

 Traces: kagent otel.tracing (Phase 2) fans agent LLM/tool spans to Dynatrace +
 Phoenix via otel-gateway-collector.opentelemetry-operator-system.svc:4317.
================================================================
EOF
