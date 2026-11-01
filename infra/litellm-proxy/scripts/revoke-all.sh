#!/usr/bin/env bash
# Revoke ALL minted virtual keys (ISI-6995). Run as root ON THE LXC.
# Run this BETWEEN the two sessions so no attendee budget carries over.
#
#   bash revoke-all.sh            # deletes every minted key
#
# Does NOT touch the master key or the DeepSeek key — only virtual keys.
set -euo pipefail
ENV_FILE=/etc/litellm/litellm.env
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
: "${LITELLM_MASTER_KEY:?missing in env}"

LITELLM_BASE="${LITELLM_BASE_URL:-http://127.0.0.1:4000}" python3 <<'PY'
import os, json, urllib.request, urllib.error
base = os.environ["LITELLM_BASE"].rstrip("/")
mk = os.environ["LITELLM_MASTER_KEY"]

def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        base + path, data=data, method=method,
        headers={"Authorization": f"Bearer {mk}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)

tokens, page = [], 1
while True:
    # size is capped at 100 by LiteLLM; paginate over total_pages.
    d = api("GET", f"/key/list?page={page}&size=100&return_full_object=true")
    ks = d.get("keys") or []
    for k in ks:
        tokens.append(k["token"] if isinstance(k, dict) else k)
    if not ks or page >= d.get("total_pages", 1):
        break
    page += 1

if not tokens:
    print("No virtual keys to revoke.")
else:
    api("POST", "/key/delete", {"keys": tokens})
    print(f"Revoked {len(tokens)} virtual key(s).")
PY
