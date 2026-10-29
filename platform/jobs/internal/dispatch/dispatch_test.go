package dispatch

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
)

const testSecret = "testsecretvalue"

func newDispatcher(t *testing.T, srv *httptest.Server, clk clock.Clock) *Dispatcher {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "a"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "a", "jobs-secret"), []byte(testSecret+"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	d := New(clk, dir, "test")
	d.URL = func(app string, port int, job string) string { return srv.URL + "/_jobs/" + job }
	return d
}

func baseReq() Request {
	return Request{
		App: "a", Port: 8080, Job: "j", Timeout: time.Minute, RunID: "01HZZZZZZZZZZZZZZZZZZZZZZZ",
		Trigger: "schedule", Attempt: 1, ScheduledFor: time.Date(2026, 1, 1, 15, 0, 7, 0, time.UTC),
	}
}

func TestRequestShapeMatchesContract(t *testing.T) {
	var gotHdr http.Header
	var gotBody map[string]any
	var gotPath, gotMethod string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotHdr, gotPath, gotMethod = r.Header.Clone(), r.URL.Path, r.Method
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()
	d := newDispatcher(t, srv, clock.NewFake(time.Now()))
	res := d.Call(context.Background(), baseReq())
	if res.Class != ClassOK || res.HTTPStatus != 204 || res.Err != "" {
		t.Fatalf("result = %+v", res)
	}
	if gotMethod != "POST" || gotPath != "/_jobs/j" {
		t.Fatalf("method/path = %s %s", gotMethod, gotPath)
	}
	if gotHdr.Get("Authorization") != "Bearer "+testSecret {
		t.Fatalf("Authorization = %q", gotHdr.Get("Authorization"))
	}
	if gotHdr.Get("Content-Type") != "application/json" || gotHdr.Get("X-Platform-Run-Id") != baseReq().RunID ||
		gotHdr.Get("User-Agent") != "platform-jobs-runner/test" {
		t.Fatalf("headers = %v", gotHdr)
	}
	want := map[string]any{
		"v": float64(1), "run_id": baseReq().RunID, "job": "j", "trigger": "schedule", "attempt": float64(1),
		"scheduled_for": "2026-01-01T15:00:07Z", "queue_id": nil, "enqueued_at": nil, "payload": nil,
	}
	if len(gotBody) != len(want) {
		t.Fatalf("body = %v", gotBody)
	}
	for k, v := range want {
		if gotBody[k] != v {
			t.Fatalf("body[%s] = %#v, want %#v", k, gotBody[k], v)
		}
	}
}

func TestQueuedRequestCarriesQueueFields(t *testing.T) {
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
	}))
	defer srv.Close()
	d := newDispatcher(t, srv, clock.NewFake(time.Now()))
	r := baseReq()
	r.Trigger, r.ScheduledFor = "queue", time.Time{}
	r.QueueID, r.EnqueuedAt = "q1", time.Date(2026, 1, 1, 1, 2, 3, 0, time.UTC)
	r.Payload = json.RawMessage(`{"x":1}`)
	if res := d.Call(context.Background(), r); res.Class != ClassOK {
		t.Fatalf("result = %+v", res)
	}
	if gotBody["queue_id"] != "q1" || gotBody["enqueued_at"] != "2026-01-01T01:02:03Z" || gotBody["scheduled_for"] != nil {
		t.Fatalf("body = %v", gotBody)
	}
	if p, _ := gotBody["payload"].(map[string]any); p["x"] != float64(1) {
		t.Fatalf("payload = %v", gotBody["payload"])
	}
}

func TestClassification(t *testing.T) {
	cases := map[int]Class{
		200: ClassOK, 201: ClassOK, 204: ClassOK, 299: ClassOK,
		408: ClassRetryable, 425: ClassRetryable, 429: ClassRetryable, 500: ClassRetryable, 503: ClassRetryable, 599: ClassRetryable,
		400: ClassPermanent, 401: ClassPermanent, 403: ClassPermanent, 404: ClassPermanent, 410: ClassPermanent,
		301: ClassPermanent, 302: ClassPermanent, 307: ClassPermanent, 100: ClassPermanent, 600: ClassPermanent, 0: ClassPermanent,
	}
	for status, want := range cases {
		if got := classify(status); got != want {
			t.Errorf("classify(%d) = %v, want %v", status, got, want)
		}
	}
	if Class(99).String() != "permanent" {
		t.Error("an unknown class must read as permanent")
	}
}

