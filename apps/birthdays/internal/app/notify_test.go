package app

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gpropersi/apps/apps/birthdays/internal/platform"
)

// fakeNotifs is the Notifier the tests drive: it records calls and returns what the test set.
type fakeNotifs struct {
	mu                                                      sync.Mutex
	log                                                     *[]string // shared call log (nil = not recording)
	provisions, resets, creates, deletes, lookups           int
	provisionErr, resetErr, createErr, deleteErr, lookupErr error
	created                                                 []platform.PersonalDestinationInput
	deleted                                                 []int64
	lookedUp                                                [][]int64
	deliverable                                             map[int64]bool
	nextDest                                                int64
	beforeProvision                                         func()
	resetEmptyPassword                                      bool
	onLookup                                                func()
	sends                                                   []platform.Message
	sendErrs                                                []error // consumed in order, one per Send; a nil entry succeeds
	ensurePublisherErr                                      error
	ensurePublishers                                        int
}

func (f *fakeNotifs) Send(_ context.Context, m platform.Message) (platform.Result, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sends = append(f.sends, m)
	if len(f.sendErrs) > 0 {
		err := f.sendErrs[0]
		f.sendErrs = f.sendErrs[1:]
		return platform.Result{}, err
	}
	return platform.Result{}, nil
}

func (f *fakeNotifs) EnsurePublisher(context.Context) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ensurePublishers++
	return f.ensurePublisherErr
}

func (f *fakeNotifs) rec(name string) {
	if f.log != nil {
		*f.log = append(*f.log, name)
	}
}

func (f *fakeNotifs) Provision(context.Context, string) (platform.Provisioned, error) {
	if f.beforeProvision != nil {
		f.beforeProvision() // outside f.mu so a blocked hook cannot stall other calls
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.provisions++
	f.rec("provision")
	if f.provisionErr != nil {
		return platform.Provisioned{}, f.provisionErr
	}
	return platform.Provisioned{UserID: "ntfy-user-1", PersonHash: "h", Password: "pw-first-secret"}, nil
}

func (f *fakeNotifs) ResetPassword(context.Context, string) (platform.PasswordReset, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.resets++
	if f.resetErr != nil {
		return platform.PasswordReset{}, f.resetErr
	}
	if f.resetEmptyPassword {
		return platform.PasswordReset{UserID: "ntfy-user-1"}, nil
	}
	return platform.PasswordReset{UserID: "ntfy-user-1", Password: "pw-reset-secret"}, nil
}

func (f *fakeNotifs) CreatePersonalDestination(_ context.Context, _ string, in platform.PersonalDestinationInput) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.creates++
	f.created = append(f.created, in)
	if f.createErr != nil {
		return 0, f.createErr
	}
	f.nextDest++
	return 900 + f.nextDest, nil
}

func (f *fakeNotifs) DeletePersonalDestination(_ context.Context, _ string, id int64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deletes++
	f.deleted = append(f.deleted, id)
	return f.deleteErr
}

func (f *fakeNotifs) LookupPersonalDestinations(_ context.Context, _ string, ids []int64) (map[int64]bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lookups++
	f.lookedUp = append(f.lookedUp, ids)
	if f.onLookup != nil {
		f.onLookup()
	}
	if f.lookupErr != nil {
		return nil, f.lookupErr
	}
	out := map[int64]bool{}
	for _, id := range ids {
		out[id] = f.deliverable[id]
	}
	return out, nil
}

type notifySettings struct {
	Ntfy              bool  `json:"ntfy"`
	Destinations      int64 `json:"destinations"`
	StaleDestinations int64 `json:"stale_destinations"`
}

type ntfyResp struct {
	UserID   string         `json:"user_id"`
	SetupURL string         `json:"setup_url"`
	Password *string        `json:"password"`
	Settings notifySettings `json:"settings"`
}

type destResp struct {
	Destination struct {
		ID    int64  `json:"id"`
		Kind  string `json:"kind"`
		Label string `json:"label"`
		Hint  string `json:"hint"`
		Stale bool   `json:"stale"`
	} `json:"destination"`
	SigningSecret string         `json:"signing_secret"`
	Settings      notifySettings `json:"settings"`
}

const (
	discordURL = "https://discord.com/api/webhooks/1234/tokenabc"
	webhookURL = "https://hooks.example.test/path/xyz"
)

