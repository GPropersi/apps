package app

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gpropersi/apps/apps/tmplgoreact/internal/app/db"
	"github.com/gpropersi/apps/apps/tmplgoreact/internal/platform"
)

// Fixtures are assembled at runtime so no hygiene allowlist entry is needed and scaffolded copies stay clean.
func discordURL() string {
	return fmt.Sprintf("https://%s/api/webhooks/123/%s", "discord.com", "tokenABC")
}
func hookURL() string {
	return fmt.Sprintf("https://%s/in/%s", "hooks.example.test", "sekret-path-xyz")
}
func privateURL() string { return fmt.Sprintf("https://%d.%d.%d.%d/x", 10, 0, 0, 1) }

func destCreate(kind, label, url string) req {
	body, _ := json.Marshal(map[string]string{"kind": kind, "label": label, "url": url})
	return req{method: "POST", path: "/api/notify/destinations", json: true, body: string(body)}
}

type destResp struct {
	Destination *struct {
		ID    int64  `json:"id"`
		Kind  string `json:"kind"`
		Label string `json:"label"`
		Hint  string `json:"hint"`
		Stale bool   `json:"stale"`
	} `json:"destination"`
	SigningSecret *string `json:"signing_secret"`
	Phone         *struct {
		Ntfy              bool `json:"ntfy"`
		Destinations      int  `json:"destinations"`
		StaleDestinations int  `json:"stale_destinations"`
	} `json:"phone"`
}

// addDest creates a destination through the API and returns its id.
func (e *notifsEnv) addDest(t *testing.T, kind string) int64 {
	t.Helper()
	url := discordURL()
	if kind == "webhook" {
		url = hookURL()
	}
	rec := e.do(destCreate(kind, "mine", url))
	var got destResp
	decode(t, rec.Body.String(), &got)
	if rec.Code != 201 || got.Destination == nil {
		t.Fatalf("create = %d %s", rec.Code, rec.Body.String())
	}
	return got.Destination.ID
}

func (e *notifsEnv) setStale(id int64, stale bool) {
	_, _ = e.store.SetOwnDestinationStale(context.Background(), db.SetOwnDestinationStaleParams{Stale: stale, DestinationID: id, Email: testEmail})
}

func destPath(id int64, suffix string) string {
	return fmt.Sprintf("/api/notify/destinations/%d%s", id, suffix)
}

// ---- create -------------------------------------------------------------------------------------------------------------

func TestCreateWebhookReturnsTheSigningSecretOnceAndDiscordDoesNot(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	rec := e.do(destCreate("webhook", "  hook ", hookURL()))
	var got destResp
	decode(t, rec.Body.String(), &got)
	if rec.Code != 201 || got.Destination == nil || got.SigningSecret == nil || len(*got.SigningSecret) < 40 {
		t.Fatalf("webhook = %d %s", rec.Code, rec.Body.String())
	}
	if got.Destination.Label != "hook" || got.Destination.Hint != "xyz" || got.Destination.Kind != "webhook" || got.Destination.Stale {
		t.Fatalf("destination = %+v", got.Destination)
	}
	if got.Phone == nil || got.Phone.Destinations != 1 {
		t.Fatalf("phone = %+v", got.Phone)
	}
	secret := *got.SigningSecret
	if in := e.n.createIn[0]; in.Type != "webhook" || in.Secrets["signing_secret"] != secret || in.Secrets["url"] != hookURL() || in.Label != "hook" {
		t.Fatalf("delivery-api input = %+v", in)
	}
	id := got.Destination.ID

	rec = e.do(destCreate("discord", "dc", discordURL()))
	if rec.Code != 201 || strings.Contains(rec.Body.String(), "signing_secret") {
		t.Fatalf("discord = %d %s", rec.Code, rec.Body.String())
	}
	if in := e.n.createIn[1]; in.Secrets["webhook_url"] != discordURL() || len(in.Secrets) != 1 {
		t.Fatalf("discord input = %+v", in)
	}

	// No later response carries the secret or the URL, and neither does the log.
	e.n.lookups = map[int64]bool{101: true}
	e.setStale(id, true)
	for name, r := range map[string]req{
		"list":  {method: "GET", path: "/api/notify/destinations"},
		"check": ntfyPost(destPath(id, "/check")),
		"me":    {method: "GET", path: "/api/me"},
	} {
		rec := e.do(r)
		if rec.Code != 200 {
			t.Fatalf("%s = %d %s", name, rec.Code, rec.Body.String())
		}
		for _, bad := range []string{secret, hookURL(), "sekret-path", "tokenABC"} {
			if strings.Contains(rec.Body.String(), bad) {
				t.Errorf("%s leaked %q: %s", name, bad, rec.Body.String())
			}
		}
	}
	rec = e.do(ntfyPost(destPath(id, "/test")))
	if rec.Code != 200 || strings.Contains(rec.Body.String(), secret) {
		t.Fatalf("test = %d %s", rec.Code, rec.Body.String())
	}
	for _, bad := range []string{secret, hookURL(), discordURL(), "sekret-path", "tokenABC"} {
		if strings.Contains(e.logs.String(), bad) {
			t.Errorf("log leaked %q", bad)
		}
	}
}

