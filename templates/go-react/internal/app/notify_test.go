package app

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/gpropersi/apps/apps/tmplgoreact/internal/app/db"
)

// notifyRoutes is the one table of the eight notify routes (id 1 where a route has one). wired is flipped by the step
// that lands each handler; every route-list guard test builds its list from the wired entries so the lists cannot drift.
var notifyRoutes = []struct {
	method, path string
	wired        bool
}{
	{"GET", "/api/notify/destinations", false},
	{"POST", "/api/notify/ntfy", false},
	{"POST", "/api/notify/ntfy/reset", false},
	{"POST", "/api/notify/ntfy/test", false},
	{"POST", "/api/notify/destinations", false},
	{"POST", "/api/notify/destinations/1/check", false},
	{"POST", "/api/notify/destinations/1/test", false},
	{"DELETE", "/api/notify/destinations/1", false},
}

func notifsOn(s *Server) { s.NotifsEnabled, s.NotifsName = true, "demo" }

type meBody struct {
	Email  string `json:"email"`
	Notifs bool   `json:"notifs"`
	Phone  *struct {
		Ntfy              bool `json:"ntfy"`
		Destinations      int  `json:"destinations"`
		StaleDestinations int  `json:"stale_destinations"`
	} `json:"phone"`
}

func TestMeWithNotifsDisabledHasNoPhone(t *testing.T) {
	rec := newHarness(t).do(req{method: "GET", path: "/api/me"})
	var got meBody
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || got.Email != testEmail || got.Notifs || got.Phone != nil {
		t.Fatalf("me = %d %q", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"notifs":false`) || strings.Contains(rec.Body.String(), "phone") {
		t.Fatalf("me body %q must carry notifs:false and no phone key", rec.Body.String())
	}
}

func TestMeWithNotifsEnabledReportsAFreshPerson(t *testing.T) {
	// No notifs_users row: the fake returns pgx.ErrNoRows like the real query, which is "not set up", never a 500.
	rec := newHarnessWith(t, notifsOn).do(req{method: "GET", path: "/api/me"})
	var got meBody
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || !got.Notifs || got.Phone == nil || got.Phone.Ntfy || got.Phone.Destinations != 0 || got.Phone.StaleDestinations != 0 {
		t.Fatalf("me = %d %q", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"phone":{"ntfy":false,"destinations":0,"stale_destinations":0}`) {
		t.Fatalf("me body %q", rec.Body.String())
	}
}

func TestMeReadsThePhoneStateByNormalisedEmail(t *testing.T) {
	hn := newHarnessWith(t, notifsOn)
	ctx := context.Background()
	_ = hn.store.SetNtfyUserID(ctx, db.SetNtfyUserIDParams{Email: "user@example.test", NtfyUserID: "u1"})
	for i := 0; i < 2; i++ {
		_, _ = hn.store.InsertDestination(ctx, db.InsertDestinationParams{Email: "user@example.test", NotifsID: int64(i + 1), Kind: "discord", Label: "d", Hint: "abc"})
	}
	_, _ = hn.store.SetOwnDestinationStale(ctx, db.SetOwnDestinationStaleParams{Stale: true, DestinationID: 1, Email: "user@example.test"})
	_, _ = hn.store.InsertDestination(ctx, db.InsertDestinationParams{Email: "other@example.test", NotifsID: 9, Kind: "webhook", Label: "o", Hint: "xyz"})

	rec := hn.do(req{method: "GET", path: "/api/me", header: map[string]string{"X-Test-Email": "  User@Example.TEST "}})
	var got meBody
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || got.Phone == nil || !got.Phone.Ntfy || got.Phone.Destinations != 2 || got.Phone.StaleDestinations != 1 {
		t.Fatalf("me = %d %q", rec.Code, rec.Body.String())
	}
}

func TestMePhoneReadFailureStillAnswers200WithoutPhone(t *testing.T) {
	hn := newHarnessWith(t, notifsOn)
	hn.store.failPhone = errBoom
	rec := hn.do(req{method: "GET", path: "/api/me"})
	var got meBody
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || got.Email != testEmail || !got.Notifs || got.Phone != nil || strings.Contains(rec.Body.String(), "phone") {
		t.Fatalf("me = %d %q", rec.Code, rec.Body.String())
	}
}

func TestPhoneReadFailureLogsNoEmail(t *testing.T) {
	var sb strings.Builder
	hn := newHarnessWith(t, func(s *Server) {
		notifsOn(s)
		s.Logger = slog.New(slog.NewTextHandler(&sb, nil))
	})
	hn.store.failPhone = errBoom
	hn.do(req{method: "GET", path: "/api/me"})
	if !strings.Contains(sb.String(), "phone state read failed") || strings.Contains(sb.String(), testEmail) {
		t.Fatalf("log %q must name the failed step and never the email", sb.String())
	}
}

func TestEveryAPIResponseIsNoStore(t *testing.T) {
	hn := newHarnessWith(t, notifsOn)
	for name, r := range map[string]req{
		"200":     {method: "GET", path: "/api/me"},
		"201":     {method: "POST", path: "/api/items", json: true, body: `{"text":"x"}`},
		"400":     {method: "POST", path: "/api/items", json: true, body: `{}`},
		"401":     {method: "GET", path: "/api/me", noAuth: true},
		"401 bad": {method: "GET", path: "/api/nope", noAuth: true},
		"403":     {method: "POST", path: "/api/items", json: true, body: `{}`, header: map[string]string{"Origin": "https://evil.example"}},
		"404":     {method: "GET", path: "/api/nope"},
		"405":     {method: "DELETE", path: "/api/items"},
		"413":     {method: "POST", path: "/api/items", json: true, body: strings.Repeat("p", 5000)},
		"415":     {method: "POST", path: "/api/items", body: `{}`},
	} {
		rec := hn.do(r)
		if got := rec.Header().Get("Cache-Control"); got != "no-store" {
			t.Errorf("%s (%d): Cache-Control %q, want no-store", name, rec.Code, got)
		}
	}
	// The SPA keeps its own caching.
	if got := hn.do(req{method: "GET", path: "/", noAuth: true}).Header().Get("Cache-Control"); got != "no-cache" {
		t.Errorf("SPA Cache-Control %q, want no-cache", got)
	}
}

func TestNotifyRoutesAreTheJSON404WhenNotifsIsOff(t *testing.T) {
	hn := newHarness(t)
	for _, c := range notifyRoutes {
		rec := hn.do(req{method: c.method, path: c.path, json: true, body: `{}`})
		if rec.Code != 404 {
			t.Errorf("%s %s = %d, want 404 with notifs off", c.method, c.path, rec.Code)
			continue
		}
		wantError(t, rec.Code, rec.Body.String(), "not_found", rec)
	}
}

func TestNotifyEmailTrimsAndLowercases(t *testing.T) {
	hn := newHarness(t)
	for in, want := range map[string]string{" A@B.C ": "a@b.c", "x@y.z": "x@y.z"} {
		hr, _ := http.NewRequest("GET", "/", nil)
		hr = hr.WithContext(context.WithValue(hr.Context(), testIdentityKey{}, in))
		w := &recorder{header: http.Header{}}
		got, ok := hn.srv.notifyEmail(w, hr)
		if !ok || got != want {
			t.Errorf("notifyEmail(%q) = %q, %v, want %q", in, got, ok, want)
		}
	}
	for _, in := range []string{"", "   "} {
		hr, _ := http.NewRequest("GET", "/", nil)
		hr = hr.WithContext(context.WithValue(hr.Context(), testIdentityKey{}, in))
		w := &recorder{header: http.Header{}}
		if _, ok := hn.srv.notifyEmail(w, hr); ok || w.status != 401 {
			t.Errorf("notifyEmail(%q) ok=%v status=%d, want 401", in, ok, w.status)
		}
	}
}

func TestServerClockAndLimiterAreLazy(t *testing.T) {
	now := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	s := &Server{}
	if d := time.Since(s.now()); d < 0 || d > time.Minute {
		t.Fatalf("a nil Now must read time.Now, got offset %v", d)
	}
	s.Now = func() time.Time { return now }
	l := s.testLimiter()
	if l != s.testLimiter() {
		t.Fatal("the limiter must be created once")
	}
	if _, ok := l.Allow("k"); !ok {
		t.Fatal("first send must be allowed")
	}
	if _, ok := l.Allow("k"); ok {
		t.Fatal("second send within the cooldown must be refused")
	}
	now = now.Add(testCooldown + time.Second) // the limiter reads the clock late, through s.Now
	if _, ok := l.Allow("k"); !ok {
		t.Fatal("after the cooldown the send must be allowed")
	}
}

// ---- production wiring -------------------------------------------------------------------------------------------------

func TestProductionNotifsFailsClosed(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	for name, c := range map[string]struct {
		yaml    string
		wantID  string
		wantNil bool
	}{
		"absent":         {"name: demo\n", "", true},
		"false":          {"name: demo\nnotifs: false\n", "", true},
		"true":           {"name: demo-app\nnotifs: true\n", "apps_demo_app", false},
		"unparsable":     {": : :", "", true},
		"invalid name":   {"name: Bad_Name!\nnotifs: true\n", "", true},
		"missing name":   {"notifs: true\n", "", true},
		"wrong type":     {"name: demo\nnotifs: [1]\n", "", true},
		"template yaml":  {string(appYAMLForTest), "", true},
		"notifs as text": {"name: demo\nnotifs: \"yes please\"\n", "", true},
	} {
		if name == "template yaml" && strings.Contains("\n"+c.yaml, "\nnotifs: true\n") {
			// A scaffold test appends `notifs: true` to the template's app.yaml (platform/scaffold/test_app_new.sh), and an
			// app opts in the same way: the flag-on result is the contract, an app_<name> id with a notifier.
			c.wantNil, c.wantID = false, "apps_"+strings.ReplaceAll(declaredName(c.yaml), "-", "_")
		}
		n, id := productionNotifs([]byte(c.yaml), log)
		if (n == nil) != c.wantNil || id != c.wantID {
			t.Errorf("%s: notifier nil=%v appID=%q, want nil=%v appID=%q", name, n == nil, id, c.wantNil, c.wantID)
		}
	}
}

// declaredName reads the top-level `name:` line of an app.yaml text.
func declaredName(yaml string) string {
	for _, line := range strings.Split(yaml, "\n") {
		if v, ok := strings.CutPrefix(line, "name: "); ok {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

func TestRunEnablesNotifsFromAppYAMLAndFailsClosedOnBadYAML(t *testing.T) {
	for name, c := range map[string]struct {
		yaml string
		want bool
	}{
		"on":  {"name: demo\nnotifs: true\njobs:\n  - name: add-note\n    timeout: 30s\n", true},
		"off": {"name: demo\njobs:\n  - name: add-note\n    timeout: 30s\n", false},
	} {
		d, _ := fakeDeps(t, &fakeBackend{fakeStore: newFakeStore()}, true)
		d.AppYAML = []byte(c.yaml)
		startRun(t, d, func(base string) {
			hr, _ := http.NewRequest("GET", base+"/api/me", nil)
			hr.Header.Set("X-Test-Email", testEmail)
			resp, err := http.DefaultClient.Do(hr)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = resp.Body.Close() }()
			b, _ := io.ReadAll(resp.Body)
			var got meBody
			decode(t, string(b), &got)
			if resp.StatusCode != 200 || got.Notifs != c.want || (got.Phone != nil) != c.want {
				t.Errorf("%s: /api/me = %d %s, want notifs %v", name, resp.StatusCode, b, c.want)
			}
		})
	}
}

// ---- the fake store's transaction model ---------------------------------------------------------------------------

func TestFakeGetNtfyUserIDReturnsTheRealNoRowsError(t *testing.T) {
	s := newFakeStore()
	if _, err := s.GetNtfyUserID(context.Background(), "a@b.c"); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("missing row = %v, want pgx.ErrNoRows", err)
	}
	if _, err := s.GetOwnDestination(context.Background(), db.GetOwnDestinationParams{DestinationID: 1, Email: "a@b.c"}); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("missing destination = %v, want pgx.ErrNoRows", err)
	}
}

func TestFakeDestinationsAreScopedByEmail(t *testing.T) {
	ctx := context.Background()
	s := newFakeStore()
	row, _ := s.InsertDestination(ctx, db.InsertDestinationParams{Email: "a@x.y", NotifsID: 5, Kind: "discord", Label: "l", Hint: "h"})
	if _, err := s.GetOwnDestination(ctx, db.GetOwnDestinationParams{DestinationID: row.ID, Email: "b@x.y"}); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("another person's id = %v, want missing", err)
	}
	if n, _ := s.SetOwnDestinationStale(ctx, db.SetOwnDestinationStaleParams{Stale: true, DestinationID: row.ID, Email: "b@x.y"}); n != 0 {
		t.Fatal("another person's destination was staled")
	}
	if n, _ := s.DeleteOwnDestination(ctx, db.DeleteOwnDestinationParams{DestinationID: row.ID, Email: "b@x.y"}); n != 0 {
		t.Fatal("another person's destination was deleted")
	}
	if n, _ := s.CountDestinations(ctx, "a@x.y"); n != 1 {
		t.Fatalf("count = %d, want 1", n)
	}
}

