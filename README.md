# Smart Corridor

> [!CAUTION]
> **THIS IS FOR DEMO AND EVALUATION PURPOSES ONLY.** Authentication is off by default. For production, turn on [the gateway](#the-gateway). See the [documentation](https://developers.innovatrics.com/docs/border-control/smart-biometric-corridors/).

Corridor and e-gate clearance on top of [Face Matcher](face-matcher/). The Hub turns identifications into per-traveller clearance decisions, CIGS (Corridor Identity Grouping Service) groups detections into identities, and the operational display is the officer dashboard. Face Matcher is vendored in `face-matcher/` and started by `start.sh`.

| Component                     | Version           | Set in                  |
| ----------------------------- | ----------------- | ----------------------- |
| Corridor Hub                  | 0.13.0            | `.env` `HUB_VERSION`      |
| Operational display           | 0.13.0            | `.env` `FRONTEND_VERSION` |
| CIGS                          | 0.5.0             | `.env` `CIGS_VERSION`     |
| Face Matcher                  | v5_4.43.0.10149   | `face-matcher/.env` `VERSION` |
| Face Matcher UI               | 2.1.2             | `face-matcher/.env` `FACE_MATCHER_UI_VERSION` |
| DSS, CEA (optional)           | 0.4.0, 0.3.1      | `dxm/.env` (see [dxm/](dxm/README.md)) |

Display 0.13.0 needs Hub 0.13.0; the fallback is 0.12.0 for both. Since Hub 0.12.0 identification comes from CIGS: with CIGS stopped or `CIGS_SOURCE_ENABLED=false` the Hub identifies no one and does not warn. Start order is CIGS, Hub, Display; compose waits for CIGS to be healthy before it starts the Hub.

# Deployment

Before deploying, you will need:

- Docker and `docker compose`
- Login to the container registry `docker login registry.dot.innovatrics.com -u <username> -p <password>`. The credentials are available in our [Customer Portal](https://customerportal.innovatrics.com/). If a pull is refused with `unauthorized`, ask your Innovatrics contact for pull rights.

## License

- Identify the hardware id (hwid) of your machine with `docker run --rm registry.dot.innovatrics.com/vpp/license-manager:3.2.7`.
- Obtain a license with the `smart_corridor` block for your hwid from the [Customer Portal](https://customerportal.innovatrics.com/) (bought, or a trial from your Innovatrics sales representative).
- Copy `iengine.lic` to `secrets/`.

## Running

- `start.sh` - starts Face Matcher, then the corridor services
- `stop.sh` - stops everything, keeps data
- `factory-reset.sh` - stops everything and deletes containers, images and volumes

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

Without the gateway, ports are published on all interfaces with default credentials. Do not expose the host to an untrusted network.

## Configuration

- `.env` - corridor image versions, dashboard port, gateway switch (`CORRIDOR_GATEWAY_ENABLED`, `CORRIDOR_HOST`)
- `.env.hub` - Hub settings, documented inline: denied watchlists, dead-letter expiry, database, corridor units and cameras, storage, zone notifications
- `face-matcher/` - a copy of the [Face Matcher](face-matcher/README.md) repository. Do not edit it, except `face-matcher/.env.face-matcher-ui`, which carries the Smart Corridor watchlist member labels (`WATCHLIST_MEMBER_KEY_n` / `WATCHLIST_MEMBER_LABEL_n`).

**Clearance.** Every watchlist match is GREEN unless its watchlist is listed in `VPP_ADAPTER_DENIED_WATCHLISTS` (ids or globs such as `red.*`); then it is RED. `*` makes every match RED.

**Zone notifications.** The Hub can emit `zone.*` events (entered, left, occupancy, counts) on the `corridorEvents` subscription. See the commented example in `.env.hub`.

**Remote TIS (optional).** `dxm/` adds DSS, which syncs travelers of upcoming journeys from a Traveler Identity Service into Face Matcher watchlists, and CEA, which reports corridor visits back to TIS as Encounters. See [dxm/README.md](dxm/README.md).

**Document scans** in the display's person detail and History need `HUB_DOCUMENT_IMAGES` and the DSS's `DSS_DOCUMENT_IMAGES`, and are allowed on isolated nodes only. Both are off here; the display works without them.

# The gateway

With `CORRIDOR_GATEWAY_ENABLED=true` in `.env`, `start.sh` puts Envoy and the corridor's own Keycloak in front of all services. Every published port is then HTTPS: people sign in on Keycloak, systems send a bearer token, the gateway checks the role. Services behind it run unchanged on `face-matcher-network`.

| Port | Service                  | Role                                                            |
| ---- | ------------------------ | --------------------------------------------------------------- |
| 8095 | Corridor dashboard       | `corridor-operator`                                             |
| 8000 | Face Matcher UI          | `face-matcher-admin`                                            |
| 8090 | Hub API                  | `corridor-integrator`; `/corridor-hub/admin/`: `corridor-admin` |
| 8098 | Face Matcher REST API    | `corridor-integrator` or `corridor-admin`                       |
| 8097 | Face Matcher GraphQL API | `corridor-integrator` or `corridor-admin`                       |
| 8443 | Keycloak                 | login pages and tokens                                          |
| 8883 | MQTT over TLS            | the broker's own credentials                                    |

PostgreSQL, pgAdmin, RabbitMQ and S3 are published on loopback only; nothing else is published.

To turn it on:

1. In `.env`, set `CORRIDOR_GATEWAY_ENABLED=true` and `CORRIDOR_HOST` to the name (or IPv4) clients use for this host. Logins work under that name only.
2. Put the certificate (with chain) into `secrets/tls/server.crt` and its key into `secrets/tls/server.key`. Without them `start.sh` generates a self-signed one (evaluation only).
3. Run `start.sh`. The first start writes secrets into `secrets/gateway/` and imports the `corridor` realm into Keycloak.
4. Create accounts:

   ```
   gateway/users.sh add-user display-gate-1 corridor-operator
   gateway/users.sh add-user jane.doe face-matcher-admin corridor-admin
   gateway/users.sh add-integrator border-system
   gateway/users.sh list
   gateway/users.sh revoke <name>
   ```

   `add-user` prints a one-time password. `add-integrator` prints a client secret; the system gets a token (5 min lifetime) from `https://<CORRIDOR_HOST>:8443/realms/corridor/protocol/openid-connect/token` with `grant_type=client_credentials`.

Notes:

- Sessions end after 30 min idle / 10 h max; wall displays (port 8095) after 30 days idle. Lifetimes are in `gateway/realm/corridor-realm.json`, imported at the first start only. Sign out at `https://<CORRIDOR_HOST>:<port>/oauth2/signout`.
- Changing `CORRIDOR_HOST` later requires `factory-reset.sh` or fixing the redirect URIs of the `corridor-gateway` and `corridor-display` clients in Keycloak.
- `factory-reset.sh` deletes Keycloak's accounts; `secrets/` is kept.
- Not protected: traffic inside `face-matcher-network`, the default credentials of the dependencies (change them), MQTT clients (authenticated by the broker).

## Production use

This deployment demonstrates how to wire everything up and is not fit for production as shipped. Turn the gateway on with the site's own certificate and change the default credentials of the dependencies.