func destBody(kind, label, url string) string {
	b, err := json.Marshal(map[string]string{"kind": kind, "label": label, "url": url}) // %q would emit invalid JSON escapes
	if err != nil {
		panic(err)
	}
	return string(b)
}

func (hn *harness) addDest(email, kind, url string) destResp {
	hn.t.Helper()
	rec := hn.as(email, "POST", "/api/notify/destinations", destBody(kind, "Family", url))
	hn.wantStatus(rec, 201, "")
	var d destResp
	decode(hn.t, rec.Body.String(), &d)
	return d
}

func TestNtfyPasswordIsReturnedOnceAndRepeatDoesNotReprovision(t *testing.T) {
	hn := newHarness(t)
	rec := hn.as(alice, "POST", "/api/notify/ntfy", `{}`)
	hn.wantStatus(rec, 200, "")
	var first ntfyResp
	decode(t, rec.Body.String(), &first)
	if first.Password == nil || *first.Password != "pw-first-secret" || first.UserID != "ntfy-user-1" {
		t.Fatalf("first provision = %+v", first)
	}
	if want := "https://notifs-setup.4irl.app/?app=apps_birthdays&user=ntfy-user-1&name=Birthdays"; first.SetupURL != want {
		t.Fatalf("setup_url = %q, want %q", first.SetupURL, want)
	}
	if strings.Contains(first.SetupURL, "pw-") {
		t.Fatal("the setup link must not carry the password")
	}
	if !first.Settings.Ntfy {
		t.Fatal("settings.ntfy must be true right after provisioning")
	}
	if got := rec.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control = %q, want no-store", got)
	}

	rec = hn.as(alice, "POST", "/api/notify/ntfy", `{}`)
	hn.wantStatus(rec, 200, "")
	var again ntfyResp
	decode(t, rec.Body.String(), &again)
	if again.Password != nil || again.UserID != "ntfy-user-1" || again.SetupURL != first.SetupURL || !again.Settings.Ntfy {
		t.Fatalf("repeat = %+v (password must be null, id and link stable)", again)
	}
	if strings.Contains(rec.Body.String(), "pw-first-secret") {
		t.Fatal("the repeat response leaked the password")
	}
	if hn.notifs.provisions != 1 {
		t.Fatalf("Provision called %d times, want 1 (a second call would invalidate the first token)", hn.notifs.provisions)
	}
	var me struct {
		Settings notifySettings `json:"settings"`
	}
	decode(t, hn.as(alice, "GET", "/api/me", "").Body.String(), &me)
	if !me.Settings.Ntfy {
		t.Fatal("/api/me does not show ntfy after provisioning")
	}
}

func TestConcurrentFirstNtfyCallsProvisionOnce(t *testing.T) {
	hn := newHarness(t)
	hn.wantStatus(hn.as(alice, "GET", "/api/me", ""), 200, "") // the users row exists before the race
	// Force overlap: the first Provision blocks until the second request has started (its UpsertUser is counted before
	// it takes the store lock the first transaction holds), or 2 s pass.
	base := hn.store.arrived.Load()
	overlapped := false
	hn.notifs.beforeProvision = func() {
		for deadline := time.Now().Add(2 * time.Second); time.Now().Before(deadline); time.Sleep(time.Millisecond) {
			if hn.store.arrived.Load() >= base+2 {
				overlapped = true
				return
			}
		}
	}
	var wg sync.WaitGroup
	codes := make([]int, 2)
	bodies := make([]string, 2)
	for i := range codes {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rec := hn.as(alice, "POST", "/api/notify/ntfy", `{}`)
			codes[i], bodies[i] = rec.Code, rec.Body.String()
		}()
	}
	wg.Wait()
	if !overlapped {
		t.Fatal("the second request never arrived while the first was provisioning: the test did not overlap")
	}
	recs := make([]ntfyResp, 2)
	for i := range recs {
		if codes[i] != 200 {
			t.Fatalf("call %d = %d", i, codes[i])
		}
		decode(t, bodies[i], &recs[i])
	}
	if hn.notifs.provisions != 1 {
		t.Fatalf("Provision called %d times for two concurrent first calls, want 1", hn.notifs.provisions)
	}
	withPassword := 0
	for _, r := range recs {
		if r.Password != nil {
			withPassword++
		}
	}
	if withPassword != 1 {
		t.Fatalf("%d responses carried the password, want exactly 1", withPassword)
	}
}

