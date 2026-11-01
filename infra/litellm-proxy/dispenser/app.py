"""Workshop key dispenser (ISI-6995 / ISI-6992 WS2).

A tiny FastAPI service that sits on 127.0.0.1:8080 behind a Tailscale Funnel
path (`/dispense`). An attendee presents the room password; the dispenser mints
a fresh, budget-capped LiteLLM virtual key on demand and returns everything the
attendee's client needs:

    GET /dispense
      header: X-Room-Password: <room password>
      200 -> {"proxy_url": "...", "virtual_key": "sk-...", "model": "deepseek-chat"}
      401 -> bad or absent password

On-demand minting (not a pre-minted pool) means there is no pool to exhaust and
every key is independently capped, so one attendee burning their $4 never
affects anyone else.

All configuration comes from the environment (see litellm.env.example). No
secrets or URLs are baked into this file.
"""

from __future__ import annotations

import os

import httpx
from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse

# ── Config from the environment (populated by the systemd EnvironmentFile) ────
LITELLM_BASE = os.environ.get("LITELLM_BASE_URL", "http://127.0.0.1:4000")
MASTER_KEY = os.environ["LITELLM_MASTER_KEY"]          # required
ROOM_PASSWORD = os.environ["WORKSHOP_ROOM_PASSWORD"]   # required
PROXY_PUBLIC_URL = os.environ["PROXY_PUBLIC_URL"]      # required
MODEL = os.environ.get("DISPENSER_MODEL", "deepseek-chat")
MAX_BUDGET = float(os.environ.get("VIRTUAL_KEY_MAX_BUDGET", "4"))
BUDGET_DURATION = os.environ.get("VIRTUAL_KEY_BUDGET_DURATION", "30d")

app = FastAPI(title="Workshop Key Dispenser", docs_url=None, redoc_url=None)


@app.get("/healthz")
async def healthz() -> dict:
    """Liveness probe — does not touch LiteLLM or reveal any secret."""
    return {"status": "ok"}


# Served at BOTH paths: Tailscale Funnel's `--set-path=/dispense` strips the
# prefix before proxying, so a public GET /dispense arrives here as GET / .
# The explicit /dispense route keeps direct (non-funnel) calls working too.
@app.get("/")
@app.get("/dispense")
async def dispense(x_room_password: str | None = Header(default=None)) -> JSONResponse:
    # Constant-ish comparison; the password is low-entropy and rotated per
    # session, so this is a gate, not a cryptographic secret.
    if not x_room_password or x_room_password != ROOM_PASSWORD:
        raise HTTPException(status_code=401, detail="invalid or missing room password")

    payload = {
        "models": [MODEL],              # locks the key to the one allowlisted model
        "max_budget": MAX_BUDGET,       # hard per-attendee USD cap -> 429 when hit
        "budget_duration": BUDGET_DURATION,
        "metadata": {"source": "workshop-dispenser"},
    }
    try:
        async with httpx.AsyncClient(timeout=15.0) as client:
            resp = await client.post(
                f"{LITELLM_BASE}/key/generate",
                headers={"Authorization": f"Bearer {MASTER_KEY}"},
                json=payload,
            )
    except httpx.RequestError as exc:  # proxy down / unreachable
        raise HTTPException(status_code=502, detail="proxy unreachable") from exc

    if resp.status_code != 200:
        # Do not leak the upstream body (may echo the master key context).
        raise HTTPException(status_code=502, detail="key minting failed")

    virtual_key = resp.json().get("key")
    if not virtual_key:
        raise HTTPException(status_code=502, detail="malformed mint response")

    return JSONResponse(
        {
            "proxy_url": PROXY_PUBLIC_URL,
            "virtual_key": virtual_key,
            "model": MODEL,
        }
    )
