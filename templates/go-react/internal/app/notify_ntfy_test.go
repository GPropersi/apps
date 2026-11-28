package app

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gpropersi/apps/apps/tmplgoreact/internal/app/db"
	"github.com/gpropersi/apps/apps/tmplgoreact/internal/platform"
)

func ntfyPost(path string) req { return req{method: "POST", path: path, json: true, body: `{}`} }

type ntfyBody struct {
	UserID   string  `json:"user_id"`
	SetupURL string  `json:"setup_url"`
	Password *string `json:"password"`
	Phone    *struct {
		Ntfy              bool `json:"ntfy"`
		Destinations      int  `json:"destinations"`
		StaleDestinations int  `json:"stale_destinations"`
	} `json:"phone"`
}

func (e *notifsEnv) setUp(t *testing.T) {
	t.Helper()
	if rec := e.do(ntfyPost("/api/notify/ntfy")); rec.Code != 200 {
		t.Fatalf("setup = %d %s", rec.Code, rec.Body.String())
	}
}

// ---- POST /api/notify/ntfy -------------------------------------------------------------------------------------------

func TestNtfyFirstProvisionReturnsThePasswordOnceAndRepeatReturnsNull(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	rec := e.do(ntfyPost("/api/notify/ntfy"))
	var got ntfyBody
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || got.Password == nil || *got.Password != "first-pw" || got.UserID != "u-1" {
		t.Fatalf("first = %d %s", rec.Code, rec.Body.String())
	}
	if got.SetupURL != "https://notifs-setup.4irl.app/?app=apps_demo&user=u-1&name=demo" {
		t.Fatalf("setup_url = %q", got.SetupURL)
	}
	if got.Phone == nil || !got.Phone.Ntfy {
		t.Fatalf("phone = %+v, want ntfy true", got.Phone)
	}

	rec = e.do(ntfyPost("/api/notify/ntfy"))
	got = ntfyBody{}
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || got.Password != nil || !strings.Contains(rec.Body.String(), `"password":null`) || got.UserID != "u-1" {
		t.Fatalf("repeat = %d %s", rec.Code, rec.Body.String())
	}
	if n := e.n.provisionCount(); n != 1 {
		t.Fatalf("Provision calls = %d, want 1", n)
	}
}

func TestNtfyUsesTheNormalisedEmailForTheRowAndTheNotifier(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	rec := e.do(req{method: "POST", path: "/api/notify/ntfy", json: true, body: `{}`, header: map[string]string{"X-Test-Email": "  User@Example.TEST "}})
	if rec.Code != 200 {
		t.Fatalf("= %d %s", rec.Code, rec.Body.String())
	}
	if _, ok := e.n.provisioned["user@example.test"]; !ok {
		t.Fatalf("provisioned %v, want the normalised email", e.n.provisioned)
	}
	if _, ok := e.store.ntfyUsers["user@example.test"]; !ok {
		t.Fatalf("rows %v, want the normalised email", e.store.ntfyUsers)
	}
}

func TestNtfyWithAHyphenatedAppNameUsesItVerbatimInTheLinkAndTheTitle(t *testing.T) {
	e := newNotifsEnv(t, "my-app")
	rec := e.do(ntfyPost("/api/notify/ntfy"))
	var got ntfyBody
	decode(t, rec.Body.String(), &got)
	if got.SetupURL != "https://notifs-setup.4irl.app/?app=apps_my_app&user=u-1&name=my-app" {
		t.Fatalf("setup_url = %q", got.SetupURL)
	}
	if rec := e.do(ntfyPost("/api/notify/ntfy/test")); rec.Code != 200 {
		t.Fatalf("test = %d %s", rec.Code, rec.Body.String())
	}
	if e.n.sends[0].Title != "my-app test notification" {
		t.Fatalf("title = %q", e.n.sends[0].Title)
	}
}

