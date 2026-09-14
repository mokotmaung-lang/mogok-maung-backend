# System Context — Mogok Maung Myanmar Football Betting System

> Feed this file to any AI coder as context for every prompt on this repository.
> It encodes the architectural truth AND the non-negotiable financial rules.
> Keep this file truthful — when something changes, update it in the same PR.

## 1. What this system is

A Myanmar traditional football betting platform ("Body/Maung" — ဘော်ဒီ / မောင်း) with
a hierarchical wallet model: **Admin → Agent → End User**. Every unit of value flows
through an immutable **double-entry ledger** (`unit_ledger`); balances are never
mutated without an audit row.

### Reference architecture (spec) vs this repo

| Spec path (imagined)                    | Actual path in THIS repo            |
|------------------------------------------|-------------------------------------|
| `apps/admin-dashboard/` + `apps/agent-dashboard/` | `web/` (Next.js 14 + Tailwind, role-gated) |
| `apps/user-mobile-app/`                  | `mobile/` (Flutter; Dart sources only — no android/ios scaffold yet) |
| `services/user-service/`                 | root Go module `cmd/api/` + `pkg/`  |
| `services/workers/bet-settlement-worker/`| `cmd/worker/` (RabbitMQ consumer)   |
| —                                        | `cmd/webhook/` (Viber/Telegram bot webhook worker, :8090) |
| `database/migrations/`                   | `migrations/` (numbered `0000NN_*.up.sql`, auto-applied at boot) |
| `database/seeders/`                      | `database/seeders/` (manual bootstrap, see 001_bootstrap_admin.sql) |
| infra (not in original spec)             | `infrastructure/terraform|nginx`, `scripts/dr`, `loadtest/` |
| legacy from earliest spec                | `prisma/schema.prisma` (stale, unmaintained), `deploy/cloudflare` |

**Do NOT reorganize the root** to match the spec tree; the compose notes this already.
Root IS the Go module (`go.mod`, `pkg/`, `cmd/`). Migrations live at `migrations/`.

## 2. Core Rules (non-negotiable)

### Core Rule 1 — Hold Balance (Pessimistic Locking)
Every bet placement MUST:
- `SELECT ... FOR UPDATE` the affected wallet row(s) **inside the transaction** before any balance read.
- Compute **Maximum Potential Loss** from Myanmar odds (e.g. BODY odds `1-50` → **1.5× stake**; `NO_LOSS`/`0` → 1.0×; `2-00` → 2.0×; MAUNG → always 1.0× stake) and move exactly that amount: `current_balance -= holdAmount`, `hold_balance += holdAmount`.
- Return HTTP 400 when `current_balance < holdAmount` (`ErrInsufficientBalance`).
- Verify every match is `OPEN` (`FOR SHARE`) inside the same transaction.
- Multi-row wallets: **acquire locks in ascending user_id order** (see `pkg/wallet/wallet.go`) — this is a deadlock guardrail, not a nicety.

### Core Rule 2 — Double-Entry Ledger
- **Never** `UPDATE users SET current_balance = ...` without inserting a `unit_ledger` row (with `balance_before`, `balance_after`, and a `type` from the ENUM).
- Ledger `type` ENUM lives in Go as `TrxType`: `DEPOSIT, WITHDRAW, BET_HOLD, BET_WIN, BET_LOSE, BET_REFUND`.
- The ledger is append-only and the source of truth; balance = `SUM(amount_change)` per user.

### Core Rule 3 — Myanmar Maung Multiplier Formula
Settled per selection, then multiplied parlay-style across the ticket:
- `WIN` → multiplier = match multiplier
- `HALF_WIN` → `1 + (matchMultiplier - 1) / 2`
- `HALF_LOSE` → `0.5`
- `DRAW` → `1.0` (omitted from parlay impact)
- `LOSE` → ticket multiplier = `0.0` (Maung broken)

**All money math runs in fixed-point decimal** (`github.com/shopspring/decimal`) —
never raw `float64` in the settlement core (`pkg/settlement`, `pkg/worker/formula.go`).
Float64 exists only as the JSON/DB boundary type.

## 3. Engine guardrails (institutionalized)

