package platform

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	testNotifsKey    = "dak_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	testNotifsID     = "id-client.access"
	testNotifsSecret = "s3cr3t-client-value"
	testNotifsEmail  = "person@example.test"
)

type recordedRequest struct {
	Method string
	Path   string
	Header http.Header
	Body   string
}

// notifsServer records every request and answers with the handler's status and body.
type notifsServer struct {
	*httptest.Server
	mu       sync.Mutex
	requests []recordedRequest
	status   int
	body     string
	delay    time.Duration
	block    chan struct{} // when set, the handler waits for it to close (or the client to go away) before answering
	location string        // sets a Location header (with a 3xx status) when non-empty
}

func newNotifsServer(t *testing.T) *notifsServer {
	t.Helper()
	s := &notifsServer{status: http.StatusOK, body: `{}`}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		s.mu.Lock()
		s.requests = append(s.requests, recordedRequest{Method: r.Method, Path: r.URL.Path, Header: r.Header.Clone(), Body: string(b)})
		status, body, delay, loc := s.status, s.body, s.delay, s.location
		s.mu.Unlock()
		if s.block != nil {
			select {
			case <-s.block:
			case <-r.Context().Done():
			}
		}
		if delay > 0 {
			time.Sleep(delay)
		}
		if loc != "" {
			w.Header().Set("Location", loc)
		}
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(s.Close)
	return s
}

func (s *notifsServer) set(status int, body string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.status, s.body = status, body
}

func (s *notifsServer) reqs() []recordedRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]recordedRequest(nil), s.requests...)
}

func writeNotifsFiles(t *testing.T, dir string, files map[string]string) {
	t.Helper()
	for name, v := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(v), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func fullFiles(srv *notifsServer) map[string]string {
	return map[string]string{
		"notifs-key":                  testNotifsKey + "\n",
		"notifs-access-client-id":     testNotifsID + "\n",
		"notifs-access-client-secret": testNotifsSecret + "\n",
		"notifs-base-url":             srv.URL + "\n",
	}
}

func newTestNotifs(t *testing.T, srv *notifsServer) (*NotifsClient, string, *bytes.Buffer) {
	t.Helper()
	dir := t.TempDir()
	writeNotifsFiles(t, dir, fullFiles(srv))
	c := NewNotifsClient(dir, "apps_birthdays")
	var buf bytes.Buffer
	c.Logger = slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug}))
	return c, dir, &buf
}

