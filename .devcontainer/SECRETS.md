# Codespace Secrets Contract

> **Never commit secrets.** These are provided as **Codespace secrets**, injected
> as environment variables at container start. Nothing here is stored in git.
> `.devcontainer/bootstrap/check-secrets.sh` reports which are present (values are
> never printed) and runs automatically during `postCreate`.

## Where to set them

GitHub → **Settings → Codespaces → Secrets** (user-level) or the repo's
**Settings → Secrets and variables → Codespaces** (repo-level). Scope each secret
to the `henrikrexed/dynatrace-AI-Agent-Workshop` repository. After adding/rotating
a secret, **rebuild or restart the Codespace** so the new value is injected.

## Recommended: workshop prefix (auto-derived if unset)

| Variable | Purpose | Example / format |
|----------|---------|------------------|
| `WORKSHOP_PREFIX` | **Not a secret**, but prompted in the same create dialog. Isolates this attendee's objects (namespaces, OTel attributes) on the **shared** Dynatrace tenant (ISI-6986). **Strongly recommended** — it is the friendly label facilitators filter telemetry by. If unset or malformed, the bootstrap **auto-derives** a valid, per-attendee prefix from your Codespace identity so the stack still deploys (ISI-7005) — set it explicitly to choose your own label. | lowercase RFC-1123 label `^[a-z][a-z0-9-]{1,18}$` — start with a letter, 2-19 chars, e.g. `team-alpha` |

> `WORKSHOP_PREFIX` is resolved by `resolve_workshop_prefix` in
> `.devcontainer/bootstrap/lib.sh` (and the mirrored resolver in
> `cluster/install.sh`): an explicit valid value always wins; otherwise it is
> normalized or derived deterministically from `$GITHUB_USER` / `$CODESPACE_NAME`
> so nothing renders an unresolved `${WORKSHOP_PREFIX}` and no attendee lands in
> an empty cluster. Isolation is preserved — distinct GitHub identities derive
> distinct prefixes.

## Required secrets

| Variable | Purpose | Example / format |
|----------|---------|------------------|
| `DT_TENANT_URL` | Dynatrace tenant used by the Operator (k8smonitoring) and OTLP export. | `https://abc12345.live.dynatrace.com` |
| `DT_API_TOKEN` | Dynatrace **ingest** token — the OTel collector OTLP export + the DynaKube `dataIngestToken` (traces/metrics/logs ingest scopes). Classic (`dt0c01`) or platform (`dt0s16`). | `dt0c01.XXXX...` |
| `WORKSHOP_ROOM_PASSWORD` | **The only model credential you supply.** The workshop room password (given by the host, rotated per session). At startup `.devcontainer/bootstrap/dispense-llm.sh` exchanges it — over the public dispenser (Tailscale Funnel, HTTPS) — for a **per-attendee LiteLLM-proxy endpoint + a freshly minted, budget-capped virtual key**, written to the gitignored `.workshop-llm.env`. That one key powers the kagent agents **and** the Phoenix / dt-evals judge. **No raw DeepSeek/OpenAI key is needed anywhere** (ISI-6996). | the room password string |
| `WORKSHOP_DISPENSER_URL` | **The dispenser endpoint, given by the host alongside the room password.** `dispense-llm.sh` POSTs the room password here to mint your per-attendee key. **Required and fail-closed** — there is **no** host baked into the repo (the proxy is published over a rotatable Tailscale Funnel, so hardcoding it in this public repo is a leak — ISI-7000). | `https://litellm-proxy.<tailnet>.ts.net/dispense` |
| `GITHUB_TOKEN` / `GH_PAT` | Token for the **GitHub MCP** wired into the BMAD crew (Phase 3). Codespaces injects a scoped `GITHUB_TOKEN`; for the write demo provide a **fine-grained `GH_PAT`** scoped to the one demo repo (Contents RW · Issues RW · Pull requests RW; no org/admin). The installer prefers `GH_PAT`, falling back to `GITHUB_TOKEN`. | `github_pat_...` |
| `GH_DEMO_REPO` | The **BMAD/"bad crew"** demo repository the GitHub MCP writes to (issues/PRs). Explicit var so the environment test can assert it. | `owner/repo` or full URL |

