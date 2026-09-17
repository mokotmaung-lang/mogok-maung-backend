package amqpcfg

import (
	"net/url"
	"testing"

	amqp "github.com/rabbitmq/amqp091-go"
)

func TestDSNDefaults(t *testing.T) {
	t.Setenv("RABBITMQ_USER", "broker_65258727")
	t.Setenv("RABBITMQ_PASS", "secret")

	dsn := DSN()
	if dsn != "amqp://broker_65258727:secret@rabbitmq:5672/" {
		t.Fatalf("unexpected DSN: %s", dsn)
	}
}

func TestDSNPercentEncodesSpecialCharacterPassword(t *testing.T) {
	user := "broker_65258727"
	pass := "c+rGPp5/8JY7hOUjBs7dHTtaxNNLfS+adQ36SQks86A="

	t.Setenv("RABBITMQ_USER", user)
	t.Setenv("RABBITMQ_PASS", pass)

	dsn := DSN()

	// net/url must parse it — the malformed interpolation never returns here.
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatalf("url.Parse(%q): %v", dsn, err)
	}
	got, _ := u.User.Password()
	if got != pass {
		t.Fatalf("password round-trip: got %s, want %s", got, pass)
	}

	// The RabbitMQ client itself must accept the resulting DSN — this is what
	// previously looped forever ("invalid port \":c+rGPp5\" after host").
	if _, err := amqp.ParseURI(dsn); err != nil {
		t.Fatalf("amqp.ParseURI(%q): %v", dsn, err)
	}
}

func TestDSNHostPortVhost(t *testing.T) {
	t.Setenv("RABBITMQ_USER", "u")
	t.Setenv("RABBITMQ_PASS", "p")
	t.Setenv("RABBITMQ_HOST", "broker.internal")
	t.Setenv("RABBITMQ_PORT", "5673")
	t.Setenv("RABBITMQ_VHOST", "payments")

	dsn := DSN()
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatalf("url.Parse(%q): %v", dsn, err)
	}
	if u.Host != "broker.internal:5673" {
		t.Fatalf("host/port: got %s", u.Host)
	}
	if u.Path != "/payments" {
		t.Fatalf("vhost path: got %q", u.Path)
	}
}

func TestDSNComponentPrecedenceOverLegacyURL(t *testing.T) {
	t.Setenv("AMQP_URL", "amqp://old:broken@127.0.0.1:5672/")
	t.Setenv("RABBITMQ_USER", "u")
	t.Setenv("RABBITMQ_PASS", "p")

	if got := DSN(); got != "amqp://u:p@rabbitmq:5672/" {
		t.Fatalf("component build must win over AMQP_URL, got %s", got)
	}
}

func TestDSNLegacyFallback(t *testing.T) {
	t.Setenv("AMQP_URL", "amqp://u:p@127.0.0.1:5672/")
	t.Setenv("RABBITMQ_USER", "")
	t.Setenv("RABBITMQ_PASS", "")

	if got := DSN(); got != "amqp://u:p@127.0.0.1:5672/" {
		t.Fatalf("legacy AMQP_URL fallback failed, got %s", got)
	}
}

func TestDSNUnset(t *testing.T) {
	t.Setenv("AMQP_URL", "")
	t.Setenv("RABBITMQ_USER", "")
	t.Setenv("RABBITMQ_PASS", "")

	if got := DSN(); got != "" {
		t.Fatalf("expected empty DSN, got %s", got)
	}
}
