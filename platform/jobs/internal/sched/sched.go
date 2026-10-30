// Package sched is the runner's scheduler: it fires each declared job at its cron time plus a fixed per-job
// offset, applies the single-flight, global-cap and backup-window rules, calls the app through a Caller, and
// records every run, skip and state change for the status page.
//
// All timing goes through clock.Clock, so the tests advance a fake clock instead of sleeping.
package sched

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"hash/fnv"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/dispatch"
	"github.com/gpropersi/apps/platform/jobs/internal/history"
	"github.com/gpropersi/apps/platform/jobs/internal/logx"
	"github.com/gpropersi/apps/platform/jobs/internal/registry"
	"github.com/gpropersi/apps/platform/jobs/internal/window"
)

const (
	// MaxConcurrent is the platform-wide cap on runs in flight.
	MaxConcurrent = 3
	// CapWait is how long a scheduled fire waits for a free slot before it is skipped_cap.
	CapWait = 60 * time.Second
	// ReloadEvery is the registry and window.env re-read period.
	ReloadEvery = 30 * time.Second
	// JumpThreshold is the clock jump (and the lateness) beyond which due jobs are treated as missed.
	JumpThreshold = 2 * time.Minute

	// maxCatchUpScan bounds the walk from the first missed fire to the latest one.
	maxCatchUpScan = 5000
)

// Notifier delivers a state-change alert. Step 7 supplies the Discord implementation.
//
// Notify must not block: the scheduler calls it from its main loop and from run goroutines, so a slow delivery
// would stall every tick. An implementation queues the message internally and delivers it from its own goroutine.
type Notifier interface {
	Notify(msg string)
}

// Caller makes the HTTP call for one run; *dispatch.Dispatcher is the production implementation.
type Caller interface {
	Call(ctx context.Context, r dispatch.Request) dispatch.Result
}

// Config wires a Scheduler.
type Config struct {
	Clock        clock.Clock
	RegistryRoot string // <root>/<app>/app.yaml
	WindowPath   string // backup window.env
	StateDir     string // jobs-state: schedule.tsv
	Caller       Caller
	History      *history.Writer
	Status       *history.Status
	Notifier     Notifier
	Log          *logx.Logger
	// NewRunID returns a fresh run id; the default is a ULID stamped with the clock.
	NewRunID func() string
}

type jobKey struct{ app, job string }

// persistedRow is one schedule.tsv row: last_fired, and the pending deferral of a catch_up run when there is one.
type persistedRow struct {
	lastFired   time.Time
	deferred    time.Time
	deferredFor time.Time
}

type jobState struct {
	app    string
	port   int
	job    registry.Job
	offset time.Duration

	lastFired time.Time
	nextDue   time.Time
	// deferred is the instant a catch_up job refused by the window runs once, at the window END plus its offset.
	deferred    time.Time
	deferredFor time.Time

	lastResult  string
	lastStarted time.Time
	lastEnded   time.Time
	noSecret    bool
}

// runJob is the immutable view of a job a run goroutine works from, so a registry reload cannot change it
// mid-run.
type runJob struct {
	key     jobKey
	port    int
	timeout time.Duration
	catchUp bool
	offset  time.Duration
}

// Scheduler fires jobs. Create it with New and call Run.
type Scheduler struct {
	cfg Config

	mu        sync.Mutex
	jobs      map[jobKey]*jobState
	invalid   map[string]string // app directory -> reason it is disabled_invalid_config
	hash      string
	loaded    bool
	persisted map[jobKey]persistedRow // rows read from schedule.tsv at start; nil after the first reload
	winState  string                  // "", ok, invalid
	zone      *time.Location
	zoneName  string
	inflight  map[jobKey]bool

	sem   chan struct{}
	wake  chan struct{}
	ready chan struct{}

	flushMu sync.Mutex
	stateMu sync.Mutex
	wg      sync.WaitGroup
	root    context.Context

	// test hooks
	ticksDone  atomic.Int64
	capWaiting atomic.Int32
}

