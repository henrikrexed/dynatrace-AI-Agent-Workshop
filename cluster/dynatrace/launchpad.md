# 🤖 Dynatrace AI Agent Workshop

> Build, secure, **observe**, evaluate and **cost-optimize** a multi-agent AI
> platform on Kubernetes — driven entirely from a GitHub Codespace, with
> **Dynatrace AI Observability** end to end.

---

## What you'll do today

You'll run two agent sets on a Kubernetes cluster — an **SRE agent** that
investigates a broken cluster and the **BMAD software-building crew** — then
see, prove, and cut their cost with Dynatrace. The lab is self-paced; most
attendees get through observe → diagnose → evaluate → optimize in a sitting.

1. **Stand up the platform** inside a GitHub Codespace — a single-node `kind`
   cluster with **kagent** (agents on Kubernetes), the **BMAD** crew, and the
   toolchain, all bootstrapped automatically on create
2. **Wire the agents + GitHub MCP** so the BMAD crew can open issues and PRs on
   your demo repo, powered by **DeepSeek** reached through the workshop's hosted
   model proxy (unlocked by your **room password** — no personal LLM key needed)
3. **Secure the agents** with **Tetragon** runtime security (watch an agent read
   credential files) and the Agent Sandbox
4. **Observe everything in this tenant** — an OpenTelemetry Collector streams the
   agents' **`gen_ai.*` traces, metrics, and logs** here; the **Dynatrace
   Operator + DynaKube** add Kubernetes topology to Smartscape
5. **Diagnose a broken cluster** — let the SRE agent find the root cause, then
   check its work against the telemetry
6. **Evaluate the agents** with **Phoenix (Arize)** and **dt-evals** — LLM-as-judge
   on the trace-sourced `gen_ai.*` spans (relevance, faithfulness, hallucination)
7. **Optimize** — use the Dashboard, Notebook and Site Reliability Guardian in
   this tenant to find unused tools/skills and inefficient loops, and cut token
   spend **without losing quality**

---

## ⚙️ Codespace secrets — what you set, what we provide

The Codespace bootstrap reads its credentials from GitHub **Codespace secrets**
— injected as environment variables at container start, never committed to git.
Set them on your fork: **Settings → Secrets and variables → Codespaces**.

### 🔑 Tokens (some provided by your workshop host)

Your host may hand you the Dynatrace tokens in chat or on the landing page.
**Paste them verbatim** — don't regenerate host-provided tokens yourself.

| Codespace secret | What it does |
|---|---|
| `DT_API_TOKEN` | Dynatrace **ingest** token — the OTel Collector's OTLP export (traces/metrics/logs) and the DynaKube `dataIngestToken`. Scopes: `openTelemetryTrace.ingest` · `metrics.ingest` · `logs.ingest` |
| `DYNATRACE_API_TOKEN` | Dynatrace **operator + dt-evals** token — the DynaKube `apiToken` (Kubernetes-monitoring / ActiveGate scopes) **and** the Phase-4 eval token (`storage:spans:read` · `storage:events:write`). **Distinct** from `DT_API_TOKEN` |
| `DT_PLATFORM_TOKEN` | Dynatrace **platform** token (`dt0s16`) for the `dtctl` CLI — pushes the optimization Dashboard, Notebook, Guardian, and Workflow to this tenant |

### 📝 Variables you define yourself

| Codespace secret | Example | What it does |
|---|---|---|
| `DT_TENANT_URL` | `https://abc12345.live.dynatrace.com` | This tenant's URL. The `.live.` host is the OTLP / operator ingest endpoint; `dtctl` derives the `.apps.` platform URL from it automatically |
| `WORKSHOP_ROOM_PASSWORD` | *(from your host)* | The workshop **room password** — the only model credential you supply. At startup it is exchanged, over the workshop's hosted proxy, for a per-attendee model endpoint + key powering every kagent agent **and** the Phoenix / dt-evals judge. No DeepSeek/OpenAI key needed |
| `WORKSHOP_DISPENSER_URL` | `https://litellm-proxy.<tailnet>.ts.net/dispense` | The **dispenser URL** from your host (given with the room password) — where the password is exchanged for your key. **Required**: no dispenser host is baked into the repo |
| `GH_PAT` | `github_pat_...` | A **fine-grained** GitHub PAT scoped to your demo repo only (Contents RW · Issues RW · Pull requests RW) so the BMAD crew's GitHub MCP can open issues / PRs |
| `GH_DEMO_REPO` | `your-username/bad-crew-demo` | The demo repo the BMAD crew writes to, as `owner/repo` |

