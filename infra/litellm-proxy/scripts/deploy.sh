#!/usr/bin/env bash
# Install / update the LiteLLM proxy + dispenser on the LXC host (ISI-6995).
# Idempotent: safe to re-run. Run as root ON THE LXC.
#
#   scp -r infra/litellm-proxy root@<lxc>:/opt/litellm/src
#   ssh root@<lxc> 'bash /opt/litellm/src/scripts/deploy.sh'
#
# NEVER overwrites /etc/litellm/litellm.env — secrets are preserved across runs.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV=/opt/litellm/venv
PY="$VENV/bin/python"

echo "==> deploy from $SRC"

# 1. Directories
install -d -m 755 /opt/litellm /opt/litellm/dispenser
install -d -m 750 /etc/litellm
install -d -m 755 /var/lib/litellm

# 2. Python venv + deps
# Recreate if the venv is missing OR broken (e.g. created before python3-venv
# was installed, leaving a dir with no pip).
if [ ! -x "$PY" ] || [ ! -x "$VENV/bin/pip" ]; then
  echo "==> creating venv (clean)"
  rm -rf "$VENV"
  python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install --quiet --upgrade pip
echo "==> installing litellm[proxy] + dispenser deps (this can take a minute)"
"$VENV/bin/pip" install --quiet 'litellm[proxy]' prisma
"$VENV/bin/pip" install --quiet -r "$SRC/dispenser/requirements.txt"

# Generate the Prisma Python client (db push syncs the schema, but the client
# bindings must be generated or LiteLLM fails at startup). Needs the venv bin on
# PATH so the `prisma-client-py` generator entry point is found, and HOME/cache
# pointed at a writable dir.
SCHEMA="$VENV/lib/python3.11/site-packages/litellm/proxy/schema.prisma"
if [ -f "$SCHEMA" ]; then
  echo "==> prisma generate"
  PATH="$VENV/bin:$PATH" HOME=/var/lib/litellm XDG_CACHE_HOME=/var/lib/litellm/.cache \
    "$VENV/bin/python" -m prisma generate --schema="$SCHEMA" >/dev/null 2>&1 \
    || echo "!! prisma generate failed (check manually)"
fi

# 3. App files
install -m 644 "$SRC/config.yaml"        /etc/litellm/config.yaml
install -m 644 "$SRC/dispenser/app.py"   /opt/litellm/dispenser/app.py

# 4. Secret file — create from template ONLY if absent; never clobber.
if [ ! -f /etc/litellm/litellm.env ]; then
  install -m 600 "$SRC/litellm.env.example" /etc/litellm/litellm.env
  echo "!! Created /etc/litellm/litellm.env from template."
  echo "!! EDIT IT and set the real DEEPSEEK_API_KEY before the proxy can serve."
fi
chmod 600 /etc/litellm/litellm.env
chown root:root /etc/litellm/litellm.env

# 5. systemd units
install -m 644 "$SRC/systemd/litellm.service"   /etc/systemd/system/litellm.service
install -m 644 "$SRC/systemd/dispenser.service" /etc/systemd/system/dispenser.service
systemctl daemon-reload
systemctl enable --now litellm.service
# Give LiteLLM a moment to run DB migrations before the dispenser starts.
sleep 5
systemctl enable --now dispenser.service

# 6. Health
echo "==> litellm:  $(systemctl is-active litellm.service)"
echo "==> dispenser: $(systemctl is-active dispenser.service)"
curl -fsS http://127.0.0.1:4000/health/readiness >/dev/null 2>&1 \
  && echo "==> proxy readiness OK" || echo "!! proxy not ready yet (check: journalctl -u litellm -n50)"
curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1 \
  && echo "==> dispenser health OK" || echo "!! dispenser not ready (check: journalctl -u dispenser -n50)"
echo "==> done"
