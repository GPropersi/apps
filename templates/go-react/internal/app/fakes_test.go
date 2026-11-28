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

	"github.com/gpropersi/apps/apps/tmplgoreact/internal/app/db"
	"github.com/gpropersi/apps/apps/tmplgoreact/internal/platform"
)

const (
	testHost  = "app.example.test"
	testEmail = "user@example.test"
)

// fakeStore is an in-memory db.Querier. Its InTx (fakes_tx_test.go) shares the live state and keeps an undo log, so a
// failed or cancelled transaction rolls back like a real one. mu guards one query call at a time and is never held
// across a transaction body. The model is read-uncommitted (other callers see a transaction's writes before it ends), so
// tests assert serialisation, caps, cancellation and rollback, never "invisible until commit". A transaction locks one
// email only.
type fakeStore struct {
	mu          sync.Mutex
	items       []db.Item
	nextItemID  int64
	jobRuns     map[string]string
	ntfyUsers   map[string]string // email -> ntfy user id (notifs_users)
	dests       []destRow         // ordered by id
	nextDestID  int64
	failItems   error // CreateItem returns this when set
	failList    error
	failPhone   error // GetNtfyUserID and GetDestinationCounts return this when set
	failCounts  error // only GetDestinationCounts returns this (a phone read that fails after the mutation)
	failDelete  error // DeleteOwnDestination returns this when set (a local delete failing after the remote one)
	failInsert  error // InsertDestination returns this when set (a local insert failing after the remote create)
	failSetNtfy error // the next SetNtfyUserID in a transaction returns this once (a local write failing after a remote provision)

	lockMu sync.Mutex
	locks  map[string]chan struct{} // per-email transaction locks (LockNotifsEmail)
}

// destRow is one destinations row.
type destRow struct {
	id, notifsID int64
	email, kind  string
	label, hint  string
	stale        bool
}

func newFakeStore() *fakeStore {
	return &fakeStore{jobRuns: map[string]string{}, ntfyUsers: map[string]string{}, locks: map[string]chan struct{}{}}
}

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
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.createItemLocked(arg)
}

func (s *fakeStore) createItemLocked(arg db.CreateItemParams) (db.Item, error) {
	if s.failItems != nil {
		return db.Item{}, s.failItems
	}
	s.nextItemID++
	it := db.Item{
		ID: s.nextItemID, Text: arg.Text, CreatedBy: arg.CreatedBy, Source: arg.Source,
		CreatedAt: pgtype.Timestamptz{Time: time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC), Valid: true},
	}
	s.items = append(s.items, it)
	return it, nil
}

func (s *fakeStore) InsertJobRun(_ context.Context, arg db.InsertJobRunParams) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.jobRuns[arg.IdempotencyKey]; ok {
		return 0, nil
	}
	s.jobRuns[arg.IdempotencyKey] = arg.Job
	return 1, nil
}

func (s *fakeStore) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.items)
}

type fakeQueue struct {
	err      error
	calls    []map[string]string
	seenKeys map[string]bool
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

func (q *fakeQueue) EnqueueUnique(ctx context.Context, job, key string, payload any, _ time.Duration) (string, bool, error) {
	if q.seenKeys == nil {
		q.seenKeys = map[string]bool{}
	}
	if q.seenKeys[job+":"+key] {
		return "", false, nil
	}
	id, err := q.Enqueue(ctx, job, payload)
	if err != nil {
		return "", false, err
	}
	q.seenKeys[job+":"+key] = true
	return id, true, nil
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
	srv   *Server
	h     http.Handler
}

func newHarness(t *testing.T) *harness { return newHarnessWith(t, nil) }

// newHarnessWith builds the harness and lets the test adjust the Server (flags, clock, notifier) before its router is
// built.
func newHarnessWith(t *testing.T, tweak func(*Server)) *harness {
	t.Helper()
	store := newFakeStore()
	queue := &fakeQueue{}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	jobs := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTeapot) // proves /_jobs/* reaches the jobs handler
	})
	srv := &Server{Store: store, Queue: queue, Jobs: jobs, Static: testStatic, Logger: logger,
		Auth: fakeAuth.Middleware, EmailOf: fakeAuth.EmailOf, Tx: store}
	if tweak != nil {
		tweak(srv)
	}
	return &harness{t: t, store: store, queue: queue, srv: srv, h: srv.Handler()}
}

type req struct {
	method string
	path   string
	body   string
	header map[string]string
	noAuth bool
	json   bool // sets Content-Type: application/json
	chunk  bool // the body has no known length (ContentLength -1), like a chunked upload
	ctx    context.Context
}

func (hn *harness) do(r req) *httptest.ResponseRecorder {
	hn.t.Helper()
	hr := httptest.NewRequest(r.method, r.path, strings.NewReader(r.body))
	hr.Host = testHost
	if r.chunk {
		hr.ContentLength = -1
	}
	if r.ctx != nil {
		hr = hr.WithContext(r.ctx)
	}
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