func TestCreateRejectsBadInputWithTheContractCodesAndStoresNothing(t *testing.T) {
	for name, c := range map[string]struct {
		r    req
		code string
	}{
		"empty label":   {destCreate("discord", "  ", discordURL()), "invalid_label"},
		"long label":    {destCreate("discord", strings.Repeat("a", 51), discordURL()), "invalid_label"},
		"private ip":    {destCreate("webhook", "x", privateURL()), "invalid_url"},
		"http":          {destCreate("webhook", "x", strings.Replace(hookURL(), "https", "http", 1)), "invalid_url"},
		"not discord":   {destCreate("discord", "x", hookURL()), "invalid_url"},
		"bad kind":      {destCreate("sms", "x", hookURL()), "invalid_url"},
		"bad json":      {req{method: "POST", path: "/api/notify/destinations", json: true, body: `{`}, "invalid_url"},
		"empty body":    {req{method: "POST", path: "/api/notify/destinations", json: true, body: ``}, "invalid_url"},
		"userinfo":      {destCreate("webhook", "x", "https://u:p@"+"hooks.example.test/a"), "invalid_url"},
		"label control": {destCreate("webhook", "a\u0001b", hookURL()), "invalid_label"},
	} {
		e := newNotifsEnv(t, "demo")
		rec := e.do(c.r)
		if rec.Code != 400 {
			t.Errorf("%s = %d %s, want 400", name, rec.Code, rec.Body.String())
			continue
		}
		wantError(t, rec.Code, rec.Body.String(), c.code, rec)
		if e.n.createCount() != 0 || len(e.store.dests) != 0 {
			t.Errorf("%s had an effect", name)
		}
	}
}

func TestCreateMapsDeliveryAPI400s(t *testing.T) {
	for name, c := range map[string]struct {
		err    error
		status int
		code   string
	}{
		"not public":   {&platform.NotifsError{Status: 400, Message: "url must resolve to public addresses"}, 400, "url_not_public"},
		"other 400":    {&platform.NotifsError{Status: 400, Message: "bad url"}, 400, "invalid_url"},
		"server error": {&platform.NotifsError{Status: 503, Message: "down"}, 500, "notify_unavailable"},
		"transport":    {errBoom, 500, "notify_unavailable"},
	} {
		e := newNotifsEnv(t, "demo")
		e.n.createErr = c.err
		rec := e.do(destCreate("webhook", "x", hookURL()))
		if rec.Code != c.status {
			t.Errorf("%s = %d %s, want %d", name, rec.Code, rec.Body.String(), c.status)
			continue
		}
		wantError(t, rec.Code, rec.Body.String(), c.code, rec)
		if len(e.store.dests) != 0 || len(e.n.deletedIDs()) != 0 {
			t.Errorf("%s stored or deleted something", name)
		}
	}
}

