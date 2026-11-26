# DSS and CEA: the corridor with a remote TIS

Optional. Connects the corridor to a Traveler Identity Service (TIS) that runs elsewhere:

```
TIS ──travelers, portraits──▶ DSS ──watchlist members──▶ FaceMatcher
 ▲                                                                      │ cameras
 └── Encounter (one per corridor visit) ◀── CEA ◀── cea.export ◀── Hub ◀── CIGS
```

- **DSS** (corridor-data-synchronization-service) puts every ENROLLED traveler with a portrait in TIS into one FaceMatcher watchlist (route r1, `SOURCE_MODE=travelers`): no journey needed. The members mirror TIS: a traveler TIS no longer lists as ENROLLED leaves the watchlist. A route over journeys (the travelers of flights arriving in the next 24 h, a watchlist per flight) is the commented alternative in `dxm/dss.env`.
- **CEA** (corridor-event-aggregation-service) collects the Hub's identifications of those travelers into visits and delivers each visit to TIS as an Encounter within seconds of its first match. Matches less than `CEA_PASSAGE_QUIET` apart extend the visit; a match after a longer pause opens a new visit and a new Encounter. Travelers TIS merged or rejected are parked.

| Service | Version | Port (loopback) |
|---|---|---|
| DSS | 0.4.0 | 8660 |
| CEA | 0.3.1 | 8670 |
| TIS | 0.34.0 or later (the content endpoint the DSS reads portraits through) | remote |

DSS and CEA are amd64-only. On Apple Silicon turn on Docker Desktop → "Use Rosetta for x86/amd64 emulation".

## What you need

- The corridor running (`start.sh`), with the Hub at 0.12.0 or later.
- TIS reachable from this host, its token endpoint included, without an interactive login in front of it (TIS checks its own OAuth tokens).
- Two TIS clients with the client-credentials grant: one for the DSS, one for CEA.
- TIS 0.34.0 or later. The DSS reads portraits through TIS's API (`TIS_OBJECT_DOWNLOAD=content` in `dxm/dss.env`, `GET /api/v1/stored-objects/{id}/content`) with its own token, so TIS's object store need not be reachable from here. Against an older TIS, which has no such endpoint, the DSS stops every run and syncs no one.
- Test data only: the DSS copies every synced traveler's portrait and name into this FaceMatcher.

## Configuration

`dxm/.env`, no secrets:

- `TIS_BASE_URL`, `TIS_TOKEN_URL`: TIS with its context path, e.g. `https://tis.example/traveler-identity-service` and `…/traveler-identity-service/oauth2/token`. A TIS on this host: `http://host.docker.internal:<port>/…`.
- `DSS_TIS_CLIENT_ID`, `CEA_TIS_CLIENT_ID`: the two clients.
- `DSS_DEPLOYMENT_ID`: this corridor's name, unique on that TIS (`[a-z0-9][a-z0-9-]{0,31}`). It labels the members this DSS owns and is the Encounters' location.
- `DSS_WATCHLIST_ID`: the watchlist route r1 fills. Create it once with the corridor running, in FaceMatcher UI or through VPP's API, and copy its id:

  ```
  curl -s -X POST http://127.0.0.1:8098/api/v1/Watchlists -H 'Content-Type: application/json' \
    -d '{"displayName":"Travelers","fullName":"Travelers"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
  ```

  `factory-reset.sh` deletes it with FaceMatcher's volumes: create it again and update the id.

`dxm/dss.env` (route r1: every ENROLLED traveler, into `DSS_WATCHLIST_ID`) and `dxm/cea.env` carry the services' settings. An unknown `CEA_*` name stops CEA at startup.

In `.env.hub`, turn on the export and restart the corridor (`start.sh`):

```
CEA_EXPORT_ENABLED=true
CEA_EXPORT_EXCHANGE=cea.export
```