func TestFakeInTxRollsBackEveryWriteOnError(t *testing.T) {
	ctx := context.Background()
	s := newFakeStore()
	keep, _ := s.InsertDestination(ctx, db.InsertDestinationParams{Email: "a@x.y", NotifsID: 1, Kind: "discord", Label: "keep", Hint: "h"})
	err := s.InTx(ctx, func(q db.Querier) error {
		_ = q.SetNtfyUserID(ctx, db.SetNtfyUserIDParams{Email: "a@x.y", NtfyUserID: "u"})
		_, _ = q.InsertDestination(ctx, db.InsertDestinationParams{Email: "a@x.y", NotifsID: 2, Kind: "webhook", Label: "new", Hint: "h"})
		_, _ = q.SetOwnDestinationStale(ctx, db.SetOwnDestinationStaleParams{Stale: true, DestinationID: keep.ID, Email: "a@x.y"})
		_, _ = q.CreateItem(ctx, db.CreateItemParams{Text: "t", CreatedBy: "c", Source: "task"})
		_, _ = q.InsertJobRun(ctx, db.InsertJobRunParams{IdempotencyKey: "k", Job: "j"})
		if n, _ := q.DeleteOwnDestination(ctx, db.DeleteOwnDestinationParams{DestinationID: keep.ID, Email: "a@x.y"}); n != 1 {
			t.Fatal("delete inside the transaction did not see the live row")
		}
		return errBoom
	})
	if !errors.Is(err, errBoom) {
		t.Fatalf("InTx = %v, want the callback error", err)
	}
	rows, _ := s.ListDestinations(ctx, "a@x.y")
	if len(rows) != 1 || rows[0].ID != keep.ID || rows[0].Stale {
		t.Fatalf("destinations after rollback = %+v, want the original untouched row", rows)
	}
	if _, err := s.GetNtfyUserID(ctx, "a@x.y"); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("ntfy user survived the rollback: %v", err)
	}
	if len(s.items) != 0 || len(s.jobRuns) != 0 {
		t.Fatalf("items %d, job_runs %v survived the rollback", len(s.items), s.jobRuns)
	}
}

