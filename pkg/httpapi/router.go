package httpapi

import (
	"context"
	"database/sql"
	"fmt"
	"net/http"
	"time"

	"github.com/go-redis/redis/v8"

	"mogok-maung-backend/pkg/api"
	"mogok-maung-backend/pkg/auth"
	"mogok-maung-backend/pkg/bet"
	"mogok-maung-backend/pkg/database"
	"mogok-maung-backend/pkg/feed"
	"mogok-maung-backend/pkg/models"
	"mogok-maung-backend/pkg/websocket"
	"mogok-maung-backend/pkg/worker"
)

// healthHandler reports liveness + DB (+ Redis when the live gateway is wired)
// connectivity on both /health and its versioned alias /api/v1/health (used by
// load balancers, smoke tests and deploy scripts). A 503 is returned as soon
// as PostgreSQL OR Redis becomes unreachable, so the probe only ever sees 200
// "ok" when every backend dependency answers.
func healthHandler(db *sql.DB, live *websocket.Hub) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := database.HealthCheck(db); err != nil {
			http.Error(w, "unhealthy: database", http.StatusServiceUnavailable)
			return
		}
		if live != nil {
			ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
			defer cancel()
			if err := live.Ping(ctx); err != nil {
				http.Error(w, "unhealthy: redis", http.StatusServiceUnavailable)
				return
			}
		}
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	}
}

