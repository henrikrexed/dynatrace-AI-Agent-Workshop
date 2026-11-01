#!/usr/bin/env bash
# One-time local PostgreSQL provisioning for LiteLLM (ISI-6995). Run as root ON
# THE LXC. LiteLLM's virtual-key/budget store requires PostgreSQL (it rejects
# sqlite:// at boot), so the proxy needs a local DB.
#
#   apt-get install -y postgresql
#   bash setup-postgres.sh                 # generates a random db password
#   bash setup-postgres.sh 'my-password'   # or set one explicitly
#
# Idempotent: re-running updates the role password and ensures the db exists.
# Prints the DATABASE_URL to paste into /etc/litellm/litellm.env.
set -euo pipefail

DB_NAME=litellm
DB_USER=litellm
DB_PASS="${1:-$(openssl rand -hex 16)}"

command -v psql >/dev/null || { echo "install postgresql first: apt-get install -y postgresql" >&2; exit 1; }
systemctl is-active --quiet postgresql || systemctl start postgresql

# Role (create or update password), then database owned by it.
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
    ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';
  ELSE
    CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';
  END IF;
END
\$\$;
SQL
# CREATE DATABASE can't run inside the DO block / a transaction; do it guarded.
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
fi

echo
echo "PostgreSQL ready. Put this in /etc/litellm/litellm.env (DATABASE_URL):"
echo
echo "    DATABASE_URL=postgresql://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}"
echo
