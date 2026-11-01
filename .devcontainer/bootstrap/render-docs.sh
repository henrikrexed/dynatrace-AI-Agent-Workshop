#!/usr/bin/env bash
# =============================================================================
# render-docs.sh — personalize the workshop docs for THIS attendee (ISI-7007)
# =============================================================================
# The workshop runs on a SHARED Dynatrace tenant, so every DQL query and the
# importable Dynatrace launchpad must carry the attendee's own identity. The
# canonical, git-tracked docs keep readable `${WORKSHOP_PREFIX}` / `${DT_TENANT_URL}`
# placeholders (so the published GitHub Pages site is self-documenting); this
# script renders a PERSONALIZED copy under `.workshop-site/` (git-ignored) that
# the in-cluster mkdocs Deployment serves (cluster/mkdocs/mkdocs.yaml), and that
# an attendee imports into Dynatrace as their welcome doc.
#
# SCOPED envsubst — only the workshop identity vars are substituted, so shell
# snippets in the docs (`$HOME`, `${REPO_ROOT}`, `$WORKSHOP_PREFIX` in `echo`
# examples, the collector's `${env:...}` refs, …) are LEFT INTACT. This mirrors
# cluster/install.sh's scoped collector render (ISI-6989 lesson).
#
# Idempotent + non-destructive: rewrites `.workshop-site/` from scratch each run,
# never touches the tracked sources. Safe to re-run from postStart after a
# `git pull`. Needs: envsubst (gettext-base). Degrades to a warning if absent.
#   bash .devcontainer/bootstrap/render-docs.sh
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

# The one place that names which tokens are attendee-personalized. Keep this in
# sync with the placeholders used across docs/ and cluster/dynatrace/launchpad.md.
SUBST_VARS='${WORKSHOP_PREFIX} ${DT_TENANT_URL} ${DT_ENVIRONMENT}'

OUT="${REPO_ROOT}/.workshop-site"

if ! have envsubst; then
  warn "envsubst not found (gettext-base) — docs will not be personalized; the in-cluster site keeps literal \${WORKSHOP_PREFIX} placeholders"
fi

# Guarantee a valid, deterministic per-attendee prefix even if WORKSHOP_PREFIX is
# unset/invalid (auto-derives from the Codespace identity — ISI-7005).
resolve_workshop_prefix >/dev/null 2>&1 || true
export WORKSHOP_PREFIX DT_TENANT_URL DT_ENVIRONMENT

log "rendering personalized docs → ${OUT#${REPO_ROOT}/}  (WORKSHOP_PREFIX='${WORKSHOP_PREFIX:-}')"

# Rewrite from scratch so a re-run never leaves stale files behind.
rm -rf "${OUT}"
mkdir -p "${OUT}"

# mkdocs config (docs_dir defaults to ./docs, resolved relative to the config).
cp "${REPO_ROOT}/mkdocs.yml" "${OUT}/mkdocs.yml"
# Whole docs tree (markdown + assets); personalize the markdown in place.
cp -r "${REPO_ROOT}/docs" "${OUT}/docs"

render_launchpad() {
  # Full scoped envsubst — the launchpad is a welcome doc whose table values ARE
  # the attendee's live env; it carries no instructional ${…} that must survive.
  local f="$1"
  if have envsubst; then
    local tmp="${f}.rendered"
    envsubst "${SUBST_VARS}" < "${f}" > "${tmp}" && mv "${tmp}" "${f}"
  fi
}

render_json_asset() {
  # Personalize a UI-importable JSON asset (notebook / dashboard / workflow the
  # attendee downloads from their in-cluster mkdocs site and uploads into their
  # Dynatrace tenant). These carry DQL that filters on workshop.attendee ==
  # "${WORKSHOP_PREFIX}" and service.name == "${WORKSHOP_PREFIX}-sre-agent"
  # (ISI-6988), so the download must already match THIS attendee — no more
  # find/replace step. Full scoped envsubst: a generated document carries no
  # instructional ${…} that must survive, only the identity placeholders.
  local f="$1"
  if have envsubst; then
    local tmp="${f}.rendered"
    envsubst "${SUBST_VARS}" < "${f}" > "${tmp}" && mv "${tmp}" "${f}"
  fi
}