func TestNtfyWithNoNotifierAnswersNotifyUnavailable(t *testing.T) {
	// The flag is on but the notifier is not configured: every notify call fails closed, never a panic or a 404.
	hn := newHarnessWith(t, func(s *Server) { s.NotifsEnabled, s.NotifsName = true, "demo" })
	_ = hn.store.SetNtfyUserID(context.Background(), db.SetNtfyUserIDParams{Email: testEmail, NtfyUserID: "u-1"})
	for _, path := range []string{"/api/notify/ntfy", "/api/notify/ntfy/reset", "/api/notify/ntfy/test"} {
		rec := hn.do(ntfyPost(path))
		if rec.Code != 500 {
			t.Errorf("%s = %d, want 500", path, rec.Code)
			continue
		}
		wantError(t, rec.Code, rec.Body.String(), "notify_unavailable", rec)
	}
}

func TestNtfyProvisionFailureIsNotifyUnavailableAndStoresNothing(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	e.n.provisionErr = &platform.NotifsError{Status: 503, Message: "down"}
	rec := e.do(ntfyPost("/api/notify/ntfy"))
	wantError(t, rec.Code, rec.Body.String(), "notify_unavailable", rec)
	if rec.Code != 500 || len(e.store.ntfyUsers) != 0 {
		t.Fatalf("= %d, rows %v", rec.Code, e.store.ntfyUsers)
	}
}

func TestNtfyProvisionSucceedsButTheLocalWriteFails(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	e.store.failSetNtfy = errBoom
	rec := e.do(ntfyPost("/api/notify/ntfy"))
	if rec.Code != 500 {
		t.Fatalf("= %d %s", rec.Code, rec.Body.String())
	}
	wantError(t, rec.Code, rec.Body.String(), "internal", rec)
	if strings.Contains(rec.Body.String(), "first-pw") || strings.Contains(e.logs.String(), "first-pw") {
		t.Fatal("the one-time password reached the body or the log")
	}
	if len(e.store.ntfyUsers) != 0 {
		t.Fatalf("rows %v, want none", e.store.ntfyUsers)
	}

	// Recovery: Set up again finds the remote person (password null) and writes the missing row; Generate then works.
	rec = e.do(ntfyPost("/api/notify/ntfy"))
	var got ntfyBody
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || got.Password != nil || len(e.store.ntfyUsers) != 1 {
		t.Fatalf("retry = %d %s rows %v", rec.Code, rec.Body.String(), e.store.ntfyUsers)
	}
	rec = e.do(ntfyPost("/api/notify/ntfy/reset"))
	var reset struct{ Password string }
	decode(t, rec.Body.String(), &reset)
	if rec.Code != 200 || reset.Password != "reset-pw" {
		t.Fatalf("reset = %d %s", rec.Code, rec.Body.String())
	}
}

