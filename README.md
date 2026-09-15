# Mogok Maung Backend

Production repository for Mogok Maung — Go REST API (PostgreSQL + Redis + RabbitMQ),
Flutter Web SPA (`mobile/build/web`), and the admin dashboard (`admin-web` submodule),
deployed behind nginx + Let's Encrypt.

- SPA: `https://oddsmyanmar.online`
- API / WSS: `https://api.oddsmyanmar.online`

---

## VS Code Remote-SSH Deployment Guide

Use VS Code Remote-SSH to connect to the VPS as a normal editor session and run
maintenance/deploy steps from the integrated terminal. Everything below is GUIdriven — you only paste one block into VS Code.

### 1. Required facts

| Item        | Value                    |
| ----------- | ------------------------ |
| VPS IP      | `104.207.77.242`         |
| SSH port    | `22022`                  |
| SSH user    | `root`                   |
| SSH key     | `~/.ssh/mogok_vps` (local WSL/Windows) |

### 2. Add the SSH host to `~/.ssh/config`

On your **local** machine (Windows: `C:\Users\KoMaw\.ssh\config`, WSL:
`~/.ssh/config`), append this block:

```ssh
Host mmvps
    HostName 104.207.77.242
    Port 22022
    User root
    IdentityFile ~/.ssh/mogok_vps
    IdentitiesOnly yes
    ServerAliveInterval 60
```

Verify from a terminal before VS Code:

```bash
ssh mmvps hostname && echo CONNECTED
```

### 3. Connect in VS Code

1. Install the **Remote - SSH** extension
   (`ms-vscode-remote.remote-ssh`).
2. `F1` → **Remote-SSH: Connect to Host…** → pick **mmvps**.
3. On first connect, choose Ubuntu as the platform.
4. Once connected, open the project folder via Explorer: open folder
   `/opt/mogok-maung` (top-level `C:\` drives are not the VPS — you are now on the
   VPS filesystem).

### 4. First-time deployment (once)

If `/opt/mogok-maung` is empty, in the integrated terminal on the VPS:

```bash
git clone --branch main https://github.com/mokotmaung-lang/mogok-maung-backend.git /opt/mogok-maung
cd /opt/mogok-maung && bash scripts/prod/deploy-vps.sh
```

`deploy-vps.sh` automates everything (idempotent, safe to re-run):

1. Installs Docker (with fallback) + enables ufw (`22022`, 22, 80, 443).
2. Clones/pulls `main` into `/opt/mogok-maung`.
3. Creates `.env.production` from `.env.example` (domain-substituted) — real
   secrets are auto-generated with `openssl rand`, never stored in git.
4. Delegates to `go-live.sh`:
   - postgres TLS certs (`setup-db-tls.sh`)
   - Let's Encrypt for `oddsmyanmar.online` + `api.oddsmyanmar.online`
     (`setup-ssl.sh` — snap certbot, webroot, renewal timer, nginx vhosts)
   - docker compose up + migrations + SUPER_ADMIN bootstrap + smoke tests
     (`deploy.sh`, incl. port-80/443 preflight and `nginx -t`)
   - public verification: `/health`, SPA, admin-gate 403, SSL expiry
5. Aborts early if critical inputs are missing (placeholder GIT_URL, missing
   `DOMAIN_NAME`, non-resolving DNS records).

Result check:

```bash
curl -fsS https://api.oddsmyanmar.online/health   # → ok
```

### 5. Day-to-day (subsequent updates)

```bash
cd /opt/mogok-maung
git pull origin main
bash scripts/prod/deploy.sh          # rebuild + restart + migrate only
```

### 6. Before the first deploy (DNS prerequisites)

- `api.oddsmyanmar.online` **A → 104.207.77.242** (does NOT exist yet — you must
  add it at the DNS provider).
- `oddsmyanmar.online` **A → 104.207.77.242** — remove the stale `52.24.84.18` /
  `54.149.218.69` records first.
- Confirm the VPS answers on `104.207.77.242:22022` (and later 80/443) before
  running `deploy-vps.sh`, otherwise certbot will fail.

---

## Scripts (all in `scripts/prod/`)

| Script              | Purpose                                                        |
| ------------------- | -------------------------------------------------------------- |
| `deploy-vps.sh`     | one-shot fresh-VPS provisioning (clone → env → go-live)        |
| `go-live.sh`        | 7-step rollout (docker, secrets, DNS, TLS, SSL, deploy, verify)|
| `deploy.sh`         | compose up, migrations, SUPER_ADMIN, smoke, nginx reload       |
| `setup-ssl.sh`      | nginx install/configure + certbot (snap) + renewal timer       |
| `setup-db-tls.sh`   | postgres TLS (ssl=on)                                          |
| `bootstrap-admin.sh`| idempotent SUPER_ADMIN creation                                |
| `smoke-test.sh`     | API health checks (auth, wallets, fixtures)                    |
| `rsync-deploy.sh`   | rsync-based alternative to git clone                           |
| `build-flutter.sh`  | web/AAB builds with `--dart-define`                            |

Environment contract: `.env.production.example` (committed; `CHANGE_ME_*` values
are replaced with strong generated secrets by `go-live.sh` on the server). For
local development with `docker-compose.yml`, copy `.env.example` → `.env`.