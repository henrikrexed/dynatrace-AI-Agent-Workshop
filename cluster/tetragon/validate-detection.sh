#!/usr/bin/env bash
# validate-detection.sh — ISI-6957
#
# Prove the `detect-sensitive-file-access` TracingPolicy actually fires a real
# `security_file_permission` / `process_kprobe` event when a sandbox pod reads
# its service-account token. This is the reproducible end-to-end check behind the
# module 03 step "Detect an agent reading sensitive files".
#
# ROOT CAUSE this guards against (ISI-6953): `tetra getevents` is a LIVE stream
# with no history replay. A one-shot `cat token; sleep` reads once at pod startup
# — before you start watching — so the stream stays empty and detection looks
# broken. The snoop pod here reads the token IN A LOOP, so a read always lands
# inside the capture window.
#
# PRECONDITION: a cluster with Tetragon installed in the `tetragon` namespace and
# a working `tetra` CLI inside the DaemonSet (the workshop install does this).
#
# USAGE:   bash cluster/tetragon/validate-detection.sh
#          WATCH_SECONDS=40 bash cluster/tetragon/validate-detection.sh
# EXIT:    0 = detection fired (PASS); 1 = no event seen / precondition missing (FAIL)
set -euo pipefail

NS="${SANDBOX_NS:-agent-sandbox}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="${HERE}/sensitive-file-access.yaml"
WATCH_SECONDS="${WATCH_SECONDS:-30}"

log()  { printf '\n\033[1;34m[validate]\033[0m %s\n' "$*"; }
pass() { printf '\n\033[1;32m[ PASS ]\033[0m %s\n' "$*"; }
fail() { printf '\n\033[1;31m[ FAIL ]\033[0m %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || fail "kubectl not found on PATH"
[ -f "$POLICY" ] || fail "policy not found: $POLICY"
kubectl -n tetragon get ds/tetragon >/dev/null 2>&1 \
  || fail "Tetragon DaemonSet not found in ns 'tetragon' — install Tetragon first"

log "Ensuring namespace $NS exists"
kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS"

log "Applying TracingPolicy (idempotent)"
kubectl apply -f "$POLICY"
kubectl -n "$NS" get tracingpolicynamespaced detect-sensitive-file-access

log "Starting looping snoop pod (reads its SA token every 2s)"
kubectl -n "$NS" delete pod snoop --ignore-not-found >/dev/null 2>&1 || true
kubectl -n "$NS" run snoop --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"containers":[{"name":"snoop","image":"busybox:1.36","securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"runAsUser":65534,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}},"command":["sh","-c","while true; do cat /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null 2>&1; sleep 2; done"]}]}}' \
  --command -- sh -c 'while true; do cat /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null 2>&1; sleep 2; done'
kubectl -n "$NS" wait --for=condition=Ready pod/snoop --timeout=90s

OUT="$(mktemp)"
cleanup() {
  log "Cleaning up snoop pod (policy left in place)"
  kubectl -n "$NS" delete pod snoop --ignore-not-found >/dev/null 2>&1 || true
  rm -f "$OUT"
}
trap cleanup EXIT

log "Capturing 'tetra getevents --namespace $NS' for ${WATCH_SECONDS}s"
# kubectl exec streams forever; `timeout` bounds the capture. 124 = timed out (expected).
set +e
timeout "${WATCH_SECONDS}s" kubectl -n tetragon exec ds/tetragon -c tetragon -- \
  tetra getevents -o compact --namespace "$NS" >"$OUT" 2>&1
set -e

log "Events captured in window:"
cat "$OUT" || true

if grep -qiE 'security_file_permission|process_kprobe' "$OUT" && grep -q 'snoop' "$OUT"; then
  pass "detection fired — snoop read of the service-account token was caught"
  exit 0
fi

printf '\n\033[1;31m[ FAIL ]\033[0m no security_file_permission/process_kprobe event for snoop in %ss.\n' "$WATCH_SECONDS" >&2
printf 'Hints: confirm Tetragon pods are Ready, the policy is applied, and the host\n' >&2
printf 'kernel exposes /sys/kernel/btf/vmlinux so the kprobe can attach.\n' >&2
exit 1