func TestNtfyLockRunsInsideTheTransactionBeforeProvision(t *testing.T) {
	hn := newHarness(t)
	var calls []string
	hn.store.calls, hn.notifs.log = &calls, &calls
	hn.wantStatus(hn.as(alice, "POST", "/api/notify/ntfy", `{}`), 200, "")
	if got, want := strings.Join(calls, ","), "tx-begin,lock,get,provision,tx-end"; got != want {
		t.Fatalf("call order %q, want %q", got, want)
	}
}

func TestNtfyFailuresAndLostStore(t *testing.T) {
	t.Run("notifs failure is notify_unavailable and stores nothing", func(t *testing.T) {
		hn := newHarness(t)
		hn.notifs.provisionErr = &platform.NotifsError{Status: 503, Message: "boom"}
		hn.wantStatus(hn.as(alice, "POST", "/api/notify/ntfy", `{}`), 500, "notify_unavailable")
		var me struct {
			Settings notifySettings `json:"settings"`
		}
		decode(t, hn.as(alice, "GET", "/api/me", "").Body.String(), &me)
		if me.Settings.Ntfy {
			t.Fatal("a failed provision must not mark ntfy as set up")
		}
	})
	t.Run("a failed store after a provision is 500 and the password is not in the response or logs", func(t *testing.T) {
		hn := newHarness(t)
		hn.store.failSetNtfy = errBoom
		rec := hn.as(alice, "POST", "/api/notify/ntfy", `{}`)
		hn.wantStatus(rec, 500, "internal")
		if strings.Contains(rec.Body.String(), "pw-first-secret") || strings.Contains(hn.logs.String(), "pw-first-secret") {
			t.Fatal("the password leaked after a failed store")
		}
	})
	t.Run("an unconfigured client is notify_unavailable", func(t *testing.T) {
		hn := newHarness(t)
		hn.notifs.provisionErr = platform.ErrNotifsUnconfigured
		hn.wantStatus(hn.as(alice, "POST", "/api/notify/ntfy", `{}`), 500, "notify_unavailable")
		if !strings.Contains(hn.logs.String(), "unconfigured") {
			t.Fatal("the log does not say notifs is unconfigured")
		}
	})
}

func TestNtfyReset(t *testing.T) {
	hn := newHarness(t)
	hn.wantStatus(hn.as(alice, "POST", "/api/notify/ntfy/reset", `{}`), 409, "ntfy_not_set_up")
	if hn.notifs.resets != 0 {
		t.Fatal("reset called delivery-api for a person who never set up ntfy")
	}
	hn.wantStatus(hn.as(alice, "POST", "/api/notify/ntfy", `{}`), 200, "")

	rec := hn.as(alice, "POST", "/api/notify/ntfy/reset", `{}`)
	hn.wantStatus(rec, 200, "")
	var ok struct {
		Password string         `json:"password"`
		SetupURL string         `json:"setup_url"`
		Settings notifySettings `json:"settings"`
	}
	decode(t, rec.Body.String(), &ok)
	if ok.Password != "pw-reset-secret" || !strings.HasSuffix(ok.SetupURL, "&user=ntfy-user-1&name=Birthdays") || !ok.Settings.Ntfy {
		t.Fatalf("reset = %+v", ok)
	}
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("reset response is cacheable")
	}

	for _, c := range []struct {
		name   string
		err    error
		status int
		code   string
	}{
		{"delivery-api 404 user does not exist", &platform.NotifsError{Status: 404, Message: "user does not exist"}, 409, "ntfy_not_set_up"},
		{"delivery-api 429", &platform.NotifsError{Status: 429}, 429, "rate_limited"},
		{"delivery-api 503", &platform.NotifsError{Status: 503}, 500, "notify_unavailable"},
		{"unconfigured", platform.ErrNotifsUnconfigured, 500, "notify_unavailable"},
	} {
		hn.notifs.resetErr = c.err
		er := hn.as(alice, "POST", "/api/notify/ntfy/reset", `{}`)
		hn.wantStatus(er, c.status, c.code)
		if strings.Contains(er.Body.String(), "password") {
			t.Fatalf("%s: an error answer carries a password key: %s", c.name, er.Body.String())
		}
	}
	// A 200 with an empty password would show a blank one-time password after the old one died.
	hn.notifs.resetErr = nil
	hn.notifs.resetEmptyPassword = true
	hn.wantStatus(hn.as(alice, "POST", "/api/notify/ntfy/reset", `{}`), 500, "notify_unavailable")
	hn.notifs.resetEmptyPassword = false

	// Settings counters on a reset with a stale destination present.
	hn.addDest(alice, "webhook", webhookURL)
	hn.store.dests[0].Stale = true
	rec = hn.as(alice, "POST", "/api/notify/ntfy/reset", `{}`)
	hn.wantStatus(rec, 200, "")
	var withStale struct {
		Settings notifySettings `json:"settings"`
	}
	decode(t, rec.Body.String(), &withStale)
	if withStale.Settings.Destinations != 1 || withStale.Settings.StaleDestinations != 1 {
		t.Fatalf("reset settings = %+v, want 1 destination, 1 stale", withStale.Settings)
	}
}

