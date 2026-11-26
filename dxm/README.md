# DSS and CEA: the corridor with a remote TIS

Optional. Connects the corridor to a Traveler Identity Service (TIS) that runs elsewhere:

```
TIS ──travelers, journeys, portraits──▶ DSS ──watchlists, members──▶ FaceMatcher
 ▲                                                                      │ cameras
 └── Encounter (one per corridor visit) ◀── CEA ◀── cea.export ◀── Hub ◀── CIGS
```

- **DSS** (corridor-data-synchronization-service) puts the travelers of upcoming journeys into FaceMatcher watchlists `dxm.r1.flight.<flight>.<yyyyMMddHHmm>`. Only ENROLLED travelers with a portrait are synced.
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

`dxm/dss.env` (route r1: journeys arriving in the next 24 h) and `dxm/cea.env` carry the services' settings. An unknown `CEA_*` name stops CEA at startup.

In `.env.hub`, turn on the export and restart the corridor (`start.sh`):

```
CEA_EXPORT_ENABLED=true
CEA_EXPORT_EXCHANGE=cea.export
```

**Document scans** (`DSS_DOCUMENT_IMAGES`, `HUB_DOCUMENT_IMAGES`) stay off: copies of travel documents are allowed on isolated nodes only.

## Secrets

Outside any repository, in `DXM_SECRETS_DIR` (default `~/.config/smart-corridor/dxm`, mode 700), each file mode 600, plain `KEY=value`, no quotes, no `$` in the value:

- `tis-dss.env`: `TIS_CLIENT_SECRET=<secret>`
- `tis-cea.env`: `CEA_TIS_CLIENT_SECRET=<secret>`
- `cea-local.env`: CEA's database and broker passwords and admin token. `dxm/setup.sh` writes it once.

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

- **TIS → corridor.** `curl -s http://127.0.0.1:8660/corridor-data-synchronization-service/status`: route r1's `lastSync.outcome` is `succeeded`, `tisReachable` and `vppReachable` are true, and FaceMatcher UI shows the `dxm.r1.flight.…` watchlists.
- **Corridor → TIS.** A synced traveler passes a camera: the display shows the identification, `curl -s http://127.0.0.1:8090/corridor-hub/actuator/prometheus | grep hub_cea_export_total` counts published and acked, `curl -s http://127.0.0.1:8670/corridor-event-aggregation-service/status` shows a visit, and within seconds TIS has an Encounter at location `DSS_DEPLOYMENT_ID`.
- **Typical failures.** `tisAuthRejected`: wrong or missing client secret. `tisReachable=false`: URL or network. Route r1's `lastSync.outcome` `failed` with `TIS_OBJECT_DOWNLOAD=content needs a TIS with the stored-object content endpoint`: TIS is older than 0.34.0. `degraded` with `stored object content failed` in `docker logs sceg-dss`: that traveler's portrait is missing in TIS.
