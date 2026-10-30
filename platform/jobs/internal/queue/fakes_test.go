package queue

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/dispatch"
	"github.com/gpropersi/apps/platform/jobs/internal/history"
	"github.com/gpropersi/apps/platform/jobs/internal/logx"
)

const errWrongType = "WRONGTYPE Operation against a key holding the wrong kind of value"
const errOOM = "OOM command not allowed when used memory > 'maxmemory'."
const errAbort = "EXECABORT Transaction discarded because of previous errors."

var errConn = io.ErrUnexpectedEOF

// ---- in-memory Redis ----

type fakeStore struct {
	mu    sync.Mutex
	lists map[string][]string // index 0 is the left end
	zsets map[string]map[string]float64
	strs  map[string]string
	calls map[string]int

	// fail is consulted before each command; a non-nil error is returned without executing it.
	fail func(cmd string, args []string) error
	// failExec is consulted before each EXEC. apply=true applies the block and then returns err (a lost reply).
	failExec func(cmds []Cmd) (apply bool, err error)
	// lmoveLostOnce makes the next LMOVE apply and then fail with a connection error.
	lmoveLostOnce bool
}

func newFakeStore() *fakeStore {
	return &fakeStore{lists: map[string][]string{}, zsets: map[string]map[string]float64{}, strs: map[string]string{}, calls: map[string]int{}}
}

func (f *fakeStore) begin(cmd string, args ...string) error {
	f.calls[cmd]++
	if f.fail != nil {
		return f.fail(cmd, args)
	}
	return nil
}

func (f *fakeStore) kind(key string) string {
	switch {
	case f.strs[key] != "" || f.hasStr(key):
		return "string"
	case len(f.lists[key]) > 0:
		return "list"
	case len(f.zsets[key]) > 0:
		return "zset"
	}
	return "none"
}

func (f *fakeStore) hasStr(key string) bool { _, ok := f.strs[key]; return ok }

func (f *fakeStore) count(cmd string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls[cmd]
}

func (f *fakeStore) LIndexLast(_ context.Context, key string) (string, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.begin("LINDEX", key); err != nil {
		return "", false, err
	}
	if f.kind(key) == "string" || f.kind(key) == "zset" {
		return "", false, errors.New(errWrongType)
	}
	l := f.lists[key]
	if len(l) == 0 {
		return "", false, nil
	}
	return l[len(l)-1], true, nil
}

func (f *fakeStore) LMove(_ context.Context, src, dst, from, to string) (string, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.begin("LMOVE", src, dst); err != nil {
		return "", false, err
	}
	l := f.lists[src]
	if len(l) == 0 {
		return "", false, nil
	}
	var item string
	if from == "RIGHT" {
		item, f.lists[src] = l[len(l)-1], l[:len(l)-1]
	} else {
		item, f.lists[src] = l[0], l[1:]
	}
	if to == "LEFT" {
		f.lists[dst] = append([]string{item}, f.lists[dst]...)
	} else {
		f.lists[dst] = append(f.lists[dst], item)
	}
	if f.lmoveLostOnce { // applied, but the reply is lost
		f.lmoveLostOnce = false
		return "", false, errConn
	}
	return item, true, nil
}

func (f *fakeStore) LPos(_ context.Context, key, val string) (bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.begin("LPOS", key); err != nil {
		return false, err
	}
	for _, v := range f.lists[key] {
		if v == val {
			return true, nil
		}
	}
	return false, nil
}

func (f *fakeStore) LRem(_ context.Context, key, val string) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.begin("LREM", key); err != nil {
		return 0, err
	}
	return f.lrem(key, val), nil
}

func (f *fakeStore) lrem(key, val string) int64 {
	l := f.lists[key]
	for i, v := range l {
		if v == val {
			f.lists[key] = append(append([]string{}, l[:i]...), l[i+1:]...)
			return 1
		}
	}
	return 0
}

