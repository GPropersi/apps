// Command testapp is a minimal app that implements the full jobs CONTRACT for the runner's tests. It uses only the
// standard library and never imports runner packages, so it stays an independent check of the contract.
package main

import (
	"crypto/subtle"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
)

// DefaultDeclared is the job list used when JOBS_DECLARED is unset: ok-job always succeeds and always-fail always
// answers 503 (a retryable failure). testapp-up writes the same list into the app.yaml it registers.
const DefaultDeclared = "ok-job,always-fail"

const (
	jobPrefix   = "/_jobs/"
	maxBodySize = 1 << 20
	failingJob  = "always-fail"
)

// jobRequest is the POST body (CONTRACT v1). Nullable fields are kept as raw values: the testapp only validates
// the ones it needs.
type jobRequest struct {
	V        int             `json:"v"`
	RunID    string          `json:"run_id"`
	Job      string          `json:"job"`
	Trigger  string          `json:"trigger"`
	Attempt  int             `json:"attempt"`
	QueueID  *string         `json:"queue_id"`
	Payload  json.RawMessage `json:"payload"`
	Enqueued *string         `json:"enqueued_at"`
}

// handler serves POST /_jobs/<name>.
type handler struct {
	secret   string
	declared map[string]bool
	logf     func(format string, a ...any)

	mu   sync.Mutex
	done map[string]bool // idempotency keys of calls that succeeded
}

// newHandler returns the CONTRACT handler for a secret and a comma-separated declared job list.
func newHandler(secret, declared string, logf func(string, ...any)) *handler {
	d := map[string]bool{}
	for _, n := range strings.Split(declared, ",") {
		if n = strings.TrimSpace(n); n != "" {
			d[n] = true
		}
	}
	return &handler{secret: secret, declared: d, logf: logf, done: map[string]bool{}}
}

// newHandlerFromEnv reads JOBS_SECRET_FILE and JOBS_DECLARED. A missing or empty secret is an error (fail closed).
func newHandlerFromEnv(getenv func(string) string) (*handler, error) {
	path := getenv("JOBS_SECRET_FILE")
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	secret := strings.TrimSpace(string(b))
	if secret == "" {
		return nil, io.ErrUnexpectedEOF
	}
	declared := getenv("JOBS_DECLARED")
	if declared == "" {
		declared = DefaultDeclared
	}
	return newHandler(secret, declared, log.Printf), nil
}

func (h *handler) authorized(r *http.Request) bool {
	got := r.Header.Get("Authorization")
	want := "Bearer " + h.secret
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

func (h *handler) reply(w http.ResponseWriter, r *http.Request, job string, status int, why string) {
	h.logf("call job=%q status=%d run_id=%q why=%q", clip(job), status, clip(r.Header.Get("X-Platform-Run-Id")), why)
	// The body is a fixed plain-text reason and never echoes a request value; the headers keep a browser from
	// sniffing it as HTML.
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, why+"\n")
}

// ServeHTTP checks in this order: method (405), bearer (401), declared job (404), body (400), idempotency (200),
// always-fail (503), then success (200).
func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	job := strings.TrimPrefix(r.URL.Path, jobPrefix)
	if !strings.HasPrefix(r.URL.Path, jobPrefix) || job == "" || strings.Contains(job, "/") {
		h.reply(w, r, job, http.StatusNotFound, "not found")
		return
	}
	if r.Method != http.MethodPost {
		h.reply(w, r, job, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if !h.authorized(r) {
		h.reply(w, r, job, http.StatusUnauthorized, "unauthorized")
		return
	}
	if !h.declared[job] {
		h.reply(w, r, job, http.StatusNotFound, "job not declared")
		return
	}
	var req jobRequest
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBodySize))
	if err != nil || json.Unmarshal(body, &req) != nil || req.V != 1 || req.RunID == "" || req.Job != job || req.Attempt < 1 {
		h.reply(w, r, job, http.StatusBadRequest, "bad request body")
		return
	}
	key := req.RunID
	if req.QueueID != nil && *req.QueueID != "" {
		key = *req.QueueID
	}
	if job == failingJob {
		h.reply(w, r, job, http.StatusServiceUnavailable, "always-fail")
		return
	}
	h.mu.Lock()
	repeat := h.done[key]
	h.done[key] = true
	h.mu.Unlock()
	if repeat {
		h.reply(w, r, job, http.StatusOK, "already done")
		return
	}
	h.reply(w, r, job, http.StatusOK, "ok")
}

// clip bounds an untrusted value before it is logged (callers print it with %q, which escapes newlines).
func clip(s string) string {
	const max = 80
	if len(s) > max {
		return s[:max]
	}
	return s
}
