#!/usr/bin/env bash
# Teardown the workshop proxy (ISI-6995). Run as root ON THE LXC.
# Order matters: revoke keys -> stop services -> stop funnel. The final
# `pct destroy` is run from a Proxmox node, NOT here (see README teardown).
set -euo pipefail

echo "==> revoking all virtual keys"
bash "$(dirname "${BASH_SOURCE[0]}")/revoke-all.sh" || echo "!! revoke-all failed (continuing)"

echo "==> stopping services"
systemctl disable --now dispenser.service || true
systemctl disable --now litellm.service || true

echo "==> stopping Tailscale Funnel"
tailscale funnel --https=443 off 2>/dev/null \
  || tailscale serve reset 2>/dev/null \
  || echo "!! could not stop funnel from here; reset in the Tailscale admin console"

echo "==> services + funnel down. From a Proxmox node, finish with:"
echo "      pct stop <CTID> && pct destroy <CTID>"