func TestUnconfiguredNotifierIsNotifyUnavailableAndTheRestWorks(t *testing.T) {
	hn := newHarness(t)
	hn.h = (&Server{Store: hn.store, Tx: hn.store, Queue: hn.queue, Jobs: http.NotFoundHandler(), Static: testStatic,
		Logger: slog.New(slog.NewTextHandler(hn.logs, nil)), Auth: fakeAuth.Middleware, EmailOf: fakeAuth.EmailOf}).Handler()
	hn.wantStatus(hn.as(alice, "POST", "/api/notify/ntfy", `{}`), 500, "notify_unavailable")
	hn.wantStatus(hn.as(alice, "POST", "/api/notify/destinations", destBody("discord", "x", discordURL)), 500, "notify_unavailable")
	hn.wantStatus(hn.as(alice, "GET", "/api/me", ""), 200, "")
	hn.create(alice, sam)
}

func TestCreateDestinationValidation(t *testing.T) {
	hn := newHarness(t)
	long := strings.Repeat("l", 51)
	for _, c := range []struct{ name, body, code string }{
		{"http url", destBody("webhook", "x", "http://hooks.example.test/a"), "invalid_url"},
		{"no host", destBody("webhook", "x", "https:///a"), "invalid_url"},
		{"not a url", destBody("webhook", "x", "nope"), "invalid_url"},
		{"userinfo", destBody("webhook", "x", "https://u:p@hooks.example.test/a"), "invalid_url"},
		{"space in url", destBody("webhook", "x", "https://hooks.example.test/a b"), "invalid_url"},
		{"unknown kind", destBody("slack", "x", webhookURL), "invalid_url"},
		{"discord wrong host", destBody("discord", "x", "https://evil.example/api/webhooks/1/t"), "invalid_url"},
		{"discord lookalike host", destBody("discord", "x", "https://discord.com.evil.example/api/webhooks/1/t"), "invalid_url"},
		{"discord wrong path", destBody("discord", "x", "https://discord.com/other/1/t"), "invalid_url"},
		{"discord http", destBody("discord", "x", "http://discord.com/api/webhooks/1/t"), "invalid_url"},
		{"discord port", destBody("discord", "x", "https://discord.com:8443/api/webhooks/1/t"), "invalid_url"},
		{"discord dotdot path", destBody("discord", "x", "https://discord.com/api/webhooks/../../x"), "invalid_url"},
		{"webhook dotdot path", destBody("webhook", "x", "https://hooks.example.test/a/../b"), "invalid_url"},
		{"localhost", destBody("webhook", "x", "https://localhost/a"), "invalid_url"},
		{"sub localhost", destBody("webhook", "x", "https://a.localhost/a"), "invalid_url"},
		{"dot local", destBody("webhook", "x", "https://printer.local/a"), "invalid_url"},
		{"dot internal", destBody("webhook", "x", "https://svc.internal/a"), "invalid_url"},
		{"loopback v4", destBody("webhook", "x", "https://127.0.0.1/a"), "invalid_url"},
		{"private v4", destBody("webhook", "x", "https://10.1.2.3/a"), "invalid_url"},
		{"link local v4", destBody("webhook", "x", "https://169.254.169.254/a"), "invalid_url"},
		{"unspecified v4", destBody("webhook", "x", "https://0.0.0.0/a"), "invalid_url"},
		{"loopback v6", destBody("webhook", "x", "https://[::1]/a"), "invalid_url"},
		{"mapped loopback v6", destBody("webhook", "x", "https://[::ffff:127.0.0.1]/a"), "invalid_url"},
		{"unique local v6", destBody("webhook", "x", "https://[fd00::1]/a"), "invalid_url"},
		{"url over 2048", destBody("webhook", "x", "https://hooks.example.test/"+strings.Repeat("a", 2048)), "invalid_url"},
		{"control rune in label", destBody("webhook", "a\u0007b", webhookURL), "invalid_label"},
		{"newline in label", destBody("webhook", "a\nb", webhookURL), "invalid_label"},
		{"empty label", destBody("webhook", "  ", webhookURL), "invalid_label"},
		{"label over 50", destBody("webhook", long, webhookURL), "invalid_label"},
		{"not json", `nope`, "invalid_url"},
	} {
		rec := hn.as(alice, "POST", "/api/notify/destinations", c.body)
		hn.wantStatus(rec, 400, c.code)
		if hn.notifs.creates != 0 {
			t.Fatalf("%s: delivery-api was called for an invalid request", c.name)
		}
		if rec.Header().Get("Cache-Control") != "no-store" {
			t.Fatalf("%s: the 400 answer is cacheable", c.name)
		}
	}
	// A 500 notify answer carries it too.
	hn.notifs.createErr = &platform.NotifsError{Status: 503}
	rec := hn.as(alice, "POST", "/api/notify/destinations", destBody("webhook", "x", webhookURL))
	hn.wantStatus(rec, 500, "notify_unavailable")
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("the 500 answer is cacheable")
	}
	hn.notifs.createErr = nil
	for _, host := range []string{"discord.com", "discordapp.com"} {
		hn.addDest(alice, "discord", "https://"+host+"/api/webhooks/1/tok")
	}
}