func TestFakeSetNtfyUserIDIsIdempotentAndItsRollbackKeepsTheOldRow(t *testing.T) {
	ctx := context.Background()
	s := newFakeStore()
	_ = s.SetNtfyUserID(ctx, db.SetNtfyUserIDParams{Email: "a@x.y", NtfyUserID: "first"})
	_ = s.InTx(ctx, func(q db.Querier) error {
		_ = q.SetNtfyUserID(ctx, db.SetNtfyUserIDParams{Email: "a@x.y", NtfyUserID: "second"})
		return errBoom
	})
	if id, err := s.GetNtfyUserID(ctx, "a@x.y"); err != nil || id != "first" {
		t.Fatalf("ntfy id = %q, %v, want the original row (ON CONFLICT DO NOTHING, rollback keeps it)", id, err)
	}
}

func TestFakeInTxRollsBackWhenTheBodyPanics(t *testing.T) {
	ctx := context.Background()
	s := newFakeStore()
	func() {
		defer func() { _ = recover() }()
		_ = s.InTx(ctx, func(q db.Querier) error {
			_ = q.LockNotifsEmail(ctx, "a@x.y")
			_ = q.SetNtfyUserID(ctx, db.SetNtfyUserIDParams{Email: "a@x.y", NtfyUserID: "u"})
			panic("boom")
		})
	}()
	if _, err := s.GetNtfyUserID(ctx, "a@x.y"); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatal("a write survived a panicking transaction")
	}
	if err := s.InTx(ctx, func(q db.Querier) error { return q.LockNotifsEmail(ctx, "a@x.y") }); err != nil {
		t.Fatalf("the lock leaked after a panic: %v", err)
	}
}

