package sched

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/dispatch"
	"github.com/gpropersi/apps/platform/jobs/internal/history"
	"github.com/gpropersi/apps/platform/jobs/internal/logx"
)

const goodWindow = "BACKUP_WINDOW_START=03:30\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=America/Los_Angeles\n"

var la = mustLoc("America/Los_Angeles")

func mustLoc(name string) *time.Location {
	l, err := time.LoadLocation(name)
	if err != nil {
		panic(err)
	}
	return l
}

// laTime builds a Los Angeles wall-clock instant on 2026-03-04 (no DST change near it).
func laTime(h, m, s int) time.Time { return time.Date(2026, 3, 4, h, m, s, 0, la) }

// fnvOffset is an independent FNV-1a 32 implementation of the contract: fnv1a32("<app>/<job>") mod 60 seconds.
func fnvOffset(s string) time.Duration {
	h := uint32(2166136261)
	for _, c := range []byte(s) {
		h ^= uint32(c)
		h *= 16777619
	}
	return time.Duration(h%60) * time.Second
}

func appYAML(name string, jobs ...string) string {
	s := fmt.Sprintf("schema_version: 1\nname: %s\nowner: family\npurpose: test app\ntemplate: flask\nmemory_cap: 64m\nport: 8080\n", name)
	if len(jobs) > 0 {
		s += "jobs:\n" + strings.Join(jobs, "")
	}
	return s
}

func jobYAML(name, schedule, timeout string, catchUp bool) string {
	s := "  - name: " + name + "\n    timeout: " + timeout + "\n"
	if schedule != "" {
		s += "    schedule: \"" + schedule + "\"\n"
	}
	if catchUp {
		s += "    catch_up: true\n"
	}
	return s
}

var okResult = dispatch.Result{Class: dispatch.ClassOK, HTTPStatus: 200}

type fakeCaller struct {
	mu   sync.Mutex
	reqs []dispatch.Request
	fn   func(ctx context.Context, r dispatch.Request) dispatch.Result
}

func (f *fakeCaller) Call(ctx context.Context, r dispatch.Request) dispatch.Result {
	f.mu.Lock()
	f.reqs = append(f.reqs, r)
	fn := f.fn
	f.mu.Unlock()
	if fn == nil {
		return okResult
	}
	return fn(ctx, r)
}

func (f *fakeCaller) requests() []dispatch.Request {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]dispatch.Request(nil), f.reqs...)
}

func (f *fakeCaller) count() int { return len(f.requests()) }

type fakeNotifier struct {
	mu     sync.Mutex
	msgs   []string
	alerts []string
}

func (n *fakeNotifier) Notify(msg string) {
	n.mu.Lock()
	n.msgs = append(n.msgs, msg)
	n.mu.Unlock()
}

// Alert makes fakeNotifier a RunAlerter.
func (n *fakeNotifier) Alert(app, job, result, msg string) {
	n.mu.Lock()
	n.alerts = append(n.alerts, app+"/"+job+"/"+result)
	n.mu.Unlock()
}

func (n *fakeNotifier) runAlerts() []string {
	n.mu.Lock()
	defer n.mu.Unlock()
	return append([]string(nil), n.alerts...)
}

func (n *fakeNotifier) messages() []string {
	n.mu.Lock()
	defer n.mu.Unlock()
	return append([]string(nil), n.msgs...)
}

type lockedBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuf) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuf) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

type env struct {
	t        *testing.T
	fake     *clock.Fake
	start    time.Time
	reg      string
	win      string
	state    string
	hist     string
	caller   Caller
	fc       *fakeCaller
	notif    *fakeNotifier
	logs     *lockedBuf
	s        *Scheduler
	status   *history.Status
	cancel   context.CancelFunc
	done     chan struct{}
	statDone chan struct{}
	stopOnce sync.Once
}

// newEnv prepares directories, a window file and the registry apps; call run() to start the scheduler.
func newEnv(t *testing.T, start time.Time, windowText string, apps map[string]string) *env {
	t.Helper()
	root := t.TempDir()
	e := &env{
		t: t, fake: clock.NewFake(start), start: start,
		reg: filepath.Join(root, "registry"), win: filepath.Join(root, "backup", "window.env"),
		state: filepath.Join(root, "jobs-state"), hist: filepath.Join(root, "jobs-status"),
		fc: &fakeCaller{}, notif: &fakeNotifier{}, logs: &lockedBuf{},
	}
	e.caller = e.fc
	for _, d := range []string{e.reg, filepath.Dir(e.win)} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	e.writeWindow(windowText)
	for name, y := range apps {
		e.writeApp(name, y)
	}
	return e
}

func (e *env) writeWindow(text string) {
	e.t.Helper()
	// temp + rename, like install-backup.sh: the file gets a new inode every time
	tmp := e.win + ".tmp"
	if err := os.WriteFile(tmp, []byte(text), 0o644); err != nil {
		e.t.Fatal(err)
	}
	if err := os.Rename(tmp, e.win); err != nil {
		e.t.Fatal(err)
	}
}

func (e *env) writeApp(name, y string) {
	e.t.Helper()
	dir := filepath.Join(e.reg, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		e.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "app.yaml"), []byte(y), 0o644); err != nil {
		e.t.Fatal(err)
	}
}

