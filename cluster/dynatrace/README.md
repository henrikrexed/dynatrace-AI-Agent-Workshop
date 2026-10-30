# cluster/dynatrace — Dynatrace Operator (Kubernetes monitoring mode)

Installs the Dynatrace Operator via Helm and a `DynaKube` that monitors the
Codespace cluster in **k8smonitoring mode** — ActiveGate-based, **no** node
OneAgent full-stack (lightest mode, right for a single-node Codespace).

| File | Role |
|------|------|
| `values.yaml` | Helm values for `dynatrace/dynatrace-operator` (trimmed footprint). |
| `dynakube.yaml` | `DynaKube` CR (`dynatrace.com/v1beta6`); `${DT_TENANT_URL}` injected by `install.sh`. |

## Secrets

`secrets.sh` creates `secret/dynakube` in the `dynatrace` namespace from
`DT_API_TOKEN`. **The secret name must equal the DynaKube name** (`dynakube`) —
that is the operator's lookup convention.

Token scopes needed — the same `DT_API_TOKEN` is reused for the operator **and**
the OTel collector, so it must carry **all seven**: Kubernetes monitoring /
ActiveGate (`activeGateTokenManagement.create`, `entities.read`, `settings.read`,
`settings.write`) **plus** OTLP ingest (`openTelemetryTrace.ingest`,
`metrics.ingest`, `logs.ingest`). An ingest-only token leaves the DynaKube in
`Error` with `ScopeMissing` / `DynatraceApiError` conditions.

## Verify

```bash
kubectl get dynakube -n dynatrace
kubectl -n dynatrace get pods            # operator, webhook, activegate Ready
```

Cluster topology + metrics then appear under **Kubernetes** in the Dynatrace tenant.