func (f *fakeStore) LRangeAll(_ context.Context, key string) ([]string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.begin("LRANGE", key); err != nil {
		return nil, err
	}
	if k := f.kind(key); k == "string" || k == "zset" {
		return nil, errors.New(errWrongType)
	}
	return append([]string{}, f.lists[key]...), nil
}

func (f *fakeStore) ZCard(_ context.Context, key string) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.begin("ZCARD", key); err != nil {
		return 0, err
	}
	if k := f.kind(key); k == "string" || k == "list" {
		return 0, errors.New(errWrongType)
	}
	return int64(len(f.zsets[key])), nil
}

func (f *fakeStore) ZRangeDue(_ context.Context, key string, max int64, limit int) ([]string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.begin("ZRANGEBYSCORE", key); err != nil {
		return nil, err
	}
	if k := f.kind(key); k == "string" || k == "list" {
		return nil, errors.New(errWrongType)
	}
	var out []string
	for m, sc := range f.zsets[key] {
		if sc <= float64(max) {
			out = append(out, m)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		return f.zsets[key][out[i]] < f.zsets[key][out[j]] || (f.zsets[key][out[i]] == f.zsets[key][out[j]] && out[i] < out[j])
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (f *fakeStore) Type(_ context.Context, key string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.begin("TYPE", key); err != nil {
		return "", err
	}
	return f.kind(key), nil
}

func (f *fakeStore) Close() error { return nil }

func (f *fakeStore) Exec(_ context.Context, cmds []Cmd) ([]error, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls["EXEC"]++
	if f.fail != nil {
		if err := f.fail("EXEC", nil); err != nil {
			return nil, err
		}
	}
	var lost error
	if f.failExec != nil {
		var applied bool
		applied, lost = f.failExec(cmds)
		if lost != nil && !applied { // lost before the block was applied
			return nil, lost
		}
	}
	errs := make([]error, len(cmds))
	for i, c := range cmds {
		errs[i] = f.applyCmd(c)
	}
	if lost != nil {
		return nil, lost
	}
	return errs, nil
}

func (f *fakeStore) applyCmd(c Cmd) error {
	wrong := errors.New(errWrongType)
	key := c.Args[0]
	switch c.Name {
	case "LREM":
		if k := f.kind(key); k == "string" || k == "zset" {
			return wrong
		}
		f.lrem(key, c.Args[2])
	case "LPUSH", "RPUSH":
		if k := f.kind(key); k == "string" || k == "zset" {
			return wrong
		}
		if c.Name == "LPUSH" {
			f.lists[key] = append([]string{c.Args[1]}, f.lists[key]...)
		} else {
			f.lists[key] = append(f.lists[key], c.Args[1])
		}
	case "LTRIM":
		if k := f.kind(key); k == "string" || k == "zset" {
			return wrong
		}
		stop, _ := strconv.Atoi(c.Args[2])
		if l := f.lists[key]; len(l) > stop+1 {
			f.lists[key] = l[:stop+1]
		}
	case "ZADD":
		if k := f.kind(key); k == "string" || k == "list" {
			return wrong
		}
		sc, _ := strconv.ParseFloat(c.Args[1], 64)
		if f.zsets[key] == nil {
			f.zsets[key] = map[string]float64{}
		}
		f.zsets[key][c.Args[2]] = sc
	case "ZREM":
		if k := f.kind(key); k == "string" || k == "list" {
			return wrong
		}
		delete(f.zsets[key], c.Args[1])
	default:
		return fmt.Errorf("fake: unknown command %s", c.Name)
	}
	return nil
}

// test helpers

func (f *fakeStore) push(key string, items ...string) { // LPUSH: the last item ends up leftmost
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, it := range items {
		f.lists[key] = append([]string{it}, f.lists[key]...)
	}
}

func (f *fakeStore) list(key string) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string{}, f.lists[key]...)
}

func (f *fakeStore) setList(key string, items ...string) { // items[0] is the left end
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lists[key] = append([]string{}, items...)
}

func (f *fakeStore) setString(key, v string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.strs[key] = v
	delete(f.lists, key)
}

func (f *fakeStore) clearString(key string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.strs, key)
}

