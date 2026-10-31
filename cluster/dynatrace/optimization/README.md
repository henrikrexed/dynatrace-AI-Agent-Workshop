# Phase 5 · AI Agent Optimization artifacts (ISI-6720)

Dynatrace artifacts that turn the kagent crew's `gen_ai.*` spans into the three
optimization signals from **[`docs/06-optimize.md`](../../../docs/06-optimize.md)**
(token spend, unused tools, inefficient loops), a reproducible **before/after**
story, and a **continuous guardian** that gates cost + quality regressions.

All four are **dtctl-ready YAML** — `dtctl apply`/`dtctl create` straight from
this directory. Every DQL/SLI was validated against live crew telemetry before
commit.

| File | Kind | Deploy |
|------|------|--------|
| `ai-agent-optimization.dashboard.yaml` | Dashboard | `dtctl apply -f ai-agent-optimization.dashboard.yaml` |
| `ai-agent-optimization-before-after.notebook.yaml` | Notebook | `dtctl create notebook -f ai-agent-optimization-before-after.notebook.yaml` |
| `ai-agent-quality-cost.guardian.yaml` | Site Reliability Guardian (settings) | `dtctl create settings -f ai-agent-quality-cost.guardian.yaml --schema app:dynatrace.site.reliability.guardian:guardians --scope environment` |
| `ai-agent-optimization.workflow.yaml` | Workflow (scheduled guardian run) | `dtctl create workflow -f ai-agent-optimization.workflow.yaml` |
| `tool-grants.lookup.json` | Lookup table (tools each agent is granted) | embedded inline in the dashboard/notebook coverage query — no deploy needed (or upload as a native Dynatrace lookup table) |

## Prerequisites

- A Dynatrace tenant receiving OTLP from the Phase 2/3 cluster (the kagent crew
  emits `gen_ai.*` spans under `service.namespace == "kagent"`).
- `dtctl` authenticated against that tenant
  (`dtctl config use-context <your-context>`; verify with `dtctl auth whoami`).

## Deploy (in order)

```bash
dtctl config use-context <your-tenant>

# 1 · Dashboard + notebook (find the waste, tell the before/after story)
dtctl apply -f ai-agent-optimization.dashboard.yaml
dtctl create notebook -f ai-agent-optimization-before-after.notebook.yaml

# 2 · Guardian (the continuous cost + quality gate)
dtctl create settings -f ai-agent-quality-cost.guardian.yaml \
  --schema app:dynatrace.site.reliability.guardian:guardians --scope environment

# 3 · Workflow that runs the guardian daily. It references the guardian by
#     objectId — after step 2, grab the new objectId and set it in the workflow:
dtctl get settings --schema app:dynatrace.site.reliability.guardian:guardians \
  -o json --plain | grep -B2 "AI Agent Quality"      # -> objectId
#     edit ai-agent-optimization.workflow.yaml -> tasks.run_validation.input.objectId
dtctl create workflow -f ai-agent-optimization.workflow.yaml
```

> The workflow ships with its schedule **disabled**
> (`trigger.schedule.isActive: false`). Flip it to `true` to go continuous.

The dashboard/notebook YAML carry **no `id`** — the server assigns one on first
deploy. To *update* a dashboard later, download it first
(`dtctl get dashboard <id> -o yaml --plain > file.yaml`), edit, and re-`apply` —
this preserves UI edits.

## The guardian

A Site Reliability Guardian is the regression gate behind the optimization loop.
Three DQL objectives, all validated against live telemetry:

| Objective | SLI (crew, LLM-call spans) | Rule | target / warning |
|-----------|----------------------------|------|------------------|
| Cost per LLM call | avg input tokens / call | `<=` | 20000 / 18000 |
| Loop efficiency | avg LLM-call hops / task | `<=` | 5 / 4 |
| Answer substance (quality proxy) | avg output tokens / call | `>=` | 200 / 300 |

> **Which span is an "LLM call"?** The SLIs no longer filter on
> `span.name == "call_llm"` — on the current kagent/ADK emission that guard
> silently zeroed token sums. They now key on `isNotNull(gen_ai.usage.*_tokens)`:
> any span carrying usage tokens *is* an LLM call. Same correction is applied to
> the dashboard and notebook so all assets stay in lockstep.

The quality proxy backstops the cost cuts: an agent that got "cheaper" by
emitting empty/truncated answers trips it. For the **LLM-judge** quality gate
(relevance, faithfulness, hallucination), pair this with the Phase-4 dt-evals
suite ([`evals/dt-evals`](../../../evals/dt-evals)) — that is the complementary
gate the workflow narrative references.

## Tool-coverage lookup — never-called tools (ISI-6972)

`tool-grants.lookup.json` is the source-of-truth table of every tool each agent
is **granted** (generated from `agents/sre/sre-agent.yaml` and
`agents/bmad-crew/*.yaml` `toolNames`). The dashboard's **Tool coverage** tile
and the notebook's **tool-coverage** cell left-join it against the tools an agent
**actually called** in traces and flag the zero-call rows — the prime "remove
tools the agent never uses" cut:

```
data record(tool = "k8s_get_resources"), record(tool = "k8s_describe_resource"), … /* the agent's granted set */
| lookup [
    fetch spans
    | filter service.namespace == "kagent" and service.name == "seta_sre_investigator"
        and gen_ai.operation.name == "execute_tool" and gen_ai.tool.name != "(merged tools)"
    | summarize calls = count(), by:{tool = gen_ai.tool.name}
  ], sourceField:tool, lookupField:tool, prefix:"called_"
| fieldsAdd calls = coalesce(called_calls, 0)
| fieldsAdd verdict = if(calls == 0, "NEVER CALLED — drop candidate", else: "used")
| sort calls asc
```

- The granted set is embedded **inline** (`data record(...)`) so the query is
  self-contained — no table upload required. The JSON file is the maintainable
  source you regenerate the inline block from when `toolNames` changes.
- The per-agent `service.name` filter is **intentional** (coverage is a per-agent
  question). To score another agent, swap the `service.name` and the inline rows
  for that agent (filter the JSON on `agent`/`traceServiceName`).
- The `tool` join key must match `gen_ai.tool.name` as emitted on your tenant.
  `seta_sre_investigator` + the `k8s_*` names are confirmed in the reference
  tenant; the `bmad_*` service names follow the observed `bmad_<role>` pattern —
  confirm them (and whether GitHub-MCP tool names are prefixed) before trusting a
  crew-wide join.

## Reference deployment (ISI-6720)

First deployed to `oat05854.dev.apps.dynatracelabs.com`:

- Dashboard `70385f20-36c4-4a82-bf33-eef1a2d03855`
- Notebook `600cc6ab-8874-40ad-8e80-8a9c24806084`
- Guardian `de5dde8f-c585-3e6a-a115-daa7f4d263ca`
- Workflow `70bebb93-12ab-45bd-abff-3d2997dced2b`

Queries carry no hard-coded dashboard time filter — the dashboard time-picker
and notebook section timeframes drive the window (that is how you switch between
the *before* and *after* windows). The guardian/workflow use an explicit 24h
validation window.