// New returns a Scheduler. It does nothing until Run.
func New(cfg Config) *Scheduler {
	if cfg.NewRunID == nil {
		clk := cfg.Clock
		cfg.NewRunID = func() string { return clock.NewULID(clk.Now()) }
	}
	return &Scheduler{
		cfg:      cfg,
		jobs:     map[jobKey]*jobState{},
		invalid:  map[string]string{},
		inflight: map[jobKey]bool{},
		sem:      make(chan struct{}, MaxConcurrent),
		wake:     make(chan struct{}, 1),
		ready:    make(chan struct{}),
		root:     context.Background(),
	}
}

// Ready is closed once the first scan is done and the scheduling timers are armed.
func (s *Scheduler) Ready() <-chan struct{} { return s.ready }

func (s *Scheduler) now() time.Time { return s.cfg.Clock.Now() }

func (s *Scheduler) logf(format string, a ...any) { s.cfg.Log.Printf(format, a...) }

func (s *Scheduler) notify(msg string) {
	s.logf("alert %s", msg)
	if s.cfg.Notifier != nil {
		s.cfg.Notifier.Notify(msg)
	}
}

func offsetFor(app, job string) time.Duration {
	h := fnv.New32a()
	_, _ = h.Write([]byte(app + "/" + job))
	return time.Duration(h.Sum32()%60) * time.Second
}

// Run blocks until ctx ends, then waits for the runs still in flight (their requests are cancelled with ctx).
func (s *Scheduler) Run(ctx context.Context) {
	s.root = ctx
	if err := os.MkdirAll(s.cfg.StateDir, 0o700); err != nil {
		s.logf("state mkdir_failed dir=%s err=%q", s.cfg.StateDir, err.Error())
	}
	s.loadStateFile()
	_, _ = s.windowDecision() // sets the zone and window_state before any next_due is computed
	s.reload()
	tick := s.cfg.Clock.NewTicker(ReloadEvery)
	defer tick.Stop()
	lastWall := s.now()
	s.processDue(true) // the start-up missed-run scan
	armed := false
	for {
		s.processDue(false)
		var timer <-chan time.Time
		if due, ok := s.earliest(); ok {
			timer = s.cfg.Clock.After(due.Sub(s.now()))
		}
		if !armed {
			armed = true
			close(s.ready)
		}
		select {
		case <-ctx.Done():
			s.wg.Wait()
			return
		case <-s.wake:
		case <-timer:
		case <-tick.C():
			now := s.now()
			jumped := now.Sub(lastWall)-ReloadEvery > JumpThreshold
			lastWall = now
			_, _ = s.windowDecision()
			s.reload()
			if jumped {
				s.logf("clock jump detected: scanning for missed runs")
				s.processDue(false) // a fire that is on time keeps its schedule trigger
				s.processDue(true)
			}
			s.ticksDone.Add(1)
		}
	}
}

func (s *Scheduler) kick() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

// earliest returns the soonest next_due or deferred instant.
func (s *Scheduler) earliest() (time.Time, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var best time.Time
	for _, js := range s.jobs {
		for _, t := range []time.Time{js.nextDue, js.deferred} {
			if !t.IsZero() && (best.IsZero() || t.Before(best)) {
				best = t
			}
		}
	}
	return best, !best.IsZero()
}

// location returns the zone cron schedules are evaluated in; the caller holds s.mu.
func (s *Scheduler) location() *time.Location {
	if s.zone != nil {
		return s.zone
	}
	return time.UTC
}

// nextFire returns the first fire instant strictly after `after` (cron minute plus the job offset), or the zero
// Time for an enqueue-only job. The caller holds s.mu.
func (s *Scheduler) nextFire(js *jobState, after time.Time) time.Time {
	if js.job.Cron == nil {
		return time.Time{}
	}
	m := js.job.Cron.Next(after.Add(-js.offset), s.location())
	if m.IsZero() {
		return time.Time{}
	}
	return m.Add(js.offset)
}