func TestCreateDestinationMapsDeliveryErrors(t *testing.T) {
	for _, c := range []struct {
		name   string
		err    error
		status int
		code   string
	}{
		{"not public", &platform.NotifsError{Status: 400, Message: "secrets.url must resolve to public addresses"}, 400, "url_not_public"},
		{"unresolved host", &platform.NotifsError{Status: 400, Message: "secrets.url host could not be resolved"}, 400, "invalid_url"},
		{"other 400", &platform.NotifsError{Status: 400, Message: "secrets.url is not a valid url"}, 400, "invalid_url"},
		{"503 unavailable", &platform.NotifsError{Status: 503, Message: "personal destinations unavailable"}, 500, "notify_unavailable"},
		{"500", &platform.NotifsError{Status: 500}, 500, "notify_unavailable"},
		{"429", &platform.NotifsError{Status: 429}, 500, "notify_unavailable"},
		{"401", &platform.NotifsError{Status: 401}, 500, "notify_unavailable"},
		{"network", platform.ErrNotifsRetryable, 500, "notify_unavailable"},
		{"unconfigured", platform.ErrNotifsUnconfigured, 500, "notify_unavailable"},
	} {
		t.Run(c.name, func(t *testing.T) {
			hn := newHarness(t)
			hn.notifs.createErr = c.err
			hn.wantStatus(hn.as(alice, "POST", "/api/notify/destinations", destBody("webhook", "Home", webhookURL)), c.status, c.code)
			if len(hn.store.dests) != 0 {
				t.Fatal("a failed create left a local row")
			}
		})
	}
}

