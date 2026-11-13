#!/bin/sh
# Run by start.sh inside the gateway's image, as the user who runs start.sh, with secrets/ mounted at /secrets.
# Writes what must never be in the repository, once: the gateway's two client secrets, the secret that signs its
# session cookies, Keycloak's administrator and database passwords, and a self-signed certificate when the site
# has not put its own into secrets/tls/. Existing files are kept, so a restart changes nothing.
set -eu
umask 077

G=/secrets/gateway
T=/secrets/tls
mkdir -p "$G" "$T"

new() { [ -s "$G/$1" ] || openssl rand -hex "$2" > "$G/$1"; }
new gateway-client-secret 32
new display-client-secret 32
new hmac-secret 32
new keycloak-admin-password 16
new keycloak-db-password 16

# The three secrets Envoy reads, in the shape it reads them in.
sds() {
  printf 'resources:\n  - "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.Secret\n    name: %s\n    generic_secret:\n      secret:\n        inline_string: "%s"\n' \
    "$1" "$(cat "$G/$1")" > "$G/$1.yaml"
}
sds gateway-client-secret
sds display-client-secret
sds hmac-secret

# What Keycloak reads at its start (docker-compose.gateway.yml, env_file). The realm import fills the two client
# secrets into the clients it creates, once; afterwards they live in Keycloak's database.
{
  echo "KC_DB_PASSWORD=$(cat "$G/keycloak-db-password")"
  echo "KC_BOOTSTRAP_ADMIN_PASSWORD=$(cat "$G/keycloak-admin-password")"
  echo "KC_CORRIDOR_GATEWAY_SECRET=$(cat "$G/gateway-client-secret")"
  echo "KC_CORRIDOR_DISPLAY_SECRET=$(cat "$G/display-client-secret")"
} > "$G/keycloak.env"

if [ -s "$T/server.crt" ] && [ -s "$T/server.key" ]; then
  if ! openssl x509 -in "$T/server.crt" -noout -checkhost "$CORRIDOR_HOST" 2>/dev/null | grep -q 'does match' \
    && ! openssl x509 -in "$T/server.crt" -noout -checkip "$CORRIDOR_HOST" 2>/dev/null | grep -q 'does match'; then
    echo "WARNING: secrets/tls/server.crt is not issued for $CORRIDOR_HOST; browsers will refuse it." >&2
  fi
else
  case "$CORRIDOR_HOST" in
    *[!0-9.]*) san="DNS:$CORRIDOR_HOST" ;;
    *) san="IP:$CORRIDOR_HOST" ;;
  esac
  [ "$CORRIDOR_HOST" = localhost ] || san="$san,DNS:localhost"
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 397 -subj "/CN=$CORRIDOR_HOST" \
    -addext "subjectAltName=$san,IP:127.0.0.1" -addext extendedKeyUsage=serverAuth \
    -keyout "$T/server.key" -out "$T/server.crt" 2>/dev/null
  echo "NOTICE: no certificate in secrets/tls/, so a self-signed one was made for $CORRIDOR_HOST."
  echo "        Browsers will warn about it. For anything but an evaluation, put the site's own"
  echo "        server.crt and server.key there and restart."
fi
