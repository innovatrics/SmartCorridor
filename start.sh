#!/usr/bin/env bash
set -e

# Starts FaceMatcher (facematcher/), then the corridor services. With the gateway on (CORRIDOR_GATEWAY_ENABLED=true
# in .env) also the corridor's Keycloak and the gateway, the only container that then publishes ports.
# MCT is separate, see README.md.

# FaceMatcher UI shows no identification view in a corridor: the dashboard shows the matches.
export FACE_MATCHER_UI_IDENTIFICATION=false

setting() { grep -E "^$1=" ./.env | head -n1 | cut -d '=' -f2- | sed -E -e 's/\r$//' -e 's/[[:space:]]+#.*$//' -e 's/[[:space:]]+$//'; }

GATEWAY="$(setting CORRIDOR_GATEWAY_ENABLED)"

# The Hub's document scan identity (dxm/README.md, "Document scans") is in DXM_SECRETS_DIR, set in dxm/.env and,
# for a plain `docker compose` that start.sh does not run, in .env. A difference would make such a restart read
# another directory: with document scans on, the Hub then refuses to start.
DXM_SECRETS_DIR="$(cd ./dxm && setting DXM_SECRETS_DIR)"
DXM_SECRETS_DIR_ROOT="$(setting DXM_SECRETS_DIR)"
if [ "$DXM_SECRETS_DIR" != "$DXM_SECRETS_DIR_ROOT" ]; then
  echo "ERROR: DXM_SECRETS_DIR differs: '$DXM_SECRETS_DIR' in dxm/.env, '$DXM_SECRETS_DIR_ROOT' in .env. Set the same value in both." >&2
  exit 1
fi
export DXM_SECRETS_DIR="${DXM_SECRETS_DIR//\$\{HOME\}/$HOME}"
case "$GATEWAY" in
  true | false) ;;
  *) echo "ERROR: CORRIDOR_GATEWAY_ENABLED in .env must be true or false, not '$GATEWAY'. See README.md." >&2; exit 1 ;;
esac

# One license for everything. FaceMatcher looks for it in its own secrets/.
if [ ! -f ./secrets/iengine.lic ]; then
  echo "ERROR: secrets/iengine.lic not found. See README.md." >&2
  exit 1
fi
chmod a+r ./secrets/iengine.lic
[ -e ./facematcher/secrets/iengine.lic ] || ln -sf ../../secrets/iengine.lic ./facematcher/secrets/iengine.lic

COMPOSE=(docker compose -f ./docker-compose.yml -f ./docker-compose.gateway.yml --env-file ./.env)
# The gateway's file is always named, so that switching the gateway off removes its containers too.
export CORRIDOR_UID_GID="$(id -u):$(id -g)"
CORRIDOR_HOST="$(setting CORRIDOR_HOST)"
export CORRIDOR_HOST="${CORRIDOR_HOST:-$(hostname)}"
if [ "$GATEWAY" = true ]; then
  # The secrets and, unless the site put its own there, a certificate: made once, in secrets/, by the user who runs
  # this script and readable by no one else. Made in the gateway's image, so the host needs no openssl.
  mkdir -p ./secrets
  docker run --rm --user "$CORRIDOR_UID_GID" -e CORRIDOR_HOST -v "$PWD/secrets:/secrets" \
    -v "$PWD/gateway/make-secrets.sh:/make-secrets.sh:ro" --entrypoint /bin/sh "$(setting GATEWAY_IMAGE)" /make-secrets.sh
  # FaceMatcher's services publish no port, its dependencies only on this host's loopback: the gateway reaches them
  # on face-matcher-network.
  export COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml:docker-compose.override.yml}:../gateway/facematcher.gateway.yml"
  export DEPENDENCIES_BIND_ADDRESS=127.0.0.1
else
  unset DEPENDENCIES_BIND_ADDRESS
  # Turned off after it was on: the gateway holds the ports FaceMatcher's services take back, so it goes first.
  "${COMPOSE[@]}" rm --stop --force gateway keycloak >/dev/null 2>&1 || true
fi

(cd ./facematcher && bash run.sh)

# The Hub's own database on the platform PostgreSQL: waits for pgsql, creates it only when missing.
# The password is POSTGRES_PASSWORD from facematcher/dependencies/docker-compose.yml.
docker run --rm -i --network face-matcher-network -e PGPASSWORD=Test1234 postgres:18.6 \
  sh -c 'until pg_isready -q -h pgsql -U postgres; do sleep 1; done; psql -v ON_ERROR_STOP=1 -q -h pgsql -U postgres' <<'SQL'
