# ![ainvironment](public/logo.svg)

Containerized cloud dev environment — successor to `scripts/nanocode.sh`
(the old host-install script, kept here as a porting reference).

The host stays **thin**: NVMe layout, NVIDIA driver, Docker + NVIDIA Container
Toolkit, cloudflared. Everything else — node, gcloud/aws CLIs, code-server,
**opencode v2**, **openchamber** — runs in one image started by docker compose.
cloudflared maps subdomains onto the loopback ports this stack publishes.

**No gemini anywhere.**

## Architecture

```
 browser ──► cloudflare edge (subdomains)
                   │
                   ▼
        cloudflared (host — /etc/cloudflared/config.yml)
                   │
        ┌──────────┴────────────────────────────────────┐
        │ 127.0.0.1:8080  ──► code-server               │
        │ 127.0.0.1:4096  ──► opencode serve (v2 UI/API)│
        │ 127.0.0.1:3000  ──► openchamber ──► opencode  │
        └───────────────────────────────────────────────┘
```

## Repo layout

```
.
├── setup.sh                      # master host bootstrap (MOCKUP)
├── Dockerfile                    # the one shared dev image
├── docker-compose.yml            # services, network, volumes, ports
├── .env.example                  # cp to .env — tunables + secrets
├── .editorconfig                 # max_line_length = 90
├── README.md
├── config/
│   └── cloudflared/config.yml    # subdomain -> loopback port ingress
└── scripts/
    └── nanocode.sh               # old host script (verbatim reference)
```

## Services

One image (`Dockerfile`), three services — only `command`, port and env differ.

| service | command | container | host (loopback) |
|---------|---------|-----------|-----------------|
| `code-server` | `code-server --auth password` | `:8080` | `127.0.0.1:8080` |
| `opencode` | `opencode serve` (v2 API + web UI) | `:4096` | `127.0.0.1:4096` |
| `openchamber` | `openchamber serve --foreground` | `:3000` | `127.0.0.1:3000` |

Notes:

- `opencode serve` starts the v2 API **and** web server on one port (v2.0.x).
  The web UI connects to that same server — no separate UI process.
- `openchamber` points at the shared opencode server via
  `OPENCODE_HOST=http://opencode:4096` + `OPENCODE_SKIP_START=true`, so both
  web UIs see the same sessions/auth. Remove those two env vars and
  openchamber instead spawns its own private opencode inside its container.
- Ports bind to `127.0.0.1` only — nothing is exposed directly; cloudflared
  reaches them from the host network.

## cloudflared ingress

`config/cloudflared/config.yml` is the source of truth for the mapping:

| subdomain (example) | ingress service | compose service |
|---------------------|-----------------|-----------------|
| `code.example.com` | `http://localhost:8080` | `code-server` |
| `opencode.example.com` | `http://localhost:4096` | `opencode` |
| `chamber.example.com` | `http://localhost:3000` | `openchamber` |

The file is a draft: swap the placeholder hostnames, then either use it as-is
for a locally-managed tunnel (`cloudflared tunnel create`, put the tunnel id +
credentials path in the file), or keep a token-based tunnel and mirror the
same three ingress rows in the Cloudflare dashboard.

## Volumes

Bind mounts (from the host):

| host | in-container | purpose |
|------|--------------|---------|
| `/nvme0n1-disk/workspaces` | `/home/dev/workspaces` | code |
| `/var/run/docker.sock` | same | DooD socket |
| `${DOCKER_BIN}` | `/usr/bin/docker` | DooD CLI, version-matched |
| `${DOCKER_PLUGINS}` | `/usr/lib/docker/cli-plugins` | DooD compose plugin |
| `$HOME/.ssh` | `/home/dev/.ssh` | ssh keys |
| `$HOME/.aws` | `/home/dev/.aws` | aws credentials |
| `$HOME/.config/gcloud` | `/home/dev/.config/gcloud` | gcloud credentials |

Named volumes (persist tool state across rebuilds — they live under
`/var/lib/docker/volumes`, which `setup.sh` relocates to NVMe, so state ends
up on the big disk for free):

| volume | in-container |
|--------|--------------|
| `opencode-data` | `/home/dev/.local/share/opencode` (auth, db, sessions) |
| `opencode-config` | `/home/dev/.config/opencode` |
| `opencode-home` | `/home/dev/.opencode` (binary + plugins) |
| `openchamber-config` | `/home/dev/.config/openchamber` |
| `code-server-data` | `/home/dev/.local/share/code-server` |

DooD (docker-out-of-docker): the container gets the host socket **and** the
host CLI/compose-plugin binaries, so client version always matches the daemon
and no nested dockerd runs. `group_add` grants the `dev` user socket access
(host docker gid → `DOCKER_GID` in `.env`).

## Usage (draft)

```bash
# once, on the host:     sudo ./setup.sh     # mockup — see file header
cp .env.example .env                         # edit secrets/ports
docker compose up -d --build                 # everything
docker compose up -d code-server             # just one service
docker compose logs -f openchamber
```

## Secrets

- `.env` (gitignored): `CODE_SERVER_PASSWORD` or argon2
  `CODE_SERVER_HASHED_PASSWORD`, `OPENCHAMBER_UI_PASSWORD`.
- Fix over nanocode.sh: secrets are no longer passed as CLI flags (they leaked
  into shell history, the reboot-resume unit file, and `ps aux` — the current
  host tunnel token is visible in `ps` right now).

## Migration from nanocode.sh

| nanocode.sh (host install) | here |
|----------------------------|------|
| NVMe layout | `setup.sh` step 1 (kept) |
| NVIDIA driver + reboot-resume | `setup.sh` step 2 (resume TODO) |
| Docker + Container Toolkit | `setup.sh` steps 3-4 (kept) |
| code-server systemd unit | compose service `code-server` |
| Node 20 on host | image (Node 26, `ARG NODE_MAJOR`) |
| aws / gcloud CLIs on host | image |
| gemini-cli + bashrc hacks | **dropped — no gemini anywhere** |
| `grc` | dropped for now (re-add to image if needed) |
| cloudflared token service | `setup.sh` step 5 + `config/cloudflared/config.yml` |

## Conventions

Max line length **90** (see `.editorconfig`; `scripts/nanocode.sh` is a verbatim
copy and exempt). Check with:

```bash
git ls-files | xargs awk 'length > 90 {print FILENAME":"FNR" len="length}'
```

## Status / TODO

- [x] scaffold: Dockerfile, compose, cloudflared ingress config, `.env.example`
- [ ] implement `setup.sh` (currently a mockup)
- [ ] build & smoke-test the image inside the container
- [ ] verify openchamber ↔ opencode wiring over the compose network
- [ ] service selection via compose `profiles:` (e.g. `--profile ai`)
- [ ] optional GPU: `gpus: all` / a `compose.gpu.yml` override
- [ ] healthchecks for all three services
