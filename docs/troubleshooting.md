# Troubleshooting

A single place for the problems attendees hit most, grouped by module. Each
component also has a deeper README under
[`cluster/`](https://github.com/henrikrexed/dynatrace-AI-Agent-Workshop/tree/main/cluster)
and [`agents/`](https://github.com/henrikrexed/dynatrace-AI-Agent-Workshop/tree/main/agents).

## First, the three catch-all checks

```bash
kubectl get pods -A | grep -vE 'Running|Completed'   # anything not healthy
kubectl get events -A --sort-by=.lastTimestamp | tail -30
bash .devcontainer/bootstrap/check-resources.sh      # CPU/memory headroom
```

!!! tip "Most failures are resources or secrets"
    On a 2-core/4GB Codespace the stack will not fit. Use **4-core / 16 GB** or
    larger (see [`.devcontainer/DECISIONS.md`](https://github.com/henrikrexed/dynatrace-AI-Agent-Workshop/blob/main/.devcontainer/DECISIONS.md)).
    The second most common cause is a missing/misscoped secret — run
    `bash .devcontainer/bootstrap/check-secrets.sh`.

---

## Module 00 — Setup

**Cluster not reachable / `kubectl` hangs.** Re-create or restart the cluster:

```bash
bash .devcontainer/postCreate.sh     # full, idempotent bootstrap
bash .devcontainer/postStart.sh      # just restart the cluster after a resume
kubectl cluster-info
```

**Secrets not detected.** Codespace secrets only apply to codespaces created
*after* they're set. Set them, then **rebuild** the container (Command Palette →
*Codespaces: Rebuild Container*), and verify:

```bash
bash .devcontainer/bootstrap/check-secrets.sh    # prints presence only, never values
```

---

## Module 01 — Platform install

**The install reports warnings but doesn't crash.** That's by design — missing
secrets degrade gracefully (a component is skipped or warns). Re-run after fixing
the secret: `bash cluster/install.sh`.

**Dynatrace: no data on the tenant.** Check `DT_TENANT_URL` / `DT_API_TOKEN` and
the ingest scopes (`openTelemetryTrace.ingest`, `metrics.ingest`, `logs.ingest`).
The OTLP export uses `DT_API_TOKEN`; the DynaKube operator uses
`DYNATRACE_API_TOKEN`. The DynaKube secret name **must equal** the DynaKube name
(`dynakube`).

```bash
kubectl get dynakube -n dynatrace
kubectl -n dynatrace get pods            # operator, webhook, activegate Ready
```

**DynaKube stuck in `Error` / `ScopeMissing`.** `kubectl describe dynakube -n
dynatrace` shows conditions such as `ActiveGateConnectionInfo … DynatraceApiError`,
`MonitoredEntity … settings:objects:write … ScopeMissing`, or
`MetadataEnrichmentRules … missing scopes`. Cause: `DYNATRACE_API_TOKEN` — the
DynaKube operator token (`apiToken`) — is missing the Kubernetes-monitoring scopes.
Add them — classic: `activeGateTokenManagement.create`, `entities.read`,
`settings.read`, `settings.write`; platform (`dt0s16`):
`fleet-management:activegate.tokens:create`,
`fleet-management:activegate.connection-info:read`, `settings:objects:read`,
`settings:objects:write` (see [Token C](start-benchmark.md#4-create-the-required-tokens)).
No new Codespace secret is needed — add the scopes to the existing
`DYNATRACE_API_TOKEN`. Fix:

```bash
# After adding the k8s-monitoring scopes to DYNATRACE_API_TOKEN (or regenerating it):
bash cluster/secrets.sh                              # refresh secret/dynakube
# Or patch the refreshed token straight in without a redeploy:
#   kubectl -n dynatrace patch secret dynakube --type merge \
#     -p "{\"stringData\":{\"apiToken\":\"<operator-token>\"}}"
kubectl -n dynatrace delete pod -l app.kubernetes.io/name=activegate  # re-read token
kubectl get dynakube -n dynatrace                    # Phase should go Running
```

**OTel operator hangs applying the collector CR.** The operator must use its
self-signed webhook cert (`autoGenerateCert`), already set in
[`otel/operator-values.yaml`](https://github.com/henrikrexed/dynatrace-AI-Agent-Workshop/blob/main/cluster/otel/operator-values.yaml).
`install.sh` retries the CR for ~60s while the webhook registers.

```bash
kubectl -n opentelemetry-operator-system get otelcol
kubectl -n opentelemetry-operator-system logs deploy/opentelemetry-operator
```

### Tetragon not Ready or CrashLooping

k3d/kind nodes share the **Codespace host kernel**; Tetragon needs BTF and probe
permissions.

```bash
kubectl -n tetragon logs ds/tetragon -c tetragon
kubectl -n tetragon get pods
```

- Confirm host BTF exists: `ls /sys/kernel/btf/vmlinux`.
- **Fallback:** run observation-only (no enforcement). `TracingPolicy` with
  `Sigkill` may be unavailable on a restricted host kernel — document it as a
  known Codespace limitation rather than blocking the workshop. See
  [`cluster/tetragon/README.md`](https://github.com/henrikrexed/dynatrace-AI-Agent-Workshop/blob/main/cluster/tetragon/README.md).

**Phoenix not Ready.** It uses one RWO PVC with `strategy: Recreate` — never two
pods on the same volume.

```bash
kubectl -n phoenix get pods
kubectl -n phoenix logs deploy/phoenix
```

---

## Module 02 — Agents & MCP wiring

**The GitHub `RemoteMCPServer` isn't `Accepted` / `discoveredTools` is empty.**
The tool server couldn't start or authenticate. Check the token and the
controller:

```bash
kubectl -n kagent get mcpserver,remotemcpserver
kubectl -n kagent describe remotemcpserver github-mcp-remote
kubectl -n kagent logs deploy/kagent-controller
```

- `GH_PAT` must be a fine-grained PAT scoped to the demo repo (Contents /
  Issues / Pull requests RW). No org/admin scopes.

**An `Agent` isn't `Accepted`.** Usually a bad `ModelConfig` or missing model
secret.

```bash
kubectl -n kagent get agents
kubectl -n kagent describe agent sre-agent
kubectl -n kagent get secret kagent-deepseek    # model key present?
```

**A2A prompt times out.** Multi-hop BMAD runs take minutes — keep the client
timeout generous (`curl -m 300`). Watch progress in the kagent UI
(`kubectl -n kagent port-forward svc/kagent-ui 8080:8080`).

**The SRE agent fails with `http://dynatrace-mcp.kagent:3000/mcp … context
deadline exceeded`.** The Dynatrace MCP server was removed from the workshop —
the SRE agent is now Kubernetes-only. This error means your cluster still holds
an **orphaned CR** from a pre-removal install: the old `dynatrace-mcp` MCPServer
and `dynatrace-mcp-remote` RemoteMCPServer were left behind, and the controller
keeps trying (and failing) to reach the server that no longer exists. Current
`main` no longer ships these manifests, so re-running the installer now
self-heals — it purges the orphans on every run:

```bash
bash agents/install-agents.sh
```

Or delete them manually:

```bash
kubectl -n kagent delete remotemcpserver dynatrace-mcp-remote --ignore-not-found
kubectl -n kagent delete mcpserver       dynatrace-mcp        --ignore-not-found
kubectl -n kagent delete deployment,service dynatrace-mcp     --ignore-not-found
```

---

## Module 03 — Secure

**A pod won't schedule into `agent-sandbox`.** That's PSA `restricted` working —
pods must be non-root, drop ALL caps, no privilege escalation, seccomp
`RuntimeDefault`. Add the required `securityContext` (see the examples in
[module 03](03-secure.md)).

**A sandboxed pod can't reach a service.** Expected — the default-deny
NetworkPolicy allows egress only to DNS and the OTel gateway. Add an explicit
egress rule if a workload legitimately needs more.

---

## Module 04 — Observe

**No agent traces in Dynatrace.** First generate traffic (send a prompt). Then
check the pipeline end to end:

```bash
kubectl -n opentelemetry-operator-system get otelcol
kubectl -n opentelemetry-operator-system logs deploy/otel-gateway-collector | tail -40
```

Confirm kagent `otel.tracing` points at
`otel-gateway-collector.opentelemetry-operator-system.svc:4317`, and that the
tenant/token scopes include `openTelemetryTrace.ingest`.

**Gateway logs `HTTP Status Code 404` / `Unimplemented` exporting to Dynatrace.**
The spans reach the collector but Dynatrace rejects the request:

```
error  Exporting failed. Dropping data.  {"otelcol.component.id": "otlphttp/dynatrace", ...
  "error": "... request to https://<env>.apps.dynatrace.com/api/v2/otlp/v1/traces
  responded with HTTP Status Code 404", "dropped_items": 3}
```

The tell is the host: `.apps.dynatrace.com`. That is the **platform/apps** domain
(the MCP + `dtctl` URL, `DT_ENVIRONMENT`) and it does **not** serve `/api/v2/otlp`.
OTLP ingest lives on the **environment** domain, `.live.dynatrace.com`. Set
`DT_TENANT_URL` to the `.live.` URL (e.g. `https://abc12345.live.dynatrace.com`)
and re-provision — `cluster/install.sh` and `cluster/secrets.sh` now auto-correct
an `.apps.` tenant to `.live.`, but a stale secret from a previous run must be
refreshed:

```bash
bash cluster/secrets.sh                                           # rebuilds secret/dynatrace-otlp
kubectl -n opentelemetry-operator-system rollout restart deploy/otel-gateway-collector
kubectl -n opentelemetry-operator-system logs deploy/otel-gateway-collector | grep -i dynatrace
```

**Gateway logs `connection refused` to `phoenix.phoenix.svc...:4317` at startup.**
Benign and self-healing — the gateway starts before Phoenix is Ready and retries.
Once Phoenix is up the `otlp/phoenix` exporter connects and the warnings stop
(the `debug` exporter also keeps logging span counts). Only investigate if it
persists after `kubectl -n phoenix get pods` shows Phoenix `Running`.

!!! note "`otlphttp`/`k8sattributes`/`resourcedetection` deprecation warnings"
    `"otlphttp" alias is deprecated; use "otlp_http"` and the matching
    `resource_detection` / `k8s_attributes` lines are informational in collector
    0.161+. The old aliases still work — not an error, no action needed.

---

## Module 05 — Diagnose

**`run.sh inject 12` exits 2 with "requires the otel-demo app".** Scenario 12 is
the opt-in app scenario. Either skip it (run 01–03) or deploy the demo once with a
single Helm install (the platform stack is already up):
`helm upgrade --install otel-demo oci://ghcr.io/henrikrexed/charts/opentelemetry-demo-light --version 0.2.8 -n otel-demo --create-namespace -f cluster/otel-demo/values-light.yaml --wait`
(or the all-in-one `INSTALL_OTEL_DEMO=true bash cluster/install.sh`). Scenarios
01–03 have no such dependency.

**`unknown/ambiguous scenario id`.** Pass a numeric prefix (`01`, `12`) or the
full dir name (`01-crashloopbackoff`); run `bash scenarios/run.sh list` to see
valid ids.

**The injected pod never appears.** `run.sh` applies into the `workshop-faults`
namespace — watch there, not `default`: `kubectl get pods -n workshop-faults`.
A fail-closed allowlist rejects (exit 2) any manifest referencing a platform
namespace *before* applying, so if inject refused, check the manifest's
`namespace:` is `workshop-faults`.

**The agent cites the wrong failure class** (e.g. "OOMKilled" for the crash
loop). That's a graded *fail*, not a tooling bug — the infra scenarios sit on
distinct evidence channels on purpose. Re-run and, if it persists, confirm the
`sre-agent` has its k8s read tools (`k8s_get_pod_logs`, `k8s_get_events`) from
module 02.

**Cleanup left something behind.** `bash scenarios/run.sh cleanup <id>` is
idempotent; for infra scenarios it deletes the whole `workshop-faults`
namespace. Re-run it, or `kubectl delete ns workshop-faults --ignore-not-found`.

---

## Module 06 — Evaluate

**Phoenix UI empty.** Same root cause as "no traces" above — fix the OTel
pipeline, then re-send prompts. Confirm the forward:

```bash
kubectl -n phoenix port-forward svc/phoenix 6006:6006   # then http://localhost:6006
```

**dt-evals can't resolve dependencies.** Run inside `evals/` with `uv`:

```bash
cd evals && uv sync
```

The concrete suite ships in module 06 — `evals/dt-evals/workshop-agents.dt-eval.yaml`
plus the Phoenix scripts are on `main`.

---

## Still stuck?

- Re-run the idempotent installers — they reconcile, they don't duplicate:
  `bash .devcontainer/postCreate.sh`, `bash cluster/install.sh`,
  `bash agents/install-agents.sh`.
- Tear down and start clean: `bash cluster/uninstall.sh`, then reinstall.
- Open an issue on the
  [workshop repo](https://github.com/henrikrexed/dynatrace-AI-Agent-Workshop/issues).