func TestNtfyPhoneReadFailingAfterTheMutationKeepsTheSecretAndTheRow(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	e.store.failCounts = errBoom
	rec := e.do(ntfyPost("/api/notify/ntfy"))
	var got ntfyBody
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || got.Password == nil || *got.Password != "first-pw" || strings.Contains(rec.Body.String(), "phone") {
		t.Fatalf("provision = %d %s, want 200 with the password and no phone", rec.Code, rec.Body.String())
	}
	if _, ok := e.store.ntfyUsers[testEmail]; !ok {
		t.Fatal("the notifs_users row did not commit")
	}

	rec = e.do(ntfyPost("/api/notify/ntfy/reset"))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"password":"reset-pw"`) || strings.Contains(rec.Body.String(), "phone") {
		t.Fatalf("reset = %d %s", rec.Code, rec.Body.String())
	}
	rec = e.do(ntfyPost("/api/notify/ntfy/test"))
	if rec.Code != 200 || strings.Contains(rec.Body.String(), "phone") {
		t.Fatalf("test = %d %s", rec.Code, rec.Body.String())
	}
	logs := e.logs.String()
	if !strings.Contains(logs, "phone state read failed") {
		t.Fatalf("log %q must name the failed step", logs)
	}
	for _, secret := range []string{"first-pw", "reset-pw", testEmail} {
		if strings.Contains(logs, secret) {
			t.Fatalf("log holds %q: %s", secret, logs)
		}
	}
}

func TestNtfyLogsNeverHoldASecretAURLOrAnEmailOnFailure(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	leak := &platform.NotifsError{Status: 500, Message: "bad user@example.test pw-secret https://hooks.example/abc"}
	e.n.provisionErr = leak
	e.do(ntfyPost("/api/notify/ntfy"))
	e.n.provisionErr = nil
	e.setUp(t)
	e.n.resetErr = leak
	e.do(ntfyPost("/api/notify/ntfy/reset"))
	e.n.sendErrs = []error{leak}
	e.do(ntfyPost("/api/notify/ntfy/test"))
	logs := e.logs.String()
	if !strings.Contains(logs, "notify failed") {
		t.Fatalf("log %q must record the failures", logs)
	}
	for _, bad := range []string{"user@example.test", "pw-secret", "https://hooks", "first-pw"} {
		if strings.Contains(logs, bad) {
			t.Fatalf("log holds %q: %s", bad, logs)
		}
	}
}

func TestNtfyConcurrentFirstProvisionsIssueOnePasswordAndOneProvision(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	gate, entered := make(chan struct{}), make(chan struct{}, 1)
	e.n.provisionGate, e.n.provisionEntered = gate, entered
	recs := make([]*httptest.ResponseRecorder, 2)
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); recs[0] = e.do(ntfyPost("/api/notify/ntfy")) }()
	<-entered // the first call holds the lock inside Provision
	go func() { defer wg.Done(); recs[1] = e.do(ntfyPost("/api/notify/ntfy")) }()
	time.Sleep(20 * time.Millisecond) // let the second reach the lock; the assertions hold either way
	close(gate)
	wg.Wait()
	passwords := 0
	for _, rec := range recs {
		var got ntfyBody
		decode(t, rec.Body.String(), &got)
		if rec.Code != 200 {
			t.Fatalf("= %d %s", rec.Code, rec.Body.String())
		}
		if got.Password != nil {
			passwords++
		}
	}
	if passwords != 1 || e.n.provisionCount() != 1 {
		t.Fatalf("passwords %d, Provision calls %d, want 1 and 1", passwords, e.n.provisionCount())
	}
}

func TestNtfyLockWaitEndsOnCancelReleasesTheLockAndNeverBlocksAnotherPerson(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	gate, entered := make(chan struct{}), make(chan struct{}, 1)
	e.n.provisionGate, e.n.provisionEntered = gate, entered
	first := make(chan *httptest.ResponseRecorder, 1)
	go func() { first <- e.do(ntfyPost("/api/notify/ntfy")) }()
	<-entered

	// A different person is not blocked (the gate holds the first Provision call only).
	if rec := e.do(req{method: "POST", path: "/api/notify/ntfy", json: true, body: `{}`, header: map[string]string{"X-Test-Email": "b@example.test"}}); rec.Code != 200 {
		t.Fatalf("another person = %d", rec.Code)
	}

	// The same person waits on the lock and ends with a context error when cancelled; its writes are undone.
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	rec := e.do(req{method: "POST", path: "/api/notify/ntfy", json: true, body: `{}`, ctx: ctx})
	if rec.Code != 500 {
		t.Fatalf("a cancelled waiter = %d %s, want 500", rec.Code, rec.Body.String())
	}
	if n := e.n.provisionCount(); n != 2 { // the holder and the other person; never the waiter
		t.Fatalf("Provision calls = %d, the waiter must never reach it", n)
	}

	close(gate)
	if rec := <-first; rec.Code != 200 {
		t.Fatalf("holder = %d", rec.Code)
	}
	// The lock is free for the next caller, which sees the stored row.
	rec = e.do(ntfyPost("/api/notify/ntfy"))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"password":null`) {
		t.Fatalf("next caller = %d %s", rec.Code, rec.Body.String())
	}
}

// ---- POST /api/notify/ntfy/reset -------------------------------------------------------------------------------------