func TestDestinationLifecycleCountersAndStoredFields(t *testing.T) {
	hn := newHarness(t)
	wh := hn.addDest(alice, "webhook", webhookURL)
	if wh.Destination.Kind != "webhook" || wh.Destination.Hint != "xyz" || wh.Destination.Label != "Family" || wh.Destination.Stale {
		t.Fatalf("webhook destination = %+v", wh.Destination)
	}
	if len(wh.SigningSecret) != 43 {
		t.Fatalf("signing secret %q: want 43 base64url chars (32 random bytes)", wh.SigningSecret)
	}
	if wh.Settings.Destinations != 1 || wh.Settings.StaleDestinations != 0 {
		t.Fatalf("settings after the first add = %+v", wh.Settings)
	}
	in := hn.notifs.created[0]
	if in.Type != "webhook" || in.Secrets["url"] != webhookURL || in.Secrets["signing_secret"] != wh.SigningSecret || in.Label != "Family" {
		t.Fatalf("delivery-api got %+v", in)
	}
	dc := hn.addDest(alice, "discord", discordURL)
	if dc.SigningSecret != "" {
		t.Fatal("a discord destination has no signing secret")
	}
	if dc.Destination.Hint != "abc" || hn.notifs.created[1].Secrets["webhook_url"] != discordURL {
		t.Fatalf("discord destination = %+v, sent %+v", dc.Destination, hn.notifs.created[1])
	}
	if dc.Settings.Destinations != 2 {
		t.Fatalf("settings = %+v", dc.Settings)
	}

	// The stored rows hold only notifs_id, kind, label and the 3-char hint (fDest has exactly the table's columns).
	want := []fDest{
		{ID: wh.Destination.ID, UserID: 1, NotifsID: 901, Kind: "webhook", Label: "Family", Hint: "xyz"},
		{ID: dc.Destination.ID, UserID: 1, NotifsID: 902, Kind: "discord", Label: "Family", Hint: "abc"},
	}
	if fmt.Sprint(hn.store.dests) != fmt.Sprint(want) {
		t.Fatalf("stored rows %+v, want %+v", hn.store.dests, want)
	}

	rec := hn.as(alice, "GET", "/api/notify/destinations", "")
	hn.wantStatus(rec, 200, "")
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("the destination list is cacheable")
	}
	var list struct {
		Destinations []struct {
			ID   int64  `json:"id"`
			Hint string `json:"hint"`
		} `json:"destinations"`
	}
	decode(t, rec.Body.String(), &list)
	if len(list.Destinations) != 2 {
		t.Fatalf("list = %+v", list)
	}
	for _, leak := range []string{webhookURL, discordURL, wh.SigningSecret, "hooks.example.test"} {
		if strings.Contains(rec.Body.String(), leak) {
			t.Fatalf("the list response leaked %q", leak)
		}
	}
	if empty := hn.as(bob, "GET", "/api/notify/destinations", ""); strings.Contains(empty.Body.String(), "null") {
		t.Fatalf("an empty list must be [], got %s", empty.Body.String())
	}

	// Delete: delivery-api then the row, answers 200 {settings}; the other row is stale, so the counters must show it.
	hn.store.dests[1].Stale = true
	rec = hn.as(alice, "DELETE", fmt.Sprintf("/api/notify/destinations/%d", wh.Destination.ID), `{}`)
	hn.wantStatus(rec, 200, "")
	var del struct {
		Settings notifySettings `json:"settings"`
	}
	decode(t, rec.Body.String(), &del)
	if del.Settings.Destinations != 1 || del.Settings.StaleDestinations != 1 || hn.notifs.deleted[0] != 901 {
		t.Fatalf("delete: settings %+v deleted %v", del.Settings, hn.notifs.deleted)
	}
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("the delete response is cacheable")
	}
}

func TestHintIsTheEndOfThePathNeverTheQuery(t *testing.T) {
	for url, want := range map[string]string{
		webhookURL: "xyz",
		discordURL: "abc",
		"https://hooks.example.test/path/xyz?secret=qrs#frag": "xyz",
		"https://hooks.example.test/path/xyz/":                "xyz",
		"https://hooks.example.test/?token=abcdef":            "def",
	} {
		if got := platform.DestinationHint(url); got != want {
			t.Errorf("platform.DestinationHint(%q) = %q, want %q", url, got, want)
		}
	}
}

func TestDestinationLimitIs10(t *testing.T) {
	hn := newHarness(t)
	for i := range 10 {
		hn.addDest(alice, "webhook", fmt.Sprintf("https://hooks.example.test/h%d", i))
	}
	hn.wantStatus(hn.as(alice, "POST", "/api/notify/destinations", destBody("webhook", "x", webhookURL)), 409, "too_many_destinations")
	if hn.notifs.creates != 10 {
		t.Fatalf("delivery-api saw %d creates, want 10 (the cap is checked before the call)", hn.notifs.creates)
	}
}

func TestFailedLocalInsertRemovesTheRemoteDestination(t *testing.T) {
	hn := newHarness(t)
	hn.store.failInsertDest = errBoom
	hn.wantStatus(hn.as(alice, "POST", "/api/notify/destinations", destBody("webhook", "x", webhookURL)), 500, "internal")
	if len(hn.notifs.deleted) != 1 || hn.notifs.deleted[0] != 901 {
		t.Fatalf("the orphaned remote destination was not removed: %v", hn.notifs.deleted)
	}
}

