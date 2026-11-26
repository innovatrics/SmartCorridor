# secrets/

Put `iengine.lic` here. It is git-ignored. The license must contain the `smart_corridor` block. `start.sh` links it into `facematcher/secrets/`.

With the gateway on, `start.sh` also writes, once, and keeps afterwards:

- `gateway/`: the gateway's client secrets, the secret that signs its session cookies, and Keycloak's database and administrator passwords. Readable by the user who runs `start.sh` only.
- `tls/server.crt` and `tls/server.key`: a self-signed certificate for `CORRIDOR_HOST`, unless you put the site's own certificate (chain included) and key there before. Both git-ignored.
