---
scenario: 12-intermittent-5xx
fault_family: app
namespace: otel-demo
requires: [cluster-state, otel-demo]
pass_threshold: 3
---

# Expected Diagnosis — Intermittent 5xx on the product path (service-endpoint fault)

> **App scenario — needs the opt-in `opentelemetry-demo-light` app (ISI-6847).**
> Unlike 01–03 this fault lives in the `otel-demo` namespace, but it is graded the
> same way: on **cluster state + OTel signals** the SRE agent can gather with
> `kubectl` (Service endpoints, pod logs, service connectivity) — **not** on a
> Dynatrace-tool query. The agent is k8s/OTel-only (ISI-6935); it does not call a
> Dynatrace MCP tool. If `otel-demo` is not deployed, `run.sh inject 12` fails
> fast — this scenario is skippable on the minimum tier.

## Root cause (one sentence)
A faulty `product-catalog` backend has joined the `product-catalog` Service's endpoints, so a fraction of the frontend's product requests are load-balanced to it and fail — surfacing as intermittent 5xx / gRPC errors on the astronomy-shop product/browse path, while the rest of the requests succeed.

## Required signals (grader checks the agent cited ≥ pass_threshold of these)
- the failures are **intermittent / a fraction of requests** (an elevated-but-partial error rate, not 100%), i.e. some product requests still succeed
- the errors are **5xx / gRPC errors on the product-catalog call path** (frontend → product-catalog), e.g. failed `GetProduct` / `ListProducts`
- k8s evidence: the `product-catalog` **Service has more than one endpoint and one is unhealthy/faulty** (an extra backend Pod behind the same Service — `kubectl get endpoints product-catalog`)
- the **upstream `product-catalog` backend is the cause**; the frontend only surfaces it (the frontend pods are healthy — the fault is in a downstream dependency, not the frontend)

> **Optional (not graded):** an attendee observing the tenant in the Dynatrace UI
> may also see an open Dynatrace problem with Davis pointing at `product-catalog`.
> That is a nice cross-check on the "observe in Dynatrace" path, but it is **not
> required** — the diagnosis is graded on the kubectl + OTel evidence above.

## Acceptable root-cause phrasings (any one satisfies the "root cause" check)
- "a bad product-catalog backend is serving a share of requests, causing intermittent 5xx"
- "part of the product-catalog fleet is faulty, so some frontend product requests fail"
- "an unhealthy product-catalog endpoint is the upstream cause of the intermittent errors on the frontend"

## Must NOT claim (negative signals — catch small-model confabulation)
- the **frontend itself** is the root cause (it only surfaces the upstream failure — the fault is in the `product-catalog` backend)
- a **total outage** / every request failing (the signal is *intermittent* — a partial error rate)
- a CrashLoopBackOff / OOMKilled / ImagePullBackOff of the *healthy* product-catalog pod (wrong family → scenarios 01–03)
- a database (postgres) or cart/checkout/payment outage as the primary cause without evidence

## Expected remediation (optional step — graded only if the attendee remediates)
Remove the faulty backend from rotation so the Service only routes to healthy `product-catalog` pods — `bash scenarios/run.sh cleanup 12` (the hook deletes the injected faulty Deployment; it never touches the healthy demo). An agent-driven remediation stays inside the non-destructive operate set (scale the faulty workload to 0, or re-apply the healthy manifest); no `k8s_delete_resource`.
