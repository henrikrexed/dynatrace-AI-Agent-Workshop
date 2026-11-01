#!/usr/bin/env bash
# Phase 2 — install the full platform stack into the Codespace cluster.
# Idempotent: every step is `helm upgrade --install` or `kubectl apply`, so
# re-running reconciles rather than duplicating. Safe to run after postCreate.
#
# Usage:   bash cluster/install.sh
# Secrets: read from the environment (see .devcontainer/SECRETS.md). Missing
#          secrets degrade gracefully (component skipped or warns), never crash.
# Toggles: INSTALL_<COMPONENT>=false to skip one, e.g. INSTALL_DYNATRACE=false.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "${SCRIPT_DIR}/versions.env"

log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[  ok  ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ warn ]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ fail ]\033[0m %s\n' "$*" >&2; }

INSTALL_DYNATRACE="${INSTALL_DYNATRACE:-true}"
INSTALL_OTEL="${INSTALL_OTEL:-true}"
INSTALL_TETRAGON="${INSTALL_TETRAGON:-true}"
INSTALL_KAGENT="${INSTALL_KAGENT:-true}"
INSTALL_PHOENIX="${INSTALL_PHOENIX:-true}"
INSTALL_AGENT_SANDBOX="${INSTALL_AGENT_SANDBOX:-true}"
# Opt-in ONLY (the single component defaulting false): the opentelemetry-demo-light
# app for the diagnostic module's scenario #12. Off by default so the base workshop
# and scenarios 01-03 fit the minimum 4-core/16GB Codespace. See cluster/otel-demo/.
INSTALL_OTEL_DEMO="${INSTALL_OTEL_DEMO:-false}"

kubectl cluster-info >/dev/null 2>&1 || { err "cluster not reachable — run .devcontainer/postCreate.sh first"; exit 1; }
command -v helm >/dev/null || { err "helm not found"; exit 1; }
command -v envsubst >/dev/null || warn "envsubst not found — Dynatrace apiUrl substitution will be skipped"

# WORKSHOP_PREFIX — the per-attendee isolation prefix (ISI-6986). Downstream
# manifests template namespaces + OTel attributes with it. An explicit valid value
# always wins; when unset/malformed we GRACEFULLY derive a deterministic, valid
# per-attendee prefix from the Codespace identity rather than fail-close into an
# empty cluster (ISI-7005). Self-contained copy of resolve_workshop_prefix from
# .devcontainer/bootstrap/lib.sh — kept identical so standalone `bash
# cluster/install.sh` and the devcontainer bootstrap derive the SAME value.
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
  if [ -n "$_raw_prefix" ]; then
    warn "WORKSHOP_PREFIX='${_raw_prefix}' is invalid — using normalized '${WORKSHOP_PREFIX}' so the stack still deploys. Set a valid WORKSHOP_PREFIX (${WORKSHOP_PREFIX_PATTERN}) in Codespace secrets to pick your own isolation label."
  else
    warn "WORKSHOP_PREFIX was not set — auto-derived '${WORKSHOP_PREFIX}' from your Codespace identity so the stack still deploys. Set WORKSHOP_PREFIX in Codespace secrets to pick a friendly isolation label (e.g. team-alpha)."
  fi
fi
export WORKSHOP_PREFIX

# prep-stack.sh (Phase 1) already created namespaces + classic helm repos. Make
# this script self-sufficient too (safe if already done).
for ns in dynatrace opentelemetry-operator-system kagent tetragon agent-sandbox phoenix; do
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns" >/dev/null
done
# Register the classic Helm repos ourselves (mirrors prep-stack.sh's add_repo):
# a no-op when they already exist, so deploy-on-create works even when
# postCreate.sh calls install.sh directly without first running prep-stack.sh.
# Without this, `helm repo update <name>` errors on repos that were never added
# and the first `helm upgrade --install dynatrace/...` hard-fails under set -e
# ("repo dynatrace not found"), aborting all install steps (ISI-6860).
# kagent charts are OCI pulls and need no repo add — left as-is below.
add_repo() {
  local n="$1" u="$2"
  helm repo list 2>/dev/null | awk '{print $1}' | grep -qx "$n" \
    || helm repo add "$n" "$u" >/dev/null 2>&1 \
    || warn "could not add helm repo '$n' ($u)"
}
add_repo dynatrace       https://raw.githubusercontent.com/Dynatrace/dynatrace-operator/main/config/helm/repos/stable
add_repo open-telemetry  https://open-telemetry.github.io/opentelemetry-helm-charts
add_repo cilium          https://helm.cilium.io
helm repo update >/dev/null 2>&1 || warn "helm repo update had warnings (offline?)"

# ---------------------------------------------------------------------------
# DT_TENANT_URL must be the environment (.live.dynatrace.com) domain: it serves
# both the DynaKube apiUrl (/api) and the OTLP ingest path (/api/v2/otlp). The
# platform/apps domain (.apps.dynatrace.com) is for the MCP + dtctl (DT_ENVIRONMENT)
# and does NOT serve /api/v2/otlp — exporting there returns HTTP 404 and the
# gateway drops every span (ISI-6937). Auto-correct a mis-set .apps. tenant here
# so the exported value (inherited by secrets.sh below and the envsubst at the
# DynaKube step) is always the ingest domain.
if [ -n "${DT_TENANT_URL:-}" ] && [[ "${DT_TENANT_URL}" == *".apps.dynatrace.com"* ]]; then
  export DT_TENANT_URL="${DT_TENANT_URL/.apps.dynatrace.com/.live.dynatrace.com}"
  warn "DT_TENANT_URL pointed at the .apps. (platform) domain — corrected to ${DT_TENANT_URL} for OTLP ingest + DynaKube apiUrl (set DT_ENVIRONMENT for the .apps. MCP/dtctl URL)"
fi

# ---------------------------------------------------------------------------
log "0/6  Provisioning secrets from the environment"
bash "${SCRIPT_DIR}/secrets.sh" || warn "secret step reported issues (continuing)"

# ---------------------------------------------------------------------------
if [ "$INSTALL_DYNATRACE" = "true" ]; then
  log "1/6  Dynatrace Operator (k8smonitoring mode)"
  helm upgrade --install dynatrace-operator dynatrace/dynatrace-operator \
    --version "${DT_OPERATOR_CHART_VERSION}" \
    --namespace dynatrace \
    -f "${SCRIPT_DIR}/dynatrace/values.yaml" --wait --timeout 5m
  kubectl -n dynatrace rollout status deploy/dynatrace-webhook --timeout=120s || warn "dynatrace-webhook not ready yet"
  if [ -n "${DT_TENANT_URL:-}" ] && command -v envsubst >/dev/null; then
    envsubst < "${SCRIPT_DIR}/dynatrace/dynakube.yaml" | kubectl apply -f -
    ok "DynaKube applied (tenant monitoring enabled)"
  else
    warn "DT_TENANT_URL unset (or no envsubst) — operator installed, DynaKube NOT applied; set the secret and re-run"
  fi
else
  warn "INSTALL_DYNATRACE=false — skipping Dynatrace"
fi

# ---------------------------------------------------------------------------
if [ "$INSTALL_OTEL" = "true" ]; then
  log "2/6  OpenTelemetry Operator + gateway collector"
  helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
    --version "${OTEL_OPERATOR_CHART_VERSION}" \
    --namespace opentelemetry-operator-system \
    -f "${SCRIPT_DIR}/otel/operator-values.yaml" --wait --timeout 5m
  kubectl -n opentelemetry-operator-system rollout status deploy/opentelemetry-operator --timeout=120s || warn "otel operator not ready"
  # Webhook needs a moment to register before the CR validates.
  # Render ${WORKSHOP_PREFIX} into the resource processor (k8s.cluster.name +
  # workshop.attendee) so this attendee's telemetry is isolated on the shared
  # tenant (ISI-6986). SCOPED envsubst — only ${WORKSHOP_PREFIX} is substituted,
  # leaving the collector's own ${env:...} runtime refs intact. envsubst is
  # required here (WORKSHOP_PREFIX was already validated at the top of this script).
  if command -v envsubst >/dev/null; then
    COLLECTOR_MANIFEST="$(envsubst '${WORKSHOP_PREFIX}' < "${SCRIPT_DIR}/otel/collector-gateway.yaml")"
  else
    warn "envsubst not found — collector will be applied with an unresolved \${WORKSHOP_PREFIX}; install gettext and re-run"
    COLLECTOR_MANIFEST="$(cat "${SCRIPT_DIR}/otel/collector-gateway.yaml")"
  fi
  for i in {1..15}; do
    printf '%s\n' "$COLLECTOR_MANIFEST" | kubectl apply -f - 2>/dev/null && { ok "OpenTelemetryCollector applied (workshop.attendee=${WORKSHOP_PREFIX})"; break; }
    sleep 4
  done
else
  warn "INSTALL_OTEL=false — skipping OpenTelemetry"
fi

# ---------------------------------------------------------------------------
if [ "$INSTALL_TETRAGON" = "true" ]; then
  log "3/6  Tetragon (eBPF runtime security)"
  helm upgrade --install tetragon cilium/tetragon \
    --version "${TETRAGON_CHART_VERSION}" \
    --namespace tetragon \
    -f "${SCRIPT_DIR}/tetragon/values.yaml" --wait --timeout 5m || \
    warn "Tetragon install reported issues — check eBPF/BTF support (see cluster/tetragon/README.md)"
else
  warn "INSTALL_TETRAGON=false — skipping Tetragon"
fi

# ---------------------------------------------------------------------------
if [ "$INSTALL_KAGENT" = "true" ]; then
  log "4/6  kagent (clean base — no default agents/tools)"
  helm upgrade --install kagent-crds "${KAGENT_OCI_REPO}/kagent-crds" \
    --version "${KAGENT_CHART_VERSION}" --namespace kagent --wait --timeout 5m
  # The chart's default ModelConfig base URL/model come from values.yaml (DeepSeek);
  # override them here with WORKSHOP_LLM_* (versions.env) so when a room password
  # dispensed a LiteLLM-proxy endpoint (ISI-6996) the chart default routes through
  # the proxy too — D3: ALL DeepSeek traffic via the proxy, no raw key anywhere.
  helm upgrade --install kagent "${KAGENT_OCI_REPO}/kagent" \
    --version "${KAGENT_CHART_VERSION}" --namespace kagent \
    -f "${SCRIPT_DIR}/kagent/values.yaml" \
    --set "providers.openAI.model=${WORKSHOP_LLM_MODEL}" \
    --set "providers.openAI.config.baseUrl=${WORKSHOP_LLM_BASE_URL}" \
    --wait --timeout 5m
  # Fixed-nodePort Service for the UI (chart 0.10.4 can't pin a nodePort itself).
  # kind maps nodePort 30080 -> forwarded Codespace port 8080.
  kubectl apply -f "${SCRIPT_DIR}/kagent/ui-nodeport.yaml" && ok "kagent UI NodePort (30080 -> localhost:8080) applied"
else
  warn "INSTALL_KAGENT=false — skipping kagent"
fi

# ---------------------------------------------------------------------------
if [ "$INSTALL_PHOENIX" = "true" ]; then
  log "5/6  Phoenix (LLM eval/trace UI)"
  # DEEPSEEK_BASE_URL in the manifest is injected from WORKSHOP_LLM_BASE_URL
  # (versions.env) — DeepSeek by default, or the per-attendee LiteLLM-proxy
  # endpoint when a room password dispensed one (ISI-6996). SCOPED envsubst: only
  # ${WORKSHOP_LLM_BASE_URL} is substituted, leaving every other $ intact. Falls
  # back to a plain apply if gettext is missing (manifest default base URL stands).
  if command -v envsubst >/dev/null; then
    envsubst '${WORKSHOP_LLM_BASE_URL}' < "${SCRIPT_DIR}/phoenix/phoenix.yaml" | kubectl apply -f -
  else
    warn "envsubst not found — applying Phoenix with its default (non-proxy) base URL"
    kubectl apply -f "${SCRIPT_DIR}/phoenix/phoenix.yaml"
  fi
  kubectl -n phoenix rollout status deploy/phoenix --timeout=180s || warn "Phoenix not ready yet"
else
  warn "INSTALL_PHOENIX=false — skipping Phoenix"
fi

# ---------------------------------------------------------------------------
if [ "$INSTALL_AGENT_SANDBOX" = "true" ]; then
  log "6/6  Agent Sandbox (isolation baseline)"
  kubectl apply -f "${SCRIPT_DIR}/agent-sandbox/isolation.yaml"
else
  warn "INSTALL_AGENT_SANDBOX=false — skipping Agent Sandbox"
fi

# ---------------------------------------------------------------------------
# Opt-in app dependency for the fault-injection diagnostic module (scenario #12).
# Default OFF — keeps the base install inside the 4-core/16GB Codespace floor.
# Enable with:  INSTALL_OTEL_DEMO=true bash cluster/install.sh
if [ "$INSTALL_OTEL_DEMO" = "true" ]; then
  log "opt  opentelemetry-demo-light (scenario #12 app dependency, ns: otel-demo)"
  kubectl get ns otel-demo >/dev/null 2>&1 || kubectl create ns otel-demo >/dev/null
  # Light fork publishes its own OCI chart (not a values overlay). Services export
  # OTLP straight to the workshop gateway (collector.enabled=false in values-light),
  # so the injected 5xx surfaces as a Dynatrace problem on the astronomy-shop path.
  helm upgrade --install otel-demo "${OTEL_DEMO_OCI_REPO}" \
    --version "${OTEL_DEMO_CHART_VERSION}" \
    --namespace otel-demo \
    -f "${SCRIPT_DIR}/otel-demo/values-light.yaml" --wait --timeout 8m || \
    warn "otel-demo-light install reported issues — check pods: kubectl get pods -n otel-demo"
  ok "opentelemetry-demo-light deployed (scenario #12 unblocked)"
else
  warn "INSTALL_OTEL_DEMO=false — opentelemetry-demo-light NOT deployed (scenario #12 needs 'INSTALL_OTEL_DEMO=true bash cluster/install.sh')"
fi

cat <<'EOF'

================================================================
 Phase 2 platform install complete.
   kubectl get pods -A            # all operators/components should be Ready
   kubectl get dynakube -n dynatrace
   kubectl get otelcol -n opentelemetry-operator-system

 UIs (NodePort -> forwarded Codespace ports, no port-forward needed):
   Phoenix   -> http://localhost:6006   (NodePort 30606)
   kagent UI -> http://localhost:8080   (NodePort 30080)

 Telemetry: once agents run (Phase 3), spans fan out to Dynatrace + Phoenix
 via otel-gateway-collector.opentelemetry-operator-system.svc:4317.

 Diagnostic module scenario #12 (opt-in, OFF by default):
   INSTALL_OTEL_DEMO=true bash cluster/install.sh   # deploys otel-demo-light
   kubectl get pods -n otel-demo                    # astronomy-shop services
================================================================
EOF
