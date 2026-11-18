#!/usr/bin/env bash
set -e

# Stops everything and deletes containers, images and volumes, Keycloak's accounts with them. MCT is separate, see
# README.md. secrets/ is kept: the license, and the gateway's secrets and certificate, which the next start reuses.
export CORRIDOR_UID_GID="$(id -u):$(id -g)" CORRIDOR_HOST="${CORRIDOR_HOST:-$(hostname)}"
docker compose -f ./docker-compose.yml -f ./docker-compose.gateway.yml --env-file ./.env down -v --rmi all 2>/dev/null || true
(cd ./face-matcher && bash factory-reset.sh)
