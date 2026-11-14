package app

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"testing/fstest"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/gpropersi/apps/apps/starterprobe/internal/app/db"
	"github.com/gpropersi/apps/apps/starterprobe/internal/platform"
)

const (
	testHost  = "app.example.test"
	testEmail = "user@example.test"
)

// fakeStore is an in-memory db.Querier. State changes made inside InTx are kept only when fn returns nil, like a
// transaction.
type fakeStore struct {
	mu        sync.Mutex
	items     []db.Item
	jobRuns   map[string]string
	failItems error // CreateItem returns this when set
	failList  error
}

func newFakeStore() *fakeStore { return &fakeStore{jobRuns: map[string]string{}} }

func (s *fakeStore) ListItems(context.Context) ([]db.Item, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failList != nil {
		return nil, s.failList
	}
	out := make([]db.Item, 0, len(s.items))
	for i := len(s.items) - 1; i >= 0; i-- { // newest first
		out = append(out, s.items[i])
	}
	if len(out) > 50 {
		out = out[:50]
	}
	return out, nil
}

func (s *fakeStore) CreateItem(_ context.Context, arg db.CreateItemParams) (db.Item, error) {
	if s.failItems != nil {
		return db.Item{}, s.failItems
	}
	it := db.Item{
		ID: int64(len(s.items) + 1), Text: arg.Text, CreatedBy: arg.CreatedBy, Source: arg.Source,
		CreatedAt: pgtype.Timestamptz{Time: time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC), Valid: true},
	}
	s.items = append(s.items, it)
	return it, nil
}

func (s *fakeStore) InsertJobRun(_ context.Context, arg db.InsertJobRunParams) (int64, error) {
	if _, ok := s.jobRuns[arg.IdempotencyKey]; ok {
		return 0, nil
	}
	s.jobRuns[arg.IdempotencyKey] = arg.Job
	return 1, nil
}

// InTx runs fn against a copy and keeps the changes only on success.
func (s *fakeStore) InTx(_ context.Context, fn func(db.Querier) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	cp := &fakeStore{items: append([]db.Item(nil), s.items...), jobRuns: map[string]string{}, failItems: s.failItems}
	for k, v := range s.jobRuns {
		cp.jobRuns[k] = v
	}
	if err := fn(cp); err != nil {
		return err
	}
	s.items, s.jobRuns = cp.items, cp.jobRuns
	return nil
}

func (s *fakeStore) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.items)
}

type fakeQueue struct {
	err   error
	calls []map[string]string
}

func (q *fakeQueue) Enqueue(_ context.Context, job string, payload any) (string, error) {
	if q.err != nil {
		return "", q.err
	}
	if job != "add-note" {
		return "", platform.ErrUndeclaredJob
	}
	q.calls = append(q.calls, payload.(map[string]string))
	return "01JTESTULID0000000000000000", nil
}

type testIdentityKey struct{}

// fakeAuth stands in for Cloudflare Access: the X-Test-Email header is the identity, and no header is a 401.
var fakeAuth = Auth{
	Middleware: func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			email := r.Header.Get("X-Test-Email")
			if email == "" {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusUnauthorized)
				_, _ = io.WriteString(w, `{"error":"unauthenticated"}`)
				return
			}
			next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), testIdentityKey{}, email)))
		})
	},
	EmailOf: func(r *http.Request) (string, bool) {
		email, ok := r.Context().Value(testIdentityKey{}).(string)
		return email, ok
	},
}

var testStatic = fstest.MapFS{
	"index.html":           {Data: []byte("<!doctype html><title>spa</title>")},
	"assets/app-abc123.js": {Data: []byte("console.log(1)")},
	"robots.txt":           {Data: []byte("User-agent: *\n")},
}

type harness struct {
	t     *testing.T
	store *fakeStore
	queue *fakeQueue
	h     http.Handler
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	store := newFakeStore()
	queue := &fakeQueue{}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	jobs := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTeapot) // proves /_jobs/* reaches the jobs handler
	})
	srv := &Server{Store: store, Queue: queue, Jobs: jobs, Static: testStatic, Logger: logger,
		Auth: fakeAuth.Middleware, EmailOf: fakeAuth.EmailOf}
	return &harness{t: t, store: store, queue: queue, h: srv.Handler()}
}

type req struct {
	method string
	path   string
	body   string
	header map[string]string
	noAuth bool
	json   bool // sets Content-Type: application/json
}

func (hn *harness) do(r req) *httptest.ResponseRecorder {
	hn.t.Helper()
	hr := httptest.NewRequest(r.method, r.path, strings.NewReader(r.body))
	hr.Host = testHost
	if !r.noAuth {
		hr.Header.Set("X-Test-Email", testEmail)
	}
	if r.json {
		hr.Header.Set("Content-Type", "application/json")
	}
	for k, v := range r.header {
		hr.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	hn.h.ServeHTTP(rec, hr)
	return rec
}

var errBoom = errors.New("boom")
