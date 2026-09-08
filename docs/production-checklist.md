# Mogok Maung — Production Environment Test Checklist
# (Production မလွှင့်တင်မီ မဖြစ်မနေ စစ်ဆေးရမည့် Checklist)

အောက်ပါ checklist ကို Live မလွှင့်မီ signature-off ပြုလုပ်ပြီးမှ သာလွှင့်ရမည်။
Each item must be verified (not assumed) and recorded with date + verifier.

Reference: `infrastructure/terraform/*` (networking, rds, ecs, redis, alb)
`scripts/dr/*` (PITR + ledger verification), `docker-compose.yml` (local/CI),
`pkg/settlement/*` + `web/lib/myanmar-settlement.ts`, `mobile/lib` (Flutter).

---

## 1. Security & Access Isolation — လုံခြုံရေး အပိုင်း

### 1.1 DB Network Isolation
- [ ] Terraform `networking.tf`: RDS (primary + replica) ✅ in **private subnets only**
      (`aws_db_instance.app` → `var.private_subnet_ids`). No `publicly_accessible`.
- [ ] Security Group rule: inbound 5432 allowed **only from the API/worker SG**;
      try from a public IP and expect **timeout** (not error).
- Verfiy:
  ```sh
  aws ec2 describe-security-groups --group-ids $(terraform output -raw vpc_sg) --region $REGION
  # then from a dev box: psql "host=$RDS_ENDPOINT ..." → expect "Connection timed out"
  ```

### 1.2 Admin/Agent IP Whitelist
- [ ] Cloudflare WAF rule set: paths `/admin/*` and `/agent/*` → allow only
      office/public IPs (or Zero Trust), everything else → block.
- [ ] Nginx/ALB listener: same restriction double-checked at edge.
- [ ] Test from a NON-whitelisted IP → expect 403 (not redirect, not login page).

### 1.3 SSL/TLS
- [ ] TLS 1.3 enforced on ALB (policy: `ELBSecurityPolicy-TLS13-1-2-2021-06`).
- [ ] ACM cert valid, auto-renewal, no expiring certs (`--days 30` scan).
- [ ] **WebSocket**: `wss://` used by live-odds client; `ws://` rejected.
- [ ] `openssl s_client -connect api.example.com:443 -tls1_3` handshake OK;
      TLS1.2-and-below `openssl s_client -tls1_2` → fails.
- [ ] HSTS header present; redirect http→https 100%.

---

## 2. Data Integrity & Concurrency — ငွေစာရင်း တိကျမှု အပိုင်း

### 2.1 Race Condition / Pessimistic Locking
- [ ] Deposit-withdraw + bet-hold paths use `SELECT … FOR UPDATE` on
      `users` row before balance mutation (verify `pkg/api/units.go`+ `pkg/settlement`).
- [ ] Concurrent test (n=50 goroutines × deposit 100): **final balance exact**,
      **no negative balance** ever (CHECK constraint violated → 0 rows).
- [ ] Big-match concurrency test: two bets on same last balance → second
      waits (locks), never over-commits.
- Verify (SQL):
  ```sql
  SELECT COUNT(*) FROM unit_ledger WHERE balance_after < 0;              -- = 0
  SELECT SUM(amount_change) FROM unit_ledger WHERE user_id=42;           -- == current_balance
  ```

### 2.2 Double-Entry Ledger Audit
- [ ] Every `unit_ledger` row has `balance_before`/`balance_after` consistent
      and `type IN (DEPOSIT,WITHDRAW,BET_HOLD,BET_WIN,BET_LOSE,BET_REFUND)`.
- [ ] Restore a ledger snapshot and assert `balance_before` of row N == `balance_after` of row N-1
      (script: `scripts/dr/verify-ledger.sql`).
- [ ] Balance = `SUM(amount_change)` over ledger **for every user** — the
      immutable ledger is the source of truth, never a live counter.

---

## 3. High Availability & Scalability — ခံနိုင်ရည်ရှိမှု အပိုင်း

### 3.1 ECS Fargate Auto-Scaling
- [ ] `terraform/ecs.tf` + `terraform/autoscaling.tf`: `aws_appautoscaling_target` min=2 /
      max=10 with **cooldowns** (`scale_in_cooldown=300s`, `scale_out_cooldown=60s`), and
      **three** target-tracking policies live:
      ECSServiceAverageCPUUtilization (70%), ECSServiceAverageMemoryUtilization (80%),
      ALBRequestCountPerTarget (500, `disable_scale_in`).