**Document scans** (passport pages in the display) are off; to switch them on, see [Document scans](#document-scans-passport-pages-in-the-operational-display).

## Secrets

Outside any repository, in `DXM_SECRETS_DIR` (default `~/.config/smart-corridor/dxm`, mode 700), each file mode 600, plain `KEY=value`, no quotes, no `$` in the value:

- `tis-dss.env`: `TIS_CLIENT_SECRET=<secret>`
- `tis-cea.env`: `CEA_TIS_CLIENT_SECRET=<secret>`
- `cea-local.env`: CEA's database and broker passwords and admin token. `dxm/setup.sh` writes it once.
- `documents-s3.json`, `documents-admin.env`, `documents-dss.env`, `documents-hub.env`: the document store's identities, only with [document scans](#document-scans-passport-pages-in-the-operational-display) on. `dxm/setup-documents.sh` writes them once and keeps them.

## Running

```
dxm/setup.sh                                                            # once, and after factory-reset.sh
docker compose -f dxm/docker-compose.yml --env-file dxm/.env up -d
```

`setup.sh` creates CEA's database and role on the corridor's PostgreSQL, and the `cea.export` exchange, `cea.identification.q` queue (with dead-lettering) and the `cea` user on its RabbitMQ.

Ready when both answer 200:

- `curl http://127.0.0.1:8660/corridor-data-synchronization-service/actuator/health/readiness`
- `curl http://127.0.0.1:8670/corridor-event-aggregation-service/ready`

`stop.sh` and `factory-reset.sh` stop DSS and CEA too. `factory-reset.sh` deletes CEA's database and the DSS's members with FaceMatcher's volumes; run `setup.sh` again afterwards (it keeps `cea-local.env`).

## Checking

- **TIS → corridor.** `curl -s http://127.0.0.1:8660/corridor-data-synchronization-service/status`: route r1's `lastSync.outcome` is `succeeded`, `tisReachable` and `vppReachable` are true, and FaceMatcher UI shows the members in the watchlist `DSS_WATCHLIST_ID`, one per ENROLLED traveler with a portrait.
- **Corridor → TIS.** A synced traveler passes a camera: the display shows the identification, `curl -s http://127.0.0.1:8090/corridor-hub/actuator/prometheus | grep hub_cea_export_total` counts published and acked, `curl -s http://127.0.0.1:8670/corridor-event-aggregation-service/status` shows a visit, and within seconds TIS has an Encounter at location `DSS_DEPLOYMENT_ID`.
- **Typical failures.** `tisAuthRejected`: wrong or missing client secret. `tisReachable=false`: URL or network. Route r1's `lastSync.outcome` `failed` with `TIS_OBJECT_DOWNLOAD=content needs a TIS with the stored-object content endpoint`: TIS is older than 0.34.0. `degraded` with `stored object content failed` in `docker logs sceg-dss`: that traveler's portrait is missing in TIS. `destinationMissing`: the watchlist `DSS_WATCHLIST_ID` does not exist (after `factory-reset.sh`). `sizeBound`: TIS lists more ENROLLED travelers than `ROUTE_1_SIZE_BOUND`; nothing is written until it is raised. `removalGuard` on route r1's `lastDeletion`: more than half of the members would leave at once, e.g. after TIS was reset; nothing is removed. If they really left, add `ROUTE_1_ALLOW_FULL_PURGE=true` to `dxm/dss.env`, restart the DSS, wait for one deletion run (`degraded`, every removal still confirmed by TIS), then remove the line and restart again.

## Document scans (passport pages) in the Operational Display

Off by default. Switch them on only where the deployment's owner has accepted copies of travel documents on this machine. For an Innovatrics deployment that is SASCE-ADR-0006, whose risk owner signs off before the switch goes on.

With them on, the DSS copies each synced traveler's passport scans from TIS (through TIS's API, like the portraits) into a store of its own, and the Hub serves them to the display's person detail and History:

- the data page: per side, TIS's `IDENTITY_DOCUMENT_SCAN` of that side, else the passport's white-light image of that side (labels `docFrontUrl`, `docBackUrl`);
- the portrait crop of the passport, where TIS has one (`docPortraitUrl`).

The chip photo is never copied. The members' labels hold only the copies' keys. The Hub serves a key of this deployment to whoever reaches it (port 8090 or the display), so beyond a demo turn on [the gateway](../README.md#the-gateway).

**The store.** `sceg-documents`, SeaweedFS 4.23 in the dxm project, started with it by `COMPOSE_PROFILES=documents`, with the volume `smart-corridor-dxm_documents-data`. It is kept apart from FaceMatcher's SeaweedFS: the copies expire by a rule of their own and go with a volume of their own, they never mix with FaceMatcher's data, and 4.23 is the version the DSS's expiry and identity checks were verified on. It publishes no port.

**Switching them on**, with the corridor running and `dxm/.env` filled in:

1. `dxm/setup-documents.sh`: writes the store's identities into `DXM_SECRETS_DIR` (see [Secrets](#secrets)), starts the store, creates the bucket `corridor-documents` and publishes the expiry rule `DOCUMENT_IMAGES_EXPIRY_DAYS` (30 days) on `documents/<DSS_DEPLOYMENT_ID>/`. The DSS can only read objects in its prefix, the rule and the versioning; the Hub can only read this deployment's copies. Run it again after changing `DSS_DEPLOYMENT_ID` or `DOCUMENT_IMAGES_EXPIRY_DAYS`, and after `factory-reset.sh`; it keeps the keys.
2. In `dxm/.env`:

   ```
   DOCUMENT_IMAGES=true
   DOCUMENT_IMAGES_STORAGE_ENDPOINT=http://sceg-documents:8333
   DOCUMENT_IMAGES_STORAGE_BUCKET=corridor-documents
   COMPOSE_PROFILES=documents
   ```

3. In `.env.hub`: `HUB_DOCUMENT_IMAGES_ENABLED=true`.
4. `start.sh`, then `docker compose -f dxm/docker-compose.yml --env-file dxm/.env up -d`.

The DSS's next sync copies the scans after it has written the members. `/status` shows `storageReachable` true, and `docker logs sceg-dss` shows a `dss.images` line for each run that copied (`documentImagesCopied`). A person's detail in History shows the data page and the portrait crop.

**How long a copy lives.** A copy is deleted with its member, by the DSS's deletion run, and in any case `DOCUMENT_IMAGES_EXPIRY_DAYS` after it was made. A member that stays longer gets its copies again with the next sync after they expired.

**Switching them off.** Set `DOCUMENT_IMAGES=false` and `HUB_DOCUMENT_IMAGES_ENABLED=false`, then run `start.sh` and `up -d` again. The members lose their scan labels on the DSS's next write. While the endpoint and the bucket stay set and the store runs, the DSS still deletes the copies with their members; the rest expire.

**Deleting every copy.** `docker compose -p smart-corridor-dxm down` and `docker volume rm smart-corridor-dxm_documents-data`, or `factory-reset.sh`, which deletes the volume too. The identities stay in `DXM_SECRETS_DIR` until you delete the `documents-*` files.
