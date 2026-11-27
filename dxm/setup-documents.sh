#!/usr/bin/env bash
set -euo pipefail

# Document scans (README.md, "Document scans"): the document store's three identities with their keys (made once,
# kept), then the store itself, its bucket and the expiry rule the DSS checks before it copies anything. Idempotent;
# run with the corridor up (face-matcher-network) and dxm/.env filled in, again after factory-reset.sh. Prints no key.
cd "$(dirname "$0")"

setting() { grep -E "^$1=" ./.env | head -n1 | cut -d '=' -f2- | sed -E -e 's/\r$//' -e 's/[[:space:]]+#.*$//' -e 's/[[:space:]]+$//'; }
SECRETS="$(setting DXM_SECRETS_DIR)"
SECRETS="${SECRETS//\$\{HOME\}/$HOME}"
DEPLOYMENT="$(setting DSS_DEPLOYMENT_ID)"
DAYS="$(setting DOCUMENT_IMAGES_EXPIRY_DAYS)"
DAYS="${DAYS:-30}"
[[ "$DEPLOYMENT" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "ERROR: set DSS_DEPLOYMENT_ID in dxm/.env first." >&2; exit 1; }
[[ "$DAYS" =~ ^[1-9][0-9]{0,4}$ ]] || { echo "ERROR: DOCUMENT_IMAGES_EXPIRY_DAYS in dxm/.env must be a number of days." >&2; exit 1; }

# The DSS writes <prefix><DSS_DEPLOYMENT_ID>/<id> (its default prefix documents/); the Hub serves only that namespace.
BUCKET=corridor-documents
PREFIX=documents/
NAMESPACE="$PREFIX$DEPLOYMENT/"
mkdir -p "$SECRETS" && chmod 700 "$SECRETS"
umask 077

# A key already written is kept; a missing one is made.
r() { local s; s="$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c "$1" || true)"; printf '%s' "$s"; }
kept() { [ -f "$SECRETS/$1" ] && sed -n "s/^$2=//p" "$SECRETS/$1" | head -n1 || true; }
ADMIN_ID="$(kept documents-admin.env AWS_ACCESS_KEY_ID)";                  ADMIN_ID="${ADMIN_ID:-$(r 20)}"
ADMIN_KEY="$(kept documents-admin.env AWS_SECRET_ACCESS_KEY)";             ADMIN_KEY="${ADMIN_KEY:-$(r 40)}"
DSS_ID="$(kept documents-dss.env DOCUMENT_IMAGES_STORAGE_ACCESS_KEY)";     DSS_ID="${DSS_ID:-$(r 20)}"
DSS_KEY="$(kept documents-dss.env DOCUMENT_IMAGES_STORAGE_SECRET_KEY)";    DSS_KEY="${DSS_KEY:-$(r 40)}"
HUB_ID="$(kept documents-hub.env HUB_DOCUMENT_IMAGES_ACCESS_KEY)";         HUB_ID="${HUB_ID:-$(r 20)}"
HUB_KEY="$(kept documents-hub.env HUB_DOCUMENT_IMAGES_SECRET_KEY)";        HUB_KEY="${HUB_KEY:-$(r 40)}"

printf 'AWS_ACCESS_KEY_ID=%s\nAWS_SECRET_ACCESS_KEY=%s\nAWS_DEFAULT_REGION=us-east-1\n' "$ADMIN_ID" "$ADMIN_KEY" \
  > "$SECRETS/documents-admin.env"
printf 'DOCUMENT_IMAGES_STORAGE_ACCESS_KEY=%s\nDOCUMENT_IMAGES_STORAGE_SECRET_KEY=%s\n' "$DSS_ID" "$DSS_KEY" \
  > "$SECRETS/documents-dss.env"
printf 'HUB_DOCUMENT_IMAGES_NAMESPACE=%s\nHUB_DOCUMENT_IMAGES_ACCESS_KEY=%s\nHUB_DOCUMENT_IMAGES_SECRET_KEY=%s\n' \
  "$NAMESPACE" "$HUB_ID" "$HUB_KEY" > "$SECRETS/documents-hub.env"

# The store's identities. admin: this script only. corridor-dss: exactly what the DSS needs (its README, "Storage
# identity"): objects under the prefix, listing, and reading the expiry rule and the versioning, which it checks before
# it copies. corridor-hub-documents: reading the copies of this deployment, nothing else.
q='\"'
DSS_POLICY="{${q}Version${q}:${q}2012-10-17${q},${q}Statement${q}:[\
{${q}Effect${q}:${q}Allow${q},${q}Action${q}:[${q}s3:GetObject${q},${q}s3:PutObject${q},${q}s3:DeleteObject${q}],${q}Resource${q}:[${q}arn:aws:s3:::$BUCKET/$PREFIX*${q}]},\
{${q}Effect${q}:${q}Allow${q},${q}Action${q}:[${q}s3:ListBucket${q}],${q}Resource${q}:[${q}arn:aws:s3:::$BUCKET${q},${q}arn:aws:s3:::$BUCKET/$PREFIX*${q}]},\
{${q}Effect${q}:${q}Allow${q},${q}Action${q}:[${q}s3:GetLifecycleConfiguration${q},${q}s3:GetBucketVersioning${q}],${q}Resource${q}:[${q}arn:aws:s3:::$BUCKET${q}]}]}"
HUB_POLICY="{${q}Version${q}:${q}2012-10-17${q},${q}Statement${q}:[\
{${q}Effect${q}:${q}Allow${q},${q}Action${q}:[${q}s3:GetObject${q}],${q}Resource${q}:[${q}arn:aws:s3:::$BUCKET/$NAMESPACE*${q}]}]}"
CONFIG="$SECRETS/documents-s3.json"
BEFORE="$(cat "$CONFIG" 2>/dev/null | cksum || true)"
cat > "$CONFIG" <<JSON
{
 "identities": [
  {"name": "admin", "credentials": [{"accessKey": "$ADMIN_ID", "secretKey": "$ADMIN_KEY"}], "actions": ["Admin", "Read", "Write", "List", "Tagging"]},
  {"name": "corridor-dss", "credentials": [{"accessKey": "$DSS_ID", "secretKey": "$DSS_KEY"}], "policyNames": ["corridor-dss-documents"]},
  {"name": "corridor-hub-documents", "credentials": [{"accessKey": "$HUB_ID", "secretKey": "$HUB_KEY"}], "policyNames": ["corridor-hub-documents"]}
 ],
 "policies": [
  {"name": "corridor-dss-documents", "content": "$DSS_POLICY"},
  {"name": "corridor-hub-documents", "content": "$HUB_POLICY"}
 ]
}
JSON
echo "Identities in $SECRETS: documents-s3.json, documents-admin.env, documents-dss.env, documents-hub.env."

# The store reads its identities when it starts: started here, and recreated when they changed (its volume is kept).
COMPOSE=(docker compose -f ./docker-compose.yml --env-file ./.env --profile documents)
if [ "$BEFORE" != "$(cksum < "$CONFIG")" ]; then
  "${COMPOSE[@]}" up -d --force-recreate documents
else
  "${COMPOSE[@]}" up -d documents
fi

# aws-cli 2.22: later releases send a CRC32 checksum on every upload, which SeaweedFS 4.23 may refuse.
s3() {
  docker run --rm --network face-matcher-network --env-file "$SECRETS/documents-admin.env" amazon/aws-cli:2.22.0 \
    --endpoint-url http://sceg-documents:8333 s3api "$@"
}
for attempt in $(seq 1 30); do
  s3 list-buckets >/dev/null 2>&1 && break
  [ "$attempt" -eq 30 ] && { echo "ERROR: the document store does not answer; see docker logs sceg-documents" >&2; exit 1; }
  sleep 2
done
s3 head-bucket --bucket "$BUCKET" >/dev/null 2>&1 || s3 create-bucket --bucket "$BUCKET" >/dev/null
# The bucket is this package's own, with one DSS deployment: its one rule, which the DSS verifies before every copy.
s3 put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration \
  "{\"Rules\":[{\"ID\":\"dxm-document-images-expiry-$DEPLOYMENT\",\"Filter\":{\"Prefix\":\"$NAMESPACE\"},\"Status\":\"Enabled\",\"Expiration\":{\"Days\":$DAYS}}]}"
s3 get-bucket-lifecycle-configuration --bucket "$BUCKET" --output text \
  --query 'Rules[].[ID,Filter.Prefix,Status,Expiration.Days]' | sed 's/^/Expiry rule: /'
echo "Document store ready: bucket $BUCKET, copies under $NAMESPACE, deleted $DAYS days after they are made."
