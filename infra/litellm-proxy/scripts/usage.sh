#!/usr/bin/env bash
# Cheap spend/budget summary (ISI-6995). Run as root ON THE LXC.
# Lets Henrik watch total spend vs the ~$240 session ceiling in real time.
#
#   bash usage.sh
set -euo pipefail
ENV_FILE=/etc/litellm/litellm.env
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a
: "${LITELLM_MASTER_KEY:?missing in env}"

LITELLM_BASE="${LITELLM_BASE_URL:-http://127.0.0.1:4000}" \
CEILING="${SESSION_CEILING_USD:-240}" python3 <<'PY'
import os, json, urllib.request
base = os.environ["LITELLM_BASE"].rstrip("/")
mk = os.environ["LITELLM_MASTER_KEY"]
ceiling = float(os.environ["CEILING"])

def api(path):
    req = urllib.request.Request(
        base + path, headers={"Authorization": f"Bearer {mk}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)

rows, total, page = [], 0.0, 1
while True:
    d = api(f"/key/list?page={page}&size=100&return_full_object=true")
    ks = d.get("keys") or []
    for k in ks:
        if not isinstance(k, dict):
            continue
        spend = float(k.get("spend") or 0)
        total += spend
        alias = k.get("key_alias") or k.get("key_name") or (k.get("token", "") or "")[:12]
        rows.append((alias, spend, k.get("max_budget")))
    if not ks or page >= d.get("total_pages", 1):
        break
    page += 1

print("%-18s%12s%8s" % ("key", "spend $", "cap $"))
for alias, spend, budget in sorted(rows, key=lambda r: -r[1]):
    cap = "-" if budget is None else "%.0f" % budget
    print("%-18s%12.4f%8s" % (str(alias), spend, cap))
print("-" * 38)
print("%-18s%12.4f  / ceiling $%.0f" % ("TOTAL", total, ceiling))
print("keys=%d  spent=%.1f%% of ceiling" % (len(rows), (total / ceiling * 100) if ceiling else 0))
PY
