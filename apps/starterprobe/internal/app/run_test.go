package app

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	app_starterprobe "github.com/gpropersi/apps/apps/starterprobe"
	"github.com/gpropersi/apps/apps/starterprobe/internal/platform"
)

var appYAMLForTest = app_starterprobe.AppYAML

// fakeBackend is a Backend over fakeStore that records the startup calls.
type fakeBackend struct {
	*fakeStore
	migrateErr error
	mu         sync.Mutex
	calls      []string
}

func (b *fakeBackend) Migrate(context.Context) (int, error) {
	b.record("migrate")
	return 1, b.migrateErr
}
func (b *fakeBackend) Close() { b.record("close") }
func (b *fakeBackend) record(s string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.calls = append(b.calls, s)
}

// fakeDeps builds Deps whose listener fails the test if it is ever opened unless allowListen is set.
func fakeDeps(t *testing.T, backend *fakeBackend, allowListen bool) (Deps, *[]string) {
	t.Helper()
	var order []string
	d := Deps{
		Version: "test",
		Logger:  slog.New(slog.NewTextHandler(io.Discard, nil)),
		AppYAML: appYAMLForTest,
		Static:  testStatic,
		Addr:    "127.0.0.1:0",
		LoadConfig: func() (platform.Config, error) {
			order = append(order, "config")
			return platform.Config{JobsSecret: "s3cret"}, nil
		},
		Connect: func(context.Context, platform.Config) (Backend, error) {
			order = append(order, "connect")
			return backend, nil
		},
		NewAuth: func(context.Context, platform.Config) (Auth, error) {
			order = append(order, "auth")
			return fakeAuth, nil
		},
		NewQueue: func(platform.Config, []string) (Enqueuer, io.Closer, error) {
			order = append(order, "queue")
			return &fakeQueue{}, nil, nil
		},
		Listen: func(addr string) (net.Listener, error) {
			if !allowListen {
				t.Error("the listener was opened although startup failed")
				return nil, errors.New("must not listen")
			}
			order = append(order, "listen")
			return net.Listen("tcp", addr)
		},
	}
	return d, &order
}

func TestRunRefusesAJobsMismatchBeforeTheDatabaseAndListener(t *testing.T) {
	backend := &fakeBackend{fakeStore: newFakeStore()}
	d, order := fakeDeps(t, backend, false)
	d.AppYAML = []byte("jobs:\n  - name: add-note\n    timeout: 30s\n  - name: extra-job\n    timeout: 30s\n")
	err := Run(context.Background(), d)
	if err == nil || !strings.Contains(err.Error(), "jobs mismatch") || !strings.Contains(err.Error(), "extra-job") {
		t.Fatalf("Run = %v, want a jobs mismatch naming extra-job", err)
	}
	if got := strings.Join(*order, ","); got != "config" {
		t.Fatalf("startup steps before the mismatch = %q, want only config", got)
	}
	if len(backend.calls) != 0 {
		t.Fatalf("the database was touched before VerifyJobs passed: %v", backend.calls)
	}

	d.AppYAML = []byte("jobs:\n  - name: other\n    timeout: 30s\n")
	if err := Run(context.Background(), d); err == nil || !strings.Contains(err.Error(), "jobs mismatch") {
		t.Fatalf("a declared job with no JobFunc: Run = %v", err)
	}
}

func TestRunMigrationFailureNeverOpensTheListener(t *testing.T) {
	backend := &fakeBackend{fakeStore: newFakeStore(), migrateErr: errors.New("migration 2 failed")}
	d, order := fakeDeps(t, backend, false)
	err := Run(context.Background(), d)
	if err == nil || !strings.Contains(err.Error(), "migration 2 failed") {
		t.Fatalf("Run = %v, want the migration error", err)
	}
	if got := strings.Join(*order, ","); got != "config,connect" {
		t.Fatalf("startup steps = %q, want config,connect (no auth, queue or listen after a failed migration)", got)
	}
	if got := strings.Join(backend.calls, ","); got != "migrate,close" {
		t.Fatalf("backend calls = %s, want migrate,close", got)
	}
}

func TestRunStopsOnEachStartupError(t *testing.T) {
	boom := errors.New("boom")
	for name, mutate := range map[string]func(*Deps){
		"config": func(d *Deps) { d.LoadConfig = func() (platform.Config, error) { return platform.Config{}, boom } },
		"empty jobs secret": func(d *Deps) {
			d.LoadConfig = func() (platform.Config, error) { return platform.Config{}, nil }
		},
		"bad app.yaml": func(d *Deps) { d.AppYAML = []byte(": : :") },
		"connect": func(d *Deps) {
			d.Connect = func(context.Context, platform.Config) (Backend, error) { return nil, boom }
		},
		"auth": func(d *Deps) {
			d.NewAuth = func(context.Context, platform.Config) (Auth, error) { return Auth{}, boom }
		},
		"queue": func(d *Deps) {
			d.NewQueue = func(platform.Config, []string) (Enqueuer, io.Closer, error) { return nil, nil, boom }
		},
	} {
		d, _ := fakeDeps(t, &fakeBackend{fakeStore: newFakeStore()}, false)
		mutate(&d)
		if err := Run(context.Background(), d); err == nil {
			t.Errorf("%s: Run returned nil", name)
		}
	}
}

type closeCounter struct{ n atomic.Int32 }

func (c *closeCounter) Close() error { c.n.Add(1); return nil }

func TestRunClosesTheQueueClientOnShutdown(t *testing.T) {
	backend := &fakeBackend{fakeStore: newFakeStore()}
	d, _ := fakeDeps(t, backend, true)
	cc := &closeCounter{}
	d.NewQueue = func(platform.Config, []string) (Enqueuer, io.Closer, error) { return &fakeQueue{}, cc, nil }
	lnCh := make(chan net.Listener, 1)
	inner := d.Listen
	d.Listen = func(addr string) (net.Listener, error) {
		ln, err := inner(addr)
		lnCh <- ln
		return ln, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- Run(ctx, d) }()
	<-lnCh
	if cc.n.Load() != 0 {
		t.Fatal("the queue client was closed while the server was running")
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("graceful shutdown returned %v", err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("Run did not return after cancel")
	}
	if got := cc.n.Load(); got != 1 {
		t.Fatalf("queue client closed %d times, want 1", got)
	}
}

func TestRunServesThenShutsDownOnCancel(t *testing.T) {
	backend := &fakeBackend{fakeStore: newFakeStore()}
	d, order := fakeDeps(t, backend, true)
	lnCh := make(chan net.Listener, 1)
	inner := d.Listen
	d.Listen = func(addr string) (net.Listener, error) {
		ln, err := inner(addr)
		lnCh <- ln
		return ln, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- Run(ctx, d) }()

	ln := <-lnCh
	if ln == nil {
		cancel()
		t.Fatal("the listener was not opened")
	}
	// The socket is already bound, so the connection queues until Serve accepts it.
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get("http://" + ln.Addr().String() + "/healthz")
	if err != nil {
		cancel()
		t.Fatalf("server never answered: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("healthz = %d", resp.StatusCode)
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("graceful shutdown returned %v", err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("Run did not return after cancel")
	}
	if got := strings.Join(*order, ","); got != "config,connect,auth,queue,listen" {
		t.Fatalf("startup order = %s", got)
	}
	if got := strings.Join(backend.calls, ","); got != "migrate,close" {
		t.Fatalf("backend calls = %s", got)
	}
}