> 💡 Create each token with **exactly** the scopes above — over-scoping is a
> security risk, under-scoping breaks a module. The full step-by-step is on the
> workshop's **Start the benchmark** page. Verify presence (values never printed)
> with `bash .devcontainer/bootstrap/check-secrets.sh`.

---

## 🌐 Dynatrace environment

> The Codespace bootstrap renders this page with **your** live values —
> `${DT_TENANT_URL}` and `${WORKSHOP_PREFIX}` below are filled in from the
> environment variables set on your Codespace (see
> `.devcontainer/bootstrap/render-docs.sh`). Import the rendered copy
> (`.workshop-site/launchpad.md`) into Dynatrace as your welcome doc. On the
> repo/published version these stay as literal `${…}` placeholders.

| Property | Value |
|---|---|
| **Tenant URL** | `${DT_TENANT_URL}` |
| **Your attendee prefix** | `${WORKSHOP_PREFIX}` — stamped on every span as `workshop.attendee` / `k8s.cluster.name`; your SRE agent arrives as `service.name == "${WORKSHOP_PREFIX}-sre-agent"` |
| **What lands here** | kagent `gen_ai.*` **traces** (`workshop.attendee == "${WORKSHOP_PREFIX}" and service.namespace == "kagent"`), **metrics**, **logs**, and **Kubernetes** topology in Smartscape |
| **Dashboard** | `AI Agent Optimization` — token spend, unused tools, inefficient loops (import via `dtctl apply -f cluster/dynatrace/optimization/ai-agent-optimization.dashboard.yaml`) |
| **Notebook** | `AI Agent Optimization — Before / After` — the reproducible cost-cut story |
| **Site Reliability Guardian** | `AI Agent Quality & Cost` — the continuous cost + quality regression gate |
| **Workflow** | `AI Agent Optimization` — runs the guardian on a schedule (ships disabled; flip `trigger.schedule.isActive` to `true`) |

The four optimization artifacts are **`dtctl`-ready YAML** in the repo under
`cluster/dynatrace/optimization/` — deploy them in module 07. Every DQL/SLI was
validated against live crew telemetry before commit. See that folder's `README.md`
for the exact deploy order.

---

## 🏗️ Architecture

```text
┌───────────────────────────────────────────────────────────────────┐
│  🐙  YOUR GITHUB FORK — dynatrace-AI-Agent-Workshop                │
│      Codespace secrets:                                           │
│   DT_TENANT_URL · DT_API_TOKEN · DYNATRACE_API_TOKEN              │
│   DT_PLATFORM_TOKEN · WORKSHOP_ROOM_PASSWORD                      │
│   WORKSHOP_DISPENSER_URL                                          │
│   GH_PAT · GH_DEMO_REPO                                           │
└──────────────────────┬────────────────────────────────▲──────────┘
                       │ open Codespace                 │ issues / PRs
                       ▼                                 │ (GitHub MCP)
┌──────────────────────────────────────────────────────┼──────────┐
│  💻 GITHUB CODESPACE                                  │          │
│                                                       │          │
│  ┌──────────────────────────────────────────────────┐ │          │
│  │  KIND CLUSTER  (single node)                     │ │          │
│  │                                                  │ │          │
│  │  ┌────────────────────────────────────────────┐  │ │          │
│  │  │ 🤖  kagent — AI agents on Kubernetes        │  │ │          │
│  │  │   • SRE agent  (diagnoses a broken cluster) │  │ │          │
│  │  │   • BMAD crew  (builds software) ───────────┼──┼─┘          │
│  │  │     emit gen_ai.* spans (OTel GenAI semconv)│  │            │
│  │  └──────────────────┬─────────────────────────┘  │            │
│  │                     │  OTLP/gRPC                   │            │
│  │  ┌──────────────────▼─────────────────────────┐  │            │
│  │  │ 🛡️  Tetragon — eBPF runtime security        │  │            │
│  │  │     (watches agent credential-file reads)   │  │            │
│  │  └──────────────────┬─────────────────────────┘  │            │
│  │  ┌──────────────────▼─────────────────────────┐  │            │
│  │  │ 📡  OpenTelemetry Collector                 │  │            │
│  │  │   • OTLP receiver  • filelog (pod logs)     │  │            │
│  │  │   • k8sattributes  • gen_ai normalizer      │  │            │
│  │  └──────────────────┬─────────────────────────┘  │            │
│  │  ┌──────────────────▼─────────────────────────┐  │            │
│  │  │ 🔭  dynatrace ns — Operator + DynaKube      │  │            │
│  │  │     ActiveGate (K8s monitoring; no OneAgent)│  │            │
│  │  └──────────────────┬─────────────────────────┘  │            │
│  │  ┌──────────────────┴─────────────────────────┐  │            │
│  │  │ 🧪  Phoenix (Arize) — local eval UI         │  │            │
│  │  └─────────────────────────────────────────────┘  │            │
│  └──────────────────────┼────────────────────────────┘            │
└─────────────────────────┼─────────────────────────────────────────┘
       OTLP/HTTP + token   │            K8s events + operator token
                           ▼
┌───────────────────────────────────────────────────────────────────┐
│  📊  DYNATRACE TENANT                                              │
│       gen_ai.* traces · metrics · logs · K8s entities (Smartscape) │
│                                                                   │
│   📈 Dashboard  AI Agent Optimization   — token spend, unused tools│
│   📓 Notebook   Before / After          — the cost-cut story       │
│   🛡️ Guardian   Quality & Cost          — cost + quality gate      │
│   🤖 Workflow   runs the guardian on a schedule                    │
│                                                                   │
│   ⚖️  dt-evals  — LLM-as-judge over gen_ai.* spans                 │
│         (relevance · faithfulness · hallucination)                 │
└───────────────────────────────────────────────────────────────────┘
```

