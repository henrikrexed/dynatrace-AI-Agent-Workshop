#!/usr/bin/env bash
# postCreate — runs once after the container is built (and re-runnable by hand).
# Boots the workshop cluster and preps the Phase 2 stack install. IDEMPOTENT.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bootstrap/lib.sh
source "${SCRIPT_DIR}/bootstrap/lib.sh"

log "postCreate: engine=${CLUSTER_TOOL} cluster=${CLUSTER_NAME}"

# Resolve the shared-tenant isolation prefix ONCE, up front, and export it
# (ISI-7005). A valid explicit value wins; otherwise it is derived from the
# Codespace identity so the stack still deploys. Exporting here means the child
# install.sh / check-secrets.sh and the banner below all agree on one value.
resolve_workshop_prefix

# 1. Verify the REQUIRED toolchain baked into the image is present.
#    Only the tools the bootstrap genuinely cannot proceed without are fatal.
#    mkdocs (local docs preview) and dt-evals (Phase 4, npx fallback exists) are
#    best-effort and must NEVER abort the Codespace — they are soft warnings.
missing=0
for t in kubectl helm kind dtctl node; do
  if have "$t"; then ok "tool: $t"; else err "tool MISSING: $t"; missing=1; fi
done
have mkdocs   && ok "tool: mkdocs"   || warn "mkdocs not on PATH — local docs preview unavailable (read the published site); non-fatal"
have dt-evals && ok "tool: dt-evals" || warn "dt-evals not on PATH — run-dt-eval.sh falls back to npx (see evals/dt-evals/README.md); non-fatal"
[ "$missing" -eq 0 ] || { err "required tools missing; aborting"; exit 1; }

# 2. Create (or reuse) the kind cluster (NodePort port-mappings → forwarded ports).
bash "${SCRIPT_DIR}/bootstrap/create-cluster.sh"

# 2b. Dispense the per-attendee model-proxy key (ISI-6996). Using ONLY the room
#     password, fetch this attendee's LiteLLM-proxy endpoint + a minted, budget-capped
#     virtual key and write .workshop-llm.env — which versions.env (→ install.sh /
#     install-agents.sh) and ~/.bashrc then source so ALL DeepSeek traffic routes
#     through the proxy with no raw key anywhere. Non-fatal: a missing password or an
#     unreachable host just means the agents/evals have no key (rest still installs).
#     MUST run before install.sh so secrets.sh picks up the dispensed key.
bash "${SCRIPT_DIR}/bootstrap/dispense-llm.sh" || \
  warn "model-proxy dispense skipped/failed — set WORKSHOP_ROOM_PASSWORD and WORKSHOP_DISPENSER_URL, then re-run 'bash .devcontainer/bootstrap/dispense-llm.sh' then 'bash cluster/install.sh'"

# 3. Deploy the full workshop platform. Non-fatal: a single failing component
#    (e.g. a missing secret) must never brick the Codespace — install.sh degrades
#    gracefully and per-component INSTALL_<COMPONENT>=false toggles still apply.
bash "${REPO_ROOT}/cluster/install.sh" || warn "cluster/install.sh reported issues — see output above; re-run manually with 'bash cluster/install.sh'"

# 4. Report secret presence (non-fatal).
bash "${SCRIPT_DIR}/bootstrap/check-secrets.sh" || true

cat <<'EOF'

================================================================
 Workshop bootstrap complete.
   - kind cluster 'workshop' is running.
   - The platform stack was deployed by cluster/install.sh (components with a
     missing secret are skipped cleanly, never fatal).
   - Toolchain: kubectl, helm, kind, yq, dtctl, uv, node, dt-evals, mkdocs.

 UIs (forwarded Codespace ports, via kind NodePort mappings):
   Phoenix   -> http://localhost:6006
   kagent UI -> http://localhost:8080

 Next:
   kubectl get nodes
   kubectl get pods -A
   mkdocs serve -a 0.0.0.0:8000      # workshop site on forwarded port 8000 (optional)
================================================================
EOF

# --- Shared-tenant isolation banner (ISI-6986 WS4) ---------------------------
# Echo the resolved WORKSHOP_PREFIX, a ready-to-paste attendee-scoped DQL filter,
# and a link back to the published onboarding page ("Start the benchmark"). This
# is the first thing an attendee confirms on a shared Dynatrace tenant: every
# dashboard/eval/DQL they run should carry this filter so they see only their data.
ONBOARDING_URL="https://henrikrexed.github.io/dynatrace-AI-Agent-Workshop/start-benchmark/"
echo
echo "================================================================"
echo " Your shared-tenant isolation prefix"
if [ -n "${WORKSHOP_PREFIX:-}" ] && valid_workshop_prefix "${WORKSHOP_PREFIX}"; then
  ok   "WORKSHOP_PREFIX = ${WORKSHOP_PREFIX}"
  echo
  echo "   Your agents' spans arrive as service.name = ${WORKSHOP_PREFIX}-sre-agent."
  echo "   Add this filter to any Dynatrace Notebook / dashboard query to see ONLY your data:"
  echo
  echo "     | filter workshop.attendee == \"${WORKSHOP_PREFIX}\""
  echo
  echo "   (or scope by service.name == \"${WORKSHOP_PREFIX}-sre-agent\")."
else
  # Unreachable in practice — resolve_workshop_prefix above always yields a valid
  # value. Kept as a defensive fallback message.
  warn "WORKSHOP_PREFIX could not be resolved — set it in the 'Create codespace with options…' dialog (lowercase label, e.g. team-alpha), then rebuild. Format: ${WORKSHOP_PREFIX_PATTERN}."
fi
echo
echo " Instructions (onboarding + per-module steps):"
echo "   ${ONBOARDING_URL}"
echo "================================================================"
