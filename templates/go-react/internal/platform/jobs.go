package platform

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"maps"
	"net/http"
	"strings"
)

// JobRequest is the POST body the jobs runner sends (platform/jobs/CONTRACT.md section 2).
type JobRequest struct {
	V            int             `json:"v"`
	RunID        string          `json:"run_id"`
	Job          string          `json:"job"`
	Trigger      string          `json:"trigger"`
	Attempt      int             `json:"attempt"`
	ScheduledFor *string         `json:"scheduled_for"`
	QueueID      *string         `json:"queue_id"`
	EnqueuedAt   *string         `json:"enqueued_at"`
	Payload      json.RawMessage `json:"payload"`
}

// IdempotencyKey is what a JobFunc dedupes on: the queue id for a queued run, else the run id (a scheduled run).
// Delivery is at least once, so the same key can arrive twice and must have a single effect.
func (r JobRequest) IdempotencyKey() string {
	if r.QueueID != nil && *r.QueueID != "" {
		return *r.QueueID
	}
	return r.RunID
}

// JobFunc does one job. Return nil only after the work is committed: nil answers 200 and the runner never repeats it.
// Any error answers 500, which the runner retries. A nil JobFunc also answers 200 with no work, so VerifyJobs rejects
// nil entries: the server must not start with one.
type JobFunc func(ctx context.Context, req JobRequest) error

const (
	jobsPathPrefix = "/_jobs/"
	maxJobBody     = 1 << 20
	maxLogged      = 80
)

// ErrNoJobsSecret is returned by JobsHandler for an empty secret: the endpoint must never run unauthenticated.
var ErrNoJobsSecret = errors.New("platform: jobs secret is empty")

type jobsHandler struct {
	secretSum [sha256.Size]byte
	jobs      map[string]JobFunc
	logf      func(format string, a ...any)
}

// JobsHandler serves POST /_jobs/<name> for the runner. Checks run in this order: path (404), method (405), bearer
// (401, before the body is read), declared job (404), body (400), then the JobFunc (nil 200, error 500). An empty
// secret is an error.
func JobsHandler(secret []byte, jobs map[string]JobFunc) (http.Handler, error) {
	return newJobsHandler(secret, jobs, log.Printf)
}

func newJobsHandler(secret []byte, jobs map[string]JobFunc, logf func(string, ...any)) (http.Handler, error) {
	if len(secret) == 0 {
		return nil, ErrNoJobsSecret
	}
	return &jobsHandler{secretSum: sha256.Sum256([]byte("Bearer " + string(secret))), jobs: maps.Clone(jobs), logf: logf}, nil
}

// authorized compares fixed-length digests in constant time, so neither the content nor the length of the secret
// shows in the timing.
func (h *jobsHandler) authorized(r *http.Request) bool {
	got := sha256.Sum256([]byte(r.Header.Get("Authorization")))
	return subtle.ConstantTimeCompare(got[:], h.secretSum[:]) == 1
}

func (h *jobsHandler) reply(w http.ResponseWriter, r *http.Request, job string, status int, why string) {
	h.logf("jobs: call job=%q status=%d run_id=%q why=%q", clip(job), status, clip(r.Header.Get("X-Platform-Run-Id")), why)
	// A fixed plain-text reason: the runner shows it as the error text and no request value is ever echoed.
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, why+"\n")
}

func (h *jobsHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	job, found := strings.CutPrefix(r.URL.Path, jobsPathPrefix)
	if !found || job == "" || strings.Contains(job, "/") {
		h.reply(w, r, job, http.StatusNotFound, "not found")
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		h.reply(w, r, job, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if !h.authorized(r) {
		h.reply(w, r, job, http.StatusUnauthorized, "unauthorized")
		return
	}
	fn, declared := h.jobs[job]
	if !declared {
		h.reply(w, r, job, http.StatusNotFound, "job not declared")
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxJobBody+1))
	var req JobRequest
	if err != nil || len(body) > maxJobBody || json.Unmarshal(body, &req) != nil ||
		req.V != 1 || req.RunID == "" || req.Job != job || req.Attempt < 1 {
		h.reply(w, r, job, http.StatusBadRequest, "bad request body")
		return
	}
	if err := h.run(r.Context(), fn, req); err != nil {
		h.logf("jobs: job=%q run_id=%q failed: %q", clip(job), clip(req.RunID), clip(err.Error()))
		h.reply(w, r, job, http.StatusInternalServerError, "job failed")
		return
	}
	h.reply(w, r, job, http.StatusOK, "ok")
}

// run calls the JobFunc; a nil func succeeds and a panic is an error (so never a 2xx).
func (h *jobsHandler) run(ctx context.Context, fn JobFunc, req JobRequest) (err error) {
	if fn == nil {
		return nil
	}
	defer func() {
		if p := recover(); p != nil {
			err = fmt.Errorf("panic: %v", p)
		}
	}()
	return fn(ctx, req)
}

// clip bounds an untrusted value before it is logged (callers print it with %q, which escapes newlines).
func clip(s string) string {
	if len(s) > maxLogged {
		return s[:maxLogged]
	}
	return s
}
