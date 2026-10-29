package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

const testSecret = "abcdefghijklmnopqrstuvwxyz0123456789ABCD"

func newTest() *handler {
	return newHandler(testSecret, "ok-job,always-fail", func(string, ...any) {})
}

func post(h http.Handler, path, auth, body string) int {
	r := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	if auth != "" {
		r.Header.Set("Authorization", auth)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w.Code
}

func body(job, runID, queueID string) string {
	q := "null"
	if queueID != "" {
		q = `"` + queueID + `"`
	}
	return `{"v":1,"run_id":"` + runID + `","job":"` + job + `","trigger":"queue","attempt":1,"scheduled_for":null,"queue_id":` + q + `,"enqueued_at":null,"payload":{"a":1}}`
}

func TestAuth(t *testing.T) {
	h := newTest()
	b := body("ok-job", "r1", "")
	if c := post(h, "/_jobs/ok-job", "", b); c != 401 {
		t.Fatalf("no header: %d", c)
	}
	if c := post(h, "/_jobs/ok-job", "Bearer wrong", b); c != 401 {
		t.Fatalf("wrong token: %d", c)
	}
	if c := post(h, "/_jobs/ok-job", "Bearer "+testSecret, b); c != 200 {
		t.Fatalf("good token: %d", c)
	}
}

func TestUndeclaredJobIs404(t *testing.T) {
	h := newTest()
	if c := post(h, "/_jobs/other", "Bearer "+testSecret, body("other", "r1", "")); c != 404 {
		t.Fatalf("got %d", c)
	}
	if c := post(h, "/elsewhere", "Bearer "+testSecret, "{}"); c != 404 {
		t.Fatalf("got %d", c)
	}
}

func TestBadBodyIs400(t *testing.T) {
	h := newTest()
	auth := "Bearer " + testSecret
	for _, b := range []string{"", "not json", `{"v":2,"run_id":"r","job":"ok-job","attempt":1}`,
		`{"v":1,"job":"ok-job","attempt":1}`, `{"v":1,"run_id":"r","job":"wrong","attempt":1}`} {
		if c := post(h, "/_jobs/ok-job", auth, b); c != 400 {
			t.Errorf("body %q: %d", b, c)
		}
	}
}

func TestIdempotentByQueueIDAndRunID(t *testing.T) {
	h := newTest()
	auth := "Bearer " + testSecret
	for i := 0; i < 3; i++ {
		if c := post(h, "/_jobs/ok-job", auth, body("ok-job", "run-"+string(rune('a'+i)), "q1")); c != 200 {
			t.Fatalf("queue repeat %d: %d", i, c)
		}
	}
	h.mu.Lock()
	n := len(h.done)
	h.mu.Unlock()
	if n != 1 {
		t.Fatalf("same queue_id must be one key, got %d", n)
	}
	post(h, "/_jobs/ok-job", auth, body("ok-job", "same", ""))
	post(h, "/_jobs/ok-job", auth, body("ok-job", "same", ""))
	h.mu.Lock()
	n = len(h.done)
	h.mu.Unlock()
	if n != 2 {
		t.Fatalf("same run_id must be one key, got %d total", n)
	}
}

func TestAlwaysFailIs503(t *testing.T) {
	h := newTest()
	for i := 0; i < 2; i++ {
		if c := post(h, "/_jobs/always-fail", "Bearer "+testSecret, body("always-fail", "r1", "q1")); c != 503 {
			t.Fatalf("got %d", c)
		}
	}
}

func TestMethodNotAllowed(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/_jobs/ok-job", nil)
	w := httptest.NewRecorder()
	newTest().ServeHTTP(w, r)
	if w.Code != 405 {
		t.Fatalf("got %d", w.Code)
	}
}

func TestLogNeverHoldsSecret(t *testing.T) {
	var lines []string
	h := newHandler(testSecret, "ok-job", func(f string, a ...any) { lines = append(lines, fmt.Sprintf(f, a...)) })
	post(h, "/_jobs/ok-job", "Bearer "+testSecret, body("ok-job", "r1", ""))
	post(h, "/_jobs/ok-job", "Bearer nope", body("ok-job", "r1", ""))
	if len(lines) != 2 {
		t.Fatalf("every call must be logged, got %d", len(lines))
	}
	for _, l := range lines {
		if strings.Contains(l, testSecret) || strings.Contains(l, "Bearer") {
			t.Fatalf("log line holds a secret or bearer header: %q", l)
		}
	}
}

func TestLogEscapesUntrustedValues(t *testing.T) {
	var lines []string
	h := newHandler(testSecret, "ok-job", func(f string, a ...any) { lines = append(lines, fmt.Sprintf(f, a...)) })
	r := httptest.NewRequest(http.MethodPost, "/_jobs/x%0Afake", strings.NewReader("{}"))
	r.Header.Set("X-Platform-Run-Id", "a\nb")
	h.ServeHTTP(httptest.NewRecorder(), r)
	if len(lines) != 1 || strings.ContainsAny(lines[0], "\r\n") {
		t.Fatalf("log must stay one line: %q", lines)
	}
}

func TestConcurrentSameQueueIDIsOneKey(t *testing.T) {
	h := newTest()
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			post(h, "/_jobs/ok-job", "Bearer "+testSecret, body("ok-job", "r", "same-q"))
		}()
	}
	wg.Wait()
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.done) != 1 {
		t.Fatalf("want one key, got %d", len(h.done))
	}
}

func TestNewHandlerFromEnv(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "jobs-secret")
	if err := os.WriteFile(p, []byte(testSecret), 0o600); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{"JOBS_SECRET_FILE": p}
	h, err := newHandlerFromEnv(func(k string) string { return env[k] })
	if err != nil {
		t.Fatal(err)
	}
	if !h.declared["ok-job"] || !h.declared["always-fail"] {
		t.Fatalf("default declared list not applied: %v", h.declared)
	}
	env["JOBS_DECLARED"] = "x, y"
	h, _ = newHandlerFromEnv(func(k string) string { return env[k] })
	if !h.declared["x"] || !h.declared["y"] || h.declared["ok-job"] {
		t.Fatalf("JOBS_DECLARED not honoured: %v", h.declared)
	}
	env["JOBS_SECRET_FILE"] = filepath.Join(d, "absent")
	if _, err := newHandlerFromEnv(func(k string) string { return env[k] }); err == nil {
		t.Fatal("missing secret file must be an error")
	}
}