- **Idempotent settlement**: worker claims `bet_selections` with `FOR UPDATE SKIP LOCKED`,
  transitions `bets.status PENDING → APPROVED/REJECTED` under `WHERE status='PENDING'`,
  stamps `settled_at`. Redelivery cannot double-credit.
- **Statuses**: match `OPEN/CLOSED/FINISHED`; bet `PENDING/APPROVED/REJECTED`; request `PENDING/APPROVED/REJECTED`.
  Settlement: `APPROVED` ⇒ won (gross payout = stake × combined), `REJECTED` ⇒ lost.
- **Nullable DB columns map to Go pointers/sqlnull + `omitempty`**; request/response ENUMs
  are strict `type X string` constants.
- **Weekly settlement arithmetic**: `net = total_retained_lose − total_payout_win`
  (positive ⇒ agent owes the house). `potential_payout` column is NOT trusted/used.
- **Bot webhook worker** (`cmd/webhook`): verifies Telegram `X-Telegram-Bot-Api-Secret-Token`
  and Viber HMAC-SHA256 `X-Viber-Content-Signature` BEFORE parsing; maps `sender_id → user`
  via `bot_links`; inserts `unit_requests` as `PENDING` (metadata in `payment_info`);
  60 s dedup window for accidental redelivery; publishes real-time event to
  `agent_unit_request_queue`.
- **Decimal handicap semantics decision** (keep in sync across the 3 mirrors
  `pkg/settlement/myanmar.go`, `web/lib/myanmar-settlement.ts`, mobile calculator):
  `-36` draw currently returns **0.64×** (HALF_LOSE), body `1+50` → 1.5 payout.
  Flag this explicitly if a prompt implies a different convention.

## 4. Repository conventions

- **Migrations**: `migrations/0000NN_<name>.up.sql`, engine only runs `.up.sql`
  files greedily with an advisory lock at boot (`AUTO_MIGRATE=true`,
  `MIGRATIONS_DIR=./migrations`). No `.down.sql`. Applies 000001→000012.
- **Routes** (all under `/api/v1`): user bets/history/password; agent downlines,
  user summary+toggle, contact profile GET/PUT; settlements weekly (GET self/aggregate,
  POST admin settle); admin agents + status toggle; auth login. Webhook worker serves
  its own `POST /api/v1/webhooks/bot` on :8090.
- **Auth**: JWT bearer via `pkg/auth`; roles `SUPER_ADMIN/ADMIN/AGENT/USER`; every
  admin/agent mutator re-verifies ownership/role server-side (never trust the client).
- **Responses**: `{success, message?, data?}` with Burmese user-facing messages
  (e.g. "ငွေမလုံလောက်ပါ။" style); dates UTC; money 2dp.
- **Flutter**: l10n via `assets/l10n/{my,en}.json`; Zawgyi/Unicode auto-detection via
  `mobile/lib/core/utils/myanmar_font_engine.dart` (per-string cached) + inline
  detector in `live_match_odds_view.dart`; fonts `Pyidaungsu` / `Zawgyi-One`.
  **Resilience layer**: `ApiClient` (single HTTP choke point) throws typed
  `ApiException` (>=400) vs `NetworkException` (offline/timeout); Hive-backed
  `OfflineCache` (soft cache — no-op when uninitialised) + offline-first
  fallback in `BetHistoryRepository` (page 0 write-through/rehydrate);
  `connectivity_plus` `ConnectivityController` drives the "အင်တာနက် မရရှိပါ"
  banner via `OfflineBannerBuilder` (wired in `MaterialApp.builder`).
  `flutter_lints` via `analysis_options.yaml`. `connectivity_plus` is NOT a
  hard dependency of the business layer — the banner is a pure UI concern.
  **Perf**: `ListView.builder` used in feeds; no network images in the app yet,
  so `cached_network_image` was deliberately NOT added (no dead deps).
  **R8**: no android gradle project yet → `mobile/android/app/proguard-rules.pro`
  is a ready stub; paste the `minifyEnabled`/`proguardFiles` block after
  `flutter create .`.