// windowDecision re-reads window.env by name. It updates runner.tsv window_state, the schedule zone and, on a
// change of state, alerts once and rewrites jobs.tsv.
func (s *Scheduler) windowDecision() (window.Window, error) {
	w, err := window.Load(s.cfg.WindowPath)
	state := "ok"
	if err != nil {
		state = "invalid"
	}
	var alert string
	changed := false
	s.mu.Lock()
	prev := s.winState
	if prev != state {
		changed = true
		s.winState = state
		switch {
		case state == "invalid":
			alert = "backup window file is invalid, all runs are refused: " + err.Error()
		case prev == "invalid":
			alert = "backup window file is valid again, runs resume"
		}
	}
	if err == nil && s.zoneName != w.TZ {
		changed = true // next_due moves with the zone, so jobs.tsv and the timers need a refresh
		first := s.zoneName == ""
		s.zone, s.zoneName = w.Loc, w.TZ
		now := s.now()
		for _, js := range s.jobs {
			// The first zone read only fixes the zone next_due was computed in (UTC until then): lastFired is an
			// instant and stays, so the runs missed meanwhile are still caught up or recorded. A later zone
			// change restarts the schedule from now.
			if !first {
				js.lastFired = now
			}
			js.nextDue = s.nextFire(js, js.lastFired)
		}
	}
	s.mu.Unlock()
	s.cfg.Status.SetWindow(state)
	if changed {
		s.logf("state window_state=%s", state)
		if alert != "" {
			s.notify(alert)
		}
		s.flushJobs()
		s.kick()
	}
	return w, err
}

// registryHash fingerprints what the scheduler reads from the registry.
func registryHash(entries []registry.Entry) string {
	h := sha256.New()
	for _, e := range entries {
		fmt.Fprintf(h, "dir=%s\n", e.Dir)
		if e.Err != nil {
			fmt.Fprintf(h, "err=%s\n", e.Err.Error())
			continue
		}
		fmt.Fprintf(h, "port=%d\n", e.App.Port)
		for _, j := range e.App.Jobs {
			fmt.Fprintf(h, "job=%s|%s|%d|%t\n", j.Name, j.Schedule, j.Timeout, j.CatchUp)
		}
	}
	return hex.EncodeToString(h.Sum(nil))
}