render_doc_dql() {
  # Personalize ONLY the DQL code blocks — the queries an attendee pastes/runs —
  # leaving prose and bash/sh/text snippets with their literal ${WORKSHOP_PREFIX}.
  # Several pages deliberately show `envsubst '${WORKSHOP_PREFIX}'` or tell the
  # reader to "replace ${WORKSHOP_PREFIX}"; those must survive verbatim (ISI-7007:
  # the DQL reflects the prefix; the instructions stay as-is).
  #
  # A fenced block is treated as DQL when its info string is `dql` OR (for the
  # bare ``` fences some pages use) its first content line starts with `fetch` —
  # the DQL verb. This never touches ```bash / ```text / ```yaml blocks.
  local f="$1"
  local tmp="${f}.rendered"
  awk -v p="${WORKSHOP_PREFIX:-}" -v t="${DT_TENANT_URL:-}" -v e="${DT_ENVIRONMENT:-}" '
    function flush(dodql,   i, line) {
      for (i = 1; i <= n; i++) {
        line = buf[i]
        if (dodql) {
          gsub(/\$\{WORKSHOP_PREFIX\}/, p, line)
          gsub(/\$\{DT_TENANT_URL\}/,   t, line)
          gsub(/\$\{DT_ENVIRONMENT\}/,  e, line)
        }
        print line
      }
      n = 0
    }
    !infence {
      if ($0 ~ /^[[:space:]]*```/) {
        infence = 1; n = 0; firstverb = ""; openline = $0
        info = $0; sub(/^[[:space:]]*```/, "", info); gsub(/[[:space:]]/, "", info)
        next
      }
      print; next
    }
    infence && /^[[:space:]]*```[[:space:]]*$/ {
      print openline
      flush((info ~ /dql/) || (firstverb == "fetch"))
      print $0
      infence = 0; next
    }
    infence {
      buf[++n] = $0
      if (firstverb == "") {
        trimmed = $0; gsub(/^[[:space:]]+/, "", trimmed)
        if (trimmed != "") { split(trimmed, a, /[[:space:]]/); firstverb = a[1] }
      }
      next
    }
    END { if (infence) { print openline; flush((info ~ /dql/) || (firstverb == "fetch")) } }
  ' "${f}" > "${tmp}" && mv "${tmp}" "${f}"
}

# Personalize the DQL in every served markdown page.
while IFS= read -r -d '' md; do
  render_doc_dql "${md}"
done < <(find "${OUT}/docs" -name '*.md' -type f -print0)

# Personalize the downloadable optimization artifacts (ISI-7007): the notebook,
# dashboard and workflow JSON an attendee downloads from the in-cluster site and
# imports into Dynatrace must already carry THIS attendee's prefix in their DQL.
if [ -d "${OUT}/docs/assets/optimization" ]; then
  while IFS= read -r -d '' js; do
    render_json_asset "${js}"
  done < <(find "${OUT}/docs/assets/optimization" -name '*.json' -type f -print0)
fi

# The importable Dynatrace launchpad, personalized with the attendee's live env.
if [ -f "${REPO_ROOT}/cluster/dynatrace/launchpad.md" ]; then
  cp "${REPO_ROOT}/cluster/dynatrace/launchpad.md" "${OUT}/launchpad.md"
  render_launchpad "${OUT}/launchpad.md"
fi

ok "personalized site rendered under ${OUT#${REPO_ROOT}/} (markdown DQL + launchpad + downloadable notebook/dashboard/workflow JSON; serve in-cluster via cluster/mkdocs/mkdocs.yaml → http://localhost:8000)"