// NewRouter assembles the entire HTTP API with RBAC middleware applied at the
// route level:
//
//	public       -> /api/v1/auth/login, /health
//	SUPER_ADMIN  -> /api/v1/admin/*        (fixture control, unit approval)
//	AGENT        -> /api/v1/agent/*        (account provisioning, request relay)
//	USER         -> /api/v1/user/bets      (bet placement)
//
// onMatchResult dispatches finished-match results to the settlement worker
// (RabbitMQ); pass nil to skip dispatch (results still persist, worker will
// not run until a publisher is wired).
//
// live is the WebSocket live-gateway Hub; pass nil to disable the /ws/*
// endpoints entirely (no Redis configured). onOddsChange is invoked by the
// admin endpoints after any status/odds commit so the caller can fan the new
// snapshot out through Redis; it is ignored when live is nil.
//
// rdb is the shared Redis client used for the active-fixtures cache fast path
// (GET /api/v1/user/fixtures) and its post-sync eviction; pass nil to disable
// caching while keeping the gateway behaviour driven by `live`.
func NewRouter(db *sql.DB, jwtSecret string,
	onMatchResult func(ctx context.Context, ev worker.SettlementEvent),
	live *websocket.Hub,
	onOddsChange func(ctx context.Context, matchID int64, payload interface{}),
	rdb *redis.Client) http.Handler {
	mux := http.NewServeMux()

	// Public endpoints.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "Mogok Maung Backend API")
	})
	mux.HandleFunc("/health", healthHandler(db, live))
	// Versioned alias used by the staging/health probes (deploy-staging.sh).
	mux.HandleFunc("/api/v1/health", healthHandler(db, live))

	// 0. Authentication (public).
	api.NewAuthHandler(db, jwtSecret, 24*time.Hour).Routes(mux)

	// 0b. Realtime gateway (enabled only when Redis is configured at startup).
	if live != nil {
		mux.Handle("GET /ws/live-odds", live.HandleLiveOdds(db, jwtSecret))
		mux.Handle("GET /ws/agent/requests", live.HandleAgentRequests(jwtSecret))
	}

	authMw := auth.Authenticate(jwtSecret)
	anyRole := auth.RequireRole(models.RoleUser, models.RoleAgent, models.RoleAdmin, models.RoleSuperAdmin)
	// Sensitive user operations are gated on the default-password being rotated.
	pwGuard := auth.RequirePasswordChanged(db)

	// 1. End-user betting (blocked until the bootstrap password is changed).
	bh := bet.NewHandler(bet.NewRepository(db))
	mux.Handle("POST /api/v1/user/bets",
		auth.Chain(bh.PlaceBet, authMw, pwGuard, anyRole))

	// 1b. User self-service profile.
	uh := api.NewUserHandler(db, rdb)
	mux.Handle("GET /api/v1/user/wallet",
		auth.Chain(uh.GetWallet, authMw, anyRole))
	mux.Handle("GET /api/v1/user/bets",
		auth.Chain(uh.ListUserBets, authMw, anyRole))
	mux.Handle("GET /api/v1/user/fixtures",
		auth.Chain(uh.ListActiveFixtures, authMw, anyRole))
	mux.Handle("POST /api/v1/user/password",
		auth.Chain(uh.ChangePassword, authMw, anyRole))
	mux.Handle("POST /api/v1/units/request",
		auth.Chain(uh.CreateUnitsRequest, authMw, anyRole))
	mux.Handle("GET /api/v1/user/units/requests",
		auth.Chain(uh.ListMyUnitRequests, authMw, anyRole))

	// 2. Super admin control plane.
	// onOddsChange fans status/odds updates to the live-odds gateway.
	// The feed provider + Redis cache handle wire the fixture sync pipeline.
	ah := api.NewAdminHandler(db, onOddsChange, onMatchResult,
		api.WithFeedProvider(feed.ProviderFromEnv()),
		api.WithCache(rdb))
	mux.Handle("GET /api/v1/admin/fixtures",
		auth.Chain(ah.ListFixtures, authMw, auth.RequireRole(models.RoleSuperAdmin)))
	mux.Handle("POST /api/v1/admin/fixtures/sync",
		auth.Chain(ah.SyncFixtures, authMw, auth.RequireRole(models.RoleSuperAdmin)))
	mux.Handle("POST /api/v1/admin/fixtures/toggle",
		auth.Chain(ah.ToggleFixture, authMw, auth.RequireRole(models.RoleSuperAdmin)))
	mux.Handle("POST /api/v1/admin/fixtures/odds",
		auth.Chain(ah.UpdateFixtureOdds, authMw, auth.RequireRole(models.RoleSuperAdmin)))
	mux.Handle("PATCH /api/v1/admin/matches/{match_id}/status",
		auth.Chain(ah.UpdateMatchStatus, authMw, auth.RequireRole(models.RoleSuperAdmin)))
	mux.Handle("POST /api/v1/admin/matches/{match_id}/result",
		auth.Chain(ah.RecordMatchResult, authMw, auth.RequireRole(models.RoleSuperAdmin)))
	mux.Handle("POST /api/v1/admin/points/approve",
		auth.Chain(ah.ApproveRequest, authMw, auth.RequireRole(models.RoleSuperAdmin)))
	mux.Handle("GET /api/v1/admin/agents",
		auth.Chain(ah.ListAgents, authMw, auth.RequireRole(models.RoleSuperAdmin)))
	mux.Handle("POST /api/v1/admin/agents/toggle",
		auth.Chain(ah.ToggleAgent, authMw, auth.RequireRole(models.RoleSuperAdmin)))
	mux.Handle("POST /api/v1/admin/agents/create",
		auth.Chain(ah.CreateAgent, authMw, auth.RequireRole(models.RoleSuperAdmin)))
	mux.Handle("POST /api/v1/admin/units/allocate",
		auth.Chain(ah.AllocateUnits, authMw, auth.RequireRole(models.RoleSuperAdmin)))
	mux.Handle("POST /api/v1/admin/agents/{agent_id}/credit",
		auth.Chain(ah.CreditAgent, authMw, auth.RequireRole(models.RoleSuperAdmin)))

	// 3. Agent tier.
	ag := api.NewAgentHandler(db)
	agentRoles := auth.RequireRole(models.RoleAgent, models.RoleSuperAdmin)
	mux.Handle("POST /api/v1/agent/users/create",
		auth.Chain(ag.CreateDownlineUser, authMw, agentRoles))
	mux.Handle("POST /api/v1/agent/points/request",
		auth.Chain(ag.CreateUnitRequest, authMw, agentRoles))
	mux.Handle("POST /api/v1/agent/unit-requests",
		auth.Chain(ag.CreateAgentUnitRequest, authMw, agentRoles))
	mux.Handle("POST /api/v1/agent/units/transfer",
		auth.Chain(ag.TransferDownlineUnits, authMw, agentRoles))
	mux.Handle("POST /api/v1/agent/users/{id}/allocate-units",
		auth.Chain(ag.AllocateDownlineUnits, authMw, agentRoles))
	mux.Handle("GET /api/v1/agent/downlines",
		auth.Chain(ag.ListDownlines, authMw, agentRoles))
	mux.Handle("GET /api/v1/agent/users/summary",
		auth.Chain(ag.ListAgentUserSummary, authMw, agentRoles))
	mux.Handle("POST /api/v1/agent/users/toggle",
		auth.Chain(ag.ToggleAgentUserStatus, authMw, agentRoles))
	mux.Handle("POST /api/v1/agent/sandbox/test-bet",
		auth.Chain(ag.SandboxTestBet, authMw, agentRoles))
	mux.Handle("GET /api/v1/agent/profile/contact-info",
		auth.Chain(ag.GetAgentContactProfile, authMw, agentRoles))
	mux.Handle("PUT /api/v1/agent/profile/contact-info",
		auth.Chain(ag.UpdateAgentContactProfile, authMw, agentRoles))

	// 4. Weekly financial settlement (house <> agent).
	sm := api.NewSettlementHandler(db)
	settleRoles := auth.RequireRole(models.RoleAgent, models.RoleAdmin, models.RoleSuperAdmin)
	mux.Handle("GET /api/v1/settlements/weekly",
		auth.Chain(sm.WeeklySummary, authMw, settleRoles))
	adminSettleRoles := auth.RequireRole(models.RoleAdmin, models.RoleSuperAdmin)
	mux.Handle("POST /api/v1/admin/settlements/weekly/settle",
		auth.Chain(sm.MarkWeeklySettled, authMw, adminSettleRoles))

	return NewCORS(mux)
}
