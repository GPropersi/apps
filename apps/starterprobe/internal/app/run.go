package app

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"time"

	app_starterprobe "github.com/gpropersi/apps/apps/starterprobe"
	"github.com/gpropersi/apps/apps/starterprobe/internal/platform"
)

// ListenAddr is the container port; it matches app.yaml `port` and the Dockerfile EXPOSE.
const ListenAddr = ":8080"

const shutdownTimeout = 10 * time.Second

// Auth is the identity gate: the middleware that answers 401 without a valid identity, and the reader of the identity
// it established.
type Auth struct {
	Middleware func(http.Handler) http.Handler
	EmailOf    func(*http.Request) (string, bool)
}

// Deps are the pieces Run wires together. Production uses ProductionDeps; tests replace the parts they fake.
type Deps struct {
	Version    string
	Logger     *slog.Logger
	AppYAML    []byte
	Static     fs.FS
	Addr       string
	LoadConfig func() (platform.Config, error)
	Connect    func(ctx context.Context, cfg platform.Config) (Backend, error)
	NewAuth    func(ctx context.Context, cfg platform.Config) (Auth, error)
	NewQueue   func(cfg platform.Config, declared []string) (Enqueuer, io.Closer, error) // closer may be nil
	Listen     func(addr string) (net.Listener, error)
}

// ProductionDeps wires the real config, Postgres, Cloudflare Access, Redis and embedded files.
func ProductionDeps(version string, logger *slog.Logger) (Deps, error) {
	static, err := Static()
	if err != nil {
		return Deps{}, fmt.Errorf("static files: %w", err)
	}
	return Deps{
		Version:    version,
		Logger:     logger,
		AppYAML:    app_starterprobe.AppYAML,
		Static:     static,
		Addr:       ListenAddr,
		LoadConfig: platform.LoadConfig,
		Connect:    ConnectPostgres,
		NewAuth: func(ctx context.Context, cfg platform.Config) (Auth, error) {
			v, err := platform.NewAccessVerifier(ctx, cfg.AccessTeamDomain, cfg.AccessAud)
			if err != nil {
				return Auth{}, err
			}
			return Auth{
				Middleware: platform.RequireAccess(v),
				EmailOf: func(r *http.Request) (string, bool) {
					id, ok := platform.IdentityFrom(r.Context())
					return id.Email, ok
				},
			}, nil
		},
		NewQueue: func(cfg platform.Config, declared []string) (Enqueuer, io.Closer, error) {
			rdb := platform.NewRedisClient(cfg)
			q, err := platform.NewEnqueuer(rdb, cfg.RedisKeyPrefix, declared)
			if err != nil {
				_ = rdb.Close()
				return nil, nil, err
			}
			return q, rdb, nil
		},
		Listen: func(addr string) (net.Listener, error) { return net.Listen("tcp", addr) },
	}, nil
}

// Run is the whole server lifecycle. The startup sequence is: config, declared jobs, VerifyJobs, database, migrations,
// identity verifier, queue, and only then the listener. Any failure returns an error before the listener opens (main
// maps it to exit 1, so the deploy health check fails and the old container is restored). A cancelled ctx shuts the
// server down gracefully within 10 seconds.
func Run(ctx context.Context, d Deps) error {
	log := d.Logger
	started := time.Now()

	cfg, err := d.LoadConfig()
	if err != nil {
		return fmt.Errorf("startup: %w", err)
	}
	declared, err := platform.DeclaredJobs(d.AppYAML)
	if err != nil {
		return fmt.Errorf("startup: %w", err)
	}
	jobs := &Jobs{Logger: log}
	jobFuncs := jobs.Funcs()
	if err := platform.VerifyJobs(declared, jobFuncs); err != nil {
		return fmt.Errorf("startup: %w", err)
	}
	jobsHandler, err := platform.JobsHandler([]byte(cfg.JobsSecret), jobFuncs)
	if err != nil {
		return fmt.Errorf("startup: %w", err)
	}

	backend, err := d.Connect(ctx, cfg)
	if err != nil {
		return fmt.Errorf("startup: %w", err)
	}
	defer backend.Close()
	migStart := time.Now()
	applied, err := backend.Migrate(ctx)
	if err != nil {
		return fmt.Errorf("startup: %w", err)
	}
	log.Info("migrations done", "applied", applied, "duration_ms", time.Since(migStart).Milliseconds())
	jobs.Tx = backend

	auth, err := d.NewAuth(ctx, cfg)
	if err != nil {
		return fmt.Errorf("startup: %w", err)
	}
	queue, queueCloser, err := d.NewQueue(cfg, declared)
	if err != nil {
		return fmt.Errorf("startup: %w", err)
	}
	if queueCloser != nil {
		defer func() { _ = queueCloser.Close() }()
	}

	srv := &Server{Store: backend, Queue: queue, Jobs: jobsHandler, Static: d.Static, Logger: log,
		Auth: auth.Middleware, EmailOf: auth.EmailOf}
	httpSrv := &http.Server{
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second, // above the 30 s job timeout
		IdleTimeout:       120 * time.Second,
	}
	ln, err := d.Listen(d.Addr)
	if err != nil {
		return fmt.Errorf("startup: listen: %w", err)
	}

	log.Info("server starting", "version", d.Version, "addr", d.Addr, "migrations_applied", applied,
		"startup_ms", time.Since(started).Milliseconds())
	serveErr := make(chan error, 1)
	go func() { serveErr <- httpSrv.Serve(ln) }()

	select {
	case err := <-serveErr:
		return fmt.Errorf("serve: %w", err)
	case <-ctx.Done():
	}
	log.Info("server shutting down")
	shutCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	if err := httpSrv.Shutdown(shutCtx); err != nil {
		_ = httpSrv.Close()
		return fmt.Errorf("shutdown: %w", err)
	}
	if err := <-serveErr; err != nil && !errors.Is(err, http.ErrServerClosed) {
		return fmt.Errorf("serve: %w", err)
	}
	log.Info("server stopped")
	return nil
}
