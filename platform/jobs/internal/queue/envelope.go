// Package queue is the runner's queue consumer: it takes the envelopes apps LPUSH onto <app>:jobs:queue, runs them
// through the same guardrails as scheduled jobs, retries failures with growing delays through <app>:jobs:delayed,
// sets aside the jobs that keep failing in <app>:jobs:dead and recovers what a crash left in <app>:jobs:processing.
//
// One consumer goroutine owns every Redis queue operation. Workers only call the app and hand the outcome back.
package queue

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gpropersi/apps/platform/jobs/internal/mask"
)

// logIDBytes bounds the id and job name a log line keeps from an item that may not be valid.
const logIDBytes = 64

// rawSummary describes a raw queue item for a log line without its payload: the envelope id, the job name and the
// byte length. The payload may hold user data, so it never reaches the journal; the item itself stays recoverable
// from <app>:jobs:processing or :dead. The id and job are best effort (an unparseable or oversize item has none).
func rawSummary(raw string) string {
	id, job := "-", "-"
	if len(raw) <= MaxEnvelopeBytes {
		var fields map[string]json.RawMessage
		if json.Unmarshal([]byte(raw), &fields) == nil {
			var s string
			if json.Unmarshal(fields["id"], &s) == nil && s != "" {
				id = mask.TextN(logIDBytes, s)
			}
			if json.Unmarshal(fields["job"], &s) == nil && s != "" {
				job = mask.TextN(logIDBytes, s)
			}
		}
	}
	return fmt.Sprintf("id=%q job=%q bytes=%d", id, job, len(raw))
}

const (
	// MaxEnvelopeBytes is the largest envelope that is parsed; a bigger one is dead-lettered unread.
	MaxEnvelopeBytes = 65536
	// MaxAttempts is the number of HTTP attempts a queued job gets.
	MaxAttempts = 5
	// DeadKeep is how many dead records <app>:jobs:dead keeps.
	DeadKeep = 100
	// DeadEnvelopeBytes is how much of the raw item a dead record holds.
	DeadEnvelopeBytes = 4096
	// DelayedMax is the most entries <app>:jobs:delayed may hold before a retry dead-letters as overflow.
	DelayedMax = 1000
	// MaxLastError is the longest last_error kept on an envelope or dead record.
	MaxLastError = 300
)

// Dead-record reasons (the one enum of the contract).
const (
	ReasonInvalid   = "invalid_envelope"
	ReasonUndeclare = "undeclared_job"
	ReasonOverflow  = "overflow"
	ReasonPermanent = "permanent"
	ReasonExhausted = "retries_exhausted"
)