- [ ] Manual-scale check:
  - Inject CPU load (e.g. `stress-ng`) on one task → expect desired_count to step up
    within ~2–3 min; **must NOT exceed max_capacity**.
  - Scale down after cooldown → back to desired_count.
- [ ] Documented capacity spikes (big-match nights) tuned: `cpu`/`rps` target
      values reviewed with expected traffic model.

### 3.2 Redis Live-Odds Cluster
- [ ] Redis (ElastiCache / `redis-cache`) is the **authoritative live layer**:
      match status + odds reads go through Redis; DB is the recovery source.
- [ ] `SET/GET` latency p99 < 2 ms under a 1,000-c/s odds-update test.
- [ ] Pub/Sub: a WS subscriber sees an odds update **< 1 s** after publish
      (Redis channel → WS fan-out path verified end-to-end).
- [ ] Redis failover test (kill primary) → replica promotes without a
      duplicate-odds or torn-state error in API logs.
- [ ] Eviction policy `allkeys-lru` doesn't drop pending-settlement keys during peaks.
- NOTE: live-odds Redis wiring in `cmd/api/main.go` is still in progress —
      **must be green before launch**.

### 3.3 Bot-request → Agent Dashboard Real-time Push
- [ ] Bot webhook worker (`cmd/webhook`) verified: posts event to
      `agent_unit_request_queue` (durable AMQP) on every PENDING insert.
- [ ] **Consumer in `cmd/api` (or a dedicated fan-out service) subscribing to
      `agent_unit_request_queue` → WS broadcast to connected agent dashboards
      is IMPLEMENTED and e2e-tested** (currently not yet built — must be
      green before launch).
- [ ] Duplicate handling: `already_pending` events (60 s window, same user+type)
      do not double-broadcast.
- [ ] Consumption lag < 1 s during a 100-request/min bot flood.

---

## 4. Backup & Disaster Recovery — ဘေးအန္တရာယ် ကာကွယ်ရေး

### 4.1 PITR & WAL
- [ ] `scripts/dr/enable-pitr.sh` run: `backup_retention_period = 7` (minimum),
      `backup_window` defined, existing automatic snapshots present.
- [ ] Continuous **WAL → S3** (or automated snapshot) confirmed shipping; no gap.
- [ ] **Restore drill required** (`scripts/dr/restore-pitr.sh`):
      1. Restore to time T (10 min before "disaster").
      2. Assert bank balances at T match production ledger at T
         (`verify-ledger.sql` hash-identical).
      3. Backfill from Kafka-less replay (bets/unit_requests re-derived where needed).
- [ ] Cross-region copy or S3 lifecycle versioning enabled for WAL bucket.
- [ ] Snapshots NOT publicly accessible; restore IAM locked.

---

## 5. Localization & UX — မြန်မာဘာသာ အပိုင်း

### 5.1 Zawgyi/Unicode
- [ ] **Zawgyi→Unicode detector** (regex) present and gating text rendering:
      input is detected before save, stored/base normalized; UI renders correct font.
- [ ] **Font loader** (custom dynamic font per detected encoding) verified on
      `Android 5.x` and `iOS 12` (low-end) — no tofu/か blocks.
- [ ] Round-trip test table: 20 sample sentences each (Zawgyi + Unicode)
      show **identical glyphs** to both reader groups; DB stores canonical form.
- [ ] Fallback font loads on failure (never blank/boxes); cache TTL sane.
- [ ] Accept **both** encodings as input anywhere Burmese is typed (bets, notes);
      don't corrupt existing Zawgyi texts on read.

### 5.2 UX sanity
- [ ] L10n: my/en keys complete; missing-key fallback to English (no raw keys shown).
- [ ] Money amounts rendered with thousands separators; `ကျပ်` present where promised.
- [ ] 400ms-SIM / poor-network simulation: pages render, no permanent spinners.

---

## Sign-off
| # | Section | Result (PASS/FAIL) | Date | Verifier |
|---|---------|--------------------|------|----------|
| 1 | Security & Access Isolation | | | |
| 2 | Data Integrity & Concurrency | | | |
| 3 | High Availability & Scalability | | | |
| 4 | Backup & Disaster Recovery | | | |
| 5 | Localization & UX | | | |

All sections must be PASS before `Production Launch`.