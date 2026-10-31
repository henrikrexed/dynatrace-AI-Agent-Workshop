# 06 — Evaluate (Phoenix)

Observability (module 04) tells you *what the agent did* and *what it cost*. It
does **not** tell you whether the answer was correct, grounded, or useful. That's
**evaluation** — scoring agent outputs against expectations — and it's the step
most teams skip, which is why their agents quietly regress.

This module's evals read the **same `gen_ai.*` spans** the OTel gateway already
produces (module 02/04) — you don't re-run the agents to grade them, you grade the
traces they already emitted. In this workshop you **create your evaluation in Arize
Phoenix**:

- **Phoenix (Arize)** — the **recommended path**. An interactive trace + eval UI,
  already running from module 01, where you **build and run an LLM-as-a-judge
  evaluation entirely in the web UI** (no code) using the preconfigured DeepSeek
  judge. This is *the* way you create an evaluation here.
- **dt-evals** — a brief **alternative** for teams that want eval scores to land
  **inside Dynatrace** as bizevents, next to the rest of their telemetry. In this
  workshop it is **being replaced by Phoenix** — kept below as a short reference,
  not the main event.

Everything for this module lives under
[`evals/`](https://github.com/henrikrexed/dynatrace-AI-Agent-Workshop/tree/main/evals).
Both paths reuse the cost-efficient workshop judge — **DeepSeek** (`deepseek-chat`),
the same model that powers the agents — set once in `evals/.env`
(copy from `evals/.env.example`).

!!! warning "Generate traffic first"
    Evals score real traces. Drive the SRE agent or a BMAD task (module 02)
    **before** running either path, so there are spans to grade.

---

## Part A — Phoenix: create an evaluation in the UI

Phoenix is **how you create an evaluation in this workshop**: you build **and** run
an LLM-as-a-judge evaluation entirely in the web UI — no code — scored by the same
**DeepSeek** model that powers the agents. Open Phoenix on the forwarded Codespace
port **6006**:

```bash
kubectl -n phoenix port-forward svc/phoenix 6006:6006
# then open http://localhost:6006
```

Every agent run shows up as an LLM trace: prompt, response, tool spans, token
counts. Click a span to see its `gen_ai.*` attributes. Module 04's gateway now
also surfaces each LLM call's prompt and completion as OpenInference
`input.value` / `output.value`, so the **Input** and **Output** are visible right
in the trace view — which is exactly what the judge reads.

!!! tip "The DeepSeek judge is already wired"
    The workshop's Phoenix is preconfigured for DeepSeek (`DEEPSEEK_API_KEY` is
    injected from your Codespace key, and `PHOENIX_ALLOWED_PROVIDERS=DEEPSEEK`
    restricts the model menu), so **DeepSeek is the only — and obvious — choice**
    everywhere you pick a judge model. You never hand-enter a key. If your Phoenix
    is *not* preconfigured, add the key once under **Settings → AI Providers →
    DeepSeek** and it behaves the same from there on.

### Create and run an LLM-as-a-judge (no code)

You'll score the SRE-agent traces from your last run against a judge classifier —
start with **hallucination** (is the answer grounded in the tool output it was
given?) or **relevance** (does it actually answer the question?).

1. **Pick the traces.** Open your project's **Traces** table and select the
   SRE-agent runs you want to grade (filter to the `agent.run` / LLM spans so each
   example carries a clean question → answer pair).