func (f *fakeStore) zadd(key string, score int64, member string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.zsets[key] == nil {
		f.zsets[key] = map[string]float64{}
	}
	f.zsets[key][member] = float64(score)
}

func (f *fakeStore) zset(key string) map[string]float64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := map[string]float64{}
	for k, v := range f.zsets[key] {
		out[k] = v
	}
	return out
}

func (f *fakeStore) setFail(fn func(cmd string, args []string) error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.fail = fn
}

// ---- registry ----

type fakeReg struct {
	mu       sync.Mutex
	apps     map[string]map[string]JobSpec
	window   WindowVerdict
	windowFn func() WindowVerdict // overrides window when set
	inflight map[string]bool
	slots    int
	maxSlots int
	acquired int
	released int
	records  []history.Run
}

func newFakeReg() *fakeReg {
	return &fakeReg{apps: map[string]map[string]JobSpec{}, window: WindowAllow, inflight: map[string]bool{}, maxSlots: ResultsCap}
}

func (r *fakeReg) declare(app, job string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.apps[app] == nil {
		r.apps[app] = map[string]JobSpec{}
	}
	r.apps[app][job] = JobSpec{Port: 8080, Timeout: 10 * time.Second}
}

func (r *fakeReg) undeclareApp(app string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.apps, app)
}

func (r *fakeReg) Apps() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []string
	for a := range r.apps {
		out = append(out, a)
	}
	sort.Strings(out)
	return out
}

func (r *fakeReg) Job(app, job string) (JobSpec, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := r.apps[app][job]
	return s, ok
}

func (r *fakeReg) WindowGate(time.Duration) WindowVerdict {
	r.mu.Lock()
	fn, w := r.windowFn, r.window
	r.mu.Unlock()
	if fn != nil {
		return fn()
	}
	return w
}

func (r *fakeReg) setWindow(w WindowVerdict) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.window = w
}

func (r *fakeReg) mark(app, job string, v bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.inflight[app+"/"+job] = v
}

func (r *fakeReg) TryAcquire(app, job string) (func(), bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	k := app + "/" + job
	if r.inflight[k] || r.slots >= r.maxSlots {
		return nil, false
	}
	r.inflight[k] = true
	r.slots++
	r.acquired++
	return func() {
		r.mu.Lock()
		defer r.mu.Unlock()
		delete(r.inflight, k)
		r.slots--
		r.released++
	}, true
}

func (r *fakeReg) Record(h history.Run) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.records = append(r.records, h)
}

func (r *fakeReg) results() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []string
	for _, h := range r.records {
		out = append(out, h.Result)
	}
	return out
}

func (r *fakeReg) held() (int, int, int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.slots, r.acquired, r.released
}

// ---- caller, notifier, status ----

type fakeCaller struct {
	mu    sync.Mutex
	reqs  []dispatch.Request
	fn    func(dispatch.Request) dispatch.Result
	block chan struct{} // when set, Call waits for a receive (or close) before answering
}

func (c *fakeCaller) Call(_ context.Context, r dispatch.Request) dispatch.Result {
	c.mu.Lock()
	c.reqs = append(c.reqs, r)
	fn, block := c.fn, c.block
	c.mu.Unlock()
	if block != nil {
		<-block
	}
	if fn != nil {
		return fn(r)
	}
	return dispatch.Result{Class: dispatch.ClassOK, HTTPStatus: 200}
}

func (c *fakeCaller) calls() []dispatch.Request {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]dispatch.Request{}, c.reqs...)
}

type fakeNotes struct {
	mu     sync.Mutex
	state  []string
	alerts []string
}

func (n *fakeNotes) Notify(msg string) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.state = append(n.state, msg)
}

func (n *fakeNotes) Alert(app, job, result, msg string) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.alerts = append(n.alerts, app+"/"+job+"/"+result+": "+msg)
}

func (n *fakeNotes) counts() (int, int) {
	n.mu.Lock()
	defer n.mu.Unlock()
	return len(n.state), len(n.alerts)
}