func TestRedirectsAreNotFollowed(t *testing.T) {
	for _, code := range []int{301, 302, 307} {
		var hits atomic.Int32
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			hits.Add(1)
			http.Redirect(w, r, "/elsewhere", code)
		}))
		d := newDispatcher(t, srv, clock.NewFake(time.Now()))
		res := d.Call(context.Background(), baseReq())
		srv.Close()
		if res.Class != ClassPermanent || res.HTTPStatus != code {
			t.Fatalf("%d: result = %+v", code, res)
		}
		if hits.Load() != 1 {
			t.Fatalf("%d: the redirect was followed (%d requests)", code, hits.Load())
		}
	}
}

func TestUnauthorizedIsPermanentWithStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "nope", http.StatusUnauthorized)
	}))
	defer srv.Close()
	res := newDispatcher(t, srv, clock.NewFake(time.Now())).Call(context.Background(), baseReq())
	if res.Class != ClassPermanent || res.HTTPStatus != 401 || res.Err != "nope" {
		t.Fatalf("result = %+v", res)
	}
}

func TestErrorTextIsMaskedSanitisedAndCapped(t *testing.T) {
	long := strings.Repeat("x", 500)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("boom\t" + testSecret + "\nBearer abc.def " + long))
	}))
	defer srv.Close()
	res := newDispatcher(t, srv, clock.NewFake(time.Now())).Call(context.Background(), baseReq())
	if res.Class != ClassRetryable || res.HTTPStatus != 500 {
		t.Fatalf("result = %+v", res)
	}
	if strings.Contains(res.Err, testSecret) || strings.Contains(res.Err, "abc.def") {
		t.Fatalf("secret or token leaked: %q", res.Err)
	}
	if strings.ContainsAny(res.Err, "\t\n") || len([]rune(res.Err)) > 300 {
		t.Fatalf("error not sanitised/capped: %q", res.Err)
	}
	if !strings.HasPrefix(res.Err, "boom *** Bearer ***") {
		t.Fatalf("error = %q", res.Err)
	}
}

func TestEmptyBodyGivesStatusText(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer srv.Close()
	res := newDispatcher(t, srv, clock.NewFake(time.Now())).Call(context.Background(), baseReq())
	if res.Err != "http 502" {
		t.Fatalf("Err = %q", res.Err)
	}
}

func TestTimeoutCancelsTheRequest(t *testing.T) {
	fake := clock.NewFake(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC))
	started := make(chan struct{})
	var cancelled sync.WaitGroup
	cancelled.Add(1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body) // the server only notices a hang-up once the body is consumed
		close(started)
		select {
		case <-r.Context().Done(): // the client hung up
		case <-time.After(10 * time.Second): // never hang the suite
		}
		cancelled.Done()
	}))
	defer srv.Close()
	d := newDispatcher(t, srv, fake)
	out := make(chan Result, 1)
	go func() { out <- d.Call(context.Background(), baseReq()) }()
	<-started
	select {
	case <-out:
		t.Fatal("call returned before the deadline")
	default:
	}
	fake.Advance(time.Minute)
	res := <-out
	if !res.Timeout || res.Class != ClassRetryable || !strings.HasPrefix(res.Err, "timeout after") {
		t.Fatalf("result = %+v", res)
	}
	cancelled.Wait() // the server saw the cancellation
}

func TestConnectionRefusedIsRetryable(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	d := newDispatcher(t, srv, clock.NewFake(time.Now()))
	srv.Close() // nothing listens any more
	res := d.Call(context.Background(), baseReq())
	if res.Class != ClassRetryable || res.Timeout || res.HTTPStatus != 0 || res.Err == "" {
		t.Fatalf("result = %+v", res)
	}
}