**How telemetry flows:**

- The **kagent** agents (SRE + BMAD crew) emit OTLP/gRPC `gen_ai.*` spans to the
  cluster-local Collector
- The **OTel Collector** enriches with `k8sattributes`, normalizes GenAI
  attributes, then exports OTLP/HTTP to this tenant with `DT_API_TOKEN`
- The **Dynatrace Operator + ActiveGate** independently populate Smartscape with
  Kubernetes entities (deployments, pods, …) using `DYNATRACE_API_TOKEN`
- **Phoenix** runs locally in the Codespace for interactive eval; **dt-evals**
  reads the `gen_ai.*` spans back from this tenant and writes
  `gen_ai.evaluation.result` events
- The **dtctl** CLI pushes the Dashboard / Notebook / Guardian / Workflow to this
  tenant with `DT_PLATFORM_TOKEN`

---

## 🚀 Quick start

1. **Fork** [`henrikrexed/dynatrace-AI-Agent-Workshop`](https://github.com/henrikrexed/dynatrace-AI-Agent-Workshop)
   into your own GitHub account.
2. **On your fork**, go to *Settings → Secrets and variables → Codespaces* and add
   the secrets above (full scope-by-scope guide on the **Start the benchmark** page).
3. **Click *Code → Codespaces → Create codespace on `main`*** — pick a
   **4-core / 16 GB** (or larger) machine. The bootstrap builds the cluster and
   installs the agents automatically.
4. Sanity-check with `kubectl get nodes`, then open the workshop:
   `mkdocs serve -a 0.0.0.0:8000` and follow the modules in order.
5. Come back to **this tenant** to observe the agents, evaluate them, and deploy
   the optimization artifacts.

📖 Full walk-through: <https://henrikrexed.github.io/dynatrace-AI-Agent-Workshop/>

---

## 🛟 Need help during the workshop?

- 🐛 *Pod stuck pending?* `kubectl get pods -A` and look at the events
- 📭 *No `gen_ai.*` traces in this tenant?* Check the gateway collector:
  `kubectl -n opentelemetry-operator-system logs deploy/otel-gateway-collector --tail 100`
  and confirm `DT_API_TOKEN` / `DT_TENANT_URL`
- 🔭 *DynaKube in `Error` / `ScopeMissing`?* `DYNATRACE_API_TOKEN` is missing the
  Kubernetes-monitoring scopes — add them, re-run `bash cluster/secrets.sh`, then
  delete the ActiveGate pod
- 🤖 *Agents not responding?* Re-run the installer (idempotent):
  `bash agents/install-agents.sh`
- 🙋 *Stuck?* Ask in the workshop chat — include your tenant ID so we can find
  your agents in Smartscape

Happy observing! 🎉
