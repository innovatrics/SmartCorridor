# Face Matcher

> [!CAUTION]
> **THIS IS FOR DEMO AND EVALUATION PURPOSES ONLY.**
> Has no Auth by default. For prod turn on auth: see [Turning the login on](#turning-the-login-on) and the [documentation](https://developers.innovatrics.com/docs/border-control/smart-biometric-corridors/face-matcher/).

Face Matcher is a real-time face identification server. It processes video streams, matches faces against watchlists and publishes the results over REST, GraphQL and RabbitMQ. Face Matcher UI is the web UI for watchlists, cameras, live previews and 1:N search.

# Deployment

1. Install `Docker` and `docker compose` on the host machine.
2. Login to container registry `docker login registry.dot.innovatrics.com -u <username> -p <password>`. The credentials are available in our [Customer Portal](https://customerportal.innovatrics.com/). The images are not public. Your account needs the right to pull from two projects of the registry: `vpp/` (the platform) and `border-control/` (Face Matcher UI). If a pull is refused with `unauthorized`, your account lacks that right; ask your Innovatrics contact for it.
3. Identify hardware id (hwid) for your machine with command `docker run --rm registry.dot.innovatrics.com/vpp/license-manager:3.2.7`.
4. The registry holds the images only, never a license. The license is separate: buy it, or ask your Innovatrics sales representative for a trial; generate `iengine.lic` for this machine's hardware id in the [Customer Portal](https://customerportal.innovatrics.com/) and copy it to `secrets/`.
5. Run `run.sh`.

Face Matcher UI is at http://localhost:8000. It opens without login.

## Scripts

- `run.sh` - starts dependencies, migrates the database, starts the platform services and Face Matcher UI
- `stop.sh` - stops everything, keeps data
- `factory-reset.sh` - stops everything and deletes containers, images and volumes

## Endpoints

| Service         | URL                           | Credentials                |
| --------------- | ----------------------------- | -------------------------- |
| Face Matcher UI | http://localhost:8000         |                            |
| REST API        | http://localhost:8098         |                            |
| GraphQL API     | http://localhost:8097/graphql |                            |
| RabbitMQ        | http://localhost:15672        | guest / guest              |
| SeaweedFS (S3)  | http://localhost:8333         | admin / admin              |
| pgAdmin         | http://localhost:7070         | admin@admin.com / Test1234 |

Ports are published on all interfaces with default credentials. Do not expose the host to an untrusted network.

Face Matcher UI asks nobody to sign in, and the REST and GraphQL APIs run without authentication: whoever reaches these ports has full access. With the login off, the UI sends the APIs no credential.

## Configuration

- `.env` - all settings, documented inline. Section 4 is Face Matcher UI: registry, image version, port, `FACE_MATCHER_UI_IDENTIFICATION`.
- `.env.face-matcher-ui` - Face Matcher UI settings. The login block is first.
- `branding/face-matcher-ui/` - Face Matcher UI logo, favicon and naming
- `docker-compose.yml`, `dependencies/docker-compose.yml`, `run.sh` - the Innovatrics video processing platform release package (`video_processing_deployment.zip`)
- `docker-compose.override.yml` - Face Matcher UI, the restart policy and `user: root`, see the comment inside
- `secrets/` - git-ignored. The license; with the login on also the client secret, the TLS key and certificate.

After a change in `.env.face-matcher-ui`, `docker compose up -d face-matcher-ui` recreates the UI only.

Not deployed: offline video processing, grouping, Milvus, Access Controller. The palm services run; Face Matcher UI keeps its palm screens off (`PALMS_ENABLED=false` in `.env.face-matcher-ui`).

## Turning the login on

This section is for a standalone Face Matcher. In a Smart Corridor, Face Matcher UI's own login stays off: the corridor's gateway signs users in, in front of all its services; see the Smart Corridor README, "The gateway".

Face Matcher UI signs its users in through Keycloak (OpenID Connect). It has no other login. The official documentation: [Face Matcher](https://developers.innovatrics.com/docs/border-control/smart-biometric-corridors/face-matcher/).

### As shipped: the login and HTTPS off

The login block of `.env.face-matcher-ui`:

```
KEYCLOAK_AUTHENTICATION_ENABLED=false
HTTPS_ENABLED=false
```

For evaluation, demos and experiments on a trusted network only. The UI is served over plain HTTP and asks nobody to sign in: whoever reaches port 8000 has full access to the members' photos, the results and the live video, and can change cameras and watchlists. The UI says so in its log at every start.

Face Matcher UI has the login on by default. The line `KEYCLOAK_AUTHENTICATION_ENABLED=false` is what lets it run without login; without that line it does not start until its Keycloak settings are set. Only `true` and `false` are accepted; any other value stops the start.

### Production: the Keycloak login on, over HTTPS

`<host>` is the host name the operators type to open Face Matcher UI.

1. What you bring:
   - A Keycloak, version 17 or newer (tested with 26.8.1), that the operators' browsers and this host both reach at the same `https://` address.
   - A TLS key and certificate for `<host>`, in PEM format, the key without a password.
2. In Keycloak, in the realm of your users:
   - Create a client. Client type: OpenID Connect. Client authentication: on. Authentication flow: Standard flow only.
   - Valid redirect URIs: `https://<host>:8000/-/auth/callback`. Valid post logout redirect URIs: `https://<host>:8000/`. Web origins: none. The port is `FACE_MATCHER_UI_PORT` from `.env`.
   - On the client's Advanced tab set Proof Key for Code Exchange Code Challenge Method to `S256`.
   - Copy the client secret from the client's Credentials tab.
   - Create the role `face-matcher-admin`, as a realm role or as a role of that client, and give it to the users, or to a group. It is the one role that grants access.
3. In `.env.face-matcher-ui`, in the login block:
   - Remove the line `KEYCLOAK_AUTHENTICATION_ENABLED=false`.
   - Uncomment and fill in `KEYCLOAK_DOMAIN` (the address of Keycloak, `https://...`, without `/auth` and without the realm), `KEYCLOAK_REALM` and `KEYCLOAK_CLIENT_ID`. Uncomment `KEYCLOAK_ROLE` only if the role has another name.
   - Set `HTTPS_ENABLED=true`. Uncomment `HTTPS_HOST_NAME` and set it to `<host>`. Uncomment `HTTPS_KEY_FILE=/certs/server.key` and `HTTPS_CERT_FILE=/certs/server.crt`.

   The block then reads, for example:

   ```
   KEYCLOAK_DOMAIN=https://sso.example.com
   KEYCLOAK_REALM=face-matcher
   KEYCLOAK_CLIENT_ID=face-matcher-ui
   HTTPS_ENABLED=true
   HTTPS_HOST_NAME=face-matcher.example.com
   HTTPS_KEY_FILE=/certs/server.key
   HTTPS_CERT_FILE=/certs/server.crt
   ```
4. In `secrets/`, which is git-ignored:
   - `face-matcher-ui.env` with one line, `KEYCLOAK_CLIENT_SECRET=<the client secret>`
   - `tls/server.key` and `tls/server.crt`, the key and the certificate. The certificate file holds the certificate first, then its chain.

   The UI runs as uid 1000 and must be able to read `secrets/tls` and the files in it; `sudo chown -R 1000 secrets/tls` gives them to that user. A key it cannot read stops the start.
5. In `docker-compose.override.yml`, at `face-matcher-ui`, uncomment the two lines `- ./secrets/face-matcher-ui.env` and `- ./secrets/tls:/certs:ro`.
6. Run `run.sh`. When Face Matcher is running already, `docker compose up -d face-matcher-ui` is enough. If the UI does not come up, `docker logs face-matcher-ui` names the reason.
7. Check at `https://<host>:8000` (`run.sh` still prints the `http://` address):
   - The Keycloak login appears, and a user with the role gets in.
   - A user without the role gets "No access".
   - `http://<host>:8000` does not answer any more.
   - `docker logs face-matcher-ui` no longer says "The login is off".

**Behind a reverse proxy that terminates TLS**, in place of the key and certificate: leave `HTTPS_ENABLED=false`, skip `tls/` in step 4 and uncomment only the first of the two lines in step 5. The proxy sends `X-Forwarded-Proto: https` and keeps the `Host` header, or sets `X-Forwarded-Host`. The redirect URIs in Keycloak are the proxy's address: `https://<host>/-/auth/callback` and `https://<host>/`. A login that reaches the UI over plain HTTP is refused with "Login unavailable"; opened as `http://localhost:8000` on the host itself, it is Keycloak that refuses it. Let only the proxy reach port 8000.

**A Keycloak certificate from a private authority**: the UI has to trust that authority, otherwise the login ends in "Login unavailable" and the log says `Keycloak not reachable`. Copy the authority's certificate (PEM) to `secrets/tls/ca.crt`, add the line `NODE_EXTRA_CA_CERTS=/certs/ca.crt` to `.env.face-matcher-ui` and keep the mount of `secrets/tls` in step 5.

**Back to the shipped state**: put the line `KEYCLOAK_AUTHENTICATION_ENABLED=false` back, set `HTTPS_ENABLED=false`, remove the `NODE_EXTRA_CA_CERTS` line if you added one, comment the two lines in `docker-compose.override.yml` again and run `run.sh` (or `docker compose up -d face-matcher-ui`).

### What stays open with the login on

- The login protects Face Matcher UI only. The REST and GraphQL APIs on ports 8098 and 8097 have no authentication, so whoever reaches them goes around the login. A standalone Face Matcher may turn their authentication on, never a Smart Corridor: in `.env`, section 3.3, `Authentication__UseAuthentication=true`, `Authentication__Authority=<KEYCLOAK_DOMAIN>/realms/<KEYCLOAK_REALM>` and `Authentication__Audience=face-matcher`; in Keycloak, an Audience mapper on the UI's client that adds `face-matcher` to its access tokens. The UI then calls the APIs with the token of the signed-in user. With a Keycloak certificate from a private authority, the APIs have to trust it as well, otherwise they refuse every token (HTTP 401): with the authority's certificate in `secrets/tls/ca.crt`, uncomment the `environment` and `volumes` lines at `api` and at `graphql-api` in `docker-compose.override.yml`.
- With `VIDEO_WITHOUT_LOGIN=true` the live camera video is readable without login.
- Between the UI and the APIs the traffic, the user's token included, is plain HTTP on the compose network.
- RabbitMQ, the S3 storage, PostgreSQL and pgAdmin stay published on all interfaces with default credentials. Change the credentials and restrict the ports.

## Changes to the release package

- `docker-compose.yml`, `.env` - `grouping` and `video-*` services and their settings removed
- `.env` - `REGISTRY` points to Harbor; `Notifications__IncludeTemplates=true`; `Milvus__*` removed; section 4 added
- `dependencies/docker-compose.yml` - Milvus removed; RabbitMQ pinned to 4.3.6 with `queue_master_locator` permitted; one SeaweedFS data mount; the published ports bind to `DEPENDENCIES_BIND_ADDRESS` when it is set in the environment of `run.sh`
- `run.sh` - license from `secrets/` and the endpoint summary added; Milvus wait removed
- `deployment-common.sh` - Milvus wait removed
- `sync-embeddings-to-vector-db.sh`, `migrate-palms.sh`, `finalize-non-migrated-palms.sh` - deleted
- `docker-compose.override.yml`, `stop.sh`, `factory-reset.sh`, `.env.face-matcher-ui`, `branding/` - added

## Upgrade

1. Mirror the new release images into `registry.dot.innovatrics.com/vpp/`.
2. Unpack the new `video_processing_deployment.zip` over this directory and re-apply the changes above.
3. If the face template model changed, run the migration below.
4. Run `run.sh`.

A site with the login on: a new version of this package brings `.env.face-matcher-ui` and `docker-compose.override.yml` as shipped, with the login off. Carry the login block and the two uncommented lines over before `run.sh`, and check afterwards that the UI still asks for the login. `secrets/` is not touched.

## Upgrading from v1.0.0

v1.0.0 ran SmartFace Station. This version runs Face Matcher UI 2.1.1 in its place, on the same port. The old names are gone, without aliases:

| v1.0.0                                                      | Now                                                                                  |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| service `station`, container `fm-station`                   | service and container `face-matcher-ui`                                              |
| image `sf-station` from `vpp/`                              | image `face-matcher-ui` from `border-control/` (`FACE_MATCHER_UI_REGISTRY`)          |
| `.env.station`                                              | `.env.face-matcher-ui`                                                               |
| `branding/station/`                                         | `branding/face-matcher-ui/`                                                          |
| `STATION_VERSION`, `STATION_PORT`, `STATION_IDENTIFICATION` | `FACE_MATCHER_UI_VERSION`, `FACE_MATCHER_UI_PORT`, `FACE_MATCHER_UI_IDENTIFICATION`  |
| `STATION_PUBLIC_HOST`, `S3_PUBLIC_ENDPOINT`                 | removed: the UI serves the members' photos itself                                    |

1. Before stopping anything, try `docker pull registry.dot.innovatrics.com/border-control/face-matcher-ui:2.1.1`. If it is refused with `unauthorized`, your registry account lacks the right to pull from `border-control/`; ask your Innovatrics contact for it first.
2. Carry your own values from `.env.station` over into `.env.face-matcher-ui`: `BLACKLIST_WATCHLIST_IDS`, the `WATCHLIST_MEMBER_KEY_n` / `WATCHLIST_MEMBER_LABEL_n` labels, `CAM_PREVIEW_HOST_*`, `SCORE_CONVERSION_*`. Leave Station's `S3_*`, `AUTH0_*`, `KEYCLOAK_*` and `ROLE_KEY_*` lines behind: Face Matcher UI does not read them, and its Keycloak login is set up as described in [Turning the login on](#turning-the-login-on).
3. Carry your own logos over into `branding/face-matcher-ui/`. Of `naming-product.json` the UI reads `windowTitle` and `configSection`.
4. Change what you built on the old names: `fm-station:8000` is now `face-matcher-ui:8000`, and `run.sh` reads `FACE_MATCHER_UI_IDENTIFICATION` in place of `STATION_IDENTIFICATION`.
5. Run `run.sh`. It removes the `fm-station` container.

## Face templates migration

1. To start migration of face templates, execute
```
./migrate-faces.sh
```

This will stop the current compose services, spawn the required face detector and extractor services, and run the migration CLI command. After this, you should see output regarding the success rate of migration and also a list of watchlist members for which template migration was not possible. You should store this output to handle those members' faces manually by requesting reenrollment of their faces.

> **Note (1):** You can override the default template model version (`53`) by setting `FACE_MODEL_VERSION` env variable before running the script. Possible values are `52` (`fast`), `53` (`balanced`), `54` (`accurate`), `55` (`accurate_server`).

> **Note (2):** It is possible that there were some transient errors while running this script (e.g. some RPC calls may timeout). In that case, it is safe to run this command again.

2. To finalize migration, execute
```
./finalize-non-migrated-faces.sh
```
This will force the remaining faces that were not possible to migrate to be set to error state and thus be skipped by our matchers at startup.

3. Start the services again with `run.sh`.

## Watchlist update-log stream

If the release notes say the watchlist update-log stream needs regenerating, execute
```
./populate-wl-update-log-stream.sh
```

## Integration

A stack built on Face Matcher may rely on the following. Everything else is internal.

| Network         | `face-matcher-network`, created by `run.sh`. Join it with `external: true`.                          |
| --------------- | --------------------------------------------------------------------------------------------------- |
| REST API        | `api:8080`                                                                                          |
| GraphQL API     | `graphql-api:8080`. Face templates are included in notifications.                                    |
| RabbitMQ        | `rmq:5672` AMQP, `rmq:1883` MQTT, `rmq:5552` streams                                                |
| S3              | `seaweedfs:8333`. Use your own bucket.                                                               |
| PostgreSQL      | `pgsql:5432`                                                                                        |
| Face Matcher UI | `face-matcher-ui:8000`                                                                              |
| Admin image     | `${REGISTRY}admin:${VERSION}` from `.env`                                                            |
| Start order     | Face Matcher first. `run.sh` reads `FACE_MATCHER_UI_IDENTIFICATION` from the environment.            |
| Ports           | A stack with its own entry point may run `run.sh` with `DEPENDENCIES_BIND_ADDRESS=127.0.0.1`: PostgreSQL, pgAdmin, RabbitMQ and S3 are then published on the host's loopback only. |

Credentials are in `.env`.

## Production use

This deployment demonstrates the configuration needed to wire everything up. Turn the login of Face Matcher UI on, change the credentials and restrict the published ports before production use.
