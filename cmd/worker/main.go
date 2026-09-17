package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"syscall"

	"mogok-maung-backend/pkg/amqpcfg"
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

	// RabbitMQ is REQUIRED in production — never fall back to guest defaults.
	// go-live.sh auto-generates RABBITMQ_USER/RABBITMQ_PASS into .env.production;
	// amqpcfg percent-encodes them via net/url.UserPassword (raw base64
	// passwords contain '+', '/', '=' which would corrupt the DSN).
	amqpURL := amqpcfg.DSN()
	if amqpURL == "" {
		return fmt.Errorf("RabbitMQ is not configured — set RABBITMQ_USER and RABBITMQ_PASS in .env.production")
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