func TestNtfyResetAndTestAre409ForAPersonWhoIsNotSetUp(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	for _, path := range []string{"/api/notify/ntfy/reset", "/api/notify/ntfy/test"} {
		rec := e.do(ntfyPost(path))
		if rec.Code != 409 {
			t.Fatalf("%s = %d %s, want 409", path, rec.Code, rec.Body.String())
		}
		wantError(t, rec.Code, rec.Body.String(), "ntfy_not_set_up", rec)
	}
	if e.n.resetCalls != 0 || e.n.sendCount() != 0 {
		t.Fatal("a not-set-up person reached the notifier")
	}
	// The 409 did not start the cooldown.
	e.setUp(t)
	if rec := e.do(ntfyPost("/api/notify/ntfy/test")); rec.Code != 200 {
		t.Fatalf("first real test = %d %s", rec.Code, rec.Body.String())
	}
}

func TestNtfyResetReturnsANewPasswordAndTheSetupLink(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	e.setUp(t)
	rec := e.do(ntfyPost("/api/notify/ntfy/reset"))
	var got ntfyBody
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || got.Password == nil || *got.Password != "reset-pw" || got.Phone == nil || !got.Phone.Ntfy {
		t.Fatalf("reset = %d %s", rec.Code, rec.Body.String())
	}
	if got.SetupURL != "https://notifs-setup.4irl.app/?app=apps_demo&user=u-1&name=demo" {
		t.Fatalf("setup_url = %q (the stored id is used when the answer carries none)", got.SetupURL)
	}
	e.n.resetRes = platform.PasswordReset{UserID: "u-9", Password: "p2"}
	rec = e.do(ntfyPost("/api/notify/ntfy/reset"))
	decode(t, rec.Body.String(), &got)
	if !strings.Contains(got.SetupURL, "user=u-9") {
		t.Fatalf("setup_url = %q, want the id of the answer", got.SetupURL)
	}
}

func TestNtfyResetErrorMapping(t *testing.T) {
	for name, c := range map[string]struct {
		err    error
		pw     string
		status int
		code   string
	}{
		"404 means not set up":  {&platform.NotifsError{Status: 404, Message: "user does not exist"}, "x", 409, "ntfy_not_set_up"},
		"429":                   {&platform.NotifsError{Status: 429, Message: "slow"}, "x", 429, "rate_limited"},
		"other":                 {&platform.NotifsError{Status: 500, Message: "boom"}, "x", 500, "notify_unavailable"},
		"unconfigured":          {platform.ErrNotifsUnconfigured, "x", 500, "notify_unavailable"},
		"empty password is 500": {nil, "", 500, "notify_unavailable"},
	} {
		e := newNotifsEnv(t, "demo")
		e.setUp(t)
		e.n.resetErr = c.err
		e.n.resetRes = platform.PasswordReset{Password: c.pw}
		rec := e.do(ntfyPost("/api/notify/ntfy/reset"))
		if rec.Code != c.status {
			t.Errorf("%s: = %d %s, want %d", name, rec.Code, rec.Body.String(), c.status)
			continue
		}
		wantError(t, rec.Code, rec.Body.String(), c.code, rec)
	}
}

// ---- POST /api/notify/ntfy/test --------------------------------------------------------------------------------------

func TestNtfyTestSendsAndAnswersThePhoneState(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	e.setUp(t)
	rec := e.do(ntfyPost("/api/notify/ntfy/test"))
	var got ntfyBody
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || got.Phone == nil || !got.Phone.Ntfy {
		t.Fatalf("test = %d %s", rec.Code, rec.Body.String())
	}
	m := e.n.sends[0]
	if m.Recipient != testEmail || m.Via != "ntfy" || m.Channel != "all" || m.Title != "demo test notification" || m.Body != testBody {
		t.Fatalf("message = %+v", m)
	}
}

