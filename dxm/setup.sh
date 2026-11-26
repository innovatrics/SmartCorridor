#!/usr/bin/env bash
set -euo pipefail

# CEA's local passwords and admin token (made once, kept), then its database and broker objects on the corridor's
# PostgreSQL and RabbitMQ. Idempotent; run with the corridor up (start.sh), again after factory-reset.sh.
# Test1234 and guest/guest are the Face Matcher dependencies' own defaults: change them for anything beyond a demo.
cd "$(dirname "$0")"

setting() { grep -E "^$1=" ./.env | head -n1 | cut -d '=' -f2- | sed -E -e 's/\r$//' -e 's/[[:space:]]+#.*$//' -e 's/[[:space:]]+$//'; }
SECRETS="$(setting DXM_SECRETS_DIR)"
SECRETS="${SECRETS//\$\{HOME\}/$HOME}"
mkdir -p "$SECRETS" && chmod 700 "$SECRETS"

S="$SECRETS/cea-local.env"
if [ ! -f "$S" ]; then
  r() { LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 32; }
  (umask 077 && printf 'CEA_DB_PASSWORD=%s\nCEA_AMQP_PASSWORD=%s\nCEA_ADMIN_TOKEN=%s\n' "$(r)" "$(r)" "$(r)" > "$S")
  echo "Wrote $S"
fi
for f in tis-dss.env tis-cea.env; do
  [ -f "$SECRETS/$f" ] || echo "NOTE: $SECRETS/$f is missing; see dxm/README.md, \"Secrets\"." >&2
done

docker run --rm -i --network face-matcher-network -e PGPASSWORD=Test1234 \
  -e PW="$(sed -n 's/^CEA_DB_PASSWORD=//p' "$S")" postgres:18.6 \
  sh -c 'until pg_isready -q -h pgsql -U postgres; do sleep 1; done; psql -v ON_ERROR_STOP=1 -q -h pgsql -U postgres -v pw="$PW"' <<'SQL'
SELECT 'CREATE ROLE cea LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'cea')\gexec
SELECT format('ALTER ROLE cea PASSWORD %L', :'pw')\gexec
SELECT 'CREATE DATABASE cea OWNER cea' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'cea')\gexec
SQL

docker run --rm --network face-matcher-network -e PW="$(sed -n 's/^CEA_AMQP_PASSWORD=//p' "$S")" \
  rabbitmq:3.12.11-management sh -c '
  set -eu; a() { rabbitmqadmin --host=rmq --port=15672 --vhost=/ --username=guest --password=guest "$@" >/dev/null; }
  a declare exchange name=cea.export type=topic durable=true
  a declare exchange name=cea.dlx type=topic durable=true
  a declare queue name=cea.identification.dlq durable=true arguments="{\"x-queue-type\":\"quorum\",\"x-max-length\":10000,\"x-overflow\":\"reject-publish\"}"
  a declare queue name=cea.identification.q durable=true arguments="{\"x-queue-type\":\"quorum\",\"x-max-length\":200000,\"x-max-length-bytes\":268435456,\"x-overflow\":\"reject-publish\",\"x-dead-letter-exchange\":\"cea.dlx\",\"x-dead-letter-strategy\":\"at-least-once\",\"x-delivery-limit\":20}"
  a declare binding source=cea.export destination_type=queue destination=cea.identification.q routing_key=identification.match.v1
  a declare binding source=cea.dlx destination_type=queue destination=cea.identification.dlq routing_key="#"
  a declare user name=cea password="$PW" tags=""
  a declare permission vhost=/ user=cea configure="^$" write="^$" read="^cea\\.identification\\.q\$"'

echo "CEA database and broker objects are in place."