func TestNotifsSendHeadersBodyAndResult(t *testing.T) {
	srv := newNotifsServer(t)
	srv.set(http.StatusAccepted, `{"message":{"message_id":"m1"},"duplicate":true}`)
	c, _, _ := newTestNotifs(t, srv)
	res, err := c.Send(context.Background(), Message{
		Channel: "all", IdempotencyKey: "rem-1", Recipient: testNotifsEmail, Via: "both",
		PersonalDestinationIDs: []int64{3, 4}, Title: "T", Body: "B",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Status != 202 || res.MessageID != "m1" || !res.Duplicate {
		t.Fatalf("result %+v", res)
	}
	got := srv.reqs()
	if len(got) != 1 || got[0].Method != "POST" || got[0].Path != "/v1/messages" {
		t.Fatalf("requests %+v", got)
	}
	h := got[0].Header
	if h.Get("CF-Access-Client-Id") != testNotifsID || h.Get("CF-Access-Client-Secret") != testNotifsSecret ||
		h.Get("Authorization") != "Bearer "+testNotifsKey || h.Get("Content-Type") != "application/json" {
		t.Fatalf("headers %v", h)
	}
	var body map[string]any
	if err := json.Unmarshal([]byte(got[0].Body), &body); err != nil {
		t.Fatal(err)
	}
	to := body["to"].(map[string]any)
	display := body["display"].(map[string]any)
	if body["app_id"] != "apps_birthdays" || body["channel"] != "all" || body["idempotency_key"] != "rem-1" ||
		to["recipient"] != testNotifsEmail || to["via"] != "both" || !reflect.DeepEqual(to["personal_destination_ids"], []any{3.0, 4.0}) ||
		display["title"] != "T" || display["body"] != "B" {
		t.Fatalf("body %s", got[0].Body)
	}
}

func TestNotifsSendAcceptedWithUnreadableBodyIsStillSuccess(t *testing.T) {
	srv := newNotifsServer(t)
	srv.set(http.StatusAccepted, `not json`)
	c, _, _ := newTestNotifs(t, srv)
	res, err := c.Send(context.Background(), Message{Channel: "all", IdempotencyKey: "k", Recipient: testNotifsEmail})
	if err != nil || res.Status != 202 {
		t.Fatalf("res %+v err %v", res, err)
	}
}

func TestNotifsKeyIsReReadOnEveryCall(t *testing.T) {
	srv := newNotifsServer(t)
	c, dir, _ := newTestNotifs(t, srv)
	if _, err := c.Send(context.Background(), Message{Channel: "all", IdempotencyKey: "k", Recipient: testNotifsEmail}); err != nil {
		t.Fatal(err)
	}
	writeNotifsFiles(t, dir, map[string]string{"notifs-key": "dak_rotated\n"})
	if _, err := c.Send(context.Background(), Message{Channel: "all", IdempotencyKey: "k", Recipient: testNotifsEmail}); err != nil {
		t.Fatal(err)
	}
	got := srv.reqs()
	if len(got) != 2 || got[0].Header.Get("Authorization") != "Bearer "+testNotifsKey || got[1].Header.Get("Authorization") != "Bearer dak_rotated" {
		t.Fatalf("authorization headers: %+v", got)
	}
}

func TestNotifsStatusClassification(t *testing.T) {
	cases := []struct {
		status    int
		body      string
		retryable bool
		message   string
	}{
		{500, `{"error":"boom"}`, true, "boom"},
		{503, `{"error":"personal destinations unavailable"}`, true, "personal destinations unavailable"},
		{400, `{"error":"invalid JSON body"}`, false, "invalid JSON body"},
		{401, `{"error":"unauthorized"}`, false, "unauthorized"},
		{403, `<html>access denied</html>`, false, ""},
		{404, `{"error":"user does not exist"}`, false, "user does not exist"},
		{422, `{"error":"app has no ntfy publisher"}`, false, "app has no ntfy publisher"},
		{429, `{"error":"too many password changes"}`, false, "too many password changes"},
	}
	for _, tc := range cases {
		srv := newNotifsServer(t)
		srv.set(tc.status, tc.body)
		c, _, _ := newTestNotifs(t, srv)
		_, err := c.Send(context.Background(), Message{Channel: "all", IdempotencyKey: "k", Recipient: testNotifsEmail})
		var ne *NotifsError
		if !errors.As(err, &ne) || ne.Status != tc.status || ne.Message != tc.message {
			t.Errorf("status %d: err = %v, want *NotifsError{%d, %q}", tc.status, err, tc.status, tc.message)
			continue
		}
		if errors.Is(err, ErrNotifsRetryable) != tc.retryable {
			t.Errorf("status %d: retryable = %v, want %v", tc.status, !tc.retryable, tc.retryable)
		}
		if errors.Is(err, ErrNotifsUnconfigured) {
			t.Errorf("status %d: reported as unconfigured", tc.status)
		}
	}
}

func TestNotifsErrorMessageIsCapped(t *testing.T) {
	srv := newNotifsServer(t)
	srv.set(400, `{"error":"`+strings.Repeat("x", 1000)+`"}`)
	c, _, _ := newTestNotifs(t, srv)
	_, err := c.Send(context.Background(), Message{Channel: "all", IdempotencyKey: "k", Recipient: testNotifsEmail})
	var ne *NotifsError
	if !errors.As(err, &ne) || len(ne.Message) != 200 {
		t.Fatalf("err = %v", err)
	}
}

func TestNotifsNetworkFailureIsRetryableAndNamesNoURL(t *testing.T) {
	srv := newNotifsServer(t)
	c, _, _ := newTestNotifs(t, srv)
	srv.Close() // the base URL now refuses connections
	_, err := c.Send(context.Background(), Message{Channel: "all", IdempotencyKey: "k", Recipient: testNotifsEmail})
	if !errors.Is(err, ErrNotifsRetryable) {
		t.Fatalf("err = %v, want ErrNotifsRetryable", err)
	}
	if strings.Contains(err.Error(), srv.URL) || strings.Contains(err.Error(), "127.0.0.1") {
		t.Fatalf("error text names the URL: %v", err)
	}
}

func TestNotifsMissingFilesAreUnconfiguredAndSendNothing(t *testing.T) {
	for _, missing := range []string{"notifs-key", "notifs-access-client-id", "notifs-access-client-secret", "notifs-base-url"} {
		srv := newNotifsServer(t)
		dir := t.TempDir()
		files := fullFiles(srv)
		delete(files, missing)
		writeNotifsFiles(t, dir, files)
		c := NewNotifsClient(dir, "apps_birthdays")
		if err := c.Configured(); !errors.Is(err, ErrNotifsUnconfigured) {
			t.Errorf("without %s: Configured = %v", missing, err)
		}
		if _, err := c.Send(context.Background(), Message{Channel: "all", IdempotencyKey: "k", Recipient: testNotifsEmail}); !errors.Is(err, ErrNotifsUnconfigured) {
			t.Errorf("without %s: Send = %v", missing, err)
		}
		if err := c.EnsurePublisher(context.Background()); !errors.Is(err, ErrNotifsUnconfigured) {
			t.Errorf("without %s: EnsurePublisher = %v", missing, err)
		}
		if n := len(srv.reqs()); n != 0 {
			t.Errorf("without %s: %d requests reached the server", missing, n)
		}
	}
}

func TestNotifsOnlyOneAccessFileMeansNoRequest(t *testing.T) {
	for _, only := range []string{"notifs-access-client-id", "notifs-access-client-secret"} {
		srv := newNotifsServer(t)
		dir := t.TempDir()
		files := fullFiles(srv)
		delete(files, "notifs-access-client-id")
		delete(files, "notifs-access-client-secret")
		files[only] = "present\n"
		writeNotifsFiles(t, dir, files)
		c := NewNotifsClient(dir, "apps_birthdays")
		if _, err := c.Provision(context.Background(), testNotifsEmail); !errors.Is(err, ErrNotifsUnconfigured) {
			t.Errorf("only %s: err = %v", only, err)
		}
		if n := len(srv.reqs()); n != 0 {
			t.Errorf("only %s: %d requests reached the server", only, n)
		}
	}
}

func TestNotifsEmptyFileAndBadBaseURLAreUnconfigured(t *testing.T) {
	srv := newNotifsServer(t)
	for name, override := range map[string]map[string]string{
		"empty key":          {"notifs-key": "\n"},
		"base url no scheme": {"notifs-base-url": "notifs-delivery.example.test"},
		"base url ftp":       {"notifs-base-url": "ftp://x.example.test"},
	} {
		dir := t.TempDir()
		files := fullFiles(srv)
		for k, v := range override {
			files[k] = v
		}
		writeNotifsFiles(t, dir, files)
		if err := NewNotifsClient(dir, "apps_birthdays").Configured(); !errors.Is(err, ErrNotifsUnconfigured) {
			t.Errorf("%s: Configured = %v", name, err)
		}
	}
}

func TestNotifsConfiguredNeedsAllFourAndMakesNoRequest(t *testing.T) {
	srv := newNotifsServer(t)
	c, _, _ := newTestNotifs(t, srv)
	if err := c.Configured(); err != nil {
		t.Fatalf("Configured with all four files = %v", err)
	}
	if n := len(srv.reqs()); n != 0 {
		t.Fatalf("Configured made %d requests", n)
	}
	// Construction never needs the files either.
	if NewNotifsClient(filepath.Join(t.TempDir(), "absent"), "apps_birthdays") == nil {
		t.Fatal("nil client")
	}
}

func TestNotifsRedirectIsNotFollowed(t *testing.T) {
	target := newNotifsServer(t)
	srv := newNotifsServer(t)
	srv.status = http.StatusFound
	srv.location = target.URL + "/stolen"
	c, _, _ := newTestNotifs(t, srv)
	_, err := c.Send(context.Background(), Message{Channel: "all", IdempotencyKey: "k", Recipient: testNotifsEmail})
	var ne *NotifsError
	if !errors.As(err, &ne) || ne.Status != http.StatusFound {
		t.Fatalf("err = %v, want *NotifsError with status 302", err)
	}
	if n := len(target.reqs()); n != 0 {
		t.Fatalf("the redirect target received %d requests (credentials would have followed)", n)
	}
}

func TestNotifsTimeoutIsHonoured(t *testing.T) {
	srv := newNotifsServer(t)
	// The handler blocks until cleanup (registered after the server's own, so it runs first and Close never waits).
	srv.block = make(chan struct{})
	t.Cleanup(func() { close(srv.block) })
	c, _, _ := newTestNotifs(t, srv)
	if c.hc.Timeout != 10*time.Second {
		t.Fatalf("default timeout = %v, want 10s", c.hc.Timeout)
	}
	c.hc.Timeout = 100 * time.Millisecond
	started := time.Now()
	_, err := c.Send(context.Background(), Message{Channel: "all", IdempotencyKey: "k", Recipient: testNotifsEmail})
	if !errors.Is(err, ErrNotifsRetryable) || !strings.Contains(err.Error(), "timeout") {
		t.Fatalf("err = %v, want a retryable timeout", err)
	}
	if time.Since(started) > 2*time.Second {
		t.Fatalf("returned after %v, the timeout did not cut the call short", time.Since(started))
	}
}

func TestNotifsCancelledContextIsRetryable(t *testing.T) {
	srv := newNotifsServer(t)
	c, _, _ := newTestNotifs(t, srv)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := c.Send(ctx, Message{Channel: "all", IdempotencyKey: "k", Recipient: testNotifsEmail}); !errors.Is(err, ErrNotifsRetryable) || !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v, want retryable and context.Canceled", err)
	}
}

func TestNotifsPersonalDestinationCalls(t *testing.T) {
	srv := newNotifsServer(t)
	c, _, _ := newTestNotifs(t, srv)
	ctx := context.Background()

	srv.set(200, `{"personal_destination":{"id":42}}`)
	id, err := c.CreatePersonalDestination(ctx, testNotifsEmail, PersonalDestinationInput{
		Label: "Family", Type: "discord", Config: map[string]string{"a": "b"}, Secrets: map[string]string{"webhook_url": "https://x.example.test/h"},
	})
	if err != nil || id != 42 {
		t.Fatalf("create = %d, %v", id, err)
	}
	srv.set(200, `{"id":42,"deleted":true}`)
	if err := c.DeletePersonalDestination(ctx, testNotifsEmail, 42); err != nil {
		t.Fatal(err)
	}
	srv.set(200, `{}`)
	if err := c.EnsurePublisher(ctx); err != nil {
		t.Fatal(err)
	}

	got := srv.reqs()
	if len(got) != 3 {
		t.Fatalf("requests %+v", got)
	}
	var create map[string]any
	if err := json.Unmarshal([]byte(got[0].Body), &create); err != nil {
		t.Fatal(err)
	}
	if got[0].Method != "POST" || got[0].Path != "/v1/apps/apps_birthdays/personal-destinations" ||
		create["email"] != testNotifsEmail || create["opt_in"] != true || create["type"] != "discord" || create["label"] != "Family" {
		t.Fatalf("create request %+v", got[0])
	}
	if got[1].Method != "DELETE" || got[1].Path != "/v1/apps/apps_birthdays/personal-destinations/42" {
		t.Fatalf("delete request %+v", got[1])
	}
	if got[1].Body != `{"email":"`+testNotifsEmail+`"}` {
		t.Fatalf("DELETE body = %q, want the person as JSON (an empty body is a 400)", got[1].Body)
	}
	if got[2].Method != "POST" || got[2].Path != "/v1/apps/apps_birthdays/ntfy-publisher" || got[2].Body != `{}` {
		t.Fatalf("publisher request %+v", got[2])
	}
}

func TestNotifsCreateWithoutAnIDIsAnError(t *testing.T) {
	srv := newNotifsServer(t)
	srv.set(200, `{"personal_destination":{}}`)
	c, _, _ := newTestNotifs(t, srv)
	// nil Config and Secrets go out as {} (never null).
	defer func() {
		got := srv.reqs()
		if len(got) != 1 || !strings.Contains(got[0].Body, `"config":{}`) || !strings.Contains(got[0].Body, `"secrets":{}`) {
			t.Errorf("create body for nil maps: %+v", got)
		}
	}()
	if _, err := c.CreatePersonalDestination(context.Background(), testNotifsEmail, PersonalDestinationInput{}); !errors.Is(err, ErrNotifsRetryable) {
		t.Fatalf("err = %v", err)
	}
}

func TestNotifsProvisionAndResetPassword(t *testing.T) {
	srv := newNotifsServer(t)
	c, _, _ := newTestNotifs(t, srv)
	ctx := context.Background()
	srv.set(200, `{"user_id":"u_abc","person_hash":"h","topic_pattern":"t","broadcast_topic":"b","token":"tk_secret","password":"aaaa-bbbb-cccc-dddd"}`)
	p, err := c.Provision(ctx, testNotifsEmail)
	if err != nil || p.UserID != "u_abc" || p.PersonHash != "h" || p.Password != "aaaa-bbbb-cccc-dddd" {
		t.Fatalf("provision = %+v, %v", p, err)
	}
	srv.set(200, `{"user_id":"u_abc","app_id":"apps_birthdays"}`)
	p, err = c.Provision(ctx, testNotifsEmail)
	if err != nil || p.Password != "" {
		t.Fatalf("returning person must have no password: %+v, %v", p, err)
	}
	srv.set(200, `{"user_id":"u_abc","app_id":"apps_birthdays","password":"eeee-ffff-gggg-hhhh"}`)
	r, err := c.ResetPassword(ctx, testNotifsEmail)
	if err != nil || r.Password != "eeee-ffff-gggg-hhhh" || r.UserID != "u_abc" {
		t.Fatalf("reset = %+v, %v", r, err)
	}
	srv.set(200, `not json`)
	if _, err := c.Provision(ctx, testNotifsEmail); !errors.Is(err, ErrNotifsRetryable) {
		t.Fatalf("unreadable provision answer: %v", err)
	}
	srv.set(404, `{"error":"user does not exist"}`)
	var ne *NotifsError
	if _, err := c.ResetPassword(ctx, testNotifsEmail); !errors.As(err, &ne) || ne.Status != 404 {
		t.Fatalf("reset 404: %v", err)
	}
	got := srv.reqs()
	if len(got) != 5 {
		t.Fatalf("got %d requests, want 5: %+v", len(got), got)
	}
	if got[0].Path != "/v1/apps/apps_birthdays/provision" || got[2].Path != "/v1/apps/apps_birthdays/reset-password" ||
		got[0].Body != `{"email":"`+testNotifsEmail+`"}` {
		t.Fatalf("requests %+v", got)
	}
}

func TestDeliverablePredicate(t *testing.T) {
	cases := []struct {
		name  string
		found []lookedUp
		ids   []int64
		want  map[int64]bool
	}{
		{"enabled and opted in", []lookedUp{{1, true, true}}, []int64{1}, map[int64]bool{1: true}},
		{"disabled", []lookedUp{{1, false, true}}, []int64{1}, map[int64]bool{1: false}},
		{"not opted in", []lookedUp{{1, true, false}}, []int64{1}, map[int64]bool{1: false}},
		{"absent id", []lookedUp{{2, true, true}}, []int64{1}, map[int64]bool{1: false}},
		{"empty list", nil, []int64{1, 2}, map[int64]bool{1: false, 2: false}},
		{"extra ids ignored", []lookedUp{{1, true, true}, {9, true, true}}, []int64{1}, map[int64]bool{1: true}},
		{"mixed", []lookedUp{{1, true, true}, {2, false, false}}, []int64{1, 2, 3}, map[int64]bool{1: true, 2: false, 3: false}},
	}
	for _, tc := range cases {
		if got := deliverable(tc.found, tc.ids); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%s: got %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestNotifsLookupFiltersTheResponseToTheAskedIDs(t *testing.T) {
	srv := newNotifsServer(t)
	srv.set(200, `{"person_hash":"h","personal_destinations":[`+
		`{"id":1,"enabled":true,"opted_in":true},{"id":2,"enabled":false,"opted_in":true},`+
		`{"id":3,"enabled":true,"opted_in":false},{"id":9,"enabled":true,"opted_in":true}]}`)
	c, _, _ := newTestNotifs(t, srv)
	got, err := c.LookupPersonalDestinations(context.Background(), testNotifsEmail, []int64{1, 2, 3, 4})
	if err != nil {
		t.Fatal(err)
	}
	want := map[int64]bool{1: true, 2: false, 3: false, 4: false}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v (id 9 was not asked about)", got, want)
	}
	reqs := srv.reqs()
	if len(reqs) != 1 || reqs[0].Path != "/v1/apps/apps_birthdays/personal-destinations/lookup" || reqs[0].Body != `{"email":"`+testNotifsEmail+`"}` {
		t.Fatalf("requests %+v (the lookup takes only the person)", reqs)
	}
	if got, err := c.LookupPersonalDestinations(context.Background(), testNotifsEmail, nil); err != nil || len(got) != 0 || len(srv.reqs()) != 1 {
		t.Fatalf("no ids: %v %v, requests %d", got, err, len(srv.reqs()))
	}
	srv.set(200, `not json`)
	if _, err := c.LookupPersonalDestinations(context.Background(), testNotifsEmail, []int64{1}); !errors.Is(err, ErrNotifsRetryable) {
		t.Fatalf("unreadable lookup: %v", err)
	}
}

func TestNotifsAppIDFixture(t *testing.T) {
	f, err := os.Open("testdata/notifs-app-ids.txt")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	raw, err := io.ReadAll(f)
	if err != nil {
		t.Fatal(err)
	}
	checked := 0
	for _, line := range strings.Split(string(raw), "\n") {
		if strings.TrimSpace(line) == "" || strings.HasPrefix(line, "#") {
			continue
		}
		name, want, ok := strings.Cut(line, "\t")
		if !ok {
			t.Fatalf("fixture line %q has no tab", line)
		}
		got, err := NotifsAppID(name)
		if want == "REFUSED" {
			if err == nil {
				t.Errorf("%q: accepted as %q, want refused", name, got)
			}
		} else if err != nil || got != want {
			t.Errorf("%q: got %q, %v, want %q", name, got, err, want)
		}
		checked++
	}
	if checked < 10 {
		t.Fatalf("only %d fixture vectors read", checked)
	}
}

func TestNotifsInvalidClientAppIDSendsNothing(t *testing.T) {
	srv := newNotifsServer(t)
	dir := t.TempDir()
	writeNotifsFiles(t, dir, fullFiles(srv))
	c := NewNotifsClient(dir, "../evil")
	if err := c.EnsurePublisher(context.Background()); err == nil {
		t.Fatal("an invalid app id was accepted")
	}
	if n := len(srv.reqs()); n != 0 {
		t.Fatalf("%d requests", n)
	}
}

// TestNotifsLogsNeverContainSecretsEmailsOrURLs runs every method on a success and a failure path and scans what was
// logged, through both an explicit logger and the default logger.
func TestNotifsLogsNeverContainSecretsEmailsOrURLs(t *testing.T) {
	srv := newNotifsServer(t)
	c, _, buf := newTestNotifs(t, srv)
	ctx := context.Background()
	calls := map[string]func() error{
		"send": func() error {
			_, err := c.Send(ctx, Message{Channel: "all", IdempotencyKey: "k", Recipient: testNotifsEmail})
			return err
		},
		"provision": func() error { _, err := c.Provision(ctx, testNotifsEmail); return err },
		"reset":     func() error { _, err := c.ResetPassword(ctx, testNotifsEmail); return err },
		"create": func() error {
			_, err := c.CreatePersonalDestination(ctx, testNotifsEmail, PersonalDestinationInput{Secrets: map[string]string{"webhook_url": "https://hook.example.test/x"}})
			return err
		},
		"delete":    func() error { return c.DeletePersonalDestination(ctx, testNotifsEmail, 7) },
		"lookup":    func() error { _, err := c.LookupPersonalDestinations(ctx, testNotifsEmail, []int64{7}); return err },
		"publisher": func() error { return c.EnsurePublisher(ctx) },
	}
	srv.set(200, `{"personal_destination":{"id":7},"personal_destinations":[],"user_id":"u","message":{"message_id":"m"}}`)
	for name, call := range calls {
		if err := call(); err != nil {
			t.Fatalf("%s success path: %v", name, err)
		}
	}
	srv.set(500, `{"error":"`+testNotifsEmail+` leaked `+testNotifsKey+`"}`)
	failures := map[string]error{}
	for name, call := range calls {
		failures[name] = call()
	}
	srv.Close()
	for name, call := range calls {
		if err := call(); err == nil {
			t.Fatalf("%s network failure path: no error", name)
		}
	}
	// An unconfigured call (empty directory, same log buffer) and an invalid app id are scanned too.
	empty := NewNotifsClient(t.TempDir(), "apps_birthdays")
	empty.Logger = c.Logger
	if err := empty.EnsurePublisher(ctx); !errors.Is(err, ErrNotifsUnconfigured) {
		t.Fatalf("unconfigured call: %v", err)
	}
	badDir := t.TempDir()
	writeNotifsFiles(t, badDir, fullFiles(srv))
	bad := NewNotifsClient(badDir, "../evil")
	bad.Logger = c.Logger
	if err := bad.EnsurePublisher(ctx); err == nil {
		t.Fatal("an invalid app id was accepted")
	}
	// And with the default logger (a nil Logger field).
	var def bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&def, &slog.HandlerOptions{Level: slog.LevelDebug})))
	defer slog.SetDefault(prev)
	c.Logger = nil
	_ = c.EnsurePublisher(ctx)

	logged := buf.String() + def.String()
	if !strings.Contains(logged, "notifs call") {
		t.Fatalf("nothing was logged: %q", logged)
	}
	for _, secret := range []string{testNotifsKey, testNotifsSecret, testNotifsID, testNotifsEmail, srv.URL, "127.0.0.1", "hook.example.test", "Bearer", "leaked"} {
		if strings.Contains(logged, secret) {
			t.Errorf("the log contains %q", secret)
		}
	}
	// The log carries the status and operation, which is what an operator needs.
	if !strings.Contains(logged, "status=500") || !strings.Contains(logged, "op=send") {
		t.Errorf("the log lacks op and status: %s", logged)
	}
	// delivery-api's own error text is returned to the caller (it is the caller's to classify) but never logged.
	for name, err := range failures {
		var ne *NotifsError
		if !errors.As(err, &ne) || ne.Status != 500 {
			t.Errorf("%s: err = %v", name, err)
		}
	}
}