func TestDeleteDestinationRules(t *testing.T) {
	hn := newHarness(t)
	d := hn.addDest(alice, "webhook", webhookURL)
	path := fmt.Sprintf("/api/notify/destinations/%d", d.Destination.ID)

	hn.wantStatus(hn.as(bob, "DELETE", path, `{}`), 404, "not_found") // another person's id
	if hn.notifs.deletes != 0 || len(hn.store.dests) != 1 {
		t.Fatal("another person's delete reached delivery-api or removed the row")
	}
	hn.wantStatus(hn.as(alice, "DELETE", "/api/notify/destinations/999", `{}`), 404, "not_found")
	hn.wantStatus(hn.as(alice, "DELETE", "/api/notify/destinations/abc", `{}`), 404, "not_found")

	hn.notifs.deleteErr = &platform.NotifsError{Status: 503}
	hn.wantStatus(hn.as(alice, "DELETE", path, `{}`), 500, "notify_unavailable")
	hn.notifs.deleteErr = &platform.NotifsError{Status: 401}
	hn.wantStatus(hn.as(alice, "DELETE", path, `{}`), 500, "notify_unavailable")
	if len(hn.store.dests) != 1 {
		t.Fatal("a failed delivery-api delete removed the local row")
	}
	hn.notifs.deleteErr = &platform.NotifsError{Status: 404, Message: "personal destination does not exist"}
	hn.wantStatus(hn.as(alice, "DELETE", path, `{}`), 200, "") // already gone there: the row still goes
	if len(hn.store.dests) != 0 {
		t.Fatal("a delivery-api 404 must still delete the local row")
	}
}

func TestListIsOwnOnly(t *testing.T) {
	hn := newHarness(t)
	hn.addDest(alice, "webhook", webhookURL)
	rec := hn.as(bob, "GET", "/api/notify/destinations", "")
	hn.wantStatus(rec, 200, "")
	if !strings.Contains(rec.Body.String(), `"destinations":[]`) {
		t.Fatalf("bob sees %s", rec.Body.String())
	}
}

func TestCheckDestination(t *testing.T) {
	hn := newHarness(t)
	d := hn.addDest(alice, "webhook", webhookURL)
	path := fmt.Sprintf("/api/notify/destinations/%d/check", d.Destination.ID)
	type checkResp struct {
		Destination struct {
			Stale bool `json:"stale"`
		} `json:"destination"`
		Settings notifySettings `json:"settings"`
	}
	check := func() (checkResp, int) {
		rec := hn.as(alice, "POST", path, `{}`)
		var c checkResp
		if rec.Code == 200 {
			decode(t, rec.Body.String(), &c)
			if rec.Header().Get("Cache-Control") != "no-store" {
				t.Fatal("check response is cacheable")
			}
		}
		return c, rec.Code
	}
	stale := func(v bool) { hn.store.dests[0].Stale = v }

	// A non-stale row is a no-op: no lookup.
	if c, code := check(); code != 200 || c.Destination.Stale || hn.notifs.lookups != 0 {
		t.Fatalf("non-stale check: %+v %d lookups=%d", c, code, hn.notifs.lookups)
	}

	// Stale and not deliverable (absent from the lookup, or disabled / opted out, which the client folds into false).
	stale(true)
	if c, code := check(); code != 200 || !c.Destination.Stale || c.Settings.StaleDestinations != 1 {
		t.Fatalf("stale + not deliverable: %+v %d", c, code)
	}
	if hn.notifs.lookedUp[0][0] != 901 {
		t.Fatalf("lookup asked about %v, want [901]", hn.notifs.lookedUp[0])
	}
	if hn.notifs.creates != 1 || hn.notifs.deletes != 0 {
		t.Fatal("check must never create, delete or change opt-in")
	}

	// Stale and deliverable: cleared.
	hn.notifs.deliverable = map[int64]bool{901: true}
	if c, code := check(); code != 200 || c.Destination.Stale || c.Settings.StaleDestinations != 0 || c.Settings.Destinations != 1 {
		t.Fatalf("stale + deliverable: %+v %d", c, code)
	}
	if hn.store.dests[0].Stale {
		t.Fatal("the row is still stale")
	}

	// A failing lookup is notify_unavailable and changes nothing.
	stale(true)
	hn.notifs.lookupErr = &platform.NotifsError{Status: 503}
	hn.wantStatus(hn.as(alice, "POST", path, `{}`), 500, "notify_unavailable")
	if !hn.store.dests[0].Stale {
		t.Fatal("a failed lookup changed the row")
	}
	hn.notifs.lookupErr = platform.ErrNotifsUnconfigured
	hn.wantStatus(hn.as(alice, "POST", path, `{}`), 500, "notify_unavailable")

	// The row is deleted while the lookup is in flight: clearing it affects 0 rows, so the answer is 404.
	hn.notifs.lookupErr = nil
	hn.notifs.deliverable = map[int64]bool{901: true}
	hn.notifs.onLookup = func() { hn.store.dests = nil }
	hn.wantStatus(hn.as(alice, "POST", path, `{}`), 404, "not_found")
	hn.notifs.onLookup = nil

	// Another person's id, and an unknown id.
	hn.wantStatus(hn.as(bob, "POST", path, `{}`), 404, "not_found")
	hn.wantStatus(hn.as(alice, "POST", "/api/notify/destinations/999/check", `{}`), 404, "not_found")
}

