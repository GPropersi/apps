// Package dispatch makes the one HTTP call that runs a job: POST http://<app>:<port>/_jobs/<name> with the app's
// bearer secret, a deadline equal to the job's timeout and no redirect following. It classifies the response into
// the outcome classes of the jobs-runner contract.
//
// The secret is read from <secrets>/<app>/jobs-secret on every call and never logged; the error text it returns
// is the masked first 300 characters of the response body or of the transport error.
package dispatch

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/mask"
)

const (
	// maxBodyBytes is how much of a response body is read for the error text.
	maxBodyBytes = 4096
	// maxSecretBytes bounds the secret file; a real secret is 40 characters.
	maxSecretBytes = 256
)

// Class is the outcome class of one call.
type Class int

const (
	// ClassPermanent is the zero value on purpose: anything not proven ok or retryable fails closed.
	ClassPermanent Class = iota
	// ClassOK is a 2xx response.
	ClassOK
	// ClassRetryable is 408, 425, 429, 5xx, a refused connection, a DNS failure or a timeout.
	ClassRetryable
)

// String returns the contract name of the class.
func (c Class) String() string {
	switch c {
	case ClassOK:
		return "ok"
	case ClassRetryable:
		return "retryable"
	default:
		return "permanent"
	}
}

// Request is one call to an app.
type Request struct {
	App          string
	Port         int
	Job          string
	Timeout      time.Duration
	RunID        string
	Trigger      string // schedule | catch_up | queue
	Attempt      int
	ScheduledFor time.Time       // zero for a queued run
	QueueID      string          // "" for a scheduled run
	EnqueuedAt   time.Time       // zero for a scheduled run
	Payload      json.RawMessage // nil or empty means null
}

// Result is the outcome of one call.
type Result struct {
	Class      Class
	Timeout    bool   // the per-job deadline expired and the request was cancelled
	NoSecret   bool   // the secret file is missing or unusable; no request was made
	HTTPStatus int    // 0 when there was no response
	Err        string // masked, at most 300 characters; "" for ok
}

// Dispatcher calls apps.
type Dispatcher struct {
	Clock      clock.Clock
	SecretsDir string
	Version    string
	// Client is used for every call. New sets CheckRedirect so a 3xx is returned as is.
	Client *http.Client
	// URL builds the target; the default is http://<app>:<port>/_jobs/<job>. Tests point it at an httptest server.
	URL func(app string, port int, job string) string
}

// New returns a Dispatcher with the production URL scheme and a client that never follows redirects.
func New(clk clock.Clock, secretsDir, version string) *Dispatcher {
	return &Dispatcher{
		Clock:      clk,
		SecretsDir: secretsDir,
		Version:    version,
		Client: &http.Client{
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
		URL: func(app string, port int, job string) string {
			return "http://" + app + ":" + strconv.Itoa(port) + "/_jobs/" + job
		},
	}
}

type body struct {
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

func optTime(t time.Time) *string {
	if t.IsZero() {
		return nil
	}
	s := t.UTC().Format(time.RFC3339)
	return &s
}

// ReadSecret reads <dir>/<app>/jobs-secret, stripping one trailing newline. It reports false when the file is
// missing, unreadable, empty, too long or holds anything but visible ASCII (which could not be a header value).
func ReadSecret(dir, app string) (string, bool) {
	if app == "" || strings.ContainsAny(app, `/\`) || app == "." || app == ".." {
		return "", false
	}
	path := filepath.Join(dir, app, "jobs-secret")
	// Lstat first: a symlink, FIFO, device or directory is refused without being opened, so a hostile entry can
	// neither block the read nor redirect it.
	if fi, err := os.Lstat(path); err != nil || !fi.Mode().IsRegular() {
		return "", false
	}
	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxSecretBytes+1))
	if err != nil || len(b) > maxSecretBytes {
		return "", false
	}
	s := strings.TrimSuffix(string(b), "\n")
	if s == "" {
		return "", false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x21 || s[i] > 0x7e {
			return "", false
		}
	}
	return s, true
}

// Call runs one request. The timeout is enforced with Clock.After, so a test with a fake clock cancels the
// request by advancing time.
func (d *Dispatcher) Call(parent context.Context, r Request) Result {
	secret, ok := ReadSecret(d.SecretsDir, r.App)
	if !ok {
		return Result{NoSecret: true, Err: "jobs-secret is missing or unusable"}
	}
	payload := r.Payload
	if len(payload) == 0 {
		payload = json.RawMessage("null")
	}
	buf, err := json.Marshal(body{
		V: 1, RunID: r.RunID, Job: r.Job, Trigger: r.Trigger, Attempt: r.Attempt,
		ScheduledFor: optTime(r.ScheduledFor), QueueID: strPtr(r.QueueID), EnqueuedAt: optTime(r.EnqueuedAt),
		Payload: payload,
	})
	if err != nil { // an invalid payload cannot be fixed by retrying
		return Result{Class: ClassPermanent, Err: mask.Text("request body: " + err.Error())}
	}

	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	var timedOut atomic.Bool
	done := make(chan struct{})
	defer close(done)
	deadline := d.Clock.After(r.Timeout) // armed before the call so the deadline counts from its start
	go func() {
		select {
		case <-deadline:
			timedOut.Store(true)
			cancel()
		case <-done:
		}
	}()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, d.URL(r.App, r.Port, r.Job), bytes.NewReader(buf))
	if err != nil {
		return Result{Class: ClassPermanent, Err: mask.Text("build request: "+err.Error(), secret)}
	}
	req.Header.Set("Authorization", "Bearer "+secret)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Platform-Run-Id", r.RunID)
	req.Header.Set("User-Agent", "platform-jobs-runner/"+d.Version)

	resp, err := d.Client.Do(req)
	if err != nil {
		if timedOut.Load() {
			return Result{Class: ClassRetryable, Timeout: true, Err: fmt.Sprintf("timeout after %s", r.Timeout)}
		}
		// Connection refused, DNS failure, reset: the app may simply be restarting.
		return Result{Class: ClassRetryable, Err: mask.Text(err.Error(), secret)}
	}
	defer resp.Body.Close()
	raw, rerr := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
	if rerr != nil && timedOut.Load() {
		return Result{Class: ClassRetryable, Timeout: true, HTTPStatus: resp.StatusCode, Err: fmt.Sprintf("timeout after %s", r.Timeout)}
	}
	res := Result{HTTPStatus: resp.StatusCode, Class: classify(resp.StatusCode)}
	if res.Class == ClassOK {
		return res
	}
	text := string(raw)
	if len(raw) >= maxBodyBytes && len(secret) < len(raw) { // a secret cut in half by the read limit
		text = text[:len(text)-len(secret)]
	}
	text = mask.Text(text, secret)
	if text == "" {
		text = "http " + strconv.Itoa(resp.StatusCode)
	}
	res.Err = text
	return res
}

func strPtr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// classify maps an HTTP status to its outcome class. Anything outside the table is permanent.
func classify(status int) Class {
	switch {
	case status >= 200 && status <= 299:
		return ClassOK
	case status == 408 || status == 425 || status == 429:
		return ClassRetryable
	case status >= 500 && status <= 599:
		return ClassRetryable
	default:
		return ClassPermanent
	}
}