- **Web**: Next.js App Router + Tailwind `brand-*` theme tokens; server actions for
  mutations (`app/**/actions.ts`); `Intl.NumberFormat` for money (`lib/format.ts`,
  `formatKyat` for my-MM); tables memoized with `useMemo`.
- **Infra**: multi-stage Dockerfile builds 3 binaries (`mogok-maung-api`,
  `mogok-maung-worker`, `mogok-maung-webhook`); compose = postgres:16, redis:7,
  rabbitmq:3.13, api, settlement-worker, bot-webhook-worker.
  **Terraform (AWS)** highlights:
  - `infrastructure/terraform/autoscaling.tf` — ECS Fargate autoscaling for
    `user-service`. Target: min=2, max=10. Three target-tracking policies:
    CPU 70%, Memory 80%, ALB RPS 500 (`disable_scale_in`).
    Anti-thrash = `disable_scale_in` flags (AWS provider v5 dropped the
    `scale_in_cooldown`/`scale_out_cooldown` args on
    `aws_appautoscaling_target`; the old vars were removed accordingly).
  - Other: private RDS (PITR), ElastiCache, ALB, networking.

  NOTE: provider v5 renames are already applied repo-wide:
  `replication_group_description` → `description` (redis.tf); multi-line
  ternary indentation collapsed to single lines (HCL ≥1.16 parser rejects the
  wrapped `?`/`:` form); duplicate `output "redis_endpoint"` removed from
  redis.tf (kept in outputs.tf).
  `deploy/nginx/conf.d/api-admin-lockdown.conf`: dedicated 8443 listener for
  `/api/v1/(admin|agent)/` — `allow` office IP blocks + `deny all`, TLS 1.3 only,
  drops requests without CF-Connecting-IP and rebuilds X-Forwarded-For from it.
  `deploy/cloudflare/admin-ip-whitelist.sh`: WAF custom rule blocks
  `/api/v1/admin/*` + `/api/v1/agent/*` unless origin IP in `ADMIN_WHITELIST`.
  `infrastructure/nginx/nginx.conf`: rate-limit `/api/v1/auth/*` (auth_zone
  10r/m burst 20) + `limit_req_status 429`; admin/agent gate = `$admin_gate`
  map (`"1*"` office-CIDR allowlist OR `"01*"` verified cloudflared/VPC origin
  carrying `$http_cf_connecting_ip`), never header-only. Ships
  `cloudflare-ips.conf` (official ranges → `set_real_ip_from`) so the
  CF-Connecting-IP rewrite is unspoofable, plus `admin-whitelist.conf` and
  `cloudflared-ips.conf` (operator CIDRs). `nginx -t` validated in-container.
  **Local testing & build gate**: `scripts/dev/test_and_build.ps1`
  (flutter discovery → pub get → analyze → test → integration smoke on an
  attached device → optional debug APK → web typecheck + `next build`).
  Mobile backend origin + WS gateway are overridable via
  `--dart-define=API_BASE_URL/WS_BASE_URL` (`AppConfig` reads
  `String.fromEnvironment`), Android cleartext restricted dev-only to
  `10.0.2.2`/`127.0.0.1`/`localhost` via `network_security_config.xml`, and
  `mobile/integration_test/app_smoke_test.dart` boot + health-ping smoke
  (`integration_test` dev dep added). Also ran: 56 mobile tests, `flutter
  analyze` clean, `tsc` clean, `npm run build` green in the same script run.
  `deploy/nginx/conf.d/admin-dashboard.conf`: allow-listed operator portal vhost.
  **Staging deployment** (`deploy/deploy-staging.sh`): EC2 host → ECR login →
  pull `:latest-staging` images → `down -v` → `up -d --build` with
  `docker-compose.staging.yml` override (`build: !reset`, needs Compose >= 2.20;
  staging override maps spec services to OUR binaries:
  user-service+admin-service → `mogok-maung-api`, bet-settlement-worker →
  `mogok-maung-worker`, bot-webhook-worker → `mogok-maung-webhook`) → health
  retry loop on `/api/v1/health` (alias added in pkg/httpapi/router.go) →
  seeds `database/seeders/mock_data.sql` (users hierarchy incl. root/admin01/
  agent01/user01, Myanmar-odds matches, pending BODY+MAUNG bets, finished
  match + results; mock password `Staging123!`).
  **CI/CD**: `.github/workflows/deploy-backend.yml` = prod ECS rolling deploy
  (OIDC, terraform-owned infra). `.github/workflows/deploy-staging.yml` =
  test→push (`deploy/ecr-push.sh`: single build, re-tag x3 to
  api/worker/webhook, push `:latest-staging`)→deploy (self-hosted runner
  labeled `staging` on the EC2 staging host; secrets via GH env `staging`).
  `.gitlab-ci.yml` = equivalent (docker-socket runner on the staging EC2;
  manual deploy gate). Root `.gitignore` added (`.env` was previously
  committable).

