package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"syscall"

	"mogok-maung-backend/pkg/database"
	"mogok-maung-backend/pkg/worker"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := run(ctx, logger); err != nil {
		logger.Error("settlement worker exited with error", "error", err)
		os.Exit(1)
	}
	logger.Info("settlement worker stopped cleanly")
}

func run(ctx context.Context, logger *slog.Logger) error {
	db, err := database.Connect(database.DefaultConfig())
	if err != nil {
		return err
	}
	defer db.Close()

	// AMQP_URL is REQUIRED in production — never fall back to guest defaults.
	// deploy-vps.sh/go-live.sh auto-generate the broker creds into .env.production.
	amqpURL := os.Getenv("AMQP_URL")
	if amqpURL == "" {
		return fmt.Errorf("AMQP_URL is required — set it in .env.production (go-live.sh generates it during deploy)")
	}
	queue := getenv("SETTLEMENT_QUEUE", "match_settlement_queue")

	prefetch := 10
	if v := os.Getenv("SETTLEMENT_PREFETCH"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			prefetch = n
		}
	}

	w := worker.NewWorker(db, amqpURL, queue, prefetch, logger)
	return w.Run(ctx)
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