> **Model traffic all routes through the room-password proxy (D3).** The agents,
> the Phoenix evals, and the dt-evals judge every reach DeepSeek via the per-attendee
> LiteLLM proxy — the real provider key lives only on the proxy host, never in the
> Codespace. `dispense-llm.sh` writes `.workshop-llm.env` (sourced by
> `cluster/versions.env` → `install.sh`/`install-agents.sh`, and by `~/.bashrc` for
> the eval shells), overriding the committed DeepSeek defaults with the proxy
> `baseUrl` + minted `virtual_key`. Re-run it after the room password rotates:
> `bash .devcontainer/bootstrap/dispense-llm.sh && bash cluster/install.sh`.
> The dispenser host is **not** baked into the repo — supply it as the required
> `WORKSHOP_DISPENSER_URL` secret (given by the host with the room password).

## Phase 3 / 5 — Dynatrace platform (`dtctl`)

The **`dtctl` CLI** (Phase 5 optimization — dashboards, notebooks, SRG,
workflows) authenticates against the Dynatrace **platform**, which uses a
different token and URL than the Phase-2 operator/OTLP pair above:

| Variable | Purpose | Example / format |
|----------|---------|------------------|
| `DT_PLATFORM_TOKEN` | Dynatrace **platform** token for `dtctl`. Distinct from `DT_API_TOKEN`. | `dt0s16.XXXX...` |
| `DT_ENVIRONMENT` | Dynatrace **platform (apps)** URL used by `dtctl`. If unset, it is derived from `DT_TENANT_URL` by swapping `.live.`→`.apps.`. | `https://abc12345.apps.dynatrace.com` |

`dtctl` reads these from the environment / its own context config.

## Phase 4 — dt-evals (trace-sourced LLM-as-judge)

The **dt-evals** CLI pulls `gen_ai.*` spans from Dynatrace and writes
`gen_ai.evaluation.result` events back. It uses its **own** token — distinct
from the Phase-2 OTLP ingest token:

| Variable | Purpose | Example / format |
|----------|---------|------------------|
| `DYNATRACE_API_TOKEN` | Dynatrace **DynaKube operator + dt-evals** token. The DynaKube `apiToken` (Kubernetes-monitoring / ActiveGate: `settings` read/write + activegate token mgmt) **and** the Phase-4 dt-evals token (`storage:spans:read` + `storage:events:write`). An operator-scope-less token leaves the DynaKube in `Error`/`ScopeMissing`. | `dt0c01.XXXX...` |
| `DT_ENV_URL` / `DT_ENVIRONMENT_URL` | dt-evals tenant URL. If unset, `run-dt-eval.sh` derives it from `DT_TENANT_URL`. | `https://abc12345.live.dynatrace.com` |
| `DT_EVAL_SERVICE` | `service.name` of the agent to evaluate — **discovered**, not a secret (optional; see `evals/dt-evals/README.md`). | `sre-agent` |

See `evals/.env.example` and `evals/dt-evals/.env.example` for the full
eval-path env files.

## Optional secrets

| Variable | Purpose |
|----------|---------|
| `DEEPSEEK_API_KEY` / `LLM_API_KEY` | **Direct** DeepSeek key — only to bypass the room-password proxy (CI / self-host). Normally unset: the virtual key is dispensed at runtime from `WORKSHOP_ROOM_PASSWORD`. If set, it populates `secret/kagent-deepseek` / `secret/phoenix-deepseek` and the judge fallback directly against `https://api.deepseek.com`. |
| `OPENAI_API_KEY` | If you switch the agents back to OpenAI (`secret/kagent-openai`). |
| `ANTHROPIC_API_KEY` | If agents target Anthropic models (`secret/kagent-anthropic`). |

## How secrets flow into the cluster

The bootstrap only **verifies presence**. The platform install consumes them, e.g.:

```bash
# Example only — the platform install owns the real manifests/Helm values.
kubectl -n dynatrace create secret generic dynatrace-tokens \
  --from-literal=apiToken="$DT_API_TOKEN" --dry-run=client -o yaml | kubectl apply -f -
```

Secrets must be referenced from env/Helm values at install time — **never** baked
into committed manifests or the devcontainer image.

## Rotation

Rotate in the GitHub Codespaces secrets UI, then rebuild the Codespace
(`Codespaces: Rebuild Container`). Re-run `bash .devcontainer/bootstrap/check-secrets.sh`
to confirm the new values are visible.

> **Facilitators:** the room password is rotated and the model proxy is
> started/torn down on the host side — see the **Host runbook (facilitator)**
> (`docs/host-runbook.md`) for the pre-session and post-session (revoke keys →
> stop funnel → destroy LXC) checklist.