## 5. Verification & environment status

- **Local toolchain (Phase 2 DONE — all 4 gates green)**. Portable tools in
  `%TEMP%\opencode\toolchains`:
  - Go 1.27.1 (`go-root\go\bin\go.exe`): `go mod tidy` (created `go.sum`),
    `go build ./...`, `go vet ./...`, `go test ./...`, `go fmt ./...` all pass.
    ~15 real defects fixed by the first real compile (decimal.Add, WalletEvent
    sentinel Error(), Principal→`.UserID` in agent/admin SQL args, auth Chain
    signature, unused var) and `gofmt` reformatted 31 files.
  - Flutter 3.47.2 stable (`toolchains\flutter`): `flutter pub get`, `flutter
    analyze` (0 issues), `flutter test` 56/56 pass. ~40 mobile defects fixed:
    wrong-relative imports (history/wallet/betting repo paths, service_locator,
    `sl<OddsRepository>` missing imports), non-const event constructors called
    with `const`, `ref.listen`→`ref.listenManual` for `fireImmediately`, blo
    `emit` from Timer → dispatch `RefreshWalletBalance` event, font-engine
    Zawgyi regex false-positive (killed-syllable lookbehind), MMT date comma.
    `dart fix --apply` cleared the remaining lints.
  - Terraform 1.16.1 (`toolchains\tf\terraform.exe`): `fmt -recursive`,
    `init -backend=false`, `validate` all pass; plan blocked ONLY on AWS
    credentials (no creds/IMDS on this host). `.terraform.lock.hcl` created.
  - Node/web: `npx tsc --noEmit` in `web/` PASS.
  - Env: Docker 29.7.2 + Docker Desktop (`C:\Users\KoMaw\AppData\Local\Programs\DockerDesktop`),
    Python 3.14.7 (Locust 2.46.5 installed), Go/Flutter/Terraform portable. AWS CLI
    still NOT installed. NOT present: Android SDK/JDK + `mobile/android/` scaffold,
    macOS/iOS (impossible on this Windows host).
- **Live Docker integration run (DONE — all subsystems verified against real
  Postgres/Redis/RabbitMQ)**: `docker compose up` brings up 6 containers
  (postgres/redis/rabbitmq/user-api healthy, settlement-worker + bot-webhook via
  `healthcheck: disable` since they are not HTTP servers). 14 migrations applied.
  Seed `database/seeders/mock_data.sql` (8 users, 6 matches, 8 ledger rows,
  2 bets, password `Staging123!` for every account).
  - `scripts/dr/verify-ledger.sql` (3 checks + negative-hold guard) → **ZERO rows**
    after both settlement waves (place→hold→win payout incl. hold clamping).
    Check 1 invariant CORRECTED: `current_balance == SUM(amount_change)` only —
    `hold_balance` is a reservation account mutated outside the ledger, so
    adding it produced a false delta (= outstanding hold) whenever a bet was
    pending.
  - E2E: BODY bet `1-50` stake 1000 → hold 1500 (`1.5×`; per-wallet
    `current−=hold/hold+=hold`), `potential_payout=1500`, prize pays `1.5×`
    (stored `home_body_payout`); MAUNG 2-leg parlay stays PENDING until both
    legs finish; double-delivered RabbitMQ message settles idempotently (single
    `BET_WIN` row).
  - Realtime gateway LIVE-VERIFIED: `?token=JWT` required (no-token → 401),
    initial snapshot (5 frames), admin `POST /api/v1/admin/fixtures/odds` →
    live push with exact odds (`home_body_payout: 0.8`, `maung_home: 1.95`).
  - Locust 2.46.5 headless smoke: 30 reqs / 0 failures (login, fixtures, bets,
    units/request, live WS frames).
