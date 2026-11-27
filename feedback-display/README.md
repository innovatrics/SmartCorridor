# Feedback Display (optional)

The traveller-facing screen of the corridor ([SASCE-115](https://innovatrics.atlassian.net/browse/SASCE-115),
[service](https://gitlab.ba.innovatrics.net/border-control/smart-corridors/corridor-feedback-display)). It shows the
Hub's outcome for its own cameras full-screen, as a colour with a text:
- **GREEN**: "Please continue";
- **RED** and **BLUE**: "Please go to the counter". BLUE is a traveller the corridor did not identify. The two share a screen by default, so a traveller learns nothing about watchlists.
- **OCCLUDED**: "Please take off your sunglasses";
- **UNAVAILABLE** ("Out of service"): the Hub is lost.

It only reads: the Hub's events and, when a display shows the matched person, the enrolment picture from FaceMatcher.
It writes nothing to the Hub, FaceMatcher or TIS, and the corridor runs the same whether it is up or not. It needs
Hub 0.12.0 or later (BLUE).

## Start

With the corridor up (`start.sh`):

```bash
feedback-display/setup.sh                                    # once, and again after factory-reset.sh
docker compose -f feedback-display/docker-compose.yml --env-file feedback-display/.env up -d
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8087/corridor-feedback-display/actuator/health/readiness   # 200
```

`setup.sh` makes the service's database login, keeps it in `FEEDBACK_DISPLAY_SECRETS_DIR`
(`~/.config/smart-corridor/feedback-display`, outside the repository), and creates the database
`corridorfeedbackdisplay` on the corridor's PostgreSQL. The service creates its schema itself. If the database already exists from a
manual setup with another login (an earlier install note), drop it first; `setup.sh` creates it for its own login. The image is amd64 only;
on Apple Silicon it runs through Rosetta, as DSS and CEA do. It takes about 0.5–1 GB of memory: give Docker Desktop
some room if the whole corridor already runs on this machine.

## Displays

A display is one screen, with its own id, the cameras it reacts to and what it shows. They live in the database and
survive restarts. Two samples, an exit and an entrance, paired with the given cameras:

```bash
curl -s http://localhost:8098/api/v1/Cameras            # the camera ids (field "id")
feedback-display/sample-displays.sh <camera-id> [<camera-id>...]
```

Open `http://localhost:8087/corridor-feedback-display/display/exit` (or `/display/entrance`) in a browser and switch it
to full screen. Every text, colour and image is configuration:
- for the whole corridor: `PUT /corridor-feedback-display/api/v1/config/corridor`;
- per display: `PUT /corridor-feedback-display/api/v1/config/displays/<id>`.

Every write needs the current ETag in `If-Match`; `sample-displays.sh` shows how. Changes apply live. The full key
list is in the service's `docs/plan/data-model.md`.

- **Person on GREEN.** The matched member's name, enrolment picture and captured face are off by default. To show them,
  add `"greenShowName":true,"greenShowEnrolmentPicture":true,"greenShowCapturedPicture":true` to a display's
  `overrides`. Anyone in front of the screen then sees them.
- **OCCLUDED** reacts to the Hub's `zone.face_occluded` (tinted glasses or a mask by default, `.env.hub`). Only the
  entrance sample reacts to it.
- **No login yet.** The configuration API is open to whoever reaches the port. `FEEDBACK_DISPLAY_BIND=127.0.0.1` in
  `feedback-display/.env` keeps it on this machine. Set `0.0.0.0` only on a network you trust.

## Stop and reset

- `docker compose -p smart-corridor-feedback-display down`: stops it. The displays stay in the database.
- `stop.sh` stops it with the rest.
- `factory-reset.sh` deletes it with the rest, its database included. Afterwards, run `setup.sh`, start it again and
  set the displays again.
- With the Hub stopped, it shows "Out of service" after 10 s, then reconnects by itself once the Hub is back.
