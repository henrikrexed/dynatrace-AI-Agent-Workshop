# Intermittent 5xx on the astronomy-shop product path

The `opentelemetry-demo-light` astronomy shop (namespace `otel-demo`) is throwing
**intermittent** errors on the product/browse path. Ask the SRE agent to
investigate — **do not tell it the root cause**. This is the partial-failure
scenario: the symptom surfaces in your **OTel signals** (the error rate on the
product path in your Dynatrace dashboards and in Phoenix), and the agent must
root-cause it in **cluster state with `kubectl`** — every pod reads `Running`, so
a pod list alone won't reveal it.

## Drive it from the kagent UI

Open the kagent UI (`http://localhost:8080`), pick **sre-agent**, and paste:

> Users of the astronomy shop (namespace `otel-demo`) are seeing intermittent
> errors when they browse products — some requests work, some fail, and every pod
> looks `Running`. Investigate the `otel-demo` namespace with `kubectl`, find the
> root cause, and tell me which service is actually at fault and why.

## Drive it over A2A (curl)

```bash
kubectl run a2a --rm -i --restart=Never --image=curlimages/curl:8.10.1 -n kagent \
  --command -- curl -s -m 300 -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"role":"user","messageId":"m1","kind":"message","parts":[{"kind":"text","text":"The astronomy shop in the otel-demo namespace is returning intermittent errors on the product browse path, yet every pod looks Running. Investigate the namespace with kubectl, find the root cause, and tell me which service is at fault and why. Cite the k8s evidence (Service endpoints, pod readiness) you relied on."}]}}}' \
  http://kagent-controller.kagent:8083/api/a2a/kagent/sre-agent
```

## What a correct answer looks like

The agent should name **`product-catalog`** as the service at fault (not the
frontend that merely surfaces the errors), note the errors are **intermittent** (a
partial error rate, not a full outage) because only a *fraction* of requests are
load-balanced to the bad endpoint, and cite the k8s evidence: the
`product-catalog` Service has an **extra, unhealthy backend** in its endpoint
rotation (`kubectl get endpoints`, pod readiness). Grade against
[`expected-diagnosis.md`](./expected-diagnosis.md).

## Prerequisite — the app must be deployed

This scenario needs the opt-in demo app and a live observe pipeline (so the
symptom shows up in your signals). If `otel-demo` is not present, `inject` fails
fast with the enable command:

```bash
helm upgrade --install otel-demo \
  oci://ghcr.io/henrikrexed/charts/opentelemetry-demo-light --version 0.2.8 \
  -n otel-demo --create-namespace \
  -f cluster/otel-demo/values-light.yaml --wait --timeout 8m
#   (or the all-in-one: INSTALL_OTEL_DEMO=true bash cluster/install.sh)
```

## Inject / clean up

```bash
bash scenarios/run.sh inject  12      # add a faulty product-catalog backend to the Service (flips in via inject.sh)
bash scenarios/run.sh cleanup 12      # remove the faulty backend (flips back via cleanup.sh) — never touches the healthy demo
```
