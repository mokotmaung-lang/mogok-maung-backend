"""Locust load suites for the Mogok Maung betting platform.

Endpoints mirror the REAL wire contract (not the earlier draft payloads):

  Draft (wrong)                      ->  Real
  ------------------------------------------------
  /api/v1/user/matches/active        ->  /api/v1/user/fixtures
  selections[].bet_on / odds_at_bet  ->  selections[].pick / body_odds_type
  /api/v1/user/withdraw              ->  /api/v1/units/request {type, payment_info}
  mock_token_<n>                    ->  real JWT via POST /api/v1/auth/login

Blend mirrors observed production traffic:
  * 70% live-odds viewing   (read-heavy)
  * 20% bet placement       (DB write under FOR UPDATE hold)
  * 10% unit withdraw calls (approval queue feed)

Targets (distributed, 3+ workers): 20,000 concurrent users, p95 < 200ms,
error rate < 0.1%. Watch RDS CPU: > 80% while placing bets => upsize or add
a read replica per the spec.

Seed first: registered users (must_change_password=false), open matches with
body/maung odds, funded by agent point requests.

Run:
  pip install -r loadtest/requirements.txt
  MGM_BASE_URL=https://staging.example.com \
  MGM_TEST_USERNAMES=$(head -c 0 /dev/null; echo "u1,u2,u3,u4") \
  MGM_TEST_PASSWORD=... \
  locust -f loadtest/locustfile.py --host https://staging.example.com \
    -u 2000 -r 50 --csv loadtest/run --html loadtest/report.html
Distributed: see scripts/loadtest/run-locust.sh.
"""
import os
import random
import time

import websocket
from locust import HttpUser, User, between, task

BASE_URL = os.environ.get("MGM_BASE_URL", "https://myanmarbet.com").rstrip("/")
USERNAMES = [u.strip() for u in
             os.environ.get("MGM_TEST_USERNAMES", "").split(",") if u.strip()]
PASSWORD = os.environ.get("MGM_TEST_PASSWORD", "")


def login(client):
    """Real JWT from POST /api/v1/auth/login."""
    if not USERNAMES or not PASSWORD:
        raise RuntimeError("MGM_TEST_USERNAMES / MGM_TEST_PASSWORD not set")
    username = random.choice(USERNAMES)
    with client.post("/api/v1/auth/login",
                     json={"username": username, "password": PASSWORD},
                     name="/api/v1/auth/login", catch_response=True) as resp:
        if resp.status_code != 200:
            resp.failure(f"login failed ({resp.status_code}) for {username}")
            return None
        data = resp.json()
    return data.get("access_token"), username


