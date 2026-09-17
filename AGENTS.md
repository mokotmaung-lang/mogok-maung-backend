# AGENTS.md — Standing Guardrails & Prompt Modifiers

Every prompt on this repository implicitly carries the modifiers below. Apply
them to ALL generated/edited Go (and TS/Dart money math) code unless the task
explicitly says otherwise. `system_context.md` is the architectural truth — read
it before deep changes.

## 1. Struct Standard (nullable DB columns & ENUMs)
Ensure all optional DB columns map to Go pointer types or `sql.Null*` structs
(e.g. `*string`, `*int64`, `sql.NullString`, `sql.NullInt64`, `sql.NullTime`,
`sql.NullFloat64`). Implement JSON tagging with `omitempty` where appropriate.
Enforce explicit custom type definitions for ENUMs (e.g. `type BetType string`,
`type TrxType string`, `type MatchStatus string`) — never bare `string` for
enumerated domain values.

## 2. Wallet Locking Order (deadlock avoidance)
When acquiring locks on multiple resources (e.g. Agent User and End User during
wallet transfers or hold reservations), ALWAYS sort and acquire locks in
ascending order of `user_id` to strictly prevent Database Deadlocks under high
concurrency. See `pkg/wallet/wallet.go` (DEADLOCK GUARDRAIL) — do not regress it.

## 3. Money Math (fixed-point, never float64)
Do NOT use standard `float64` for Maung multiplier math or currency payouts.
Use `github.com/shopspring/decimal` for arbitrary-precision fixed-point decimal
arithmetic to eliminate precision loss during division, multiplication and
rounding (`0.1 + 0.2 != 0.3` float bias is forbidden in money paths).
- All money operations: multiply/subtract/add in `decimal`, `Round(2)` at the
  monetary boundary, convert to `float64` ONLY at the JSON/DB scan/write boundary.
- Multiplier accumulators (parlay product, potential payout/loss, settlement
  payout, hold deltas, weekly settlement net) must use `decimal.Decimal`
  internally — see `pkg/worker/formula.go`, `pkg/worker/settlement.go`,
  `pkg/bet/odds.go`, `pkg/api/http.go` (`round2`).
- Mirrors (`pkg/settlement/myanmar.go`, `web/lib/myanmar-settlement.ts`,
  `mobile` calculator) must stay in sync.

## 4. Verification gate (per session, Go)
After any change run: `go mod tidy`, `go build ./...`, `go vet ./...`,
`gofmt`, and the test suite. Live integration against the local Docker stack
uses `http://localhost:8080` (host `127.0.0.1:8080` is taken by NVIDIA
Broadcast); seed accounts all use password `Staging123!`.

## 5. UI: Myanmar font detector caching (Flutter)
The Myanmar font detector (`MyanmarFontDetector` in
`mobile/lib/widgets/live_match_odds_view.dart`, `MyanmarFontEngine` in
`mobile/lib/core/utils/myanmar_font_engine.dart`) MUST cache the detected font
family per string. High-frequency WebSocket updates (live odds frames) re-render
with the same payloads (team names, odds labels) — re-running regex detection on
every build frame is forbidden. Bounded process-shared cache (cap 512, clear on
overflow, stateless-safe). Zawgyi ↔ Unicode auto-detection must never re-render
just because detection re-ran.

## 6. UI: React dynamic tables & Myanmar Kyat formatting
Data tables that receive live/dynamic updates must memoize row rendering with
`useMemo`/`React.memo` (see `web/app/agent/downline/components/downline-table.tsx`,
`web/app/admin/fixtures/components/fixtures-table.tsx`) to prevent UI glitches
on refresh/WS activity. Amounts presented as money (wallets, holds, allocation
floats) MUST use `formatKyat` from `web/lib/format.ts`
(`Intl.NumberFormat('my-MM')` with en-US fallback for non-ICU runtimes) — never
a naked `toLocaleString()` or `formatMoney` for Kyat; `formatMoney` remains
correct only for odds/multipliers, not currency.

## 7. Edge: Nginx rate limiting & admin-plane whitelist
- `limit_req_zone` on authentication endpoints `/api/v1/auth/*` (10r/m per
  client, burst 20) — never let credential stuffing hit the API unbounded.
- `/api/v1/admin/*` and `/api/v1/agent/*` are reachable ONLY from:
  a) office CIDRs in `admin-whitelist.conf`, or b) a verified origin in
  `cloudflared-ips.conf` (cloudflared daemon / internal VPC CIDR) that ALSO
  carries `$http_cf_connecting_ip`. Gate logic lives in `$admin_gate`
  (`infrastructure/nginx/nginx.conf`) — do not regress to allowlist-only or
  header-only checks. `cloudflare-ips.conf` (official ranges) must stay wired
  to `set_real_ip_from` or the CF-Connecting-IP trust is spoofable.
- Keep `limit_req_status 429` and `server_tokens off`.

## 8. Response Language (Myanmar)
The user communicates in Myanmar (Burmese). ALL chat responses, status
updates, explanations and summaries MUST be written in Myanmar (Burmese),
Mix of Burmese and English/technical terms is fine. Code, comments, commit
messages stay in English as usual — only the conversational reply to the
user is in Myanmar. Do not wait for a reminder; apply this to every reply.