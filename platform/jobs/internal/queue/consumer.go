package queue

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/dispatch"
	"github.com/gpropersi/apps/platform/jobs/internal/history"
	"github.com/gpropersi/apps/platform/jobs/internal/logx"
	"github.com/gpropersi/apps/platform/jobs/internal/mask"
)

const (
	// ResultsCap is the results channel capacity and the platform-wide cap on runs in flight.
	ResultsCap = 3
	// IdleWait is how long a pass that took nothing waits before the next one.
	IdleWait = 250 * time.Millisecond
	// PromoteEvery is the delayed-set promotion period.
	PromoteEvery = time.Second
	// ProbeEvery is how often a parked app is probed.
	ProbeEvery = 60 * time.Second
	// BackoffInitial and BackoffCap bound the retry delay of Redis work (completion writes, reconnects).
	BackoffInitial = time.Second
	BackoffCap     = 30 * time.Second
	// promoteBatch is how many due items one promotion tick moves per app.
	promoteBatch = 100
	// probeKey is the key the connection probe reads (TYPE of a missing key is a harmless reply that still
	// exercises the runner's key scope).
	probeKey = "runner:jobs:probe"
)

// JobSpec is what the queue needs to know about a declared job.
type JobSpec struct {
	Port    int
	Timeout time.Duration
}

// WindowVerdict is the backup-window decision for one job timeout.
type WindowVerdict int

const (
	// WindowInvalid is the zero value on purpose: an unreadable window.env refuses everything.
	WindowInvalid WindowVerdict = iota
	// WindowHold means the window rule refuses a run now.
	WindowHold
	// WindowAllow means a run may start.
	WindowAllow
)

// Registry is the scheduler's view the consumer shares: the declared apps and jobs, the backup window, and the
// platform-wide cap slot with the (app, job) in-flight mark.
type Registry interface {
	// Apps returns the apps with a valid app.yaml and at least one declared job, sorted.
	Apps() []string
	// Job returns a declared job.
	Job(app, job string) (JobSpec, bool)
	// WindowGate re-reads window.env and applies the backup-window rule for a job timeout.
	WindowGate(timeout time.Duration) WindowVerdict
	// TryAcquire takes a cap slot and the (app, job) in-flight mark without blocking. release frees both.
	TryAcquire(app, job string) (release func(), ok bool)
	// Record appends a run record and updates the job table.
	Record(r history.Run)
}

// Caller makes the HTTP call for one run; *dispatch.Dispatcher is the production implementation.
type Caller interface {
	Call(ctx context.Context, r dispatch.Request) dispatch.Result
}

// Notifier delivers a state-change alert; it must not block.
type Notifier interface {
	Notify(msg string)
}

// Alerter is the optional extension of a Notifier that collapses run alerts per (app, job, result).
type Alerter interface {
	Alert(app, job, result, msg string)
}

// StatusSink receives redis_state for runner.tsv.
type StatusSink interface {
	SetRedis(v string)
}

// Config wires a Consumer.
type Config struct {
	Clock      clock.Clock
	Store      Store
	Caller     Caller
	Registry   Registry
	SecretsDir string
	Status     StatusSink
	Notifier   Notifier
	Log        *logx.Logger
	// Jitter scales every backoff and retry delay (production: clock.RandomJitter).
	Jitter clock.Jitter
	// NewRunID returns a fresh run id (default: a ULID stamped with the clock).
	NewRunID func() string
	// IdleWait overrides the idle interval (tests); zero means IdleWait.
	IdleWait time.Duration
}

type appState struct {
	name       string
	recovered  bool
	recovering int // recovery writes not landed yet
	busy       int // queued items in flight (worker running) or with a pending completion write
	pending    []*write
	parked     *parkInfo
	nextTake   time.Time
	takeFails  int
}

// Consumer is the queue state machine. Everything it does to Redis happens on the goroutine that runs Run (or, in
// tests, calls pass).
type Consumer struct {
	cfg  Config
	clk  clock.Clock
	s    Store
	root context.Context

	results chan result
	wg      sync.WaitGroup

	apps map[string]*appState
	rr   int

	promoteDue bool
	tick       clock.Ticker

	redisState string // ok | down | invalid
	redisFails int
	redisNext  time.Time
	oomActive  bool

	// Test-only hooks. They are nil in production (New leaves them nil; TestHookNilInProduction asserts it).
	afterPeek  func(app string) // between the peek and the LMOVE
	beforeExec func(app string) // between the TYPE pre-check and the EXEC
	trace      func(phase string)
}

// New returns a Consumer. It does nothing until Run.
func New(cfg Config) *Consumer {
	if cfg.Jitter == nil {
		cfg.Jitter = clock.RandomJitter
	}
	if cfg.NewRunID == nil {
		clk := cfg.Clock
		cfg.NewRunID = func() string { return clock.NewULID(clk.Now()) }
	}
	if cfg.IdleWait <= 0 {
		cfg.IdleWait = IdleWait
	}
	return &Consumer{
		cfg: cfg, clk: cfg.Clock, s: cfg.Store, root: context.Background(),
		results: make(chan result, ResultsCap), apps: map[string]*appState{}, redisState: "ok",
	}
}

