package database

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// ---------------------------------------------------------------------------
// Migrator — versioned SQL bootstrap run at API container start-up.
//
// Reads `<dir>/*.up.sql` (e.g. 000001_init_schema.up.sql) in version order and
// applies exactly-once per version, tracked in `schema_migrations`. This is the
// auto-migration engine the production spec calls for: no manual DDL, the
// container applies pending schema updates on boot.
//
// Concurrency: an exclusive PostgreSQL advisory lock is held for the whole run,
// so when the 2+ Fargate replicas start together only ONE applies migrations;
// the others wait and then see "no change".
//
// NOTE: migrations run inside a transaction. `ALTER TYPE ... ADD VALUE`
// (migrations/000007) is therefore only supported on PostgreSQL >= 12
// (RDS/Compose use 16) — the same constraint we documented in the migration.
// ---------------------------------------------------------------------------

var migrationFileRE = regexp.MustCompile(`^(\d{6})_.*\.up\.sql$`)

// advisoryLockKey is a fixed 64-bit marker ("MM" brand) scoping the lock to
// this application family. 0x4D5E4D = bytes 'M','G','M'.
const advisoryLockKey int64 = 0x4D5E4D

// Migrator applies pending migrations from a directory of numbered .up.sql files.
type Migrator struct {
	db  *sql.DB
	dir string
}

// NewMigrator builds a Migrator. Empty dir resolves to "migrations".
func NewMigrator(db *sql.DB, dir string) *Migrator {
	if dir == "" {
		dir = "migrations"
	}
	return &Migrator{db: db, dir: dir}
}

type pendingMigration struct {
	version string // zero-padded, sortable lexicographically
	path    string
}

// list returns candidate migration files sorted by version.
func (m *Migrator) list() ([]pendingMigration, error) {
	entries, err := os.ReadDir(m.dir)
	if err != nil {
		return nil, fmt.Errorf("migration: read dir %q: %w", m.dir, err)
	}
	var files []pendingMigration
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		fileName := e.Name()
		match := migrationFileRE.FindStringSubmatch(fileName)
		if match == nil {
			continue // ignore .down.sql and non-conforming files
		}
		files = append(files, pendingMigration{
			version: match[1],
			path:    filepath.Join(m.dir, fileName),
		})
	}
	sort.Slice(files, func(i, j int) bool { return files[i].version < files[j].version })
	return files, nil
}

// Run applies every pending migration exactly once. Safe to call every boot.
func (m *Migrator) Run(ctx context.Context) error {
	// One dedicated connection holds the advisory lock for the entire run
	// (session-scoped, released explicitly or on conn close).
	conn, err := m.db.Conn(ctx)
	if err != nil {
		return fmt.Errorf("migration: acquire conn: %w", err)
	}
	defer conn.Close() // closing releases the session advisory lock too

	if _, err := conn.ExecContext(ctx, `SELECT pg_advisory_lock($1)`, advisoryLockKey); err != nil {
		return fmt.Errorf("migration: acquire advisory lock: %w", err)
	}
	defer func() {
		// Best-effort release; ignore ctx so shutdown still unlocks.
		_, _ = conn.ExecContext(context.Background(), `SELECT pg_advisory_unlock($1)`, advisoryLockKey)
	}()

	if _, err := conn.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version    BIGINT PRIMARY KEY,
			applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
		)`); err != nil {
		return fmt.Errorf("migration: ensure schema_migrations: %w", err)
	}

	applied := map[string]bool{}
	rows, err := conn.QueryContext(ctx, `SELECT version FROM schema_migrations`)
	if err != nil {
		return fmt.Errorf("migration: read applied versions: %w", err)
	}
	for rows.Next() {
		var v int64
		if err := rows.Scan(&v); err != nil {
			rows.Close()
			return fmt.Errorf("migration: scan applied version: %w", err)
		}
		applied[fmt.Sprintf("%06d", v)] = true
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("migration: iterate applied versions: %w", err)
	}

	files, err := m.list()
	if err != nil {
		return err
	}

	var appliedCount int
	for _, f := range files {
		if applied[f.version] {
			continue
		}
		sqlBytes, err := os.ReadFile(f.path)
		if err != nil {
			return fmt.Errorf("migration: read %s: %w", f.path, err)
		}

		tx, err := conn.BeginTx(ctx, nil)
		if err != nil {
			return fmt.Errorf("migration: begin tx for %s: %w", f.path, err)
		}
		if _, err := tx.ExecContext(ctx, string(sqlBytes)); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("migration %s FAILED: %w", f.path, err)
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO schema_migrations (version) VALUES ($1)`, f.version); err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("migration: record version %s: %w", f.version, err)
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("migration: commit %s: %w", f.path, err)
		}

		log.Printf("migrate: applied %s (%s)", f.version, filepath.Base(f.path))
		appliedCount++
	}

	if appliedCount == 0 {
		log.Println("migrate: schema up-to-date, nothing to apply")
	} else {
		log.Printf("migrate: %d migration(s) applied — ဒေတာဘေ့စ် Schema အားလုံး အောင်မြင်စွာ Update ဖြစ်ပါပြီ", appliedCount)
	}
	return nil
}

// String normalises a migration directory reference like "file://migrations".
func NormalizeMigrationDir(raw string) string {
	return strings.TrimPrefix(raw, "file://")
}