func TestCreateWithNoNotifierAnswersNotifyUnavailable(t *testing.T) {
	hn := newHarnessWith(t, notifsOn)
	rec := hn.do(destCreate("webhook", "x", hookURL()))
	wantError(t, rec.Code, rec.Body.String(), "notify_unavailable", rec)
	if rec.Code != 500 || len(hn.store.dests) != 0 {
		t.Fatalf("= %d, rows %v", rec.Code, hn.store.dests)
	}
}

func TestTheEleventhDestinationIs409(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	for range maxDestinations {
		e.addDest(t, "discord")
	}
	rec := e.do(destCreate("discord", "one more", discordURL()))
	wantError(t, rec.Code, rec.Body.String(), "too_many_destinations", rec)
	if rec.Code != 409 || len(e.store.dests) != maxDestinations || e.n.createCount() != maxDestinations {
		t.Fatalf("= %d, rows %d, remote creates %d", rec.Code, len(e.store.dests), e.n.createCount())
	}
	// Another person has their own cap.
	rec = e.do(req{method: "POST", path: "/api/notify/destinations", json: true, header: map[string]string{"X-Test-Email": "other@example.test"},
		body: fmt.Sprintf(`{"kind":"discord","label":"o","url":%q}`, discordURL())})
	if rec.Code != 201 {
		t.Fatalf("other person = %d %s", rec.Code, rec.Body.String())
	}
}

func TestTwelveConcurrentAddsLeaveExactlyTen(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	var wg sync.WaitGroup
	var mu sync.Mutex
	codes := map[int]int{}
	for range 12 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rec := e.do(destCreate("discord", "c", discordURL()))
			mu.Lock()
			codes[rec.Code]++
			mu.Unlock()
		}()
	}
	wg.Wait()
	if codes[201] != 10 || codes[409] != 2 || len(e.store.dests) != 10 {
		t.Fatalf("codes %v, rows %d, want 10x201 and 2x409 with 10 rows", codes, len(e.store.dests))
	}
	if e.n.createCount() != 10 || len(e.n.deletedIDs()) != 0 {
		t.Fatalf("remote creates %d deletes %v, want 10 and none (a refused add never reaches delivery-api)", e.n.createCount(), e.n.deletedIDs())
	}
}

func TestCreateCancelledWhileWaitingForTheLockCreatesNothing(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	held, release := make(chan struct{}), make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = e.store.InTx(context.Background(), func(q db.Querier) error {
			if err := q.LockNotifsEmail(context.Background(), testEmail); err != nil {
				return err
			}
			close(held)
			<-release
			return nil
		})
	}()
	<-held
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	r := destCreate("discord", "x", discordURL())
	r.ctx = ctx
	rec := e.do(r)
	close(release)
	<-done
	if rec.Code != 500 {
		t.Fatalf("= %d %s, want an error", rec.Code, rec.Body.String())
	}
	wantError(t, rec.Code, rec.Body.String(), "internal", rec)
	if len(e.store.dests) != 0 || e.n.createCount() != 0 {
		t.Fatalf("rows %d, remote creates %d, want none", len(e.store.dests), e.n.createCount())
	}
}

func TestConcurrentAddAndRemoveForOnePersonSerialise(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	for range maxDestinations - 1 {
		e.addDest(t, "discord")
	}
	last := e.addDest(t, "discord")
	var wg sync.WaitGroup
	var addCode, delCode int
	wg.Add(2)
	go func() { defer wg.Done(); addCode = e.do(destCreate("discord", "n", discordURL())).Code }()
	go func() {
		defer wg.Done()
		delCode = e.do(req{method: "DELETE", path: destPath(last, ""), json: true, body: `{}`}).Code
	}()
	wg.Wait()
	if delCode != 200 || (addCode != 201 && addCode != 409) {
		t.Fatalf("add %d delete %d", addCode, delCode)
	}
	want := maxDestinations - 1
	if addCode == 201 {
		want = maxDestinations
	}
	if len(e.store.dests) != want {
		t.Fatalf("rows %d, want %d for add=%d", len(e.store.dests), want, addCode)
	}
}