type fakeStatus struct {
	mu  sync.Mutex
	set []string
}

func (s *fakeStatus) SetRedis(v string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.set = append(s.set, v)
}

func (s *fakeStatus) history() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string{}, s.set...)
}

// ---- harness ----

type harness struct {
	t       *testing.T
	clk     *clock.Fake
	st      *fakeStore
	reg     *fakeReg
	caller  *fakeCaller
	notes   *fakeNotes
	status  *fakeStatus
	secrets string
	c       *Consumer
	logbuf  *syncBuf
}

type syncBuf struct {
	mu sync.Mutex
	b  []byte
}

func (s *syncBuf) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.b = append(s.b, p...)
	return len(p), nil
}

func (s *syncBuf) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return string(s.b)
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	h := &harness{
		t: t, clk: clock.NewFake(time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)),
		st: newFakeStore(), reg: newFakeReg(), caller: &fakeCaller{}, notes: &fakeNotes{}, status: &fakeStatus{},
		secrets: t.TempDir(), logbuf: &syncBuf{},
	}
	h.addApp("a1", "j", "j2")
	h.c = New(Config{
		Clock: h.clk, Store: h.st, Caller: h.caller, Registry: h.reg, SecretsDir: h.secrets, Status: h.status,
		Notifier: h.notes, Log: logx.New(h.logbuf, h.clk), Jitter: clock.FixedJitter(0),
		NewRunID: func() string { return "RUNID" },
	})
	h.c.tick = h.clk.NewTicker(PromoteEvery)
	t.Cleanup(func() { h.c.wg.Wait() })
	return h
}

func (h *harness) addApp(app string, jobs ...string) {
	h.t.Helper()
	for _, j := range jobs {
		h.reg.declare(app, j)
	}
	dir := filepath.Join(h.secrets, app)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		h.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "jobs-secret"), []byte("0123456789012345678901234567890123456789"), 0o600); err != nil {
		h.t.Fatal(err)
	}
}

func (h *harness) removeSecret(app string) {
	h.t.Helper()
	if err := os.Remove(filepath.Join(h.secrets, app, "jobs-secret")); err != nil {
		h.t.Fatal(err)
	}
}

// env builds a valid envelope for job with a given id suffix.
func env(job, id string) string {
	return fmt.Sprintf(`{"v":1,"id":"%026s","job":"%s","payload":{"n":1},"enqueued_at":"2026-03-01T11:00:00Z"}`, id, job)
}

func envAttempt(job, id string, attempt int) string {
	return fmt.Sprintf(`{"v":1,"id":"%026s","job":"%s","payload":null,"enqueued_at":"2026-03-01T11:00:00Z","attempt":%d}`, id, job, attempt)
}

// settle runs passes until cond holds, giving worker goroutines real time to answer. Fake time does not move.
func (h *harness) settle(cond func() bool) {
	h.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		h.c.pass()
		if cond() {
			return
		}
		if time.Now().After(deadline) {
			h.t.Fatalf("condition not reached; log:\n%s", h.logbuf.String())
		}
		time.Sleep(2 * time.Millisecond)
	}
}

// quiet runs n passes with a short real pause after each, for "nothing happens" assertions.
func (h *harness) quiet(n int) {
	for i := 0; i < n; i++ {
		h.c.pass()
		time.Sleep(2 * time.Millisecond)
	}
}

func (h *harness) q(app string) []string    { return h.st.list(app + ":jobs:queue") }
func (h *harness) proc(app string) []string { return h.st.list(app + ":jobs:processing") }
func (h *harness) dead(app string) []string { return h.st.list(app + ":jobs:dead") }

func (h *harness) deadRecord(app string, i int) DeadRecord {
	h.t.Helper()
	d := h.dead(app)
	if i >= len(d) {
		h.t.Fatalf("dead list of %s has %d records, want index %d", app, len(d), i)
	}
	var r DeadRecord
	if err := jsonUnmarshal(d[i], &r); err != nil {
		h.t.Fatalf("dead record is not valid JSON: %v: %q", err, d[i])
	}
	return r
}
