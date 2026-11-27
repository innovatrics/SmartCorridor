#!/usr/bin/env bash
set -e

# Stops DSS and CEA, the corridor services, the gateway and its Keycloak if they run, and FaceMatcher; keeps data.
# MCT is separate, see README.md.
export CORRIDOR_UID_GID="$(id -u):$(id -g)" CORRIDOR_HOST="${CORRIDOR_HOST:-$(hostname)}"
# DSS, CEA and the document store (dxm/) if they run: they sit on face-matcher-network. The document copies stay in
# the store's volume.
docker compose -p smart-corridor-dxm down || true
docker compose -f ./docker-compose.yml -f ./docker-compose.gateway.yml --env-file ./.env down
(cd ./facematcher && bash stop.sh)