func TestNtfyTestCooldownIs429WithRetryAfterAndAFailedSendCounts(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	e.setUp(t)
	e.n.sendErrs = []error{&platform.NotifsError{Status: 500, Message: "boom"}}
	if rec := e.do(ntfyPost("/api/notify/ntfy/test")); rec.Code != 500 {
		t.Fatalf("failing send = %d", rec.Code)
	}
	rec := e.do(ntfyPost("/api/notify/ntfy/test"))
	wantError(t, rec.Code, rec.Body.String(), "rate_limited", rec)
	if rec.Code != 429 || rec.Header().Get("Retry-After") != "30" {
		t.Fatalf("cooldown = %d, Retry-After %q (a failed send must start it)", rec.Code, rec.Header().Get("Retry-After"))
	}
	e.clock.advance(10*time.Second + 500*time.Millisecond)
	if rec := e.do(ntfyPost("/api/notify/ntfy/test")); rec.Header().Get("Retry-After") != "20" {
		t.Fatalf("Retry-After %q, want the rounded-up 20", rec.Header().Get("Retry-After"))
	}
	e.clock.advance(20 * time.Second)
	if rec := e.do(ntfyPost("/api/notify/ntfy/test")); rec.Code != 200 {
		t.Fatalf("after the cooldown = %d %s", rec.Code, rec.Body.String())
	}
	if n := e.n.sendCount(); n != 2 {
		t.Fatalf("sends = %d, want 2 (the limited calls never send)", n)
	}
}

func TestNtfyTestCooldownsAreIndependentPerPerson(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	other := map[string]string{"X-Test-Email": "b@example.test"}
	e.setUp(t)
	if rec := e.do(req{method: "POST", path: "/api/notify/ntfy", json: true, body: `{}`, header: other}); rec.Code != 200 {
		t.Fatal(rec.Code)
	}
	if rec := e.do(ntfyPost("/api/notify/ntfy/test")); rec.Code != 200 {
		t.Fatalf("a = %d", rec.Code)
	}
	if rec := e.do(req{method: "POST", path: "/api/notify/ntfy/test", json: true, body: `{}`, header: other}); rec.Code != 200 {
		t.Fatalf("b = %d, one person's cooldown must not affect another's", rec.Code)
	}
}

func TestNtfyTestKeysAreUniqueAndNeverCarryTheEmail(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	long := strings.Repeat("a", 250) + "@example.test"
	hdr := map[string]string{"X-Test-Email": long}
	if rec := e.do(req{method: "POST", path: "/api/notify/ntfy", json: true, body: `{}`, header: hdr}); rec.Code != 200 {
		t.Fatal(rec.Code)
	}
	for i := 0; i < 2; i++ {
		if rec := e.do(req{method: "POST", path: "/api/notify/ntfy/test", json: true, body: `{}`, header: hdr}); rec.Code != 200 {
			t.Fatalf("test %d = %d", i, rec.Code)
		}
		e.clock.advance(testCooldown + time.Second)
	}
	k0, k1 := e.n.sends[0].IdempotencyKey, e.n.sends[1].IdempotencyKey
	if k0 == k1 {
		t.Fatalf("keys %q repeat: a fixed key would dedupe the second click", k0)
	}
	for _, k := range []string{k0, k1} {
		if strings.Contains(k, "aaaa") || strings.Contains(k, "example") || len(k) >= 200 || !strings.HasPrefix(k, "test-ntfy-") {
			t.Fatalf("key %q must be a bounded digest key", k)
		}
		for _, c := range k {
			if c < 0x20 || c > 0x7e {
				t.Fatalf("key %q is not printable ASCII", k)
			}
		}
	}
}

