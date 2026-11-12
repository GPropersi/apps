package platform

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
)

const testSecret = "s3cret-token"

type fakeJobs struct {
	mu       sync.Mutex
	effects  map[string]int // idempotency key -> times the work was done
	failWith error
	panics   bool
}

// do is a JobFunc that dedupes on IdempotencyKey, as CONTRACT rule 5 asks of an app.
func (f *fakeJobs) do(_ context.Context, req JobRequest) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.panics {
		panic("boom")
	}
	if f.failWith != nil {
		return f.failWith
	}
	if f.effects == nil {
		f.effects = map[string]int{}
	}
	if f.effects[req.IdempotencyKey()] == 0 {
		f.effects[req.IdempotencyKey()] = 1
	}
	return nil
}

func newTestHandler(t *testing.T, jobs map[string]JobFunc) http.Handler {
	t.Helper()
	h, err := newJobsHandler([]byte(testSecret), jobs, func(string, ...any) {})
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func call(h http.Handler, method, path, auth, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	if auth != "" {
		r.Header.Set("Authorization", auth)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

const goodBody = `{"v":1,"run_id":"RUN1","job":"add-note","trigger":"queue","attempt":1,"scheduled_for":null,"queue_id":"Q1","enqueued_at":"2026-11-08T00:00:00Z","payload":{"a":1}}`

var bearer = "Bearer " + testSecret

func TestConformance01WrongOrMissingSecretGives401(t *testing.T) {
	f := &fakeJobs{}
	h := newTestHandler(t, map[string]JobFunc{"add-note": f.do})
	for name, auth := range map[string]string{
		"wrong secret": "Bearer nope", "missing header": "", "no scheme": testSecret, "prefix of the secret": "Bearer s3cret",
	} {
		if w := call(h, http.MethodPost, "/_jobs/add-note", auth, goodBody); w.Code != http.StatusUnauthorized {
			t.Errorf("%s: status %d, want 401", name, w.Code)
		}
	}
	if len(f.effects) != 0 {
		t.Error("work was done for an unauthorized call")
	}
}

type failingBody struct{ t *testing.T }

func (b failingBody) Read([]byte) (int, error) {
	b.t.Error("the body was read before the bearer check")
	return 0, io.EOF
}

func TestBearerIsCheckedBeforeTheBodyIsRead(t *testing.T) {
	h := newTestHandler(t, map[string]JobFunc{"add-note": (&fakeJobs{}).do})
	r := httptest.NewRequest(http.MethodPost, "/_jobs/add-note", failingBody{t})
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("status %d, want 401", w.Code)
	}
}

func TestConformance02UnknownJobGives404(t *testing.T) {
	h := newTestHandler(t, map[string]JobFunc{"add-note": (&fakeJobs{}).do})
	for _, path := range []string{"/_jobs/other", "/_jobs/", "/_jobs/add-note/x", "/other", "/_jobs"} {
		if w := call(h, http.MethodPost, path, bearer, goodBody); w.Code != http.StatusNotFound {
			t.Errorf("%s: status %d, want 404", path, w.Code)
		}
	}
}

func TestNonPostGives405(t *testing.T) {
	h := newTestHandler(t, map[string]JobFunc{"add-note": (&fakeJobs{}).do})
	if w := call(h, http.MethodGet, "/_jobs/add-note", bearer, ""); w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status %d, want 405", w.Code)
	}
}

func TestConformance03BodyWithVOtherThanOneIsRejected(t *testing.T) {
	f := &fakeJobs{}
	h := newTestHandler(t, map[string]JobFunc{"add-note": f.do})
	bodies := map[string]string{
		"v 2":               strings.Replace(goodBody, `"v":1`, `"v":2`, 1),
		"v missing":         `{"run_id":"RUN1","job":"add-note","attempt":1}`,
		"not json":          `nope`,
		"empty run_id":      strings.Replace(goodBody, `"RUN1"`, `""`, 1),
		"job path mismatch": strings.Replace(goodBody, `"job":"add-note"`, `"job":"x"`, 1),
		"attempt 0":         strings.Replace(goodBody, `"attempt":1`, `"attempt":0`, 1),
		"oversize":          `{"v":1,"run_id":"R","job":"add-note","attempt":1,"payload":"` + strings.Repeat("a", maxJobBody) + `"}`,
	}
	for name, body := range bodies {
		if w := call(h, http.MethodPost, "/_jobs/add-note", bearer, body); w.Code != http.StatusBadRequest {
			t.Errorf("%s: status %d, want 400", name, w.Code)
		}
	}
	if len(f.effects) != 0 {
		t.Error("work was done for a rejected body")
	}
}

func TestConformance04DuplicateQueueIDHasASingleEffect(t *testing.T) {
	f := &fakeJobs{}
	h := newTestHandler(t, map[string]JobFunc{"add-note": f.do})
	for i := 0; i < 2; i++ {
		if w := call(h, http.MethodPost, "/_jobs/add-note", bearer, goodBody); w.Code != http.StatusOK {
			t.Fatalf("call %d: status %d, want 200", i, w.Code)
		}
	}
	if len(f.effects) != 1 || f.effects["Q1"] != 1 {
		t.Fatalf("effects %v, want one effect keyed by the queue id", f.effects)
	}
}

func TestIdempotencyKeyFallsBackToRunID(t *testing.T) {
	empty := ""
	q := "Q9"
	cases := []struct {
		name string
		req  JobRequest
		want string
	}{
		{"queue id wins", JobRequest{RunID: "R", QueueID: &q}, "Q9"},
		{"nil queue id", JobRequest{RunID: "R"}, "R"},
		{"empty queue id", JobRequest{RunID: "R", QueueID: &empty}, "R"},
	}
	for _, c := range cases {
		if got := c.req.IdempotencyKey(); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}

func TestConformance05HandlerFailureNeverAnswers2xx(t *testing.T) {
	f := &fakeJobs{failWith: errors.New("db down after partial work")}
	h := newTestHandler(t, map[string]JobFunc{"add-note": f.do})
	w := call(h, http.MethodPost, "/_jobs/add-note", bearer, goodBody)
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status %d, want 500", w.Code)
	}
	if strings.Contains(w.Body.String(), "db down") {
		t.Error("the response body echoes the error text")
	}
	f2 := &fakeJobs{panics: true}
	h2 := newTestHandler(t, map[string]JobFunc{"add-note": f2.do})
	if w := call(h2, http.MethodPost, "/_jobs/add-note", bearer, goodBody); w.Code != http.StatusInternalServerError {
		t.Fatalf("panic: status %d, want 500", w.Code)
	}
}

func TestNilJobFuncAnswers200(t *testing.T) {
	h := newTestHandler(t, map[string]JobFunc{"add-note": nil})
	if w := call(h, http.MethodPost, "/_jobs/add-note", bearer, goodBody); w.Code != http.StatusOK {
		t.Fatalf("status %d, want 200", w.Code)
	}
}

// Item 6: the comparison is constant time. The handler compares fixed-length SHA-256 digests with
// subtle.ConstantTimeCompare (jobs.go authorized), so equal and differing-length secrets take the same path. This test
// pins the behaviour that design must keep: a secret that is a prefix or an extension of the real one is refused.
func TestConformance06SecretComparisonIsConstantTimeDigest(t *testing.T) {
	h := newTestHandler(t, map[string]JobFunc{"add-note": nil})
	for _, auth := range []string{bearer + "x", bearer[:len(bearer)-1], "bearer " + testSecret, "Bearer  " + testSecret} {
		if w := call(h, http.MethodPost, "/_jobs/add-note", auth, goodBody); w.Code != http.StatusUnauthorized {
			t.Errorf("%q: status %d, want 401", auth, w.Code)
		}
	}
	if w := call(h, http.MethodPost, "/_jobs/add-note", bearer, goodBody); w.Code != http.StatusOK {
		t.Fatalf("right secret: status %d, want 200", w.Code)
	}
}

// Review evidence for item 6 (not a timing test): jobs.go uses subtle.ConstantTimeCompare and no direct comparison of
// the header with the secret.
func TestConformance06SourceUsesConstantTimeCompare(t *testing.T) {
	b, err := os.ReadFile("jobs.go")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	if !strings.Contains(src, "subtle.ConstantTimeCompare") {
		t.Error("jobs.go must compare the secret with subtle.ConstantTimeCompare")
	}
	for _, bad := range []string{"bytes.Equal", "strings.EqualFold", `Header.Get("Authorization") ==`} {
		if strings.Contains(src, bad) {
			t.Errorf("jobs.go contains %q", bad)
		}
	}
}

func TestCheckOrderIs404Then405Then401Then404(t *testing.T) {
	h := newTestHandler(t, map[string]JobFunc{"add-note": noop})
	if w := call(h, http.MethodPost, "/_jobs/other", "", goodBody); w.Code != http.StatusUnauthorized {
		t.Errorf("no auth, undeclared job: %d, want 401 (job names must not leak)", w.Code)
	}
	w := call(h, http.MethodGet, "/_jobs/add-note", "", "")
	if w.Code != http.StatusMethodNotAllowed || w.Header().Get("Allow") != http.MethodPost {
		t.Errorf("GET without auth: %d Allow=%q, want 405 and Allow: POST", w.Code, w.Header().Get("Allow"))
	}
	if w := call(h, http.MethodPost, "/_jobs/a/b", "", goodBody); w.Code != http.StatusNotFound {
		t.Errorf("bad path without auth: %d, want 404", w.Code)
	}
}

func TestScheduledRunDedupesOnRunID(t *testing.T) {
	f := &fakeJobs{}
	h := newTestHandler(t, map[string]JobFunc{"add-note": f.do})
	body := strings.Replace(goodBody, `"queue_id":"Q1"`, `"queue_id":null`, 1)
	for i := 0; i < 2; i++ {
		if w := call(h, http.MethodPost, "/_jobs/add-note", bearer, body); w.Code != http.StatusOK {
			t.Fatalf("status %d", w.Code)
		}
	}
	if len(f.effects) != 1 || f.effects["RUN1"] != 1 {
		t.Fatalf("effects %v", f.effects)
	}
}

func TestBodyBoundaryAndOddBodies(t *testing.T) {
	h := newTestHandler(t, map[string]JobFunc{"add-note": noop})
	pad := func(n int) string { // a valid body of exactly n bytes
		base := `{"v":1,"run_id":"R","job":"add-note","attempt":1,"payload":""}`
		return strings.Replace(base, `""`, `"`+strings.Repeat("a", n-len(base))+`"`, 1)
	}
	if w := call(h, http.MethodPost, "/_jobs/add-note", bearer, pad(maxJobBody)); w.Code != http.StatusOK {
		t.Errorf("body of exactly 1 MiB: %d, want 200", w.Code)
	}
	if w := call(h, http.MethodPost, "/_jobs/add-note", bearer, pad(maxJobBody+1)); w.Code != http.StatusBadRequest {
		t.Errorf("body of 1 MiB + 1: %d, want 400", w.Code)
	}
	for name, body := range map[string]string{
		"trailing garbage": goodBody + " x",
		"v as string":      strings.Replace(goodBody, `"v":1`, `"v":"1"`, 1),
		"missing job":      `{"v":1,"run_id":"R","attempt":1}`,
		"attempt string":   strings.Replace(goodBody, `"attempt":1`, `"attempt":"1"`, 1),
	} {
		if w := call(h, http.MethodPost, "/_jobs/add-note", bearer, body); w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", name, w.Code)
		}
	}
}

