#!/usr/bin/env bash
set -euo pipefail

# Two sample displays through the configuration API (README.md, "Displays"): "exit" (GREEN, BLUE, RED) and
# "entrance" (OCCLUDED), both paired with the given cameras. Replaces those two displays; the rest stays.
# Usage: feedback-display/sample-displays.sh <camera-id> [<camera-id>...]   (ids: curl -s http://localhost:8098/api/v1/Cameras)
[ $# -ge 1 ] || { echo "usage: $0 <camera-id> [<camera-id>...]" >&2; exit 2; }
cd "$(dirname "$0")"
setting() { grep -E "^$1=" ./.env | head -n1 | cut -d '=' -f2- | sed -E -e 's/\r$//' -e 's/[[:space:]]+#.*$//' -e 's/[[:space:]]+$//'; }
B="http://127.0.0.1:$(setting FEEDBACK_DISPLAY_PORT)/corridor-feedback-display/api/v1/config"
CAMS="$(printf '"%s",' "$@")"; CAMS="[${CAMS%,}]"

put() { # <display> <json>; every write bumps the revision, so each one reads the current ETag first
  local etag
  etag="$(curl -sfi "$B" | grep -i '^etag' | cut -d' ' -f2 | tr -d '\r')"
  curl -sf -o /dev/null -w "$1: %{http_code}\n" -X PUT "$B/displays/$1" -H "If-Match: $etag" \
    -H 'Content-Type: application/json' -d "$2"
}
put exit "{\"name\":\"Exit\",\"cameraIds\":$CAMS,\"overrides\":{\"reactsTo\":[\"GREEN\",\"BLUE\",\"RED\"],\"screen.green.text\":\"Please continue\",\"screen.red.text\":\"Please go to the counter\",\"screen.blue.text\":\"Please go to the counter\"}}"
put entrance "{\"name\":\"Entrance\",\"cameraIds\":$CAMS,\"overrides\":{\"reactsTo\":[\"OCCLUDED\"],\"screen.occluded.text\":\"Please take off your sunglasses\"}}"
echo "Open http://localhost:$(setting FEEDBACK_DISPLAY_PORT)/corridor-feedback-display/display/exit (or /display/entrance) full-screen."