func TestNtfyTestErrorMapping(t *testing.T) {
	for name, c := range map[string]struct {
		errs        []error
		ensureErr   error
		status      int
		code        string
		wantSends   int
		wantEnsures int
	}{
		"no publisher mints and resends": {[]error{&platform.NotifsError{Status: 422, Message: platform.MsgNoPublisher}}, nil, 200, "", 2, 1},
		"mint 429":                       {[]error{&platform.NotifsError{Status: 422, Message: platform.MsgNoPublisher}}, &platform.NotifsError{Status: 429, Message: "slow"}, 429, "rate_limited", 1, 1},
		"mint other":                     {[]error{&platform.NotifsError{Status: 422, Message: platform.MsgNoPublisher}}, &platform.NotifsError{Status: 500, Message: "x"}, 500, "notify_unavailable", 1, 1},
		"no destination matched":         {[]error{&platform.NotifsError{Status: 422, Message: platform.MsgNoDestMatched}}, nil, 409, "ntfy_not_set_up", 1, 0},
		"send 429":                       {[]error{&platform.NotifsError{Status: 429, Message: "slow"}}, nil, 429, "rate_limited", 1, 0},
		"other 422":                      {[]error{&platform.NotifsError{Status: 422, Message: "other"}}, nil, 500, "notify_unavailable", 1, 0},
		"other error":                    {[]error{io.ErrUnexpectedEOF}, nil, 500, "notify_unavailable", 1, 0},
	} {
		e := newNotifsEnv(t, "demo")
		e.setUp(t)
		e.n.sendErrs, e.n.ensurePublisherErr = c.errs, c.ensureErr
		rec := e.do(ntfyPost("/api/notify/ntfy/test"))
		if rec.Code != c.status {
			t.Errorf("%s: = %d %s, want %d", name, rec.Code, rec.Body.String(), c.status)
			continue
		}
		if c.code != "" {
			wantError(t, rec.Code, rec.Body.String(), c.code, rec)
		}
		if e.n.sendCount() != c.wantSends || e.n.ensureCalls != c.wantEnsures {
			t.Errorf("%s: sends %d ensures %d, want %d and %d", name, e.n.sendCount(), e.n.ensureCalls, c.wantSends, c.wantEnsures)
		}
		if c.wantSends == 2 && e.n.sends[0].IdempotencyKey != e.n.sends[1].IdempotencyKey {
			t.Errorf("%s: the resend must reuse the key", name)
		}
	}
}

// The precondition read (before any mutation) failing is a 500; only the read after a mutation is best effort.
func TestNtfyResetAndTestAre500WhenThePreconditionReadFails(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	e.store.failPhone = errBoom
	for _, path := range []string{"/api/notify/ntfy/reset", "/api/notify/ntfy/test"} {
		rec := e.do(ntfyPost(path))
		if rec.Code != 500 {
			t.Fatalf("%s = %d, want 500 internal when the person row cannot be read", path, rec.Code)
		}
		wantError(t, rec.Code, rec.Body.String(), "internal", rec)
	}
}

// ---- route guards, built from the wired entries of notifyRoutes ---------------------------------------------------------

func wiredNotifyRoutes() []struct {
	method, path string
	wired        bool
} {
	var out []struct {
		method, path string
		wired        bool
	}
	for _, c := range notifyRoutes {
		if c.wired {
			out = append(out, c)
		}
	}
	return out
}

func TestWiredNotifyRoutesIncludeTheThreeNtfyRoutes(t *testing.T) {
	got := map[string]bool{}
	for _, c := range wiredNotifyRoutes() {
		got[c.method+" "+c.path] = true
	}
	for _, want := range []string{"POST /api/notify/ntfy", "POST /api/notify/ntfy/reset", "POST /api/notify/ntfy/test"} {
		if !got[want] {
			t.Errorf("%s is not wired in notifyRoutes", want)
		}
	}
}

func TestEveryWiredNotifyRouteIs401WithoutIdentity(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	for _, c := range wiredNotifyRoutes() {
		if rec := e.do(req{method: c.method, path: c.path, noAuth: true, json: true, body: `{}`}); rec.Code != 401 {
			t.Errorf("%s %s = %d, want 401", c.method, c.path, rec.Code)
		}
	}
	if e.n.provisionCount() != 0 || e.n.sendCount() != 0 || e.n.resetCalls != 0 {
		t.Fatal("an unauthenticated request reached the notifier")
	}
}