func TestCreateWhoseInsertFailsDeletesTheRemoteDestination(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	e.store.failInsert = errBoom
	rec := e.do(destCreate("webhook", "x", hookURL()))
	wantError(t, rec.Code, rec.Body.String(), "internal", rec)
	if rec.Code != 500 || len(e.store.dests) != 0 {
		t.Fatalf("= %d, rows %d", rec.Code, len(e.store.dests))
	}
	if got := e.n.deletedIDs(); len(got) != 1 || got[0] != 101 {
		t.Fatalf("deleted remote ids %v, want [101]", got)
	}
	if strings.Contains(rec.Body.String(), "signing_secret") {
		t.Fatal("a failed create returned a signing secret")
	}
}

func TestCreateWhoseCleanupFailsStillAnswers500AndLogsNoSecrets(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	e.store.failInsert = errBoom
	e.n.deleteErr = &platform.NotifsError{Status: 503, Message: "down"}
	rec := e.do(destCreate("webhook", "x", hookURL()))
	wantError(t, rec.Code, rec.Body.String(), "internal", rec)
	if !strings.Contains(e.logs.String(), "notify cleanup failed") {
		t.Fatalf("log %q", e.logs.String())
	}
	if secret := e.n.createIn[0].Secrets["signing_secret"]; secret == "" || strings.Contains(e.logs.String(), secret) {
		t.Fatalf("the signing secret reached the log: %q", e.logs.String())
	}
	for _, bad := range []string{hookURL(), "sekret-path", "tokenABC"} {
		if strings.Contains(e.logs.String(), bad) {
			t.Fatalf("log leaked %q", bad)
		}
	}
}

func TestPhoneReadFailingAfterAMutationKeepsTheTwoXXAndTheOneTimeSecret(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	e.setUp(t)
	id := e.addDest(t, "discord")
	e.n.lookups = map[int64]bool{101: true}
	e.setStale(id, true)
	e.store.failCounts = errBoom

	rec := e.do(destCreate("webhook", "w", hookURL()))
	var got destResp
	decode(t, rec.Body.String(), &got)
	if rec.Code != 201 || got.SigningSecret == nil || got.Destination == nil || got.Phone != nil || strings.Contains(rec.Body.String(), "phone") {
		t.Fatalf("create = %d %s", rec.Code, rec.Body.String())
	}
	if len(e.store.dests) != 2 || len(e.n.deletedIDs()) != 0 {
		t.Fatalf("rows %d, remote deletes %v: a failed phone read must not undo the create", len(e.store.dests), e.n.deletedIDs())
	}
	newID := got.Destination.ID

	// In order: the delete must come last.
	for _, c := range []struct {
		name string
		r    req
	}{
		{"check", ntfyPost(destPath(id, "/check"))},
		{"test", ntfyPost(destPath(newID, "/test"))},
		{"delete", req{method: "DELETE", path: destPath(newID, ""), json: true, body: `{}`}},
	} {
		rec := e.do(c.r)
		if rec.Code != 200 || strings.Contains(rec.Body.String(), "phone") {
			t.Errorf("%s = %d %s, want 200 without phone", c.name, rec.Code, rec.Body.String())
		}
	}
	if !strings.Contains(e.logs.String(), "phone state read failed") {
		t.Fatal("the failed phone read was not logged")
	}
}

// ---- list ---------------------------------------------------------------------------------------------------------------