func TestMissingOrBadSecretMakesNoRequest(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits.Add(1) }))
	defer srv.Close()
	d := newDispatcher(t, srv, clock.NewFake(time.Now()))
	for name, content := range map[string]*string{"missing": nil, "empty": strPtr2(""), "newline only": strPtr2("\n"), "inner space": strPtr2("a b"), "inner newline": strPtr2("a\nb\n")} {
		p := filepath.Join(d.SecretsDir, "a", "jobs-secret")
		_ = os.Remove(p)
		if content != nil {
			if err := os.WriteFile(p, []byte(*content), 0o640); err != nil {
				t.Fatal(err)
			}
		}
		if res := d.Call(context.Background(), baseReq()); !res.NoSecret {
			t.Fatalf("%s: result = %+v", name, res)
		}
	}
	r := baseReq()
	r.App = "../a"
	if res := d.Call(context.Background(), r); !res.NoSecret {
		t.Fatalf("path traversal app: %+v", res)
	}
	if hits.Load() != 0 {
		t.Fatalf("%d requests were made without a usable secret", hits.Load())
	}
}

func strPtr2(s string) *string { return &s }

func TestOversizeOrNonRegularSecretFileIsNoSecret(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits.Add(1) }))
	defer srv.Close()
	d := newDispatcher(t, srv, clock.NewFake(time.Now()))
	p := filepath.Join(d.SecretsDir, "a", "jobs-secret")
	if err := os.WriteFile(p, []byte(strings.Repeat("s", maxSecretBytes+44)+"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if res := d.Call(context.Background(), baseReq()); !res.NoSecret {
		t.Fatalf("oversize secret: %+v", res)
	}
	// the limit is on the file: 256 characters plus a newline is 257 bytes
	if err := os.WriteFile(p, []byte(strings.Repeat("s", maxSecretBytes)+"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, ok := ReadSecret(d.SecretsDir, "a"); ok {
		t.Fatal("256 characters plus a newline exceed the 256-byte file limit")
	}
	if err := os.WriteFile(p, []byte(strings.Repeat("s", maxSecretBytes)), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, ok := ReadSecret(d.SecretsDir, "a"); !ok {
		t.Fatal("a 256-byte secret must be accepted")
	}
	// a symlink to a good file is refused
	real := filepath.Join(d.SecretsDir, "a", "real")
	if err := os.WriteFile(real, []byte("goodsecret"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(p); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(real, p); err != nil {
		t.Fatal(err)
	}
	if res := d.Call(context.Background(), baseReq()); !res.NoSecret {
		t.Fatalf("symlinked secret: %+v", res)
	}
	if hits.Load() != 0 {
		t.Fatalf("%d requests were made without a usable secret", hits.Load())
	}
}

func TestBodyOverTheReadCapWithTheSecretStraddlingItLeaksNoPrefix(t *testing.T) {
	body := strings.Repeat("x", maxBodyBytes-5) + testSecret + strings.Repeat("y", 1000)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()
	res := newDispatcher(t, srv, clock.NewFake(time.Now())).Call(context.Background(), baseReq())
	if res.Class != ClassRetryable || res.HTTPStatus != 500 {
		t.Fatalf("result = %+v", res)
	}
	if strings.Contains(res.Err, testSecret[:4]) || len([]rune(res.Err)) > 300 {
		t.Fatalf("secret prefix leaked or error too long (%d): %q", len([]rune(res.Err)), res.Err[len(res.Err)-20:])
	}
}

func TestTransportErrorTextIsMaskedWithTheSecret(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	d := newDispatcher(t, srv, clock.NewFake(time.Now()))
	d.URL = func(app string, port int, job string) string { return srv.URL + "/" + testSecret }
	srv.Close() // the dial error quotes the URL, which here carries the secret
	res := d.Call(context.Background(), baseReq())
	if res.Class != ClassRetryable || res.Timeout || res.HTTPStatus != 0 {
		t.Fatalf("result = %+v", res)
	}
	if !strings.Contains(res.Err, "***") || strings.Contains(res.Err, testSecret) {
		t.Fatalf("transport error not masked: %q", res.Err)
	}
}

func TestSecretFileIsReadPerCall(t *testing.T) {
	var last atomic.Value
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		last.Store(r.Header.Get("Authorization"))
	}))
	defer srv.Close()
	d := newDispatcher(t, srv, clock.NewFake(time.Now()))
	d.Call(context.Background(), baseReq())
	if err := os.WriteFile(filepath.Join(d.SecretsDir, "a", "jobs-secret"), []byte("rotatedvalue"), 0o640); err != nil {
		t.Fatal(err)
	}
	d.Call(context.Background(), baseReq())
	if last.Load() != "Bearer rotatedvalue" {
		t.Fatalf("Authorization = %v", last.Load())
	}
}
