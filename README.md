# Smart Corridor

> [!CAUTION]
> **THIS IS FOR DEMO AND EVALUATION PURPOSES ONLY.**
> Has no Auth by default. For prod turn on auth, the gateway: see [The gateway](#the-gateway) and the [documentation](https://developers.innovatrics.com/docs/border-control/smart-biometric-corridors/).

Corridor and e-gate clearance on top of [Face Matcher](face-matcher/). The Hub turns identifications into per-traveller clearance decisions, CIGS groups detections into identities, and the operational display is the officer dashboard. Face Matcher is vendored in `face-matcher/` and started by `start.sh`.

# Deployment

1. Install `Docker` and `docker compose` on the host machine.
2. Login to container registry `docker login registry.dot.innovatrics.com -u <username> -p <password>`. The credentials are available in our [Customer Portal](https://customerportal.innovatrics.com/). The images are not public: your account needs the right to pull from two projects of the registry, `vpp/` (the platform) and `border-control/` (the corridor services and Face Matcher UI). If a pull is refused with `unauthorized`, your account lacks that right; ask your Innovatrics contact for it.
3. Identify hardware id (hwid) for your machine with command `docker run --rm registry.dot.innovatrics.com/vpp/license-manager:3.2.7`.
4. Obtain a license with the `smart_corridor` block for your hwid from our Customer Portal https://customerportal.innovatrics.com/
5. Copy the license file `iengine.lic` to `secrets/`. The registry holds the images only, never a license: the license is bought, or a trial is asked for at your Innovatrics sales representative.
6. Run `start.sh`.

The dashboard is at http://localhost:8095. With the gateway on, everything is behind a login and HTTPS: see [The gateway](#the-gateway).

## Scripts

- `start.sh` - starts Face Matcher, then the corridor services
- `stop.sh` - stops everything, keeps data
- `factory-reset.sh` - stops everything and deletes containers, images and volumes

MCT is not started or stopped by these scripts. See below.

## Endpoints

Without the gateway (`CORRIDOR_GATEWAY_ENABLED=false`, as shipped):

| Service            | URL                                         | Credentials                |
| ------------------ | ------------------------------------------- | -------------------------- |
| Corridor dashboard | http://localhost:8095                       |                            |
| Hub GraphQL        | http://localhost:8090/corridor-hub/graphql  |                            |
| Hub GraphiQL       | http://localhost:8090/corridor-hub/graphiql |                            |
| CIGS health        | http://localhost:8096/actuator/health       |                            |
| Face Matcher UI    | http://localhost:8000                       |                            |
| REST API           | http://localhost:8098                       |                            |
| GraphQL API        | http://localhost:8097/graphql               |                            |
| RabbitMQ           | http://localhost:15672                      | guest / guest              |
| SeaweedFS (S3)     | http://localhost:8333                       | admin / admin              |
| pgAdmin            | http://localhost:7070                       | admin@admin.com / Test1234 |

Ports are published on all interfaces with default credentials. Do not expose the host to an untrusted network. With the gateway on, see [The gateway](#the-gateway) for the ports.

## Configuration

- `.env` - corridor image versions, the dashboard port, and the gateway: `CORRIDOR_GATEWAY_ENABLED`, `CORRIDOR_HOST`, its images
- `.env.hub` - Hub: denied watchlists (RED), dead-letter expiry, database, corridor units and their cameras, storage, zone notifications. Documented inline.
- `face-matcher/` - a copy of the Face Matcher repository. Do not edit it, with one exception: `face-matcher/.env.face-matcher-ui` is pre-configured with the Smart Corridor watchlist member labels (`WATCHLIST_MEMBER_KEY_n` / `WATCHLIST_MEMBER_LABEL_n`). To upgrade, replace the directory with a checkout of the new release and carry that label block over. `start.sh` runs it with `FACE_MATCHER_UI_IDENTIFICATION=false`.

All services join `face-matcher-network`, created by Face Matcher. The corridor services use only what [`face-matcher/README.md`](face-matcher/README.md#integration) lists.

## Login

As shipped, nothing in the corridor asks anyone to sign in (`CORRIDOR_GATEWAY_ENABLED=false`), and Face Matcher UI's own login stays off. Run it like that for demos and evaluation only, on a trusted network. The Hub, CIGS and the dashboard call Face Matcher's API without a token, so a login on the UI alone would protect one port while the API behind it stays open: the corridor is protected as a whole, by the gateway in front of all its services: turn it on as [The gateway](#the-gateway) says. For a standalone Face Matcher see [`face-matcher/README.md`](face-matcher/README.md#turning-the-login-on), "Turning the login on".

## The gateway

With `CORRIDOR_GATEWAY_ENABLED=true` in `.env`, `start.sh` puts a gateway (Envoy) and the corridor's own Keycloak in front of the whole corridor. The official documentation: [Smart Biometric Corridors](https://developers.innovatrics.com/docs/border-control/smart-biometric-corridors/). The gateway is then the only container that publishes ports, every port is HTTPS, a person signs in on Keycloak, a system sends a token, and the gateway checks the role. The services behind it run as before, without authentication, on `face-matcher-network`; they get neither the session cookies nor the tokens.

| Port | What                     | Who                                   | Role                                                           |
| ---- | ------------------------ | ------------------------------------- | -------------------------------------------------------------- |
| 8095 | Corridor dashboard       | operators, wall displays: sign-in     | `corridor-operator`                                            |
| 8000 | Face Matcher UI          | administrators: sign-in               | `face-matcher-admin`                                           |
| 8090 | Hub API                  | systems: bearer token                 | `corridor-integrator`; `/corridor-hub/admin/`: `corridor-admin` |
| 8098 | Face Matcher REST API    | systems: bearer token                 | `corridor-integrator` or `corridor-admin`                      |
| 8097 | Face Matcher GraphQL API | systems: bearer token                 | `corridor-integrator` or `corridor-admin`                      |
| 8443 | Keycloak                 | everyone: the login pages and tokens  | —                                                              |
| 8883 | MQTT over TLS            | cameras that publish to the broker    | the broker's own credentials                                   |

Nothing else is published: not CIGS, not the camera previews, not the synchronization leader. PostgreSQL, pgAdmin, RabbitMQ and S3 are published on the host's loopback only, for the person at the machine.

### Turning it on

1. In `.env`, set `CORRIDOR_GATEWAY_ENABLED=true` and `CORRIDOR_HOST` to the one name (or IPv4 address) operators and systems use for this host. The login works under that name only; opened under another name or address, Keycloak refuses the sign-in.
2. Put the site's certificate for `CORRIDOR_HOST` into `secrets/tls/server.crt` (the certificate first, then its chain) and its key into `secrets/tls/server.key`. Without them, `start.sh` makes a self-signed certificate: browsers warn about it, and every client has to trust it. Good for an evaluation only.
3. Run `start.sh`. The first start writes the gateway's secrets into `secrets/gateway/` and imports the realm `corridor` into Keycloak; both are kept afterwards.
4. Make the accounts, with Keycloak running:

   ```
   gateway/users.sh add-user display-gate-1 corridor-operator
   gateway/users.sh add-user jane.doe face-matcher-admin corridor-admin
   gateway/users.sh add-integrator border-system
   gateway/users.sh list
   ```

   `add-user` prints a one-time password; the first sign-in asks for a new one (at least 12 characters). `add-integrator` prints the client's secret: the system gets a token with it from `https://<CORRIDOR_HOST>:8443/realms/corridor/protocol/openid-connect/token` (`grant_type=client_credentials`, the client id and secret as HTTP Basic authentication) and sends it as `Authorization: Bearer <token>`, for the Hub's subscription too. A token lives 5 minutes; ask for a new one before it ends.

Keycloak's administration console is not published. `gateway/users.sh` uses Keycloak's admin CLI inside its container; Keycloak's administrator password is in `secrets/gateway/keycloak.env`.

### Sessions

- **People** sign in once per session: Keycloak ends a session after 30 minutes without use and after 10 hours at most. The gateway renews the 5-minute token by itself in between.
- **A wall display** signed in on port 8095 keeps its session: it ends only after 30 days without use, or when it is revoked. The browser of the display must keep its profile (cookies), or every restart asks for the password again. Give a display an account of its own with `corridor-operator` only.
- **Revoke** a session, a display's included: `gateway/users.sh revoke <name>`. It takes effect within the token's 5 minutes: from then on the gateway refuses the display's data requests, and the next load of the page asks for the password. A screen that is open stays on its last state until it is loaded again; restart the display's browser to make sure.
- **Sign out**: `https://<CORRIDOR_HOST>:<port>/oauth2/signout` ends the gateway's session and Keycloak's.

These lifetimes are set in `gateway/realm/corridor-realm.json` and imported at the first start only; later, change them in Keycloak (admin CLI) or start from a factory reset.

### What it does not protect

- Inside `face-matcher-network` everything stays plain HTTP without authentication: whoever runs a container on this host, or reaches the network, reaches every service directly.
- The default credentials of PostgreSQL, RabbitMQ, S3 and pgAdmin (in `face-matcher/.env` and `face-matcher/dependencies/docker-compose.yml`) still apply on the host's loopback and inside the network. Change them before production use.
- MQTT clients are authenticated by the broker, not by the gateway.

### Turning it off, upgrading, changing the name

- `CORRIDOR_GATEWAY_ENABLED=false` and `start.sh`: the gateway and Keycloak are removed and the ports are published as before, without any login. Keycloak's accounts stay in its database for the next time.
- `CORRIDOR_HOST` is part of the accounts' clients in Keycloak: after changing it, start from `factory-reset.sh` (which deletes all accounts) or correct the redirect addresses of the clients `corridor-gateway` and `corridor-display` in Keycloak.
- `factory-reset.sh` deletes Keycloak's database with the corridor's; `secrets/` is kept, so the next start reuses the same secrets and certificate.
- The gateway loads Keycloak's signing keys when it starts and keeps them for 5 minutes. `start.sh` recreates it; a gateway left running while Keycloak got new keys (a new database) refuses the new tokens for up to 5 minutes.

## Zone notifications (Hub 0.4.0 and newer)

The Hub can emit `zone.*` notifications (person entered, left, moved, occupancy, counts) on the `corridorEvents` subscription, each computed from the platform, CIGS or MCT. `.env.hub` contains a commented example. `person_moved` requires MCT.

## Clearance

The Hub clears every watchlist match GREEN unless the matched watchlist is listed in `VPP_ADAPTER_DENIED_WATCHLISTS` (`.env.hub`; watchlist ids as the platform reports them in a match, or globs such as `red.*`); such a match is RED. An empty list makes every match GREEN, `*` makes every match RED. The dashboard names the watchlist on each card and shows the enrolled face of the matched member next to the live one.

## Upgrading to Face Matcher v2.0.0: Face Matcher UI in place of Station

- SmartFace Station is replaced by Face Matcher UI 2.1.1, from the registry project `border-control/`: the service and container `fm-station` are now `face-matcher-ui`, still on port 8000. A system that called `fm-station:8000` on `face-matcher-network` calls `face-matcher-ui:8000`.
- `face-matcher/.env.station` is now `face-matcher/.env.face-matcher-ui`, and `branding/station/` is `branding/face-matcher-ui/`. Carry the label block over into the new file, as for every upgrade of `face-matcher/`.
- `start.sh` exports `FACE_MATCHER_UI_IDENTIFICATION` in place of `STATION_IDENTIFICATION`; `STATION_PUBLIC_HOST` is gone.
- The dashboard's camera preview points at `http://face-matcher-ui:8000` (`FACE_MATCHER_STATION_URL` in `docker-compose.yml`).

Run `stop.sh`, replace the directories, and run `start.sh`. The old container `fm-station` is removed as an orphan by Face Matcher's `run.sh`.

## Upgrading from Hub 0.9.2 / dashboard 0.9.1

- The Hub no longer proxies Face Matcher: `/corridor-hub/vpp/**` answers 404. The dashboard's nginx calls Face Matcher itself, server-side, so the browser still talks to the dashboard only. It needs `FACE_MATCHER_GQL_URL` and `FACE_MATCHER_API_URL` (set in `docker-compose.yml`) and does not start without them.
- The camera preview reads `FACE_MATCHER_STATION_URL`, formerly `SMARTFACE_STATION_URL`. The dashboard ignores the old name and logs a warning.
- `HUB_VPP_REST_URL` is removed from `.env.hub`; Hub 0.10.0 ignores it.
- Upgrade the Hub and the dashboard together, and roll both back together: dashboard 0.9.1 and older needs the Face Matcher proxy of Hub 0.9.2 and older.

If you changed `docker-compose.yml` or `.env.hub`, carry these changes over. Then run `stop.sh`, pull the new version and run `start.sh`. Coming from Hub 0.9.1 / dashboard 0.8.0, also purge the dead-letter queue as described below.

## Upgrading from Hub 0.9.1 / dashboard 0.8.0

- Events the Hub cannot process (dead letters, kept in the RabbitMQ queue `biometric_events.dlq`) no longer contain face crops, templates or watchlist member names, and each expires after `DEAD_LETTER_TTL` (`.env.hub`, default 7 days).
- The dashboard needs no configuration change.

Run `stop.sh`, pull the new version and run `start.sh`. Then purge the queue once:

```
docker exec face-matcher-dependencies-rabbitmq-1 rabbitmqctl purge_queue biometric_events.dlq
```

Dead letters written by Hub 0.9.1 and older may contain face crops and templates and never expire; until they are gone, the newer dead letters behind them do not expire either. Until the purge, the Hub logs a warning after each start. Purge in the RabbitMQ management UI works as well; add `-p <vhost>` to the command if you changed `RABBITMQ_VIRTUAL_HOST`.

## Upgrading from Hub 0.4.0 / dashboard 0.5.0

- `VPP_ADAPTER_ALLOWED_WATCHLISTS` is retired and the Hub refuses to start while it is set. Put the watchlists that must clear RED into `VPP_ADAPTER_DENIED_WATCHLISTS` instead; the meaning is inverted. With no list set, every match used to be RED and is now GREEN; `VPP_ADAPTER_DENIED_WATCHLISTS=*` keeps every match RED.
- The dashboard listens on port 8080 inside the container (non-root image).
- The Hub proxies the platform REST API for the dashboard: set `HUB_VPP_REST_URL`.
- The Hub keeps its corridor configuration and event history in PostgreSQL: set `SPRING_DATASOURCE_*` in `.env.hub` (database `corridorhub` on the platform's `pgsql`, created by `start.sh`). Without it the Hub falls back to an in-memory database and loses both on every restart.

Then run `stop.sh`, pull the new version and run `start.sh`.

# Multi-Camera Tracking (MCT)

Optional. Tracks people across corridor cameras and feeds MCT-based zone notifications and a floor-plan visualizer. Images are `linux/amd64`. Configuration is in `mct/.env.mct`.

Requires:

1. A per-camera detection feed from SmartFace Embedded Stream Processor cameras, published to `rmq` over MQTT as `edge-stream/<clientId>/frame_data`. RTSP cameras do not produce this feed.
2. A calibration model, produced per site by Innovatrics, in `mct/models_data/`, named as `MCT_MODEL`. Alternatively import it through http://localhost:8002/swagger/index.html?url=/openapi/v1.json after starting `configurationApi`.

Start, after `start.sh`:

```
docker compose -p sceg-mct -f mct/docker-compose.yml --env-file mct/.env.mct --profile migrate run --rm dbMigrator
docker compose -p sceg-mct -f mct/docker-compose.yml --env-file mct/.env.mct --profile seed run --rm configApiSeeder
docker compose -p sceg-mct -f mct/docker-compose.yml --env-file mct/.env.mct up -d
```

Run the first two only once, and `migrate` again after raising `MCT_TAG`. `seed` overwrites the model in the database.

Stop:

```
docker compose -p sceg-mct -f mct/docker-compose.yml --env-file mct/.env.mct down
```

Add `-v` to also delete the calibration database, recordings and snapshots.

| Service     | URL                   |
| ----------- | --------------------- |
| Visualizer  | http://localhost:8004 |
| Config API  | http://localhost:8002 |
| Tracker API | http://localhost:8420 |
| Identifier  | http://localhost:8003 |
| Recording   | http://localhost:8005 |

Set `ZONE_MCT_ENABLED=true` in `.env.hub` for the Hub to consume the track stream. Set `MCT_LOG_LEVEL=DEBUG` in `mct/.env.mct` to log every ingested frame.

## Production use

This deployment demonstrates the configuration needed to wire everything up. Before production use, turn the gateway on with the site's own certificate, and change the default credentials of the platform's dependencies.
