# cluster/tetragon — Tetragon (eBPF runtime security)

Installs Tetragon (`cilium/tetragon`) to observe — and optionally enforce —
process-execution and network behaviour of the agent workloads via eBPF. This is
module 5 of the workshop learning arc (securing agents).

| File | Role |
|------|------|
| `values.yaml` | Helm values for `cilium/tetragon` (DaemonSet + operator, trimmed). |
| `sensitive-file-access.yaml` | `TracingPolicyNamespaced` (observe-only) that posts an event when any process in `agent-sandbox` reads a credential path (service-account token, secrets, `/etc/shadow`, SSH keys, kubeconfig). Applied by hand in module 03. |

## eBPF on kind (important)

kind nodes are containers sharing the **Codespace host kernel**. Tetragon
loads its BPF programs into that kernel, which needs BTF (`/sys/kernel/btf/vmlinux`)
and permission to attach probes. On most GitHub Codespaces hosts this works.

If the DaemonSet pods CrashLoop or stay `NotReady`:

1. Check the logs: `kubectl -n tetragon logs ds/tetragon -c tetragon`.
2. Confirm host BTF: `ls /sys/kernel/btf/vmlinux` inside a node container.
3. **Fallback:** run Tetragon in process-visibility-only mode (no enforcement) or
   document it as a known Codespace-kernel limitation for the workshop. Enforcement
   (`TracingPolicy` with `Sigkill`) may be unavailable on a restricted host kernel.

## Demo (Phase 3+)

Once an agent runs in `agent-sandbox`, apply a `TracingPolicy` and watch exec/
network events with `kubectl -n tetragon exec ds/tetragon -c tetragon -- tetra getevents -o compact`.

For the sensitive-file detection step:

```bash
kubectl apply -f cluster/tetragon/sensitive-file-access.yaml

# Start a pod that *keeps* reading its SA token (loop — see note below).
kubectl -n agent-sandbox run snoop --image=busybox:1.36 --restart=Never \
  --command -- sh -c "while true; do cat /var/run/secrets/kubernetes.io/serviceaccount/token >/dev/null 2>&1; sleep 2; done"
kubectl -n agent-sandbox wait --for=condition=Ready pod/snoop --timeout=60s

# Watch — the read is caught within a couple of seconds.
kubectl -n tetragon exec ds/tetragon -c tetragon -- \
  tetra getevents -o compact --namespace agent-sandbox

kubectl -n agent-sandbox delete pod snoop --ignore-not-found   # clean up
```

> **Read in a loop, not once.** `tetra getevents` is a live stream with no
> history replay — it only shows events that happen *after* it attaches. A
> one-shot `cat token; sleep` reads once at startup, before you start watching,
> so the stream looks empty and detection appears broken. The loop guarantees a
> read lands inside the watch window.

See module 03 → *Detect an agent reading sensitive files* for the full step. A
reproducible end-to-end check (apply policy → loop-read → assert the event
fires) lives in [`validate-detection.sh`](validate-detection.sh), run on a live
cluster or by the `tetragon-detection` CI workflow.

## Verify

```bash
kubectl -n tetragon get pods    # tetragon DaemonSet + tetragon-operator Ready
```