func (c *Consumer) logf(format string, a ...any) { c.cfg.Log.Printf(format, a...) }

func (c *Consumer) now() time.Time { return c.clk.Now() }

func (c *Consumer) tr(phase string) {
	if c.trace != nil {
		c.trace(phase)
	}
}

func (c *Consumer) st(app string) *appState {
	s := c.apps[app]
	if s == nil {
		s = &appState{name: app}
		c.apps[app] = s
	}
	return s
}

// Run blocks until ctx ends, then waits for the runs still in flight (their requests are cancelled with ctx).
func (c *Consumer) Run(ctx context.Context) {
	c.root = ctx
	c.tick = c.clk.NewTicker(PromoteEvery)
	defer c.tick.Stop()
	for ctx.Err() == nil {
		if c.pass() {
			continue
		}
		select {
		case <-ctx.Done():
		case r := <-c.results:
			c.handleResult(r)
		case <-c.tick.C():
			c.promoteDue = true
		case <-c.clk.After(c.idleWait()):
		}
	}
	c.wg.Wait()
}

// idleWait is the short interval, or less when a write backoff or a Redis probe is due sooner.
func (c *Consumer) idleWait() time.Duration {
	wait := c.cfg.IdleWait
	now := c.now()
	consider := func(t time.Time) {
		if t.IsZero() {
			return
		}
		if d := t.Sub(now); d < wait {
			wait = d
		}
	}
	if c.redisState != "ok" {
		consider(c.redisNext)
	}
	for _, st := range c.apps {
		if st.parked == nil && len(st.pending) > 0 {
			consider(st.pending[0].notBefore)
		}
	}
	if wait < time.Millisecond {
		wait = time.Millisecond
	}
	return wait
}

// pass runs the phases in order and reports whether it made progress (so Run does not idle).
func (c *Consumer) pass() bool {
	progress := false
	if c.tick != nil {
		select {
		case <-c.tick.C():
			c.promoteDue = true
		default:
		}
	}
	c.tr("drain")
	for drained := false; !drained; {
		select {
		case r := <-c.results:
			c.handleResult(r)
			progress = true
		default:
			drained = true
		}
	}
	if !c.redisGate() {
		return progress
	}
	if c.runWrites() {
		progress = true
	}
	c.probeParked()
	c.tr("promote")
	if c.promoteDue {
		c.promoteDue = false
		c.promote()
	}
	c.tr("recover")
	c.recoverApps()
	c.tr("take")
	if c.takeAll() {
		progress = true
	}
	return progress
}

// secretReadable reports whether the app's jobs-secret can be read now.
func (c *Consumer) secretReadable(app string) bool {
	_, ok := dispatch.ReadSecret(c.cfg.SecretsDir, app)
	return ok
}

// enabledApps returns the apps the consumer may serve: a valid app.yaml with a declared job, a readable
// jobs-secret and not parked. It also clears the recovered flag of every app that is not in that state.
func (c *Consumer) enabledApps() []string {
	reg := c.cfg.Registry.Apps()
	in := map[string]bool{}
	var out []string
	for _, a := range reg {
		in[a] = true
		st := c.st(a)
		if st.parked == nil && c.secretReadable(a) {
			out = append(out, a)
		}
	}
	for name, st := range c.apps {
		if st.parked != nil || !in[name] || !c.secretReadable(name) {
			st.recovered = false
		}
	}
	sort.Strings(out)
	return out
}

// declaredFor returns the declared-job predicate of one app.
func (c *Consumer) declaredFor(app string) func(string) bool {
	return func(job string) bool {
		_, ok := c.cfg.Registry.Job(app, job)
		return ok
	}
}

func (c *Consumer) newID() string { return c.cfg.NewRunID() }

// text masks and caps an error for a record or an alert.
func text(s string) string { return mask.Text(s) }

// notify logs and sends a state-change alert.
func (c *Consumer) notify(msg string) {
	c.logf("alert %s", msg)
	if c.cfg.Notifier != nil {
		c.cfg.Notifier.Notify(msg)
	}
}

// alertRun sends a run alert, collapsed per (app, job, result) when the notifier supports it.
func (c *Consumer) alertRun(app, job, result, msg string) {
	c.logf("alert %s", msg)
	if c.cfg.Notifier == nil {
		return
	}
	if a, ok := c.cfg.Notifier.(Alerter); ok {
		a.Alert(app, job, result, msg)
		return
	}
	c.cfg.Notifier.Notify(msg)
}

func qkey(app, kind string) string { return app + ":jobs:" + kind }