// reload re-reads the registry; unchanged content (by hash) changes nothing.
func (s *Scheduler) reload() {
	entries, err := registry.Load(s.cfg.RegistryRoot)
	if err != nil {
		s.logf("registry load_failed err=%q", err.Error())
		s.cfg.Status.SetConfig("invalid")
		return
	}
	h := registryHash(entries)
	s.mu.Lock()
	if s.loaded && h == s.hash {
		s.mu.Unlock()
		return
	}
	now := s.now()
	seen := map[jobKey]bool{}
	invalid := map[string]string{}
	var added, removed, changed int
	for _, e := range entries {
		if e.Err != nil {
			invalid[e.Dir] = e.Err.Error()
			continue
		}
		for _, j := range e.App.Jobs {
			k := jobKey{e.App.Name, j.Name}
			seen[k] = true
			js, ok := s.jobs[k]
			if !ok {
				js = &jobState{app: k.app, job: j, port: e.App.Port, offset: offsetFor(k.app, k.job)}
				js.lastFired = now
				if p, found := s.persisted[k]; found {
					js.lastFired = p.lastFired
					if j.CatchUp {
						js.deferred, js.deferredFor = p.deferred, p.deferredFor
					}
				}
				js.nextDue = s.nextFire(js, js.lastFired)
				s.jobs[k] = js
				added++
				continue
			}
			js.port = e.App.Port
			if js.job.Schedule != j.Schedule || js.job.Timeout != j.Timeout || js.job.CatchUp != j.CatchUp {
				scheduleChanged := js.job.Schedule != j.Schedule
				js.job = j
				if scheduleChanged {
					js.lastFired = now
					js.nextDue = s.nextFire(js, now)
					js.deferred, js.deferredFor = time.Time{}, time.Time{}
				}
				if !j.CatchUp {
					js.deferred, js.deferredFor = time.Time{}, time.Time{}
				}
				changed++
			}
		}
	}
	for k := range s.jobs {
		if !seen[k] { // a removed app or job, or an app now disabled: stop scheduling; in-flight runs finish
			delete(s.jobs, k)
			removed++
		}
	}
	var alerts []string
	for dir, reason := range invalid {
		if s.invalid[dir] != reason {
			alerts = append(alerts, fmt.Sprintf("app %s is disabled, invalid config: %s", dir, reason))
		}
	}
	for dir := range s.invalid {
		if _, still := invalid[dir]; !still {
			alerts = append(alerts, fmt.Sprintf("app %s config is valid again or the app was removed", dir))
		}
	}
	sort.Strings(alerts)
	s.invalid, s.hash, s.loaded, s.persisted = invalid, h, true, nil
	s.mu.Unlock()

	s.logf("registry reload apps=%d jobs_added=%d jobs_removed=%d jobs_changed=%d invalid_apps=%d", len(entries), added, removed, changed, len(invalid))
	if len(invalid) > 0 {
		s.cfg.Status.SetConfig("invalid")
	} else {
		s.cfg.Status.SetConfig("ok")
	}
	for _, a := range alerts {
		s.notify(a)
	}
	s.saveState()
	s.flushJobs()
	s.kick()
}

type launch struct {
	j            runJob
	trigger      string
	scheduledFor time.Time
	skipMissed   bool
}

// processDue starts every job that is due. With force (start-up, or a clock jump) and for a job later than
// JumpThreshold, the due time counts as missed: a catch_up job runs once, any other job is recorded as
// skipped_missed. One record per job, however many fires were missed.
func (s *Scheduler) processDue(force bool) {
	now := s.now()
	var todo []launch
	s.mu.Lock()
	keys := make([]jobKey, 0, len(s.jobs))
	for k := range s.jobs {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].app != keys[j].app {
			return keys[i].app < keys[j].app
		}
		return keys[i].job < keys[j].job
	})
	dirty := false
	for _, k := range keys {
		js := s.jobs[k]
		rj := runJob{key: k, port: js.port, timeout: js.job.Timeout, catchUp: js.job.CatchUp, offset: js.offset}
		if !js.deferred.IsZero() && !js.deferred.After(now) {
			todo = append(todo, launch{j: rj, trigger: "catch_up", scheduledFor: js.deferredFor})
			js.deferred, js.deferredFor = time.Time{}, time.Time{}
			dirty = true // the deferral is persisted, so clearing it is too
		}
		if js.nextDue.IsZero() || js.nextDue.After(now) {
			continue
		}
		dirty = true
		if force || now.Sub(js.nextDue) > JumpThreshold {
			latest := js.nextDue
			capped := true
			for i := 0; i < maxCatchUpScan; i++ {
				n := s.nextFire(js, latest)
				if n.IsZero() || n.After(now) {
					capped = false
					break
				}
				latest = n
			}
			js.lastFired = latest
			if capped {
				// A dense schedule after a long outage has more missed fires than one scan covers. Move the
				// marker past the scanned range (to now) so the next scan does not start again from the same
				// fires and regenerate the same skipped_missed record; the one record per job still stands.
				js.lastFired = now
				s.logf("missed app=%s job=%s scan_capped=%d marker=%s", k.app, k.job, maxCatchUpScan, now.UTC().Format(time.RFC3339))
			}
			js.nextDue = s.nextFire(js, js.lastFired)
			if js.job.CatchUp {
				todo = append(todo, launch{j: rj, trigger: "catch_up", scheduledFor: latest})
			} else {
				todo = append(todo, launch{j: rj, trigger: "schedule", scheduledFor: latest, skipMissed: true})
			}
			continue
		}
		due := js.nextDue
		js.lastFired, js.nextDue = due, s.nextFire(js, due)
		todo = append(todo, launch{j: rj, trigger: "schedule", scheduledFor: due})
	}
	s.mu.Unlock()
	if dirty {
		s.saveState()
	}
	for _, l := range todo {
		if l.skipMissed {
			s.logf("missed app=%s job=%s scheduled_for=%s catch_up=false", l.j.key.app, l.j.key.job, l.scheduledFor.UTC().Format(time.RFC3339))
			s.skip(l.j, l.trigger, l.scheduledFor, "skipped_missed", "missed while the runner was not running")
			continue
		}
		l := l
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			s.execute(l.j, l.trigger, l.scheduledFor)
		}()
	}
	if len(todo) > 0 || dirty {
		s.flushJobs()
	}
}

