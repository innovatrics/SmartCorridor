#!/usr/bin/env bash
# Accounts of the corridor's Keycloak, with the gateway on. Runs Keycloak's own admin CLI inside its container,
# against its internal address: nothing of Keycloak's administration is published.
#
#   gateway/users.sh add-user <name> <role>...    a person, or an Operational Display; prints a one-time password
#   gateway/users.sh add-integrator <client-id>   a system that calls the APIs; prints its client secret
#   gateway/users.sh list
#   gateway/users.sh revoke <name>                ends every session of <name>, the Display's long one included
#
# Roles: corridor-operator (the Operational Display, 8095), face-matcher-admin (Face Matcher UI, 8000),
# corridor-admin (the Hub's /corridor-hub/admin/ and the APIs), corridor-integrator (the APIs: 8090, 8098, 8097).
set -euo pipefail

ROLES="corridor-operator face-matcher-admin corridor-admin corridor-integrator"
die() { echo "ERROR: $*" >&2; exit 1; }

# kcadm inside the container; the administrator's password stays in the container's environment.
kc() {
  docker exec -i sceg-keycloak bash -c '
    cfg=/tmp/kcadm-$$.config
    trap "rm -f $cfg" EXIT
    out=$(/opt/keycloak/bin/kcadm.sh config credentials --config "$cfg" --server http://localhost:8080 \
      --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" 2>&1) \
      || { echo "$out" >&2; exit 1; }
    /opt/keycloak/bin/kcadm.sh "$@" --config "$cfg"' kcadm "$@"
}

check_role() {
  case " $ROLES " in *" $1 "*) ;; *) die "unknown role $1; one of: $ROLES" ;; esac
}

docker inspect sceg-keycloak >/dev/null 2>&1 || die "Keycloak is not running; start the corridor with the gateway on"

case "${1:-}" in
  add-user)
    [ $# -ge 3 ] || die "usage: $0 add-user <name> <role>..."
    name=$2; shift 2
    for r in "$@"; do check_role "$r"; done
    kc create users -r corridor -s "username=$name" -s enabled=true >/dev/null
    for r in "$@"; do kc add-roles -r corridor --uusername "$name" --rolename "$r"; done
    # a finite read: tr on /dev/urandom cut short by head ends in SIGPIPE, which pipefail turns into a failure
    password=$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-20)
    printf '%s' "$password" | docker exec -i sceg-keycloak bash -c '
      cfg=/tmp/kcadm-$$.config; trap "rm -f $cfg" EXIT
      out=$(/opt/keycloak/bin/kcadm.sh config credentials --config "$cfg" --server http://localhost:8080 \
        --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" 2>&1) \
        || { echo "$out" >&2; exit 1; }
      /opt/keycloak/bin/kcadm.sh set-password --config "$cfg" -r corridor --username "$1" \
        --new-password "$(cat)" --temporary' setpw "$name"
    echo "User $name created with the roles: $*"
    echo "One-time password: $password"
    echo "The first sign-in asks for a new password."
    ;;
  add-integrator)
    [ $# -eq 2 ] || die "usage: $0 add-integrator <client-id>"
    cid=$2
    kc create clients -r corridor -f - >/dev/null <<JSON
{"clientId": "$cid", "enabled": true, "protocol": "openid-connect", "publicClient": false,
 "standardFlowEnabled": false, "directAccessGrantsEnabled": false, "serviceAccountsEnabled": true,
 "fullScopeAllowed": false, "defaultClientScopes": ["basic", "roles"],
 "protocolMappers": [{"name": "audience-corridor-gateway", "protocol": "openid-connect",
   "protocolMapper": "oidc-audience-mapper", "config": {"included.custom.audience": "corridor-gateway",
   "access.token.claim": "true", "id.token.claim": "false", "introspection.token.claim": "true"}}]}
JSON
    id=$(kc get clients -r corridor -q "clientId=$cid" --fields id --format csv --noquotes)
    kc add-roles -r corridor --uusername "service-account-$cid" --rolename corridor-integrator
    # the client asks for no role but this one: its token carries corridor-integrator and nothing else
    role=$(kc get roles/corridor-integrator -r corridor --fields id --format csv --noquotes)
    kc create "clients/$id/scope-mappings/realm" -r corridor -f - >/dev/null <<<"[{\"id\": \"$role\", \"name\": \"corridor-integrator\"}]"
    secret=$(kc get "clients/$id/client-secret" -r corridor --fields value --format csv --noquotes)
    echo "Client $cid created with the role corridor-integrator."
    echo "Client secret: $secret"
    echo "Token: POST https://<CORRIDOR_HOST>:8443/realms/corridor/protocol/openid-connect/token"
    echo "       grant_type=client_credentials, the client id and secret as HTTP Basic authentication."
    ;;
  list)
    echo "Users:"
    kc get users -r corridor --fields username --format csv --noquotes | grep -v '^service-account-' | sed 's/^/  /'
    echo "Integrators:"
    kc get clients -r corridor --fields clientId,serviceAccountsEnabled --format csv --noquotes | grep ',true$' | cut -d, -f1 | sed 's/^/  /'
    ;;
  revoke)
    [ $# -eq 2 ] || die "usage: $0 revoke <name>"
    id=$(kc get users -r corridor -q "username=$2" -q exact=true --fields id --format csv --noquotes)
    [ -n "$id" ] || die "no user $2"
    kc create "users/$id/logout" -r corridor
    echo "Every session of $2 is ended; a browser that holds one is asked to sign in within 5 minutes."
    ;;
  *)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