- **Live-run defects fixed**:
  1. Dockerfile: Alpine CDN unreachable on this network → `apk` removed, CA
     bundle `COPY --from=builder`, `WORKDIR /app` (migrations landed at
     `/migrations`); `.dockerignore` += `.terraform`, `*.tfstate`, `*.tfvars`.
  2. `matches.handicap` + `matches.updated_at` never existed → snapshots /
     `UpdateMatchStatus` failed `pq: column ... does not exist`; added
     `000013_add_matches_handicap`, `000014_add_matches_updated_at`.
  3. Worker `resolveOutcome` keyed results by team NAME; contract (`match_results`
     table, seeder, admin event) uses `HOME`/`AWAY` roles → rewritten to role
     keys; poison-pill deliveries no longer hot-requeue (drop after redelivery).
  4. **BODY payout bug**: worker (and history UI) paid only `1.0×` because they
     used `OddsProfile.PayoutMultiplier` instead of the stored
     `home/away_body_payout` (`1-50` fixture quoted 1.50 paid 1.00) →
     both now use the stored per-match payout with the same fallback + ≥1.0x
     floor as `bet.MaxPotentialWin` (money parity: preview == payout).
  5. `locustfile.py` harness: double-slash URL (trailing-slash BASE_URL →
     `//api/v1/...` fell through to the index handler) + root-level auth token
     extraction → normalized `BASE_URL.rstrip("/")`.
- Host quirk: NVIDIA Broadcast owns `127.0.0.1:8080`; use `http://localhost:8080`
  or `http://[::1]:8080` (and `curl.exe --noproxy "*"`).
- Realtime gateway (`pkg/websocket`) contract (unit-consistent AND live-verified):
  - `GET /ws/live-odds` — any authenticated role; `?token=JWT` (Flutter
    `live_odds_client.dart` already sends it). Initial snapshot = all
    OPEN/SUSPENDED; then Redis `live_odds_channel` fan-out. Envelope =
    `{"type":"odds_update","data":{snapshot}}` exactly matching
    `LiveOddsEnvelope`.
  - `GET /ws/agent/requests` — AGENT/SUPER_ADMIN only; drains AMQP
    `agent_unit_request_queue` → forwards webhook's `unit_request_created`
    frames verbatim to agent dashboards.
  - Wired via envs `REDIS_ADDR` (or `REDIS_HOST`+`REDIS_PORT`),
    `REDIS_PASSWORD`, reuses `AMQP_URL` + `AGENT_UNIT_REQUEST_QUEUE`. No Redis
    ⇒ no WS routes, everything else unchanged. Admin `UpdateFixtureOdds` +
    `UpdateMatchStatus` now call `onOddsChange` → snapshot → Redis.
- Schema contract `bets.potential_payout` RESOLVED (migration 000007): always
  populated at placement (`bet.MaxPotentialWin` = stake × ∏ per-leg multiplier;
  BODY pick-side payout × odds-profile, MAUNG pick multiplier, per-leg ≥1.0x),
  never NULL, round-half NUMERIC(15,2). Exposed in `PlaceBetResponse`.
- Known pre-launch blockers:
  1. `-36` draw convention (0.64× = HALF_LOSE) pending business sign-off (only
     Item 3 of Phase 1 remaining — items 1, 2, 4 are implemented).
  2. AWS credentials + AWS CLI not on this host → ECR image push, staging EC2
     deploy, Terraform plan/apply, ACM/Cloudflare/webhook config still blocked
     until creds are supplied. Docker itself IS present now (local compose +
     builds verified).
  3. `mobile/` has no `android/ios` scaffold yet — required before any APK/AAB
     (R8) or iOS build; iOS additionally needs macOS + signing certs.
- Bootstrapping the first admin: `database/seeders/001_bootstrap_admin.sql`
  (generates its own bcrypt hash — never commit a real password).