func TestFakeInTxCommitsOnSuccess(t *testing.T) {
	ctx := context.Background()
	s := newFakeStore()
	if err := s.InTx(ctx, func(q db.Querier) error {
		if err := q.LockNotifsEmail(ctx, "a@x.y"); err != nil {
			return err
		}
		return q.SetNtfyUserID(ctx, db.SetNtfyUserIDParams{Email: "a@x.y", NtfyUserID: "u"})
	}); err != nil {
		t.Fatal(err)
	}
	if id, err := s.GetNtfyUserID(ctx, "a@x.y"); err != nil || id != "u" {
		t.Fatalf("after commit = %q, %v", id, err)
	}
}

func TestFakeInTxRollsBackWhenTheContextEnds(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	s := newFakeStore()
	err := s.InTx(ctx, func(q db.Querier) error {
		_ = q.SetNtfyUserID(ctx, db.SetNtfyUserIDParams{Email: "a@x.y", NtfyUserID: "u"})
		cancel()
		return nil
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("InTx = %v, want context.Canceled", err)
	}
	if _, err := s.GetNtfyUserID(context.Background(), "a@x.y"); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatal("a write survived a cancelled transaction")
	}
}

func TestFakeLockSerialisesSameEmailAndHonoursContext(t *testing.T) {
	ctx := context.Background()
	s := newFakeStore()
	held := make(chan struct{})
	release := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		_ = s.InTx(ctx, func(q db.Querier) error {
			if err := q.LockNotifsEmail(ctx, "a@x.y"); err != nil {
				return err
			}
			close(held)
			<-release
			return nil
		})
	}()
	<-held

	// A different email is not blocked; the same email waits and gives up when its context ends.
	if err := s.InTx(ctx, func(q db.Querier) error { return q.LockNotifsEmail(ctx, "b@x.y") }); err != nil {
		t.Fatalf("a different email blocked: %v", err)
	}
	waitCtx, cancel := context.WithTimeout(ctx, 50*time.Millisecond)
	defer cancel()
	err := s.InTx(waitCtx, func(q db.Querier) error { return q.LockNotifsEmail(waitCtx, "a@x.y") })
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("a waiting lock = %v, want the context error", err)
	}

	// While one transaction holds the lock no query method of another blocks (mu is never held across a body).
	if _, err := s.CountDestinations(ctx, "a@x.y"); err != nil {
		t.Fatal(err)
	}
	close(release)
	wg.Wait()
	if err := s.InTx(ctx, func(q db.Querier) error { return q.LockNotifsEmail(ctx, "a@x.y") }); err != nil {
		t.Fatalf("the lock was not released: %v", err)
	}
}