// tryStart takes the (app, job) single-flight; the second caller gets false. Queued runs (Step 7) share it.
func (s *Scheduler) tryStart(k jobKey) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.inflight[k] {
		return false
	}
	s.inflight[k] = true
	return true
}

func (s *Scheduler) finish(k jobKey) {
	s.mu.Lock()
	delete(s.inflight, k)
	s.mu.Unlock()
}

// acquireSlot takes one of the MaxConcurrent slots, waiting up to CapWait.
func (s *Scheduler) acquireSlot() bool {
	select {
	case s.sem <- struct{}{}:
		return true
	default:
	}
	s.capWaiting.Add(1)
	defer s.capWaiting.Add(-1)
	select {
	case s.sem <- struct{}{}:
		return true
	case <-s.cfg.Clock.After(CapWait):
		return false
	case <-s.root.Done():
		return false
	}
}

func (s *Scheduler) releaseSlot() { <-s.sem }

// windowAllows applies the backup-window rule at the moment a run would start. It records the skip itself.
func (s *Scheduler) windowAllows(j runJob, trigger string, scheduledFor time.Time) bool {
	now := s.now()
	w, err := s.windowDecision()
	if err != nil {
		// Fail closed and no deferral, even for a catch_up job: a catch_up run refused because window.env is
		// invalid is lost, and the next fire is the retry (documented in the README).
		s.skip(j, trigger, scheduledFor, "refused_config", "window.env invalid: "+err.Error())
		return false
	}
	if !w.Refuses(now, j.timeout) {
		return true
	}
	reason := fmt.Sprintf("backup window %s-%s %s, timeout %s", w.Start, w.End, w.TZ, j.timeout)
	s.skip(j, trigger, scheduledFor, "skipped_window", reason)
	if j.catchUp {
		at := w.EndOn(now).Add(j.offset)
		set := false
		s.mu.Lock()
		if js := s.jobs[j.key]; js != nil && js.deferred.IsZero() {
			js.deferred, js.deferredFor = at, scheduledFor
			set = true
			s.logf("defer app=%s job=%s until=%s reason=window", j.key.app, j.key.job, at.UTC().Format(time.RFC3339))
		}
		s.mu.Unlock()
		if set {
			s.saveState() // a restart before the window ends must still run it
		}
		s.kick()
	}
	return false
}

