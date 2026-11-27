#!/usr/bin/env bash
set -euo pipefail

# The Feedback Display's database login (made once, kept), then its role and database on the corridor's PostgreSQL.
# Idempotent; run with the corridor up (start.sh), and again after factory-reset.sh.
# Test1234 is the FaceMatcher dependencies' own PostgreSQL default: change it for anything beyond a demo.
cd "$(dirname "$0")"

setting() { grep -E "^$1=" ./.env | head -n1 | cut -d '=' -f2- | sed -E -e 's/\r$//' -e 's/[[:space:]]+#.*$//' -e 's/[[:space:]]+$//'; }
SECRETS="$(setting FEEDBACK_DISPLAY_SECRETS_DIR)"
SECRETS="${SECRETS//\$\{HOME\}/$HOME}"
mkdir -p "$SECRETS" && chmod 700 "$SECRETS"

S="$SECRETS/db.env"
if [ ! -f "$S" ]; then
  r() { LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 32; }
  (umask 077 && printf 'SPRING_DATASOURCE_USERNAME=feedbackdisplay\nSPRING_DATASOURCE_PASSWORD=%s\n' "$(r)" > "$S")
  echo "Wrote $S"
fi

docker run --rm -i --network face-matcher-network -e PGPASSWORD=Test1234 \
  -e PW="$(sed -n 's/^SPRING_DATASOURCE_PASSWORD=//p' "$S")" postgres:18.6 \
  sh -c 'until pg_isready -q -h pgsql -U postgres; do sleep 1; done; psql -v ON_ERROR_STOP=1 -q -h pgsql -U postgres -v pw="$PW"' <<'SQL'
SELECT 'CREATE ROLE feedbackdisplay LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'feedbackdisplay')\gexec
SELECT format('ALTER ROLE feedbackdisplay PASSWORD %L', :'pw')\gexec
SELECT 'CREATE DATABASE corridorfeedbackdisplay OWNER feedbackdisplay' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'corridorfeedbackdisplay')\gexec
SQL
echo "Database corridorfeedbackdisplay ready. Start: docker compose -f feedback-display/docker-compose.yml --env-file feedback-display/.env up -d"