SELECT 'CREATE DATABASE corridorhub' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'corridorhub')\gexec
SQL

if [ "$GATEWAY" = true ]; then
  # Keycloak's database, with a role of its own whose password is in secrets/gateway/.
  KC_DB_PASSWORD="$(cat ./secrets/gateway/keycloak-db-password)"
  export KC_DB_PASSWORD
  docker run --rm -i --network face-matcher-network -e PGPASSWORD=Test1234 -e KC_DB_PASSWORD postgres:18.6 \
    sh -c 'psql -v ON_ERROR_STOP=1 -q -h pgsql -U postgres -v kcpw="$KC_DB_PASSWORD"' <<'SQL'
SELECT 'CREATE ROLE keycloak LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'keycloak')\gexec
SELECT format('ALTER ROLE keycloak PASSWORD %L', :'kcpw')\gexec
SELECT 'CREATE DATABASE keycloak OWNER keycloak' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak')\gexec
SQL
  unset KC_DB_PASSWORD
fi

# Create the Hub's crop bucket on the platform's S3 storage.
# The admin command gives S3 5 seconds and does not retry. SeaweedFS can be slower than that
# while the platform services start, so retry; an existing bucket counts as success.
PLATFORM=./facematcher
getvalue() { grep -E "^$1=" "$PLATFORM/.env" | head -n1 | cut -d '=' -f2- | sed -E -e 's/\r$//' -e 's/[[:space:]]+#.*$//' -e 's/[[:space:]]+$//'; }
BUCKET_ATTEMPTS=12
for attempt in $(seq 1 "$BUCKET_ATTEMPTS"); do
  if docker run --rm --network face-matcher-network "$(getvalue REGISTRY)admin:$(getvalue VERSION)" \
    ensure-s3-bucket-exists \
      --endpoint "$(getvalue S3Bucket__Endpoint)" --access-key "$(getvalue S3Bucket__AccessKey)" \
      --secret-key "$(getvalue S3Bucket__SecretKey)" --bucket-name corridor-hub; then
    break
  fi
  if [ "$attempt" -eq "$BUCKET_ATTEMPTS" ]; then
    echo "ERROR: could not create the corridor-hub bucket on $(getvalue S3Bucket__Endpoint) after $BUCKET_ATTEMPTS attempts. Check 'docker logs seaweedfs'." >&2
    exit 1
  fi
  echo "Bucket corridor-hub not created yet (attempt $attempt/$BUCKET_ATTEMPTS), retrying in 5 s..." >&2
  sleep 5
done

# Give the platform APIs a head start before Hub and CIGS connect.
sleep 10

# The platform recreates its API containers; recreate the corridor services so they resolve the new addresses.
if [ "$GATEWAY" = true ]; then
  "${COMPOSE[@]}" up -d --force-recreate --remove-orphans
  echo "Waiting for Keycloak..."
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' sceg-keycloak 2>/dev/null)" = healthy ] && break
    sleep 5
  done
  [ "$(docker inspect -f '{{.State.Health.Status}}' sceg-keycloak 2>/dev/null)" = healthy ] \
    || { echo "ERROR: Keycloak did not become ready; see docker logs sceg-keycloak" >&2; exit 1; }
  echo ""
  echo "Corridor dashboard : https://$CORRIDOR_HOST:8095"
  echo "FaceMatcher UI    : https://$CORRIDOR_HOST:8000"
  echo "Hub GraphQL        : https://$CORRIDOR_HOST:8090/corridor-hub/graphql (token)"
  echo "REST API           : https://$CORRIDOR_HOST:8098 (token)"
  echo "GraphQL API        : https://$CORRIDOR_HOST:8097/graphql (token)"
  echo "Login              : https://$CORRIDOR_HOST:8443/realms/corridor"
  echo "Accounts           : gateway/users.sh (see README.md, \"The gateway\")"
else
  docker compose -f ./docker-compose.yml --env-file ./.env up -d --force-recreate --remove-orphans
  echo ""
  echo "Corridor dashboard : http://localhost:8095"
  echo "Hub GraphQL        : http://localhost:8090/corridor-hub/graphql"
  echo "CIGS health        : http://localhost:8096/actuator/health"
  echo "FaceMatcher UI    : http://localhost:8000"
  echo "REST API           : http://localhost:8098"
  echo "GraphQL API        : http://localhost:8097/graphql"
fi