class FootballAppUser(HttpUser):
    """HTTP API user: live-odds watching, bet placement, unit requests."""

    wait_time = between(1, 3)  # 1s..3s user think time (spec)

    def on_start(self):
        creds = login(self.client)
        if creds is None:
            self.token = None
            return
        self.token, self.username = creds
        self.headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
        }
        self.fixtures = self._load_fixtures()

    def _load_fixtures(self):
        with self.client.get("/api/v1/user/fixtures",
                             headers=self.headers,
                             name="/api/v1/user/fixtures",
                             catch_response=True) as resp:
            if resp.status_code != 200:
                resp.failure(f"fixtures ({resp.status_code})")
                return []
        return resp.json().get("fixtures", [])

    @task(7)
    def view_live_odds_http(self):
        """~70%: users watch matches and Myanmar odds continuously."""
        with self.client.get("/api/v1/user/fixtures?live=1",
                             headers=self.headers,
                             name="/api/v1/user/fixtures",
                             catch_response=True) as resp:
            if resp.status_code != 200:
                resp.failure(f"fetch failed ({resp.status_code})")

    @task(2)
    def place_maung_bet(self):
        """~20%: MAUNG parlay against OPEN matches (hold-balance DB write)."""
        open_matches = [f for f in self.fixtures if f.get("status") == "OPEN"]
        if not open_matches:
            return  # no tradable market; skip quietly (recently closed)
        picks = []
        for f in random.sample(open_matches, min(2, len(open_matches))):
            picks.append({
                "match_id": f["id"],
                "pick": random.choice(["HOME", "AWAY"]),
                "body_odds_type": f.get("body_odds_type") or "1-50",
            })
        payload = {
            "bet_type": "MAUNG",
            "total_stake": float(random.choice([500, 1000, 5000])),
            "selections": picks,
        }
        with self.client.post("/api/v1/user/bets", json=payload,
                              headers=self.headers,
                              name="/api/v1/user/bets",
                              catch_response=True) as resp:
            if resp.status_code in (200, 201):
                return
            body = resp.text[:200]
            if resp.status_code == 422:
                resp.failure(f"insufficient balance: {body}")
            else:
                resp.failure(f"bet failed ({resp.status_code}): {body}")

    @task(1)
    def request_withdraw(self):
        """~10%: unit withdrawal requests land in the approval queue."""
        payload = {
            "amount": 10000.0,
            "type": "WITHDRAW",
            "payment_info": {
                "provider": "KBZPay",
                "account_name": self.username,
            },
        }
        with self.client.post("/api/v1/units/request", json=payload,
                              headers=self.headers,
                              name="/api/v1/units/request",
                              catch_response=True) as resp:
            if resp.status_code not in (200, 201):
                resp.failure(f"withdraw request ({resp.status_code}): {resp.text[:200]}")


class LiveOddsSocketUser(User):
    """A user holding an open /ws/live-odds socket simulating live watching."""

    def on_start(self):
        import requests
        token = None
        if USERNAMES and PASSWORD:
            for _ in range(3):
                user = random.choice(USERNAMES)
                try:
                    r = requests.post(
                        f"{BASE_URL}/api/v1/auth/login",
                        json={"username": user, "password": PASSWORD},
                        timeout=10)
                    if r.status_code == 200:
                        # The auth login envelope returns the JWT at top level:
                        # {"code","message","access_token": ...}.
                        token = r.json().get("access_token")
                        break
                except requests.RequestException:
                    continue

        self.ws = websocket.WebSocket()
        self.ws.settimeout(30)
        # Build a proper ws(s) origin; BASE_URL may carry a trailing slash and
        # naively appending "/ws/live-odds" would double the slash, making Go's
        # router fall through to the index handler and breaking the handshake.
        base = BASE_URL.rstrip("/")
        scheme = "wss" if base.startswith("https") else "ws"
        uri = f"{scheme}://{base.split('://', 1)[1]}/ws/live-odds"
        if token:
            uri += "?token=" + token
        started = time.time()
        try:
            self.ws.connect(uri, header=["User-Agent: locust-mm.html"])
            self.environment.events.request.fire(
                request_type="WS", name="connect",
                response_time=int((time.time() - started) * 1000),
                response_length=0, exception=None)
        except Exception as e:  # pragma: no cover
            self.environment.events.request.fire(
                request_type="WS", name="/ws/live-odds",
                response_time=0, response_length=0,
                exception=f"{type(e).__name__}: {e}")
            self.ws.close()
            raise e

    @task
    def read_odds_frame(self):
        """Blocking recv() -> one live-odds frame counted as a request."""
        started = time.time()
        try:
            frame = self.ws.recv()
        except Exception as e:  # pragma: no cover
            self.environment.events.request.fire(
                request_type="WS", name="/ws/live-odds",
                response_time=int((time.time() - started) * 1000),
                response_length=0,
                exception=f"{type(e).__name__}: {e}")
            return
        self.environment.events.request.fire(
            request_type="WS", name="/ws/live-odds",
            response_time=int((time.time() - started) * 1000),
            response_length=len(frame),
            exception=None)

    def on_stop(self):
        try:
            self.ws.close()
        except Exception:
            pass