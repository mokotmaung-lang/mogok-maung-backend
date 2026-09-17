// Package amqpcfg builds a safely percent-encoded RabbitMQ DSN from its
// component env vars.
//
// Why: deploy scripts generate the broker password with
// `openssl rand -base64 32`, which can emit '+', '/' and '='. Inlining those
// raw characters into an `amqp://user:pass@host:port/` string yields a URL
// that even Go's net/url rejects ("invalid port ... after host"), turning the
// AMQP consumers into an infinite reconnect loop. The only safe construction
// is url.UserPassword, which performs the RFC 3986 percent-encoding.
package amqpcfg

import (
	"net"
	"net/url"
	"os"
	"strings"
)

const (
	defaultHost = "rabbitmq"
	defaultPort = "5672"
)

// DSN returns the connection string for the RabbitMQ broker.
//
// Component env vars (preferred, always safe):
//
//	RABBITMQ_USER, RABBITMQ_PASS, RABBITMQ_HOST (default rabbitmq),
//	RABBITMQ_PORT (default 5672), RABBITMQ_VHOST (default "/").
//
// Legacy fallback: a pre-encoded AMQP_URL, used only when neither
// RABBITMQ_USER nor RABBITMQ_PASS is set (local/manual setups that already
// carry a valid fully-formed URL). Returns "" when RabbitMQ is not configured.
func DSN() string {
	user := os.Getenv("RABBITMQ_USER")
	pass := os.Getenv("RABBITMQ_PASS")
	if user == "" && pass == "" {
		return os.Getenv("AMQP_URL")
	}

	host := envOr("RABBITMQ_HOST", defaultHost)
	port := envOr("RABBITMQ_PORT", defaultPort)
	vhost := envOr("RABBITMQ_VHOST", "/")

	u := url.URL{
		Scheme: "amqp",
		User:   url.UserPassword(user, pass),
		Host:   net.JoinHostPort(host, port),
		Path:   "/" + strings.TrimPrefix(vhost, "/"),
	}
	return u.String()
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