func TestNoSecretsInLogsOrStoredState(t *testing.T) {
	hn := newHarness(t)
	var pw string
	{
		rec := hn.as(alice, "POST", "/api/notify/ntfy", `{}`)
		hn.wantStatus(rec, 200, "")
		var r ntfyResp
		decode(t, rec.Body.String(), &r)
		pw = *r.Password
	}
	reset := hn.as(alice, "POST", "/api/notify/ntfy/reset", `{}`)
	hn.wantStatus(reset, 200, "")
	wh := hn.addDest(alice, "webhook", webhookURL)
	dc := hn.addDest(alice, "discord", discordURL)
	// Every injected error message embeds the URL and a signing secret, as an upstream that echoes a request would.
	const echoed = "secrets.url " + webhookURL + " " + discordURL + " signing_secret=SIGNSECRET-echo pw-reset-secret "
	hn.notifs.createErr = &platform.NotifsError{Status: 400, Message: echoed + "must resolve to public addresses"}
	hn.as(alice, "POST", "/api/notify/destinations", destBody("webhook", "x", "https://private.example.test/zzz"))
	hn.notifs.createErr = &platform.NotifsError{Status: 503, Message: echoed}
	hn.as(alice, "POST", "/api/notify/destinations", destBody("webhook", "x", "https://private.example.test/zzz"))
	hn.notifs.createErr = platform.ErrNotifsUnconfigured
	hn.as(alice, "POST", "/api/notify/destinations", destBody("webhook", "x", "https://private.example.test/zzz"))
	hn.notifs.createErr = nil
	hn.notifs.deleteErr = &platform.NotifsError{Status: 503, Message: echoed}
	hn.as(alice, "DELETE", fmt.Sprintf("/api/notify/destinations/%d", wh.Destination.ID), `{}`)
	hn.notifs.deleteErr = nil
	hn.notifs.resetErr = &platform.NotifsError{Status: 503, Message: echoed}
	hn.as(alice, "POST", "/api/notify/ntfy/reset", `{}`)
	hn.notifs.resetErr = &platform.NotifsError{Status: 429, Message: echoed}
	hn.as(alice, "POST", "/api/notify/ntfy/reset", `{}`)
	hn.notifs.resetErr = nil
	hn.store.dests[0].Stale = true
	hn.notifs.lookupErr = &platform.NotifsError{Status: 503, Message: echoed}
	hn.as(alice, "POST", fmt.Sprintf("/api/notify/destinations/%d/check", hn.store.dests[0].ID), `{}`)
	hn.notifs.lookupErr = nil
	hn.as(alice, "DELETE", fmt.Sprintf("/api/notify/destinations/%d", dc.Destination.ID), `{}`)
	hn.notifs.provisionErr = &platform.NotifsError{Status: 500, Message: echoed}
	hn.as(bob, "POST", "/api/notify/ntfy", `{}`)
	hn.notifs.provisionErr = nil
	hn.store.failSetNtfy = errBoom
	hn.as(bob, "POST", "/api/notify/ntfy", `{}`)

	logs := hn.logs.String()
	for _, secret := range []string{webhookURL, discordURL, "hooks.example.test", "discord.com", "private.example.test", wh.SigningSecret,
		pw, "pw-reset-secret", "SIGNSECRET", alice, bob, "tokenabc"} {
		if strings.Contains(logs, secret) {
			t.Fatalf("the log contains %q:\n%s", secret, logs)
		}
	}
	if !strings.Contains(logs, "notify failed") {
		t.Fatal("the failures were not logged at all")
	}
}
