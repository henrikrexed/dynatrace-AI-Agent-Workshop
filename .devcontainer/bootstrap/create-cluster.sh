#!/usr/bin/env bash
# Create (or reuse) the local Kubernetes cluster for the workshop.
# Idempotent: if the cluster already exists it is kept as-is.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

wait_for_docker 90

if cluster_exists; then
  ok "cluster '${CLUSTER_NAME}' already exists (kind) — reusing"
else
  log "creating kind cluster '${CLUSTER_NAME}'..."
  # Render kind-config: the in-cluster mkdocs pod bind-mounts the attendee's
  # personalized site (.workshop-site/) via node extraMounts, so the hostPath
  # must be this repo's absolute path (ISI-7007). Ensure it exists first so the
  # bind mount resolves to a directory (pod uses hostPath type: Directory).
  export WORKSHOP_DOCS_HOSTPATH="${REPO_ROOT}/.workshop-site"
  mkdir -p "${WORKSHOP_DOCS_HOSTPATH}"
  KIND_CFG="${REPO_ROOT}/cluster/kind-config.yaml"
  if have envsubst; then
    KIND_CFG_RENDERED="$(mktemp /tmp/kind-config.XXXXXX.yaml)"
    # SCOPED envsubst — only the hostPath token; leave everything else verbatim.
    envsubst '${WORKSHOP_DOCS_HOSTPATH}' < "${REPO_ROOT}/cluster/kind-config.yaml" > "${KIND_CFG_RENDERED}"
    KIND_CFG="${KIND_CFG_RENDERED}"
  else
    warn "envsubst not found — kind-config \${WORKSHOP_DOCS_HOSTPATH} unresolved; the in-cluster docs mount may be empty (install gettext-base)"
  fi
  kind create cluster --config "${KIND_CFG}" --wait 120s
  ok "cluster created"
fi

# Make sure kubeconfig points at the workshop cluster.
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 || true

log "waiting for the cluster API to respond..."
for i in {1..30}; do
  if cluster_reachable; then break; fi
  sleep 2
done

if ! cluster_reachable; then
  err "cluster API not reachable after creation"
  exit 1
fi

kubectl wait --for=condition=Ready nodes --all --timeout=120s || warn "nodes not all Ready yet"
ok "cluster '${CLUSTER_NAME}' is reachable"
kubectl get nodes -o wide
