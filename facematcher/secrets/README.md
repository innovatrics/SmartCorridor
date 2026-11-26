# secrets/

Put `iengine.lic` here. It is git-ignored. `run.sh` links it into the repository root, where the services mount it.

Only at a site that turns the login of FaceMatcher UI on (see "Turning the login on" in the [README](../README.md)), also git-ignored:

- `face-matcher-ui.env` - one line, `KEYCLOAK_CLIENT_SECRET=<the client's secret>`
- `tls/server.key`, `tls/server.crt` - the key and the certificate of the UI's HTTPS, readable by uid 1000