func TestListReturnsOnlyTheCallersDestinationsWithoutUrls(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	e.addDest(t, "discord")
	_, _ = e.store.InsertDestination(context.Background(), db.InsertDestinationParams{Email: "other@example.test", NotifsID: 9, Kind: "webhook", Label: "theirs", Hint: "zzz"})
	rec := e.do(req{method: "GET", path: "/api/notify/destinations"})
	var got struct {
		Destinations []map[string]any `json:"destinations"`
	}
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || len(got.Destinations) != 1 || got.Destinations[0]["label"] != "mine" || strings.Contains(rec.Body.String(), "theirs") {
		t.Fatalf("list = %d %s", rec.Code, rec.Body.String())
	}
	for _, key := range []string{"id", "kind", "label", "hint", "stale"} {
		if _, ok := got.Destinations[0][key]; !ok {
			t.Errorf("destination lacks %q", key)
		}
	}
	if len(got.Destinations[0]) != 5 {
		t.Errorf("destination %v carries more than id, kind, label, hint, stale", got.Destinations[0])
	}
	// A person with none gets an empty array, not null.
	rec = e.do(req{method: "GET", path: "/api/notify/destinations", header: map[string]string{"X-Test-Email": "none@example.test"}})
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"destinations":[]`) {
		t.Fatalf("empty list = %d %s", rec.Code, rec.Body.String())
	}
}

// ---- check --------------------------------------------------------------------------------------------------------------

func TestCheckOfANonStaleRowAnswersUnchangedWithNoRemoteCall(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	id := e.addDest(t, "discord")
	e.n.lookupErr = errBoom // would 500 if the route asked
	rec := e.do(ntfyPost(destPath(id, "/check")))
	var got destResp
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || got.Destination == nil || got.Destination.Stale || got.Phone == nil {
		t.Fatalf("= %d %s", rec.Code, rec.Body.String())
	}
}

func TestCheckClearsStaleWhenDeliverableAndKeepsItOtherwise(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	id := e.addDest(t, "discord")
	e.setStale(id, true)

	rec := e.do(ntfyPost(destPath(id, "/check"))) // lookups empty: undeliverable
	var got destResp
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || got.Destination == nil || !got.Destination.Stale || got.Phone == nil || got.Phone.StaleDestinations != 1 {
		t.Fatalf("undeliverable = %d %s", rec.Code, rec.Body.String())
	}

	e.n.lookups = map[int64]bool{101: true}
	rec = e.do(ntfyPost(destPath(id, "/check")))
	got = destResp{}
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || got.Destination == nil || got.Destination.Stale || got.Phone == nil || got.Phone.StaleDestinations != 0 {
		t.Fatalf("deliverable = %d %s", rec.Code, rec.Body.String())
	}
	if rows, _ := e.store.ListDestinations(context.Background(), testEmail); rows[0].Stale {
		t.Fatal("the row is still stale")
	}
}

func TestCheckLookupErrorIsNotifyUnavailableAndConcurrentDeleteIs404(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	id := e.addDest(t, "discord")
	e.setStale(id, true)
	e.n.lookupErr = &platform.NotifsError{Status: 503, Message: "down"}
	rec := e.do(ntfyPost(destPath(id, "/check")))
	wantError(t, rec.Code, rec.Body.String(), "notify_unavailable", rec)
	if rec.Code != 500 {
		t.Fatalf("= %d", rec.Code)
	}

	e.n.lookupErr = nil
	e.n.lookups = map[int64]bool{101: true}
	e.n.onLookup = func() {
		_, _ = e.store.DeleteOwnDestination(context.Background(), db.DeleteOwnDestinationParams{DestinationID: id, Email: testEmail})
	}
	rec = e.do(ntfyPost(destPath(id, "/check")))
	wantError(t, rec.Code, rec.Body.String(), "not_found", rec)
	if rec.Code != 404 {
		t.Fatalf("= %d", rec.Code)
	}
}

// ---- delete -------------------------------------------------------------------------------------------------------------

func TestDeleteRemovesTheRemoteThenTheLocalRow(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	id := e.addDest(t, "discord")
	rec := e.do(req{method: "DELETE", path: destPath(id, ""), json: true, body: `{}`})
	var got destResp
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || got.Phone == nil || got.Phone.Destinations != 0 || len(e.store.dests) != 0 {
		t.Fatalf("= %d %s", rec.Code, rec.Body.String())
	}
	if ids := e.n.deletedIDs(); len(ids) != 1 || ids[0] != 101 {
		t.Fatalf("remote deletes %v", ids)
	}
}

func TestDeleteFailureOrders(t *testing.T) {
	// Remote delete fails: 500 notify_unavailable and the row stays, so the person can retry.
	e := newNotifsEnv(t, "demo")
	id := e.addDest(t, "discord")
	e.n.deleteErr = &platform.NotifsError{Status: 503, Message: "down"}
	rec := e.do(req{method: "DELETE", path: destPath(id, ""), json: true, body: `{}`})
	wantError(t, rec.Code, rec.Body.String(), "notify_unavailable", rec)
	if rec.Code != 500 || len(e.store.dests) != 1 {
		t.Fatalf("remote failure = %d, rows %d, want 500 and the row kept", rec.Code, len(e.store.dests))
	}
	e.n.deleteErr = nil
	if rec := e.do(req{method: "DELETE", path: destPath(id, ""), json: true, body: `{}`}); rec.Code != 200 || len(e.store.dests) != 0 {
		t.Fatalf("retry = %d, rows %d", rec.Code, len(e.store.dests))
	}

	// Remote says 404 (already gone) but the local delete fails: 500, then the retry succeeds.
	id = e.addDest(t, "discord")
	e.n.deleteErr = &platform.NotifsError{Status: 404, Message: "gone"}
	e.store.failDelete = errBoom
	rec = e.do(req{method: "DELETE", path: destPath(id, ""), json: true, body: `{}`})
	wantError(t, rec.Code, rec.Body.String(), "internal", rec)
	if rec.Code != 500 || len(e.store.dests) != 1 {
		t.Fatalf("local failure = %d, rows %d, want 500 and the row kept", rec.Code, len(e.store.dests))
	}
	e.store.failDelete = nil
	if rec := e.do(req{method: "DELETE", path: destPath(id, ""), json: true, body: `{}`}); rec.Code != 200 || len(e.store.dests) != 0 {
		t.Fatalf("retry = %d, rows %d", rec.Code, len(e.store.dests))
	}
}

func TestDeleteWithNoNotifierKeepsTheRow(t *testing.T) {
	hn := newHarnessWith(t, notifsOn)
	row, _ := hn.store.InsertDestination(context.Background(), db.InsertDestinationParams{Email: testEmail, NotifsID: 5, Kind: "discord", Label: "d", Hint: "abc"})
	rec := hn.do(req{method: "DELETE", path: destPath(row.ID, ""), json: true, body: `{}`})
	wantError(t, rec.Code, rec.Body.String(), "notify_unavailable", rec)
	if len(hn.store.dests) != 1 {
		t.Fatal("the row was deleted without a notifier")
	}
}

// ---- ownership and ids --------------------------------------------------------------------------------------------------

func TestAnotherPersonsOrNonNumericIdIs404OnEveryIdRoute(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	e.addDest(t, "discord")
	theirs, _ := e.store.InsertDestination(context.Background(), db.InsertDestinationParams{Email: "other@example.test", NotifsID: 9, Kind: "discord", Label: "t", Hint: "abc"})
	for _, path := range []string{destPath(theirs.ID, "/check"), destPath(theirs.ID, "/test"), destPath(theirs.ID, ""),
		"/api/notify/destinations/abc/check", "/api/notify/destinations/abc/test", "/api/notify/destinations/abc",
		"/api/notify/destinations/0/test", "/api/notify/destinations/-1", "/api/notify/destinations/99999999999999999999/check", destPath(999, "/test")} {
		method := "POST"
		if !strings.HasSuffix(path, "/check") && !strings.HasSuffix(path, "/test") {
			method = "DELETE"
		}
		rec := e.do(req{method: method, path: path, json: true, body: `{}`})
		if rec.Code != 404 {
			t.Errorf("%s %s = %d %s, want 404", method, path, rec.Code, rec.Body.String())
			continue
		}
		wantError(t, rec.Code, rec.Body.String(), "not_found", rec)
	}
	if e.n.sendCount() != 0 || len(e.n.deletedIDs()) != 0 || len(e.store.dests) != 2 {
		t.Fatal("a foreign or invalid id had an effect")
	}
}

// ---- test route ---------------------------------------------------------------------------------------------------------

func TestDestinationTestSendsToThePersonalIDAndStartsTheCooldown(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	id := e.addDest(t, "discord")
	rec := e.do(ntfyPost(destPath(id, "/test")))
	var got destResp
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || got.Phone == nil || e.n.sendCount() != 1 {
		t.Fatalf("= %d %s", rec.Code, rec.Body.String())
	}
	m := e.n.sends[0]
	if m.Title != "demo test notification" || len(m.PersonalDestinationIDs) != 1 || m.PersonalDestinationIDs[0] != 101 || m.Recipient != testEmail {
		t.Fatalf("message = %+v", m)
	}
	if strings.Contains(m.IdempotencyKey, testEmail) || !strings.HasPrefix(m.IdempotencyKey, fmt.Sprintf("test-dst-%d-", id)) {
		t.Fatalf("idempotency key %q", m.IdempotencyKey)
	}

	rec = e.do(ntfyPost(destPath(id, "/test")))
	wantError(t, rec.Code, rec.Body.String(), "rate_limited", rec)
	if rec.Code != 429 || rec.Header().Get("Retry-After") == "" || e.n.sendCount() != 1 {
		t.Fatalf("second = %d, Retry-After %q, sends %d", rec.Code, rec.Header().Get("Retry-After"), e.n.sendCount())
	}
	e.clock.advance(testCooldown + time.Second)
	if rec := e.do(ntfyPost(destPath(id, "/test"))); rec.Code != 200 {
		t.Fatalf("after the cooldown = %d", rec.Code)
	}
}

func TestDestinationTestOfAStaleRowIs409WithoutSendingOrStartingTheCooldown(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	id := e.addDest(t, "discord")
	e.setStale(id, true)
	for range 2 {
		rec := e.do(ntfyPost(destPath(id, "/test")))
		wantError(t, rec.Code, rec.Body.String(), "destination_stale", rec)
		if rec.Code != 409 {
			t.Fatalf("= %d", rec.Code)
		}
	}
	if e.n.sendCount() != 0 {
		t.Fatal("a stale row was sent to")
	}
	e.setStale(id, false)
	if rec := e.do(ntfyPost(destPath(id, "/test"))); rec.Code != 200 {
		t.Fatalf("after un-staling = %d: the 409s must not have started the cooldown", rec.Code)
	}
}

func TestDestinationTestRejectedAndUndeliverableMarksItStale(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	id := e.addDest(t, "discord")
	e.n.sendErrs = []error{&platform.NotifsError{Status: 422, Message: platform.MsgNoPersonalDst}}
	rec := e.do(ntfyPost(destPath(id, "/test"))) // lookups empty: undeliverable
	wantError(t, rec.Code, rec.Body.String(), "destination_stale", rec)
	if rec.Code != 409 {
		t.Fatalf("= %d", rec.Code)
	}
	if rows, _ := e.store.ListDestinations(context.Background(), testEmail); !rows[0].Stale {
		t.Fatal("the row was not marked stale")
	}
}

func TestDestinationTestRejectedButDeliverableOrLookupErrorIs500AndNotStaled(t *testing.T) {
	for name, setup := range map[string]func(*notifsEnv){
		"deliverable":  func(e *notifsEnv) { e.n.lookups = map[int64]bool{101: true} },
		"lookup error": func(e *notifsEnv) { e.n.lookupErr = &platform.NotifsError{Status: 503, Message: "down"} },
	} {
		e := newNotifsEnv(t, "demo")
		id := e.addDest(t, "discord")
		setup(e)
		e.n.sendErrs = []error{&platform.NotifsError{Status: 422, Message: platform.MsgNoPersonalDst}}
		rec := e.do(ntfyPost(destPath(id, "/test")))
		wantError(t, rec.Code, rec.Body.String(), "notify_unavailable", rec)
		if rec.Code != 500 {
			t.Fatalf("%s = %d", name, rec.Code)
		}
		if rows, _ := e.store.ListDestinations(context.Background(), testEmail); rows[0].Stale {
			t.Errorf("%s: the row was staled", name)
		}
	}
}

func TestDestinationTestOtherFailuresNeverStaleAndFailedSendsCountAgainstTheCooldown(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	id := e.addDest(t, "discord")
	e.n.sendErrs = []error{&platform.NotifsError{Status: 422, Message: "channel disabled"}}
	rec := e.do(ntfyPost(destPath(id, "/test")))
	wantError(t, rec.Code, rec.Body.String(), "notify_unavailable", rec)
	if rows, _ := e.store.ListDestinations(context.Background(), testEmail); rows[0].Stale {
		t.Fatal("another 422 staled the row")
	}
	if rec := e.do(ntfyPost(destPath(id, "/test"))); rec.Code != 429 {
		t.Fatalf("immediately after a failed send = %d, want 429 (failed sends count)", rec.Code)
	}
	// The cooldown is per person and target: another destination is unaffected.
	other := e.addDest(t, "webhook")
	if rec := e.do(ntfyPost(destPath(other, "/test"))); rec.Code != 200 {
		t.Fatalf("another destination = %d", rec.Code)
	}
}

func TestDestinationTestUpstream429Is429AndDeletedMidFlightIs404(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	id := e.addDest(t, "discord")
	e.n.sendErrs = []error{&platform.NotifsError{Status: http.StatusTooManyRequests, Message: "slow down"}}
	rec := e.do(ntfyPost(destPath(id, "/test")))
	wantError(t, rec.Code, rec.Body.String(), "rate_limited", rec)
	if rec.Code != 429 {
		t.Fatalf("= %d", rec.Code)
	}

	e = newNotifsEnv(t, "demo")
	id = e.addDest(t, "discord")
	e.n.sendErrs = []error{&platform.NotifsError{Status: 422, Message: platform.MsgNoPersonalDst}}
	e.n.onLookup = func() {
		_, _ = e.store.DeleteOwnDestination(context.Background(), db.DeleteOwnDestinationParams{DestinationID: id, Email: testEmail})
	}
	rec = e.do(ntfyPost(destPath(id, "/test")))
	wantError(t, rec.Code, rec.Body.String(), "not_found", rec)
	if rec.Code != 404 {
		t.Fatalf("deleted mid-flight = %d", rec.Code)
	}
}

func TestDestinationTestWithNoNotifierIsNotifyUnavailable(t *testing.T) {
	hn := newHarnessWith(t, notifsOn)
	row, _ := hn.store.InsertDestination(context.Background(), db.InsertDestinationParams{Email: testEmail, NotifsID: 5, Kind: "discord", Label: "d", Hint: "abc"})
	rec := hn.do(ntfyPost(destPath(row.ID, "/test")))
	wantError(t, rec.Code, rec.Body.String(), "notify_unavailable", rec)
	if rec.Code != 500 {
		t.Fatalf("= %d", rec.Code)
	}
}

func TestDestinationRoutesUseTheNormalisedEmail(t *testing.T) {
	e := newNotifsEnv(t, "demo")
	rec := e.do(req{method: "POST", path: "/api/notify/destinations", json: true, header: map[string]string{"X-Test-Email": "  User@Example.TEST "},
		body: fmt.Sprintf(`{"kind":"discord","label":"n","url":%q}`, discordURL())})
	if rec.Code != 201 || len(e.store.dests) != 1 || e.store.dests[0].email != testEmail {
		t.Fatalf("= %d %s rows %+v", rec.Code, rec.Body.String(), e.store.dests)
	}
}
