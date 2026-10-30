// Command runner is the platform jobs runner. Mode "runner" (the default) schedules the declared jobs and consumes
// the per-app Redis queues; mode "healthcheck" exits 0 only when runner.tsv has a fresh heartbeat.
package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/dispatch"
	"github.com/gpropersi/apps/platform/jobs/internal/history"
	"github.com/gpropersi/apps/platform/jobs/internal/logx"
	"github.com/gpropersi/apps/platform/jobs/internal/notify"
	"github.com/gpropersi/apps/platform/jobs/internal/queue"
	"github.com/gpropersi/apps/platform/jobs/internal/sched"
)

// The queue consumer collapses run alerts only when its Notifier is an Alerter (a runtime type assertion), so pin it.
var _ queue.Alerter = (*notify.Discord)(nil)

// version is set with -ldflags "-X main.version=...".
var version = "dev"

// Environment variable names that override a path or address (none holds a secret).
const (
	envJobsEnv      = "JOBS_ENV_FILE"
	envPasswordFile = "JOBS_REDIS_PASSWORD_FILE"
	envRegistry     = "JOBS_REGISTRY_DIR"
	envSecrets      = "JOBS_SECRETS_DIR"
	envWindowDir    = "JOBS_WINDOW_DIR"
	envStatusDir    = "JOBS_STATUS_DIR"
	envStateDir     = "JOBS_STATE_DIR"
	envRedisAddr    = "JOBS_REDIS_ADDR"
)

// config holds every path and address the runner uses.
type config struct {
	JobsEnv      string
	PasswordFile string
	Registry     string
	Secrets      string
	WindowDir    string
	StatusDir    string
	StateDir     string
	RedisAddr    string
}

// loadConfig returns the production defaults, each overridable by its environment variable.
func loadConfig(getenv func(string) string) config {
	pick := func(name, def string) string {
		if v := getenv(name); v != "" {
			return v
		}
		return def
	}
	return config{
		JobsEnv:      pick(envJobsEnv, "/etc/platform/jobs.env"),
		PasswordFile: pick(envPasswordFile, "/etc/platform/jobs-redis.password"),
		Registry:     pick(envRegistry, "/var/lib/platform/registry"),
		Secrets:      pick(envSecrets, "/var/lib/platform/job-secrets"),
		WindowDir:    pick(envWindowDir, "/opt/platform/backup"),
		StatusDir:    pick(envStatusDir, "/var/lib/platform/jobs-status"),
		StateDir:     pick(envStateDir, "/var/lib/platform/jobs-state"),
		RedisAddr:    pick(envRedisAddr, queue.RedisAddr),
	}
}

func (c config) windowPath() string { return filepath.Join(c.WindowDir, "window.env") }
func (c config) runnerTSV() string  { return filepath.Join(c.StatusDir, "runner.tsv") }

// inputs are the two start-time secrets; their values are never logged.
type inputs struct {
	webhook  string
	password string
}

// loadInputs reads jobs.env and the Redis password. Errors never include a value.
func loadInputs(c config) (inputs, error) {
	hook, err := notify.LoadEnv(c.JobsEnv)
	if err != nil {
		return inputs{}, err
	}
	pw, err := queue.ReadPassword(c.PasswordFile)
	if err != nil {
		return inputs{}, err
	}
	return inputs{webhook: hook, password: pw}, nil
}

// dispatchMode maps the arguments to a mode: no argument is the runner; an unknown one is "" (exit 2).
func dispatchMode(args []string) string {
	if len(args) == 0 {
		return "runner"
	}
	switch args[0] {
	case "runner", "healthcheck":
		return args[0]
	}
	return ""
}

func main() {
	os.Exit(run(os.Args[1:], os.Getenv, os.Stdout, os.Stderr))
}

// run is main without the process exit, so the argument dispatch is testable.
func run(args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	mode := dispatchMode(args)
	cfg := loadConfig(getenv)
	switch mode {
	case "healthcheck":
		return runHealthcheck(cfg, clock.Real{}, stderr)
	case "runner":
		ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
		defer stop()
		return runRunner(ctx, cfg, stdout)
	}
	fmt.Fprintf(stderr, "usage: runner [runner|healthcheck]\n")
	return 2
}

// runRunner wires the runner and blocks until ctx ends. It returns the process exit code.
func runRunner(ctx context.Context, cfg config, stdout io.Writer) int {
	clk := clock.Real{}
	log := logx.New(stdout, clk)
	log.Printf("runner starting version=%s", version)

	in, err := loadInputs(cfg)
	if err != nil {
		log.Printf("runner refusing to start: %s", err.Error())
		return 1
	}
	hist, err := history.NewWriter(cfg.StatusDir)
	if err != nil {
		log.Printf("runner refusing to start: status dir: %s", err.Error())
		return 1
	}
	status := history.NewStatus(clk, cfg.runnerTSV(), version, log)
	discord := notify.New(clk, log, in.webhook, nil)
	disp := dispatch.New(clk, cfg.Secrets, version)

	scheduler := sched.New(sched.Config{
		Clock: clk, RegistryRoot: cfg.Registry, WindowPath: cfg.windowPath(), StateDir: cfg.StateDir,
		Caller: disp, History: hist, Status: status, Notifier: discord, Log: log,
	})
	store := queue.NewRedisStore(cfg.RedisAddr, queue.RedisUser, in.password, queue.CommandTimeout)
	consumer := queue.New(queue.Config{
		Clock: clk, Store: store, Caller: disp, Registry: scheduler.QueueRegistry(),
		SecretsDir: cfg.Secrets, Status: status, Notifier: discord, Log: log,
	})

	return supervise(ctx, log, []component{
		{name: "notify", run: discord.Run, last: true},
		{name: "status", run: status.Run},
		{name: "scheduler", run: scheduler.Run},
		{name: "queue", run: consumer.Run},
	}, fmt.Sprintf("runner started redis=%s", cfg.RedisAddr))
}

// component is one long-running part of the runner. A last component stops after all the others have stopped.
type component struct {
	name string
	run  func(context.Context)
	last bool
}

// supervise runs the components until ctx ends and returns the process exit code. Any component returning before
// shutdown was asked for is a fault: cancel everything and exit non-zero, so the restart policy brings the runner
// back instead of leaving it up half-dead. The table is a parameter so the fault path is testable.
func supervise(ctx context.Context, log *logx.Logger, comps []component, startedMsg string) int {
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	var early atomic.Bool
	// The alert sink stops last (its own context), so alerts raised by runs that finish during shutdown are sent.
	notifyCtx, stopNotify := context.WithCancel(context.Background())
	defer stopNotify()

	var wg, notifyWG sync.WaitGroup
	for _, comp := range comps {
		group, c := &wg, runCtx
		if comp.last {
			group, c = &notifyWG, notifyCtx
		}
		group.Add(1)
		go func() {
			defer group.Done()
			comp.run(c)
			if c.Err() == nil {
				early.Store(true)
				log.Printf("runner %s exited before shutdown: stopping the runner", comp.name)
				cancel()
				return
			}
			log.Printf("runner %s stopped", comp.name)
		}()
	}
	log.Printf("%s", startedMsg)
	<-runCtx.Done()
	log.Printf("runner stopping: waiting for in-flight runs")
	wg.Wait()
	stopNotify()
	notifyWG.Wait()
	if early.Load() {
		log.Printf("runner stopped with a component fault")
		return 1
	}
	log.Printf("runner stopped")
	return 0
}
