package app

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gpropersi/apps/apps/tmplgoreact/internal/platform"
)

// fakeNotifs is a platform.Notifier that records its calls. Like delivery-api, Provision returns a password only the
// first time it provisions an email. sendErrs is consumed one entry per Send (a nil entry is a success); once empty,
// Send succeeds.
type fakeNotifs struct {
	mu                 sync.Mutex
	provisioned        map[string]string // email -> user id
	provisionCalls     int
	provisionErr       error
	provisionGate      chan struct{} // when set, Provision signals provisionEntered then waits for it to close
	provisionEntered   chan struct{}
	resetCalls         int
	resetRes           platform.PasswordReset
	resetErr           error
	sends              []platform.Message
	sendErrs           []error
	ensureCalls        int
	ensurePublisherErr error
	lookups            map[int64]bool
	lookupErr          error
	createdID          int64
	createErr          error
	createIn           []platform.PersonalDestinationInput
	deleted            []int64
	deleteErr          error
	onLookup           func() // runs (outside mu) at the start of every lookup: a hook to change state mid-flight
}

func newFakeNotifs() *fakeNotifs {
	return &fakeNotifs{provisioned: map[string]string{}, resetRes: platform.PasswordReset{Password: "reset-pw"}, createdID: 100}
}

func (f *fakeNotifs) Provision(ctx context.Context, email string) (platform.Provisioned, error) {
	f.mu.Lock()
	f.provisionCalls++
	err, gate, entered := f.provisionErr, f.provisionGate, f.provisionEntered
	f.provisionGate, f.provisionEntered = nil, nil // the gate holds the first call only
	f.mu.Unlock()
	if entered != nil {
		select {
		case entered <- struct{}{}:
		default:
		}
	}
	if gate != nil {
		select {
		case <-gate:
		case <-ctx.Done():
			return platform.Provisioned{}, ctx.Err()
		}
	}
	if err != nil {
		return platform.Provisioned{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if id, ok := f.provisioned[email]; ok {
		return platform.Provisioned{UserID: id}, nil // already provisioned: no password
	}
	id := fmt.Sprintf("u-%d", len(f.provisioned)+1)
	f.provisioned[email] = id
	return platform.Provisioned{UserID: id, Password: "first-pw"}, nil
}

func (f *fakeNotifs) ResetPassword(context.Context, string) (platform.PasswordReset, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.resetCalls++
	return f.resetRes, f.resetErr
}

func (f *fakeNotifs) CreatePersonalDestination(_ context.Context, _ string, in platform.PersonalDestinationInput) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.createIn = append(f.createIn, in)
	if f.createErr != nil {
		return 0, f.createErr
	}
	f.createdID++
	return f.createdID, nil
}

func (f *fakeNotifs) DeletePersonalDestination(_ context.Context, _ string, id int64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deleted = append(f.deleted, id)
	return f.deleteErr
}

func (f *fakeNotifs) LookupPersonalDestinations(_ context.Context, _ string, ids []int64) (map[int64]bool, error) {
	f.mu.Lock()
	hook := f.onLookup
	f.mu.Unlock()
	if hook != nil {
		hook()
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.lookupErr != nil {
		return nil, f.lookupErr
	}
	out := map[int64]bool{}
	for _, id := range ids {
		out[id] = f.lookups[id]
	}
	return out, nil
}

func (f *fakeNotifs) Send(_ context.Context, m platform.Message) (platform.Result, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sends = append(f.sends, m)
	if len(f.sendErrs) == 0 {
		return platform.Result{}, nil
	}
	err := f.sendErrs[0]
	f.sendErrs = f.sendErrs[1:]
	return platform.Result{}, err
}

func (f *fakeNotifs) EnsurePublisher(context.Context) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ensureCalls++
	return f.ensurePublisherErr
}

func (f *fakeNotifs) sendCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.sends)
}

func (f *fakeNotifs) createCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.createIn)
}

func (f *fakeNotifs) deletedIDs() []int64 {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]int64(nil), f.deleted...)
}

func (f *fakeNotifs) provisionCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.provisionCalls
}

// logBuf is a slog destination safe for concurrent handlers.
type logBuf struct {
	mu sync.Mutex
	sb strings.Builder
}

func (l *logBuf) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.sb.Write(p)
}

func (l *logBuf) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.sb.String()
}

// testClock is the harness clock: tests move it with advance.
type testClock struct {
	mu sync.Mutex
	t  time.Time
}

func newTestClock() *testClock { return &testClock{t: time.Date(2026, 3, 4, 5, 6, 7, 0, time.UTC)} }

func (c *testClock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *testClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

// notifsEnv is a harness with notifs on, a fake notifier, a log buffer and a clock.
type notifsEnv struct {
	*harness
	n     *fakeNotifs
	logs  *logBuf
	clock *testClock
}

func newNotifsEnv(t *testing.T, name string) *notifsEnv {
	t.Helper()
	n, logs, clock := newFakeNotifs(), &logBuf{}, newTestClock()
	hn := newHarnessWith(t, func(s *Server) {
		s.NotifsEnabled, s.NotifsName, s.NotifsAppID = true, name, "apps_"+strings.ReplaceAll(name, "-", "_")
		s.Notifs = n
		s.Logger = slog.New(slog.NewTextHandler(io.MultiWriter(logs), nil))
		s.Now = clock.now
	})
	return &notifsEnv{harness: hn, n: n, logs: logs, clock: clock}
}
