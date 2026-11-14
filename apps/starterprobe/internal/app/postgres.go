package app

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	"github.com/gpropersi/apps/apps/starterprobe/internal/app/db"
	"github.com/gpropersi/apps/apps/starterprobe/internal/platform"
	"github.com/gpropersi/apps/apps/starterprobe/migrations"
)

const (
	// The role limit is 3 connections (platform/data/new-db.sh); the pool takes 2 and migrations share it.
	maxConns       = 2
	connectTimeout = 5 * time.Second
	migrateTimeout = 60 * time.Second
)

// Backend is the database the server runs on: the generated queries, transactions and migrations.
type Backend interface {
	db.Querier
	Transactor
	// Migrate applies the pending migrations and returns how many it applied.
	Migrate(ctx context.Context) (int, error)
	Close()
}

type postgres struct {
	*db.Queries
	pool *pgxpool.Pool
}

// ConnectPostgres opens the pool from the DB_* settings. PgBouncer-safe: unnamed statements only (QueryExecModeExec),
// no session state. sslmode=disable because the database is on the private platform network.
func ConnectPostgres(ctx context.Context, cfg platform.Config) (Backend, error) {
	u := url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(cfg.DBUser, cfg.DBPassword),
		Host:     net.JoinHostPort(cfg.DBHost, strconv.Itoa(cfg.DBPort)),
		Path:     "/" + cfg.DBName,
		RawQuery: "sslmode=disable&connect_timeout=" + strconv.Itoa(int(connectTimeout/time.Second)),
	}
	pc, err := pgxpool.ParseConfig(u.String())
	if err != nil {
		return nil, errors.New("postgres: cannot build the connection settings") // never wrap: it would carry the password
	}
	pc.MaxConns = maxConns
	pc.MinConns = 0
	pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeExec
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return nil, fmt.Errorf("postgres: cannot create the pool: %w", err)
	}
	pingCtx, cancel := context.WithTimeout(ctx, connectTimeout)
	defer cancel()
	if err := pool.Ping(pingCtx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("postgres: cannot reach the database: %w", err)
	}
	return &postgres{Queries: db.New(pool), pool: pool}, nil
}

func (p *postgres) Close() { p.pool.Close() }

// InTx runs fn in one transaction on a pooled connection.
func (p *postgres) InTx(ctx context.Context, fn func(db.Querier) error) error {
	tx, err := p.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("postgres: begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }() // no-op after a commit
	if err := fn(p.Queries.WithTx(tx)); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("postgres: commit: %w", err)
	}
	return nil
}

// Migrate runs goose over the embedded migrations through the same pool (so the connection total stays within the
// limit), without advisory locking (one instance runs at a time), within 60 seconds.
func (p *postgres) Migrate(ctx context.Context) (int, error) {
	ctx, cancel := context.WithTimeout(ctx, migrateTimeout)
	defer cancel()
	sqlDB := stdlib.OpenDBFromPool(p.pool)
	defer func() { _ = sqlDB.Close() }()
	provider, err := goose.NewProvider(goose.DialectPostgres, sqlDB, migrations.FS)
	if err != nil {
		return 0, fmt.Errorf("migrate: %w", err)
	}
	results, err := provider.Up(ctx)
	if err != nil {
		return 0, fmt.Errorf("migrate: %w", err)
	}
	return len(results), nil
}
