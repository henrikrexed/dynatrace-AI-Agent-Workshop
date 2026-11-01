#!/usr/bin/env bash
# Rotate the room password between sessions (ISI-6995). Run as root ON THE LXC.
#
#   bash rotate-password.sh                 # generate a fresh random password
#   bash rotate-password.sh 'my-new-pw'     # set a specific one
#
# Prints the new password ONCE so Henrik can read it out to the room, updates
# /etc/litellm/litellm.env in place, and restarts the dispenser.
set -euo pipefail
ENV_FILE=/etc/litellm/litellm.env
[ -f "$ENV_FILE" ] || { echo "no $ENV_FILE" >&2; exit 1; }

NEW_PW="${1:-$(openssl rand -base64 12)}"

# Replace (or append) the WORKSHOP_ROOM_PASSWORD line.
if grep -q '^WORKSHOP_ROOM_PASSWORD=' "$ENV_FILE"; then
  sed -i "s|^WORKSHOP_ROOM_PASSWORD=.*|WORKSHOP_ROOM_PASSWORD=${NEW_PW}|" "$ENV_FILE"
else
  printf 'WORKSHOP_ROOM_PASSWORD=%s\n' "$NEW_PW" >> "$ENV_FILE"
fi
chmod 600 "$ENV_FILE"

systemctl restart dispenser.service
echo "Room password rotated. New password (share with the room):"
echo
echo "    $NEW_PW"
echo
echo "dispenser: $(systemctl is-active dispenser.service)"
