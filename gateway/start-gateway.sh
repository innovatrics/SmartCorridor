#!/bin/sh
# Entrypoint of the gateway container: fills the public host name into the configuration and starts Envoy.
# The three addresses of the login in envoy.yaml.tmpl are fixed when Envoy starts and cannot follow the name a
# browser typed, so the corridor answers under one name: CORRIDOR_HOST of .env.
set -eu

die() { echo "gateway: $1" >&2; exit 1; }

[ -n "${CORRIDOR_HOST:-}" ] || die "CORRIDOR_HOST is not set"
case "$CORRIDOR_HOST" in
  *[!A-Za-z0-9.-]*) die "CORRIDOR_HOST may hold letters, digits, dots and hyphens only: a host name or an IPv4 address" ;;
esac
for f in /etc/envoy-tls/server.crt /etc/envoy-tls/server.key \
  /etc/envoy-secrets/gateway-client-secret.yaml /etc/envoy-secrets/display-client-secret.yaml \
  /etc/envoy-secrets/hmac-secret.yaml; do
  [ -r "$f" ] || die "$f is missing or not readable; gateway/prepare.sh writes it"
done

sed "s|\${CORRIDOR_HOST}|$CORRIDOR_HOST|g" /etc/envoy/envoy.yaml.tmpl > /tmp/envoy.yaml
if grep -q '\${' /tmp/envoy.yaml; then
  die "envoy.yaml.tmpl has a placeholder this script does not fill in"
fi
exec envoy -c /tmp/envoy.yaml --log-level warn