var (
	jobNameRE = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,62}$`)
	ulidRE    = regexp.MustCompile(`^[0-9A-Za-z]{26}$`)
)

// Envelope is one queued job as apps write it, plus the fields the runner adds when it re-queues.
type Envelope struct {
	V          int             `json:"v"`
	ID         string          `json:"id"`
	Job        string          `json:"job"`
	Payload    json.RawMessage `json:"payload"`
	EnqueuedAt string          `json:"enqueued_at"`
	Attempt    int             `json:"attempt,omitempty"`
	LastError  string          `json:"last_error,omitempty"`
}

// Verdict is the result of Validate.
type Verdict struct {
	Env    *Envelope // set only when valid
	Reason string    // "" when valid, else one of the dead-record reasons
	Detail string    // why, for last_error
	ID     string    // the envelope id when it could be read
	Job    string    // the job name when it could be read
}

// Valid reports whether the envelope may be run.
func (v Verdict) Valid() bool { return v.Reason == "" && v.Env != nil }

// Validate validates one raw item. The size check comes first and nothing above MaxEnvelopeBytes is parsed. The
// same function serves the take path and recovery. declared reports whether a job name is declared by the app.
func Validate(raw string, declared func(job string) bool) Verdict {
	if len(raw) > MaxEnvelopeBytes {
		return Verdict{Reason: ReasonInvalid, Detail: fmt.Sprintf("oversize envelope (%d bytes, max %d)", len(raw), MaxEnvelopeBytes)}
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &fields); err != nil || fields == nil {
		return Verdict{Reason: ReasonInvalid, Detail: "not a JSON object"}
	}
	v := Verdict{Reason: ReasonInvalid}
	// Best-effort id and job for the record, even when something else is wrong.
	var id, job string
	if json.Unmarshal(fields["id"], &id) == nil {
		v.ID = id
	}
	if json.Unmarshal(fields["job"], &job) == nil {
		v.Job = job
	}
	for _, k := range []string{"v", "id", "job", "payload", "enqueued_at"} {
		if _, ok := fields[k]; !ok {
			v.Detail = "missing field " + k
			return v
		}
	}
	var e Envelope
	if err := json.Unmarshal(fields["v"], &e.V); err != nil || e.V != 1 {
		v.Detail = "unknown v"
		return v
	}
	if err := json.Unmarshal(fields["id"], &e.ID); err != nil || !ulidRE.MatchString(e.ID) {
		v.Detail = "id is not a 26-character ULID"
		return v
	}
	if err := json.Unmarshal(fields["job"], &e.Job); err != nil || !jobNameRE.MatchString(e.Job) {
		v.Detail = "job is not a valid job name"
		return v
	}
	e.Payload = fields["payload"]
	if err := json.Unmarshal(fields["enqueued_at"], &e.EnqueuedAt); err != nil {
		v.Detail = "enqueued_at is not a string"
		return v
	}
	if _, err := time.Parse(time.RFC3339, e.EnqueuedAt); err != nil {
		v.Detail = "enqueued_at is not RFC3339"
		return v
	}
	e.Attempt = 1
	if raw, ok := fields["attempt"]; ok {
		if err := json.Unmarshal(raw, &e.Attempt); err != nil || e.Attempt < 1 {
			v.Detail = "attempt is not an integer >= 1"
			return v
		}
	}
	if raw, ok := fields["last_error"]; ok {
		if err := json.Unmarshal(raw, &e.LastError); err != nil {
			v.Detail = "last_error is not a string"
			return v
		}
	}
	if declared == nil || !declared(e.Job) {
		v.Reason, v.Detail = ReasonUndeclare, "job "+e.Job+" is not declared in app.yaml"
		return v
	}
	return Verdict{Env: &e, ID: e.ID, Job: e.Job}
}

// Encode renders the envelope for re-queueing with the given attempt and masked last_error. The payload bytes are
// kept as they are. When the result would be too large to be taken again, last_error is dropped.
func (e Envelope) Encode(attempt int, lastError string) string {
	e.Attempt, e.LastError = attempt, lastError
	if len(e.Payload) == 0 {
		e.Payload = json.RawMessage("null")
	}
	b, err := marshalPlain(e)
	if err != nil || len(b) > MaxEnvelopeBytes {
		e.LastError = ""
		b, _ = marshalPlain(e)
	}
	return string(b)
}

// marshalPlain is json.Marshal without HTML escaping, so a payload near the size bound is not inflated (< > & would
// grow six-fold). The output is still valid JSON.
func marshalPlain(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

// DeadRecord is one entry of <app>:jobs:dead. Envelope is always a JSON string holding the raw bytes, so an invalid
// or oversize original still gives a valid record.
type DeadRecord struct {
	V             int    `json:"v"`
	Envelope      string `json:"envelope"`
	Truncated     bool   `json:"truncated"`
	EnvelopeBytes int    `json:"envelope_bytes"`
	ID            string `json:"id,omitempty"`
	Reason        string `json:"reason"`
	Attempts      int    `json:"attempts"`
	LastError     string `json:"last_error"`
	DeadAt        string `json:"dead_at"`
}

// NewDeadRecord builds the record for raw. The envelope string is cut to DeadEnvelopeBytes on a character
// boundary and invalid UTF-8 becomes U+FFFD first, so the stored string is at most DeadEnvelopeBytes after decoding.
func NewDeadRecord(raw, id, reason string, attempts int, lastError string, at time.Time) DeadRecord {
	head := raw
	if len(head) > DeadEnvelopeBytes+utf8.UTFMax {
		head = head[:DeadEnvelopeBytes+utf8.UTFMax]
	}
	clean := strings.ToValidUTF8(head, "�")
	for len(clean) > DeadEnvelopeBytes {
		_, size := utf8.DecodeLastRuneInString(clean)
		clean = clean[:len(clean)-size]
	}
	return DeadRecord{
		V: 1, Envelope: clean, Truncated: clean != raw, EnvelopeBytes: len(raw), ID: id,
		Reason: reason, Attempts: attempts, LastError: lastError, DeadAt: at.UTC().Format(time.RFC3339),
	}
}

// JSON renders the record.
func (d DeadRecord) JSON() string {
	var sb strings.Builder
	enc := json.NewEncoder(&sb)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(d) // a struct of strings and ints cannot fail
	return strings.TrimSuffix(sb.String(), "\n")
}