func TestWiredNotifyWritesRefuseCrossSite415And413WithoutEffect(t *testing.T) {
	big := strings.Repeat("p", 5000)
	for _, c := range wiredNotifyRoutes() {
		if c.method == "GET" {
			continue
		}
		for name, r := range map[string]struct {
			r    req
			code int
			want string
		}{
			"cross-site":     {req{method: c.method, path: c.path, json: true, body: `{}`, header: map[string]string{"Origin": "https://evil.example"}}, 403, "cross_site"},
			"fetch metadata": {req{method: c.method, path: c.path, json: true, body: `{}`, header: map[string]string{"Sec-Fetch-Site": "cross-site"}}, 403, "cross_site"},
			"not json":       {req{method: c.method, path: c.path, body: `{}`}, 415, "unsupported_media_type"},
			"known length":   {req{method: c.method, path: c.path, json: true, body: big}, 413, "too_large"},
			"chunked":        {req{method: c.method, path: c.path, json: true, body: big, chunk: true}, 413, "too_large"},
		} {
			e := newNotifsEnv(t, "demo")
			rec := e.do(r.r)
			if rec.Code != r.code {
				t.Errorf("%s %s %s = %d, want %d", name, c.method, c.path, rec.Code, r.code)
				continue
			}
			wantError(t, rec.Code, rec.Body.String(), r.want, rec)
			if e.n.provisionCount() != 0 || e.n.sendCount() != 0 || e.n.resetCalls != 0 || len(e.store.ntfyUsers) != 0 {
				t.Errorf("%s %s %s had an effect", name, c.method, c.path)
			}
		}
	}
}

func TestWiredNotifyRoutesAnswer405ForAnotherMethod(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	for _, c := range wiredNotifyRoutes() {
		rec := e.do(req{method: "PUT", path: c.path, json: true, body: `{}`})
		if rec.Code != 405 {
			t.Errorf("PUT %s = %d, want 405", c.path, rec.Code)
			continue
		}
		wantError(t, rec.Code, rec.Body.String(), "method_not_allowed", rec)
	}
}

func TestWiredNotifyRoutesNeverAnswer502503504AndCarryTheHeaders(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	e.setUp(t)
	e.store.failPhone, e.store.failCounts = errBoom, errBoom
	e.n.provisionErr, e.n.resetErr = io.ErrUnexpectedEOF, io.ErrUnexpectedEOF
	e.n.sendErrs = []error{io.ErrUnexpectedEOF}
	for _, c := range wiredNotifyRoutes() {
		rec := e.do(req{method: c.method, path: c.path, json: true, body: `{}`})
		if rec.Code >= 502 && rec.Code <= 504 {
			t.Errorf("%s %s = %d", c.method, c.path, rec.Code)
		}
		for header, want := range map[string]string{
			"Content-Security-Policy": cspValue, "X-Content-Type-Options": "nosniff", "Referrer-Policy": "same-origin", "Cache-Control": "no-store",
		} {
			if got := rec.Header().Get(header); got != want {
				t.Errorf("%s %s: %s = %q, want %q", c.method, c.path, header, got, want)
			}
		}
	}
}

func TestWiredNotifyRoutesAre401BehindTheRealAccessGateWithoutAVerifier(t *testing.T) {
	t.Setenv("ACCESS_DEV_EMAIL", "")
	hn := newNotifsEnv(t, "demo")
	srv := &Server{
		Store: hn.store, Queue: hn.queue, Jobs: http.NotFoundHandler(), Static: testStatic,
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		Auth:   platform.RequireAccess(nil),
		EmailOf: func(r *http.Request) (string, bool) {
			id, ok := platform.IdentityFrom(r.Context())
			return id.Email, ok
		},
		Tx: hn.store, Notifs: hn.n, NotifsEnabled: true, NotifsName: "demo", NotifsAppID: "apps_demo",
	}
	h := srv.Handler()
	for _, c := range wiredNotifyRoutes() {
		hr := httptest.NewRequest(c.method, c.path, strings.NewReader(`{}`))
		hr.Header.Set("Content-Type", "application/json")
		hr.Header.Set("Cf-Access-Jwt-Assertion", "not-a-jwt")
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, hr)
		if rec.Code != 401 {
			t.Errorf("%s %s = %d, want 401", c.method, c.path, rec.Code)
		}
	}
	if hn.n.provisionCount() != 0 || len(hn.store.ntfyUsers) != 0 {
		t.Fatal("an unauthenticated request had an effect")
	}
}

func TestWiredNotifyRoutesDoNotExistWithNotifsOff(t *testing.T) {
	hn := newHarness(t)
	for _, c := range wiredNotifyRoutes() {
		rec := hn.do(req{method: c.method, path: c.path, json: true, body: `{}`})
		if rec.Code != 404 {
			t.Errorf("%s %s = %d, want 404 with notifs off", c.method, c.path, rec.Code)
		}
	}
}
