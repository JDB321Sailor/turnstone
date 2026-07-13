# Traefik Deployment Guide

## Overview

This deployment option places Traefik in front of the Turnstone stack and uses a Docker socket proxy so Traefik can discover containers without mounting the Docker socket directly into the reverse proxy. The generated root-level `override.compose.yaml` adds Traefik, routes the Turnstone console UI and dashboard over HTTPS, and exposes the Traefik dashboard on a separate hostname behind authentication.

## Prerequisites

- A Linux host with Docker Engine and the Docker Compose v2 plugin available
- DNS records created for both public hostnames:
  - `turnstone.example.com` for the Turnstone UI and dashboard
  - `traefik.example.com` for the Traefik dashboard
- Ports `80` and `443` reachable from the internet
- A Cloudflare DNS API token with permission to complete DNS-01 challenges
- The repository cloned into a stable home-directory path, for example:

```bash
git clone https://github.com/turnstonelabs/turnstone.git ~/turnstone
cd ~/turnstone
```

## SSO prerequisites

If OIDC SSO will be enabled, finish the identity-provider setup before running `setup-traefik.sh`.

1. Create a confidential OIDC application in the identity provider.
2. Add this redirect URI:
   `https://<turnstone-host>/v1/api/auth/oidc/callback`
3. Record the issuer URL, client ID, and client secret.
4. Decide which claim contains group or role memberships.
5. Decide which group should map to the Turnstone admin role.
6. If the identity provider publishes discovery or token endpoints on additional hosts, record those trusted endpoint hostnames.
7. If the identity provider is internal-only, decide whether `TURNSTONE_OIDC_ALLOW_PRIVATE_NETWORK=true` is required.

For Authentik, create the application and provider first, note the issuer URL in the form `https://authentik.example.com/application/o/<app-slug>/`, and confirm which group claim will contain the admin group. See the Authentik project at <https://github.com/goauthentik/authentik>.

For the full Turnstone OIDC variable reference, see [docs/oidc.md](../docs/oidc.md).

## Run the setup script

From the repository root:

```bash
cd traefik
./setup-traefik.sh
```

The script will:

- verify the local prerequisites needed to run the stack
- prepare or update the root `.env`
- build the local Turnstone image unless a skip-build override is supplied for automation
- ask for the public hostnames, ACME registration email, and Cloudflare token
- optionally collect every Turnstone OIDC setting
- generate the Traefik production files under `traefik/`
- write the generated root-level `override.compose.yaml`
- preserve the separate `compose.override.yaml` node-count override mechanism used by `run.sh`

Have the following ready before running it:

- the Turnstone hostname
- the Traefik dashboard hostname
- the ACME registration email address
- the Cloudflare DNS API token
- OIDC issuer, client credentials, claim names, role mapping values, and redirect base details if SSO will be enabled

When the script finishes, return to the repository root and start the stack:

```bash
cd ..
docker compose up -d
```

## Post-deploy

1. Open `https://<turnstone-host>`.
2. If local login is enabled, create the first admin account there. If SSO-only mode is enabled, sign in with the configured identity provider.
3. Open the **Models** tab and connect at least one LLM backend.

### Connect ds4

[ds4](https://github.com/JDB321Sailor/ds4) exposes an OpenAI-compatible API. In the Models tab, create an OpenAI-compatible backend and point it at a reachable ds4 endpoint such as:

- `http://host.docker.internal:8000/v1`
- `http://192.0.2.10:8000/v1`

Use the placeholder host and port values that match the ds4 deployment.

### Connect llama.cpp

If llama.cpp is running with an OpenAI-compatible server, add it the same way and use a reachable endpoint such as:

- `http://host.docker.internal:8080/v1`
- `http://192.0.2.20:8080/v1`

Use the placeholder host and port values that match the llama.cpp server.

## Notes

- The generated root `.env`, `override.compose.yaml`, Traefik env files, ACME storage, and OIDC env files are ignored by Git.
- The generated Traefik deployment disables the default Caddy frontend unless the optional `local-caddy` profile is requested explicitly.
- Re-run `./setup-traefik.sh` whenever hostnames, DNS credentials, or OIDC settings need to change.
