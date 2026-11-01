#!/usr/bin/env bash
# ── Phase 3 · render / consistency check (ISI-6989, WS3 of ISI-6986) ─────────
# The agent & MCP manifests template their human-facing names with
# ${WORKSHOP_PREFIX} so attendees do not collide on the shared tenant. This
# check renders every manifest exactly the way agents/install-agents.sh does
# (envsubst over the whitelisted vars) with a sample prefix and asserts:
#
#   1. nothing unresolved — no `${...}` survives substitution;
#   2. no BARE resource name leaks — every sre-agent / workshop-llm / github-mcp
#      / github-mcp-remote / bmad-* that ends up applied is prefixed;
#   3. the prefixed names are actually PRESENT (a file that silently failed to
#      template would otherwise pass #1 and #2);
#   4. install-agents.sh carries no bare A2A agent path.
#
# Legitimately NOT prefixed (board decision): the `kagent` namespace, the Helm
# built-in `kagent-tool-server`, and the upstream `github-mcp-server` binary /
# image. The token boundaries below are built so those never trip the check.
#
# No cluster required — pure local render. Needs: envsubst (gettext), grep -P.
#   bash agents/check-render.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok()   { printf '\033[1;32m[  ok  ]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ fail ]\033[0m %s\n' "$*" >&2; }

command -v envsubst >/dev/null || { err "envsubst not found (gettext)"; exit 1; }
echo x | grep -qP x 2>/dev/null || { err "grep -P (PCRE) not available"; exit 1; }

# Sample values — mirror the whitelist in agents/install-agents.sh. The prefix is
# a realistic worst case (contains a '-') to exercise the boundary logic.
export WORKSHOP_PREFIX="team-test"
export GITHUB_MCP_IMAGE="ghcr.io/github/github-mcp-server:v0.0.0"
export GH_PAT="x-render-check-token"
# 00-modelconfig.yaml templates the LLM proxy base URL (ISI-6996); mirror
# install-agents.sh's SUBST_VARS so the render gate resolves it too.
export WORKSHOP_LLM_BASE_URL="https://llm-proxy.example/v1"
SUBST_VARS='${GITHUB_MCP_IMAGE} ${GH_PAT} ${WORKSHOP_PREFIX} ${WORKSHOP_LLM_BASE_URL}'

# The manifest files install-agents.sh actually applies (NOT kustomization.yaml,
# which is kustomize config and never applied as a resource).
MANIFESTS=(
  "${SCRIPT_DIR}/mcp/00-modelconfig.yaml"
  "${SCRIPT_DIR}/mcp/10-github-mcp.yaml"
  "${SCRIPT_DIR}/sre/sre-agent.yaml"
  "${SCRIPT_DIR}/bmad-crew/01-bmad-analyst.yaml"
  "${SCRIPT_DIR}/bmad-crew/02-bmad-pm.yaml"
  "${SCRIPT_DIR}/bmad-crew/03-bmad-architect.yaml"
  "${SCRIPT_DIR}/bmad-crew/04-bmad-developer.yaml"
  "${SCRIPT_DIR}/bmad-crew/05-bmad-qa.yaml"
  "${SCRIPT_DIR}/bmad-crew/06-bmad-orchestrator.yaml"
)

# Render all manifests the install way; strip full-line comments so doc prose is
# not mistaken for an applied value.
RENDERED="$(for f in "${MANIFESTS[@]}"; do
  envsubst "${SUBST_VARS}" < "$f"
  echo "---"
done | grep -vP '^\s*#')"

fail=0

# 1. nothing unresolved
if printf '%s' "${RENDERED}" | grep -nP '\$\{[A-Za-z_][A-Za-z0-9_]*\}'; then
  err "unresolved \${...} placeholder(s) above — add the var to SUBST_VARS or fix the manifest"
  fail=1
fi

# 2. no bare (unprefixed) resource names. A token is OK only when immediately
#    preceded by "${WORKSHOP_PREFIX}-". Trailing boundary (?![a-z0-9-]) keeps
#    `github-mcp` from matching inside `github-mcp-server` / `github-mcp-remote`
#    (the latter is checked as its own token).
TOKENS='github-mcp-remote|github-mcp|workshop-llm|sre-agent|bmad-analyst|bmad-pm|bmad-architect|bmad-developer|bmad-qa|bmad-orchestrator'
if printf '%s' "${RENDERED}" | grep -nP "(?<!${WORKSHOP_PREFIX}-)(?<![a-z0-9])(${TOKENS})(?![a-z0-9-])"; then
  err "bare (unprefixed) resource name(s) above — prefix with \${WORKSHOP_PREFIX}-"
  fail=1
fi

# 3. the prefixed names must actually be present (catches a file that did not template)
for expect in \
  "${WORKSHOP_PREFIX}-workshop-llm" \
  "${WORKSHOP_PREFIX}-github-mcp" \
  "${WORKSHOP_PREFIX}-github-mcp-remote" \
  "${WORKSHOP_PREFIX}-sre-agent" \
  "${WORKSHOP_PREFIX}-bmad-analyst" \
  "${WORKSHOP_PREFIX}-bmad-pm" \
  "${WORKSHOP_PREFIX}-bmad-architect" \
  "${WORKSHOP_PREFIX}-bmad-developer" \
  "${WORKSHOP_PREFIX}-bmad-qa" \
  "${WORKSHOP_PREFIX}-bmad-orchestrator" ; do
  # Herestring, not `printf | grep -q`: under `set -o pipefail` a `grep -q`
  # closes the pipe on first match, the writer catches SIGPIPE, and pipefail
  # then reports the pipeline as failed even on a successful match (a flake).
  if ! grep -qF "${expect}" <<<"${RENDERED}"; then
    err "expected prefixed name missing from render: ${expect}"
    fail=1
  fi
done

# 4. install-agents.sh must not hard-code a bare A2A agent path (it templates them)
if grep -nP 'a2a/kagent/(sre-agent|bmad-orchestrator)(?![a-z0-9-])' "${SCRIPT_DIR}/install-agents.sh"; then
  err "install-agents.sh above has a bare A2A agent path — use \${WORKSHOP_PREFIX}-"
  fail=1
fi

if [ "${fail}" -ne 0 ]; then
  err "render/consistency check FAILED"
  exit 1
fi
ok "render/consistency check passed (prefix='${WORKSHOP_PREFIX}'): all names prefixed, nothing unresolved"
