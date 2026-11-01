# Architecture Notes — Devcontainer & Codespace Bootstrap

Why the devcontainer and bootstrap are set up the way they are — cluster engine,
machine type, and tooling choices for the Codespace that runs the workshop.

## 1. Cluster engine: **kind** (single engine) + NodePort exposure

**Decision:** `kind` is the one supported cluster engine (`CLUSTER_TOOL=kind`,
set in `devcontainer.json` `containerEnv`). The workshop UIs are exposed as
**NodePort** Services whose fixed nodePorts are mapped straight through to the
forwarded Codespace ports by `cluster/kind-config.yaml` `extraPortMappings` — no
ingress controller, no manual `kubectl port-forward`.

| UI        | Service type | nodePort | kind hostPort | Codespace port |
|-----------|--------------|----------|---------------|----------------|
| Phoenix   | NodePort     | 30606    | 6006          | 6006           |
| kagent UI | NodePort     | 30080    | 8080          | 8080           |
| mkdocs    | NodePort     | 30800    | 8000          | 8000           |

**Rationale:**

- **One engine, no ambiguity.** The earlier dual k3d/kind setup made bootstrap
  behavior depend on a toggle and doubled the surface to test. kind is the
  de-facto standard for local/CI Kubernetes, runs nodes as plain Docker
  containers (so Docker-in-Docker restarts them on resume), and is well understood.
- **NodePort over ingress/LB.** kind has no built-in service LB. Rather than
  install an ingress controller just to reach two UIs, we pin each UI Service to a
  known nodePort and let kind forward the node's port to the Codespace host. This
  is the smallest, most predictable wiring and needs zero extra components.
- **Fixed nodePorts.** Phoenix's manifest sets `nodePort: 30606` directly. The
  kagent Helm chart (0.10.4) exposes `ui.service.type` but **cannot pin a
  nodePort**, so a small companion `NodePort` Service (`cluster/kagent/ui-nodeport.yaml`,
  `nodePort: 30080`) ships alongside the chart and is applied by `cluster/install.sh`.

- **mkdocs is in-cluster too (ISI-7007).** It used to run as a bare `mkdocs serve`
  process on port 8000 — not in any namespace, inconsistent with the other UIs.
  It now ships as `cluster/mkdocs/mkdocs.yaml`: a `Deployment` + fixed-nodePort
  `Service` (`30800` → host `8000`) in namespace `workshop-docs`, applied by
  `cluster/install.sh` (step 7, `INSTALL_MKDOCS=true` by default, graceful on
  failure). The pod runs the official `squidfunk/mkdocs-material` image and serves
  `.workshop-site/` — a **per-attendee render** (`.devcontainer/bootstrap/render-docs.sh`,
  scoped `envsubst`) where the DQL queries and the Dynatrace launchpad are already
  filled in with the attendee's `${WORKSHOP_PREFIX}` / `${DT_TENANT_URL}`. The
  render dir is bind-mounted into the kind nodes via `kind-config.yaml`
  `extraMounts` (hostPath rendered at create time by `create-cluster.sh`, present
  on both nodes so the pod serves wherever it is scheduled; bind mounts are live,
  so `postStart` re-renders + `rollout restart` picks up doc changes after a
  `git pull`).

> **Memory trade-off:** k3d (k3s) had a lighter footprint, which is why it was the
> original default on a 4c/16GB machine. kind + the full stack is tighter but fits;
> `onCreate`'s `check-resources.sh` still warns under the recommended floor.

> **Tetragon/eBPF note:** Tetragon needs host-kernel eBPF. kind runs nodes as
> containers sharing the Codespace host kernel. The platform install validates
> that Tetragon loads its BPF programs in the Codespace kernel; if blocked, it
> falls back to Tetragon's limited/monitoring mode.

## 2. Recommended Codespace machine type: **4-core / 16 GB** (min), prebuild on

**Decision:** recommend a **4-core / 16 GB / 32 GB-storage** machine type for the
full workshop. Declared in `devcontainer.json` `hostRequirements`. Enable a
**Codespace prebuild** on the repo so the devcontainer image + pinned tools are
cached (fast, reliable boots for attendees).

**Rationale (resource ceiling):**

- The default **2-core / 4 GB** Codespace is **insufficient** once the platform
  stack is installed. The cluster + toolchain alone fit a small machine, but the
  Dynatrace operator,
  OTel collectors, kagent, Tetragon, Phoenix, and the two agent sets together need
  well over 4 GB. `onCreate` runs `check-resources.sh`, which warns when under the
  recommended floor.
- A prebuild removes the multi-minute first-boot tool download from the attendee's
  experience and avoids rate-limit/download flakiness mid-workshop.

## 3. Tool install strategy: pinned binaries in the Dockerfile + features for DinD/gh

**Decision:** pin every tool version in `.devcontainer/Dockerfile`
(`install-tools.sh`); use official devcontainer **features** only for
Docker-in-Docker and the GitHub CLI (complex to hand-roll).

**Rationale:** reproducible prebuilds, explicit upgrade control, arch-aware
(`amd64`/`arm64`) downloads for both Intel and ARM Codespaces.

**Toolchain:** `kubectl`, `helm`, `kind`, `yq`, `dtctl`, `uv`, `node`, `dt-evals`,
and `mkdocs`. There is **no k3d** (single engine) and **no kagent CLI** — kagent is
deployed entirely via its OCI Helm chart (`cluster/install.sh`). Only
`kubectl helm kind dtctl node` are hard-required by `postCreate.sh`; `mkdocs`
(local docs preview) and `dt-evals` (npx fallback exists) are best-effort soft
warnings and never abort the bootstrap.

## 4. Idempotency model

`postCreate.sh` (once) and `postStart.sh` (every resume) are both re-runnable:
cluster creation checks existence first; `postCreate` now **deploys the full
platform** by invoking `cluster/install.sh` (every step is `helm upgrade --install`
or `kubectl apply`, and the call is non-fatal so a single failing component — e.g.
a missing secret — never bricks the Codespace). `postStart` restarts stopped kind
node containers rather than recreating the cluster. Re-running `postCreate` by hand
is safe and idempotent.

## Open questions deferred to later phases

- BindPlane live vs. illustrated — platform install.
- LLM provider powering agents + attendee key distribution — agent wiring
  (secrets contract scaffolded in `SECRETS.md`).
- Dynatrace tenant shared vs. per-attendee — evaluation/optimization modules.
- Agent Sandbox implementation choice — platform install.