func TestEveryReplyIsFixedPlainTextAndNeverEchoesInput(t *testing.T) {
	bad := &fakeJobs{failWith: errors.New("secret-detail")}
	h := newTestHandler(t, map[string]JobFunc{"add-note": noop, "fails": bad.do})
	failBody := strings.Replace(goodBody, `"job":"add-note"`, `"job":"fails"`, 1)
	for name, w := range map[string]*httptest.ResponseRecorder{
		"401": call(h, http.MethodPost, "/_jobs/add-note", "", goodBody),
		"405": call(h, http.MethodGet, "/_jobs/add-note", bearer, ""),
		"400": call(h, http.MethodPost, "/_jobs/add-note", bearer, strings.Replace(goodBody, `"RUN1"`, `"RUN1-echo"`, 1)+"x"),
		"500": call(h, http.MethodPost, "/_jobs/fails", bearer, failBody),
		"200": call(h, http.MethodPost, "/_jobs/add-note", bearer, goodBody),
	} {
		if w.Header().Get("X-Content-Type-Options") != "nosniff" || !strings.HasPrefix(w.Header().Get("Content-Type"), "text/plain") {
			t.Errorf("%s: headers %v", name, w.Header())
		}
		if strings.Contains(w.Body.String(), "echo") || strings.Contains(w.Body.String(), "secret-detail") {
			t.Errorf("%s: body echoes input: %q", name, w.Body.String())
		}
	}
	p := &fakeJobs{panics: true}
	h2 := newTestHandler(t, map[string]JobFunc{"add-note": p.do})
	if w := call(h2, http.MethodPost, "/_jobs/add-note", bearer, goodBody); strings.Contains(w.Body.String(), "boom") {
		t.Error("panic text in the response")
	}
}

