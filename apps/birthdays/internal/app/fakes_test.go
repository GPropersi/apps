package app

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/fstest"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/gpropersi/apps/apps/birthdays/internal/app/db"
	"github.com/gpropersi/apps/apps/birthdays/internal/platform"
)

const (
	testHost  = "app.example.test"
	testEmail = "user@example.test"
)

// fakeStore is an in-memory db.Querier covering the queries the current code paths call; any other query panics (the
// embedded interface is nil), so a handler that starts using one must extend the fake. State changes made inside
// InTx are kept only when fn returns nil, like a transaction. The SQL itself (access rule, CHECKs, cascades) is
// exercised against a real Postgres by test_image.sh, not here.
type fakeStore struct {
	db.Querier
	mu                   sync.Mutex
	arrived              atomic.Int32       // UpsertUser calls started (before taking mu)
	users                map[string]db.User // by email
	jobRuns              map[string]string
	failJob              error // InsertJobRun returns this when set
	failSharedGifts      error // DeleteSharedPersonGifts and DeleteOwnGifts return this when set (a mid-transaction failure)
	nextID               int64 // shared id counter for birthdays and gifts
	birthdays            []fBirthday
	shares               []fShare
	reminders            []fReminder
	gifts                []fGift
	dests                []fDest
	remSent              []fSent
	failRemSent          error     // InsertReminderSent returns this when set (a failed record after a successful send)
	failSetNtfy          error     // SetNtfyUser returns this when set (a failed store after a successful provision)
	failInsertDest       error     // InsertDestination returns this when set
	failUpsertRem        error     // UpsertViewerReminder returns this when set (after the birthday insert in a create)
	failUpdSettings      error     // UpdateSettings returns this when set (after the reminder upsert in a create)
	failAfterUpdSettings error     // UpdateSettings applies the change, then returns this (the default write must still roll back)
	calls                *[]string // shared call log: "tx-begin", "lock", "provision", "tx-end" (nil = not recording)
}

func newFakeStore() *fakeStore {
	return &fakeStore{users: map[string]db.User{}, jobRuns: map[string]string{}}
}

func (s *fakeStore) UpsertUser(_ context.Context, email string) (db.User, error) {
	s.arrived.Add(1) // counted before the lock so a test can see a request is in flight while another holds the tx
	s.mu.Lock()      // concurrent requests (the ntfy double-call test) race with InTx's state swap otherwise
	defer s.mu.Unlock()
	if u, ok := s.users[email]; ok {
		return u, nil
	}
	u := db.User{
		ID: int64(len(s.users) + 1), Email: email, DefaultOffsets: []int16{14, 7, 1},
		StartTab: "auto", ListView: "upcoming", CalendarZoom: "month", ColorScheme: "confetti",
	}
	s.users[email] = u
	return u, nil
}

func (s *fakeStore) InsertJobRun(_ context.Context, arg db.InsertJobRunParams) (int64, error) {
	if s.failJob != nil {
		return 0, s.failJob
	}
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
	cp := &fakeStore{users: map[string]db.User{}, jobRuns: map[string]string{}, failJob: s.failJob, failSharedGifts: s.failSharedGifts, nextID: s.nextID,
		birthdays: slices.Clone(s.birthdays), shares: slices.Clone(s.shares), reminders: slices.Clone(s.reminders),
		gifts: slices.Clone(s.gifts), dests: slices.Clone(s.dests), failSetNtfy: s.failSetNtfy, failInsertDest: s.failInsertDest,
		failUpsertRem: s.failUpsertRem, failUpdSettings: s.failUpdSettings, failAfterUpdSettings: s.failAfterUpdSettings,
		calls: s.calls, remSent: slices.Clone(s.remSent), failRemSent: s.failRemSent}
	s.logCall("tx-begin")
	defer s.logCall("tx-end")
	for k, v := range s.users {
		cp.users[k] = v
	}
	for k, v := range s.jobRuns {
		cp.jobRuns[k] = v
	}
	if err := fn(cp); err != nil {
		return err
	}
	s.users, s.jobRuns, s.nextID = cp.users, cp.jobRuns, cp.nextID
	s.birthdays, s.shares, s.reminders, s.gifts, s.dests = cp.birthdays, cp.shares, cp.reminders, cp.gifts, cp.dests
	s.remSent = cp.remSent
	return nil
}

type fakeQueue struct {
	err       error
	fullAfter int // when > 0, the queue reports ErrQueueFull once this many sends are queued
	calls     []queued
	seenKeys  map[string]bool
}

type queued struct {
	job     string
	key     string
	payload any
}

func (q *fakeQueue) Enqueue(_ context.Context, job string, payload any) (string, error) {
	if q.err != nil {
		return "", q.err
	}
	if q.fullAfter > 0 && len(q.calls) >= q.fullAfter {
		return "", platform.ErrQueueFull
	}
	if job != "send-reminder" {
		return "", platform.ErrUndeclaredJob
	}
	q.calls = append(q.calls, queued{job: job, payload: payload})
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
	q.calls[len(q.calls)-1].key = key
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

// harness drives two routers built from the same Server: h is the real Handler(); probe is the same middleware chain
// (security headers, request log, Auth) with one extra write route, /api/probe on every method, behind stateChanging.
// The write guard is method-agnostic middleware that the real routes reuse, so its rules are tested here without
// depending on any particular birthday route.
type harness struct {
	t          *testing.T
	store      *fakeStore
	queue      *fakeQueue
	h          http.Handler
	probe      http.Handler
	probeHits  atomic.Int64
	probeBytes atomic.Int64
	notifs     *fakeNotifs
	logs       *syncBuffer // everything the server logged
}

// syncBuffer is a concurrency-safe log sink.
type syncBuffer struct {
	mu sync.Mutex
	b  strings.Builder
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	store := newFakeStore()
	queue := &fakeQueue{}
	logs := &syncBuffer{}
	logger := slog.New(slog.NewTextHandler(logs, nil))
	notifs := &fakeNotifs{}
	jobs := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTeapot) // proves /_jobs/* reaches the jobs handler
	})
	srv := &Server{Store: store, Tx: store, Queue: queue, Notifs: notifs, NotifsAppID: "apps_birthdays", Jobs: jobs, Static: testStatic,
		Logger: logger, Auth: fakeAuth.Middleware, EmailOf: fakeAuth.EmailOf}
	hn := &harness{t: t, store: store, queue: queue, h: srv.Handler(), notifs: notifs, logs: logs}

	r := chi.NewRouter()
	r.Use(srv.securityHeaders, srv.requestLog)
	r.Route("/api", func(api chi.Router) {
		api.Use(srv.Auth)
		api.With(srv.stateChanging).HandleFunc("/probe", func(w http.ResponseWriter, r *http.Request) {
			body, tooLarge := readBody(r)
			if tooLarge {
				writeError(w, http.StatusRequestEntityTooLarge, "too_large")
				return
			}
			hn.probeHits.Add(1)
			hn.probeBytes.Add(int64(len(body)))
			w.WriteHeader(http.StatusNoContent)
		})
	})
	hn.probe = r
	return hn
}

type req struct {
	method string
	path   string
	body   string
	header map[string]string
	noAuth bool
	json   bool // sets Content-Type: application/json
	probe  bool // sent to the probe router instead of the real one
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
	h := hn.h
	if r.probe {
		h = hn.probe
	}
	h.ServeHTTP(rec, hr)
	return rec
}

var errBoom = errors.New("boom")
