#!/usr/bin/env bash
set -e

# Stops the corridor services, the gateway and its Keycloak if they run, and Face Matcher; keeps data. MCT is
# separate, see README.md.
export CORRIDOR_UID_GID="$(id -u):$(id -g)" CORRIDOR_HOST="${CORRIDOR_HOST:-$(hostname)}"
docker compose -f ./docker-compose.yml -f ./docker-compose.gateway.yml --env-file ./.env down
(cd ./face-matcher && bash stop.sh)