func TestEmptySecretIsAStartupError(t *testing.T) {
	if _, err := JobsHandler(nil, nil); !errors.Is(err, ErrNoJobsSecret) {
		t.Fatalf("nil secret: %v", err)
	}
	if _, err := JobsHandler([]byte{}, nil); !errors.Is(err, ErrNoJobsSecret) {
		t.Fatalf("empty secret: %v", err)
	}
	if h, err := JobsHandler([]byte("x"), nil); err != nil || h == nil {
		t.Fatalf("non-empty secret: %v", err)
	}
}

func TestResponsesAreFixedPlainText(t *testing.T) {
	h := newTestHandler(t, map[string]JobFunc{"add-note": (&fakeJobs{}).do})
	w := call(h, http.MethodPost, "/_jobs/<script>", bearer, goodBody)
	if w.Header().Get("X-Content-Type-Options") != "nosniff" || !strings.HasPrefix(w.Header().Get("Content-Type"), "text/plain") {
		t.Errorf("headers %v", w.Header())
	}
	if strings.Contains(w.Body.String(), "script") {
		t.Error("the body echoes the request path")
	}
}

func TestLoggedValuesAreClippedAndQuoted(t *testing.T) {
	var lines []string
	h, err := newJobsHandler([]byte(testSecret), nil, func(f string, a ...any) { lines = append(lines, f) })
	if err != nil {
		t.Fatal(err)
	}
	call(h, http.MethodPost, "/_jobs/"+strings.Repeat("a", 500), bearer, goodBody)
	if len(lines) == 0 || !strings.Contains(lines[0], "job=%q") {
		t.Fatalf("log format %v", lines)
	}
	if got := clip(strings.Repeat("a", 500)); len(got) != maxLogged {
		t.Errorf("clip length %d", len(got))
	}
}