// execute runs one scheduled or catch-up run to its record.
func (s *Scheduler) execute(j runJob, trigger string, scheduledFor time.Time) {
	if !s.windowAllows(j, trigger, scheduledFor) {
		return
	}
	if !s.tryStart(j.key) {
		s.skip(j, trigger, scheduledFor, "skipped_overlap", "the previous run of this job is still in flight")
		return
	}
	defer s.finish(j.key)
	if !s.acquireSlot() {
		s.skip(j, trigger, scheduledFor, "skipped_cap", fmt.Sprintf("no free slot of %d within %s", MaxConcurrent, CapWait))
		return
	}
	defer s.releaseSlot()
	if !s.windowAllows(j, trigger, scheduledFor) { // the wait for a slot may have reached the window
		return
	}

	runID := s.cfg.NewRunID()
	started := s.now()
	s.logf("run start app=%s job=%s trigger=%s run_id=%s", j.key.app, j.key.job, trigger, runID)
	res := s.cfg.Caller.Call(s.root, dispatch.Request{
		App: j.key.app, Port: j.port, Job: j.key.job, Timeout: j.timeout, RunID: runID,
		Trigger: trigger, Attempt: 1, ScheduledFor: scheduledFor,
	})
	ended := s.now()

	result, errText := "ok", ""
	switch {
	case res.NoSecret:
		result, errText = "skipped_no_secret", res.Err
	case res.Class != dispatch.ClassOK && !res.Timeout && s.root.Err() != nil:
		// The runner is stopping (SIGTERM), so the cancelled call is a planned stop, not an app failure: record it
		// apart from `failed` and send no alert, as the queue path does.
		result, errText = "interrupted", "the runner stopped while the run was in flight"
	case res.Timeout:
		result, errText = "timeout", res.Err
	case res.Class != dispatch.ClassOK:
		result, errText = "failed", res.Err
	}
	s.setNoSecret(j.key, res.NoSecret)
	rec := history.Run{
		RunID: runID, App: j.key.app, Job: j.key.job, Trigger: trigger, ScheduledFor: scheduledFor,
		Started: started, Ended: ended, HTTPStatus: res.HTTPStatus, Result: result, Attempt: 1, Err: errText,
	}
	if res.NoSecret {
		rec.Attempt = 0
	}
	s.record(rec)
	s.logf("run end app=%s job=%s trigger=%s run_id=%s result=%s http=%d dur_ms=%d", j.key.app, j.key.job, trigger, runID, result, res.HTTPStatus, ended.Sub(started).Milliseconds())
	if result == "failed" || result == "timeout" { // collapsed per (app, job, result) by the notifier
		s.alertRun(j.key.app, j.key.job, result, fmt.Sprintf("scheduled job %s/%s %s (attempt %d, http %d): %s", j.key.app, j.key.job, result, rec.Attempt, res.HTTPStatus, errText))
	}
}

// setNoSecret tracks state=disabled_no_secret and alerts once per change.
func (s *Scheduler) setNoSecret(k jobKey, now bool) {
	var alert string
	s.mu.Lock()
	if js := s.jobs[k]; js != nil && js.noSecret != now {
		js.noSecret = now
		if now {
			alert = fmt.Sprintf("job %s/%s is disabled: its jobs-secret is missing or unusable", k.app, k.job)
		} else {
			alert = fmt.Sprintf("job %s/%s has a usable jobs-secret again", k.app, k.job)
		}
	}
	s.mu.Unlock()
	if alert != "" {
		s.notify(alert)
	}
}

// skip records a run that did not start.
func (s *Scheduler) skip(j runJob, trigger string, scheduledFor time.Time, result, why string) {
	now := s.now()
	id := s.cfg.NewRunID()
	s.logf("run skip app=%s job=%s trigger=%s run_id=%s result=%s why=%q", j.key.app, j.key.job, trigger, id, result, why)
	s.record(history.Run{
		RunID: id, App: j.key.app, Job: j.key.job, Trigger: trigger, ScheduledFor: scheduledFor,
		Started: now, Ended: now, Result: result, Err: why,
	})
}

// record appends the run line, updates the job's last_* fields and rewrites jobs.tsv.
func (s *Scheduler) record(r history.Run) {
	if err := s.cfg.History.AppendRun(r); err != nil {
		s.logf("history append_failed run_id=%s err=%q", r.RunID, err.Error())
	}
	s.mu.Lock()
	if js := s.jobs[jobKey{r.App, r.Job}]; js != nil {
		js.lastResult, js.lastStarted, js.lastEnded = r.Result, r.Started, r.Ended
	}
	s.mu.Unlock()
	s.flushJobs()
}

