# cluster/dynatrace — Dynatrace Operator (Kubernetes monitoring mode)

Installs the Dynatrace Operator via Helm and a `DynaKube` that monitors the
Codespace cluster in **k8smonitoring mode** — ActiveGate-based, **no** node
OneAgent full-stack (lightest mode, right for a single-node Codespace).

| File | Role |
|------|------|
| `values.yaml` | Helm values for `dynatrace/dynatrace-operator` (trimmed footprint). |
| `dynakube.yaml` | `DynaKube` CR (`dynatrace.com/v1beta6`); `${DT_TENANT_URL}` injected by `install.sh`. |
| `launchpad.md` | Workshop welcome page to **import into your Dynatrace tenant** (Documents / Launchpad app) so attendees land on a one-page overview — secrets, Dynatrace environment, architecture, quick start. |
| `optimization/` | Phase 5 `dtctl`-ready Dashboard · Notebook · Guardian · Workflow (see its `README.md`). |

## Secrets

`secrets.sh` creates `secret/dynakube` in the `dynatrace` namespace with two keys.
**The secret name must equal the DynaKube name** (`dynakube`) — that is the
operator's lookup convention.

| Secret key | From env | Scopes needed |
|------------|----------|---------------|
| `apiToken` | `DYNATRACE_API_TOKEN` (operator; falls back to `DT_API_TOKEN`) | Kubernetes monitoring / ActiveGate — classic: `activeGateTokenManagement.create`, `entities.read`, `settings.read`, `settings.write`; platform: `fleet-management:activegate.tokens:create`, `fleet-management:activegate.connection-info:read`, `settings:objects:read`, `settings:objects:write` |
| `dataIngestToken` | `DT_API_TOKEN` (ingest) | classic: `metrics.ingest`, `logs.ingest`; platform: `data-acquisition:metrics:ingest` (+ logs) |

The two scope sets are **disjoint**, so the workshop uses two separate tokens:
`DYNATRACE_API_TOKEN` is the operator token (it also carries the Phase-4 dt-evals
scopes) and `DT_API_TOKEN` is the ingest token (which also feeds the OTel
collector's OTLP export). An `apiToken` missing the Kubernetes-monitoring scopes
leaves the DynaKube in `Error` with `ScopeMissing` / `DynatraceApiError` — add
those scopes to `DYNATRACE_API_TOKEN`. It falls back to `DT_API_TOKEN` only when
you deliberately use one over-scoped combined token.

## Verify

```bash
kubectl get dynakube -n dynatrace
kubectl -n dynatrace get pods            # operator, webhook, activegate Ready
```

Cluster topology + metrics then appear under **Kubernetes** in the Dynatrace tenant.