2. **Capture them as a dataset.** Use **Add to Dataset** to save the selected
   spans as a dataset — each example keeps the span's **Input** (the question) and
   **Output** (the agent's answer). This is the set the judge will score.
3. **Add an LLM evaluator.** Open the new dataset → **Evaluators** tab →
   **Add evaluator** → **LLM**. Phoenix opens it in the **Playground**:
     - **Model:** DeepSeek (the only provider in the menu — already keyed).
     - **Template:** write the judge prompt, e.g. *“You are grading whether the
       ANSWER is grounded in the provided CONTEXT/question. Reply with a single
       label: `hallucinated` or `factual`.”* (or a relevance rubric:
       `relevant` / `irrelevant`).
     - **Input mapping:** map the template's `{question}` / `{answer}` variables
       to the dataset's **input** / **output** fields.
     - **Test** it on one example to see the label + explanation, then **Save**.
4. **Run it.** From the dataset, **Run** an experiment in the Playground. Phoenix
   calls the DeepSeek judge **server-side** over every example — no local runtime.

### Read the scores

The experiment's results table gains one **label / score column per evaluator**.
Sort by it to surface the weakest answers, and click any row to read the judge's
**label, score, and explanation** next to that example's input and output. That is
your end-to-end eval — created, run, and read entirely in the Phoenix UI: fast,
visual, and the recommended way to grade these agents.

### Script the same judge instead (optional / advanced)

The UI flow above is the fast path. The repo also ships a small, version-pinned
script that builds the same two classifiers (**hallucination** + **relevance**)
from code — handy for CI, for grading the **live** spans in place, or when you
have no traffic yet:

```bash
cd evals && uv sync
# Bundled sample dataset — no cluster/traffic needed (just a judge key):
uv run python phoenix/run_phoenix_eval.py
# Live spans pulled from Phoenix, scores logged back onto the traces:
uv run python phoenix/run_phoenix_eval.py --from-phoenix
```

It prints a per-metric summary, writes `phoenix/out/phoenix_eval_results.csv`,
and (with `--from-phoenix`) annotates the originating spans so the labels show up
on the traces in the UI. Details: [`evals/phoenix/README.md`](https://github.com/henrikrexed/dynatrace-AI-Agent-Workshop/blob/main/evals/phoenix/README.md).

!!! note "`--from-phoenix` needs message content on the spans"
    The live path maps prompt/response content out of your spans in every common
    shape our agents emit — OTel GenAI semconv (`gen_ai.input.messages`, indexed
    `gen_ai.prompt.N.content` / `gen_ai.completion.N.content`, or `gen_ai.*`
    log-events) as well as OpenInference (`input.value` / `output.value` — the
    pair the gateway now also populates). If it still finds no content, it prints
    exactly which `attributes.*` were present so you can see what to add. The
    usual cause is instrumentation that **drops message bodies by default** —
    enable content capture and re-drive the agents (see the README). The bundled
    dataset path always works offline.

---

## Part B — dt-evals: scores inside Dynatrace (optional)

!!! note "Phoenix (Part A) is the workshop's recommended path"
    dt-evals remains for teams that want eval scores **inside Dynatrace**. In this
    workshop it is **being replaced by Phoenix** — kept here as a short reference,
    not a required step.

[`dt-evals`](https://github.com/dynatrace-oss/dt-evals) is a config-driven CLI that
samples `gen_ai.*` spans from your Dynatrace environment, scores each with an LLM
judge, and writes `gen_ai.evaluation.result` **bizevents** back — so a low score is
one click from the trace, prompt, and tool calls that caused it. Where Part A had
you *create* an evaluation by clicking, this path has you **create one as a config
file** — and that distinction is the whole point of the section: you don't just run
a script, you **open the config and see that the config _is_ the evaluation**, then
run it.

#### The config is the evaluation

Open [`evals/dt-evals/workshop-agents.dt-eval.yaml`](https://github.com/henrikrexed/dynatrace-AI-Agent-Workshop/blob/main/evals/dt-evals/workshop-agents.dt-eval.yaml).
Four blocks define the whole evaluation — grade **what**, judged **by whom**, scored
on **which metrics**, failing **when**:

| Block | What you're declaring | Authoring question |
|-------|-----------------------|--------------------|
| `scope` | which spans to pull (`service`, `since`, `sampling`) | *What do I grade?* |
| `judge` | the LLM-as-a-judge (DeepSeek, OpenAI-compatible) | *Who grades it?* |
| `metrics.enabled` | the rubrics to run (relevance, faithfulness, hallucination, coherence, toxicity, prompt-injection) | *What am I scoring for?* |
| `alerts.thresholds` | the pass/fail bar per metric that makes the run exit non-zero | *When does it fail?* |

```yaml
scope:
  service: ${DT_EVAL_SERVICE}   # which agent's spans — you set this below
  since: 2h
  sampling: { strategy: latest, count: 25 }
metrics:
  enabled: [relevance, faithfulness, hallucination, coherence, toxicity, prompt-injection]
alerts:
  thresholds:
    hallucination: 0            # fail if ANY hallucination is detected
    relevance: 0.6              # fail below 0.6
```

**Author it in two edits.** Point `scope` at *your* agent by setting
`DT_EVAL_SERVICE` (it fills `scope.service` at render time — discover it, don't
guess; defaults to `sre-agent`), and set the gate by tightening a
`alerts.thresholds` line — e.g. `relevance: 0.8` to demand strongly on-topic
answers. Those two edits *are* the evaluation; the run below just executes it.

**Credentials** live in `evals/.env`: a **dedicated** Dynatrace `dt0c01` token
(`storage:spans:read` + `storage:events:write`), your `…apps.dynatrace.com` URL, and
a judge key (a DeepSeek key works). For the exact scopes and where each token is
generated, see
**[Start the benchmark → Create the required tokens](start-benchmark.md#4-create-the-required-tokens)**.

```bash
cd evals/dt-evals
export DT_EVAL_SERVICE="sre-agent"   # the service.name you discovered
./run-dt-eval.sh                     # renders the config, then runs validate + run
```

The run exits non-zero on a threshold breach — a ready-made CI gate. Read the
scores back in a Dynatrace Notebook:

```dql
fetch bizevents
| filter event.type == "gen_ai.evaluation.result"
| summarize avg(toDouble(gen_ai.evaluation.score.value)), by: { gen_ai.evaluation.name }
```

Details, including the shared-vs-per-attendee tenant model:
[`evals/dt-evals/README.md`](https://github.com/henrikrexed/dynatrace-AI-Agent-Workshop/blob/main/evals/dt-evals/README.md).

---

## Part C — grade a *diagnosis* against the answer key

Parts A/B judge generic quality (grounded? relevant? toxic?). The **diagnostic
module** ([05 — Diagnose](05-diagnose.md)) asks a sharper question: when the SRE
agent investigates a *real* injected fault, **did it reach the right root
cause?** Each scenario ships an objective answer key —
`scenarios/<id>/expected-diagnosis.md` — and those keys are **registered as this
module's diagnosis-grading ground truth** under
[`evals/ground-truth/`](https://github.com/henrikrexed/dynatrace-AI-Agent-Workshop/tree/main/evals/ground-truth).

The grading check:

> Did the diagnosis cite **≥ `pass_threshold`** of the answer key's required
> signals (root cause + evidence channel), identify the root cause, and avoid the
> forbidden cross-channel claims?

Because scenarios 01–03 sit on **distinct evidence channels** (logs vs. events vs.
`OOMKilled` status), a cross-channel claim is an unambiguous fail — so this grades
objectively, even with no judge model.

### Deterministic grade (offline, no key) — recommended

```bash
cd evals
uv run python phoenix/run_diagnosis_eval.py        # bundled golden + confab diagnoses
```

It prints a PASS/FAIL per diagnosis and writes
`phoenix/out/diagnosis_eval_results.csv`. Add `--llm-judge` (needs a judge key) to
also run an LLM root-cause grader, or `--from-phoenix` to grade the agent's *live*
diagnosis spans and annotate them back onto the traces.

### Author a custom evaluator in Dynatrace (dt-evals — optional)

For teams using Part B, the sharpest form of authoring is to **write your own
evaluator** — a rubric that encodes exactly what a correct diagnosis of *one*
scenario must say. Each answer key is compiled into one, so you read it, register
it, enable it, and run it.

**1. Read the rubric.** Open
[`evals/dt-evals/evaluators/diagnosis-01-crashloopbackoff.md`](https://github.com/henrikrexed/dynatrace-AI-Agent-Workshop/blob/main/evals/dt-evals/evaluators/diagnosis-01-crashloopbackoff.md).
Its **Judge prompt** section *is* the evaluator — a binary grader (1 = correct,
0 = incorrect) with three clauses: it must **identify the root cause**, **cite ≥ 3
required signals** (`reason: CrashLoopBackOff`, the `Back-off restarting failed
container` event, a non-zero `exitCode`, the fatal log line), and make **none of
the must-not-claim** cross-channel confabulations (image-pull, OOM, probe,
node/quota). That *required-signals + must-not-claim* shape is the pattern for
authoring any objective grader. (Generated from the answer key — regenerate with
`uv run python dt-evals/gen_diagnosis_evaluators.py`, don't hand-edit.)

**2. Register it, enable it, run it.** Register writes your rubric into the local
custom-evaluator store; enabling it means uncommenting its line under
`metrics.enabled` (and the matching `alerts.thresholds`) in
[`scenario-diagnosis.dt-eval.yaml`](https://github.com/henrikrexed/dynatrace-AI-Agent-Workshop/blob/main/evals/dt-evals/scenario-diagnosis.dt-eval.yaml);
then run scoped to the one scenario you diagnosed:

```bash
cd evals/dt-evals
# Register once — paste the judge prompt from evaluators/diagnosis-01-crashloopbackoff.md
./run-dt-eval.sh evaluators add
# Then grade the diagnosis spans for that scenario:
./run-dt-eval.sh --config scenario-diagnosis.dt-eval.yaml --metric diagnosis-01-crashloopbackoff
```

Swap in the evaluator name for the scenario you ran —
`diagnosis-01-crashloopbackoff`, `diagnosis-02-imagepullbackoff`,
`diagnosis-03-oomkilled`, or `diagnosis-12-intermittent-5xx` (one per
`evaluators/*.md`; register and enable whichever you're grading).
`./run-dt-eval.sh evaluators add` is a passthrough to the pinned `dt-evals` CLI,
so there is nothing to export first.

Correct diagnoses score 1, misses score 0 — a per-scenario pass/fail bizevent next
to the trace. Details:
[`evals/ground-truth/README.md`](https://github.com/henrikrexed/dynatrace-AI-Agent-Workshop/blob/main/evals/ground-truth/README.md).

!!! tip "Closing the diagnose → evaluate → optimize loop"
    The same diagnosis runs you grade here emit the `gen_ai.*` spans whose
    token/cost/latency drive **[07 — Optimize](07-optimize.md)**. Break it
    ([05 — Diagnose](05-diagnose.md)), grade it (06), cut the waste (07).

---

## What to measure for *these* agents

| Agent | Good eval questions |
|-------|---------------------|
| **SRE agent** | Did it correctly identify the unhealthy pod? Did it call the right k8s/Dynatrace tool (not guess)? Was the diagnosis grounded in real tool output (no hallucinated pod names)? |
| **BMAD crew** | Did the workflow produce the expected artifacts (issues → branch → PR)? Did the developer agent stay within its repo scope? Did it finish within a token budget? |

## What you achieved (acceptance)

- You **created an evaluation in the Phoenix UI** (dataset → evaluator → judge)
  and read its labelled scores — no code. This is the workshop's recommended path.
- *(Optional)* You saw how the same evaluation is **authored as a dt-evals config**
  — set its scope and alert gate, run it, and the scores land **inside Dynatrace**
  as queryable bizevents with a CI-friendly pass/fail gate.
- *(Optional)* You can **author a custom evaluator** (Part C) — a required-signals
  + must-not-claim rubric — register and enable it, and grade an SRE-agent
  diagnosis PASS/FAIL against the scenario answer key, offline or in Dynatrace.

Next: **[07 — Optimize](07-optimize.md)** — now that you can *measure* cost and
quality, go cut the waste.