func (e *env) removeApp(name string) {
	e.t.Helper()
	if err := os.RemoveAll(filepath.Join(e.reg, name)); err != nil {
		e.t.Fatal(err)
	}
}

func (e *env) run() {
	e.t.Helper()
	log := logx.New(e.logs, e.fake)
	hw, err := history.NewWriter(e.hist)
	if err != nil {
		e.t.Fatal(err)
	}
	e.status = history.NewStatus(e.fake, filepath.Join(e.hist, "runner.tsv"), "test", log)
	e.s = New(Config{
		Clock: e.fake, RegistryRoot: e.reg, WindowPath: e.win, StateDir: e.state,
		Caller: e.caller, History: hw, Status: e.status, Notifier: e.notif, Log: log,
	})
	e.start = e.fake.Now() // the reload ticker counts from here
	ctx, cancel := context.WithCancel(context.Background())
	e.cancel = cancel
	e.done, e.statDone = make(chan struct{}), make(chan struct{})
	go func() { e.s.Run(ctx); close(e.done) }()
	go func() { e.status.Run(ctx); close(e.statDone) }()
	<-e.s.Ready()
	<-e.status.Ready()
	e.t.Cleanup(e.stop)
}

func (e *env) stop() {
	e.stopOnce.Do(func() {
		e.cancel()
		<-e.done
		<-e.statDone
	})
}

// restart stops the scheduler and starts a new one on the same directories (a process restart).
func (e *env) restart() {
	e.t.Helper()
	e.stop()
	e.stopOnce = sync.Once{}
	e.run()
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(time.Millisecond)
	}
}

// adv moves the fake clock forward in steps of at most one reload period, waiting after each step until the
// scheduler has processed that step's reload tick. A single large Advance would make the scheduler read a big
// wall-clock delta between two ticks and mistake it for a clock jump.
func (e *env) adv(d time.Duration) {
	e.t.Helper()
	for d > 0 {
		step := d
		if step > ReloadEvery {
			step = ReloadEvery
		}
		e.fake.Advance(step)
		d -= step
		e.waitTicks()
	}
}

func (e *env) waitTicks() {
	e.t.Helper()
	want := int64(e.fake.Now().Sub(e.start) / ReloadEvery)
	waitFor(e.t, fmt.Sprintf("%d reload ticks", want), func() bool { return e.s.ticksDone.Load() >= want })
}

// advTo advances the fake clock to the instant t.
func (e *env) advTo(t time.Time) {
	e.t.Helper()
	if d := t.Sub(e.fake.Now()); d > 0 {
		e.adv(d)
	}
}

func (e *env) runs() [][]string {
	e.t.Helper()
	files, _ := filepath.Glob(filepath.Join(e.hist, "runs-*.tsv"))
	sort.Strings(files)
	var out [][]string
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			e.t.Fatal(err)
		}
		for _, l := range strings.Split(strings.TrimSuffix(string(b), "\n"), "\n") {
			if l == "" {
				continue
			}
			cols := strings.Split(l, "\t")
			if len(cols) != 12 {
				e.t.Fatalf("run line with %d columns: %q", len(cols), l)
			}
			out = append(out, cols)
		}
	}
	return out
}

// run-record column indexes
const (
	cRunID = iota
	cApp
	cJob
	cTrigger
	cScheduledFor
	cStarted
	cEnded
	cDuration
	cResult
	cHTTP
	cAttempt
	cError
)

func (e *env) runsWhere(app, job, result string) [][]string {
	var out [][]string
	for _, r := range e.runs() {
		if (app == "" || r[cApp] == app) && (job == "" || r[cJob] == job) && (result == "" || r[cResult] == result) {
			out = append(out, r)
		}
	}
	return out
}

func (e *env) waitRun(app, job, result string) []string {
	e.t.Helper()
	var got [][]string
	waitFor(e.t, fmt.Sprintf("run %s/%s %s", app, job, result), func() bool {
		got = e.runsWhere(app, job, result)
		return len(got) > 0
	})
	return got[0]
}

// jobRow returns the jobs.tsv row for app/job (columns: app job schedule catch_up last_result last_started
// last_ended next_due state).
func (e *env) jobRow(app, job string) []string {
	e.t.Helper()
	b, err := os.ReadFile(filepath.Join(e.hist, "jobs.tsv"))
	if err != nil {
		return nil
	}
	for _, l := range strings.Split(strings.TrimSuffix(string(b), "\n"), "\n") {
		cols := strings.Split(l, "\t")
		if len(cols) == 9 && cols[0] == app && cols[1] == job {
			return cols
		}
	}
	return nil
}

func (e *env) waitJobState(app, job, state string) {
	e.t.Helper()
	waitFor(e.t, fmt.Sprintf("%s/%s state=%s", app, job, state), func() bool {
		r := e.jobRow(app, job)
		return r != nil && r[8] == state
	})
}

func (e *env) runner() []string {
	b, err := os.ReadFile(filepath.Join(e.hist, "runner.tsv"))
	if err != nil {
		return nil
	}
	return strings.Split(strings.TrimSuffix(string(b), "\n"), "\t")
}

func utc(t time.Time) string { return t.UTC().Format(time.RFC3339) }