// flushJobs rewrites jobs.tsv from the current state, serialised so an older snapshot never overwrites a newer.
func (s *Scheduler) flushJobs() {
	s.flushMu.Lock()
	defer s.flushMu.Unlock()
	s.mu.Lock()
	winInvalid := s.winState == "invalid"
	rows := make([]history.JobRow, 0, len(s.jobs)+len(s.invalid))
	for _, js := range s.jobs {
		state := "ok"
		switch {
		case winInvalid:
			state = "window_refused"
		case js.noSecret:
			state = "disabled_no_secret"
		}
		rows = append(rows, history.JobRow{
			App: js.app, Job: js.job.Name, Schedule: js.job.Schedule, CatchUp: js.job.CatchUp,
			LastResult: js.lastResult, LastStarted: js.lastStarted, LastEnded: js.lastEnded,
			NextDue: js.nextDue, State: state,
		})
	}
	for dir := range s.invalid { // the declared jobs of an invalid file are unknown: one placeholder row
		rows = append(rows, history.JobRow{App: dir, Job: "-", State: "disabled_invalid_config"})
	}
	s.mu.Unlock()
	if err := s.cfg.History.WriteJobs(rows); err != nil {
		s.logf("history write_failed file=jobs.tsv err=%q", err.Error())
	}
}

func (s *Scheduler) stateFile() string { return filepath.Join(s.cfg.StateDir, "schedule.tsv") }

// saveState persists last_fired per (app, job) (temp + rename).
func (s *Scheduler) saveState() {
	s.stateMu.Lock()
	defer s.stateMu.Unlock()
	s.mu.Lock()
	lines := make([]string, 0, len(s.jobs))
	for k, js := range s.jobs {
		line := k.app + "\t" + k.job + "\t" + js.lastFired.UTC().Format(time.RFC3339)
		if !js.deferred.IsZero() {
			line += "\t" + js.deferred.UTC().Format(time.RFC3339) + "\t" + js.deferredFor.UTC().Format(time.RFC3339)
		}
		lines = append(lines, line)
	}
	s.mu.Unlock()
	sort.Strings(lines)
	data := strings.Join(lines, "\n")
	if data != "" {
		data += "\n"
	}
	if err := history.WriteAtomic(s.stateFile(), []byte(data), 0o600); err != nil {
		s.logf("state write_failed file=schedule.tsv err=%q", err.Error())
	}
}

// loadStateFile reads schedule.tsv. A missing file means first start: no catch-up.
func (s *Scheduler) loadStateFile() {
	b, err := os.ReadFile(s.stateFile())
	if err != nil {
		if os.IsNotExist(err) {
			s.logf("state schedule_state=absent")
		} else {
			s.logf("state schedule_state=unreadable err=%q", err.Error())
		}
		return
	}
	rows := map[jobKey]persistedRow{}
	for _, line := range strings.Split(strings.TrimSuffix(string(b), "\n"), "\n") {
		if line == "" {
			continue
		}
		cols := strings.Split(line, "\t")
		if len(cols) != 3 && len(cols) != 5 { // app, job, last_fired[, deferred_until, deferred_for]
			s.logf("state schedule_state=bad_row")
			continue
		}
		var row persistedRow
		var err error
		if row.lastFired, err = time.Parse(time.RFC3339, cols[2]); err != nil {
			s.logf("state schedule_state=bad_row")
			continue
		}
		if len(cols) == 5 {
			var errA, errB error
			row.deferred, errA = time.Parse(time.RFC3339, cols[3])
			row.deferredFor, errB = time.Parse(time.RFC3339, cols[4])
			if errA != nil || errB != nil {
				s.logf("state schedule_state=bad_row")
				continue
			}
		}
		rows[jobKey{cols[0], cols[1]}] = row
	}
	s.mu.Lock()
	s.persisted = rows
	s.mu.Unlock()
	s.logf("state schedule_state=present rows=%d", len(rows))
}
