package queue

import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
)

func jsonUnmarshal(s string, v any) error { return json.Unmarshal([]byte(s), v) }

func declaredJ(job string) bool { return job == "j" || job == "j2" }

func TestEnvelopeValidate(t *testing.T) {
	ok := env("j", "01")
	if v := Validate(ok, declaredJ); !v.Valid() || v.Env.Attempt != 1 || v.Env.Job != "j" {
		t.Fatalf("valid envelope rejected: %+v", v)
	}
	if v := Validate(envAttempt("j", "01", 3), declaredJ); !v.Valid() || v.Env.Attempt != 3 {
		t.Fatalf("attempt not read: %+v", v)
	}
	cases := map[string]struct{ raw, reason string }{
		"not json":      {"not json", ReasonInvalid},
		"array":         {"[1]", ReasonInvalid},
		"null":          {"null", ReasonInvalid},
		"empty":         {"", ReasonInvalid},
		"unknown v":     {strings.Replace(ok, `"v":1`, `"v":2`, 1), ReasonInvalid},
		"missing id":    {`{"v":1,"job":"j","payload":null,"enqueued_at":"2026-03-01T11:00:00Z"}`, ReasonInvalid},
		"missing field": {`{"v":1,"id":"00000000000000000000000001","job":"j","payload":null}`, ReasonInvalid},
		"bad time":      {strings.Replace(ok, "2026-03-01T11:00:00Z", "yesterday", 1), ReasonInvalid},
		"bad attempt":   {strings.Replace(ok, `"payload"`, `"attempt":0,"payload"`, 1), ReasonInvalid},
		"bad job name":  {strings.Replace(ok, `"job":"j"`, `"job":"J!"`, 1), ReasonInvalid},
		"short id":      {strings.Replace(ok, "00000000000000000000000001", "short", 1), ReasonInvalid},
		"undeclared":    {strings.Replace(ok, `"job":"j"`, `"job":"zzz"`, 1), ReasonUndeclare},
		"oversize":      {strings.Repeat("x", MaxEnvelopeBytes+1), ReasonInvalid},
	}
	for name, c := range cases {
		v := Validate(c.raw, declaredJ)
		if v.Valid() || v.Reason != c.reason || v.Detail == "" {
			t.Errorf("%s: want reason %s with a detail, got %+v", name, c.reason, v)
		}
	}
	if v := Validate(strings.Replace(ok, `"job":"j"`, `"job":"zzz"`, 1), declaredJ); v.ID == "" || v.Job != "zzz" {
		t.Errorf("an undeclared envelope still reports its id and job: %+v", v)
	}
}

// A log line describes an item by id, job and length only: the payload (user data) never reaches the journal.
func TestRawSummaryOmitsPayload(t *testing.T) {
	raw := `{"v":1,"id":"01ABC","job":"send","payload":{"email":"user@example.test"},"enqueued_at":"x"}`
	got := rawSummary(raw)
	if strings.Contains(got, "example.test") || strings.Contains(got, "payload") {
		t.Fatalf("the summary leaks the payload: %s", got)
	}
	for _, want := range []string{`id="01ABC"`, `job="send"`, "bytes=" + strconv.Itoa(len(raw))} {
		if !strings.Contains(got, want) {
			t.Fatalf("summary %q lacks %q", got, want)
		}
	}
	if g := rawSummary("not json"); g != `id="-" job="-" bytes=8` {
		t.Fatalf("unparseable item summary = %q", g)
	}
	if g := rawSummary(strings.Repeat("x", MaxEnvelopeBytes+1)); !strings.Contains(g, `id="-"`) {
		t.Fatalf("oversize item must not be parsed: %q", g)
	}
	long := `{"id":"` + strings.Repeat("i", 500) + `","job":"j"}`
	if g := rawSummary(long); len(g) > 200 {
		t.Fatalf("a long id must be bounded: %d bytes", len(g))
	}
}

func TestEnvelopeEncodeKeepsPayload(t *testing.T) {
	v := Validate(env("j", "01"), declaredJ)
	out := v.Env.Encode(2, "boom")
	v2 := Validate(out, declaredJ)
	if !v2.Valid() || v2.Env.Attempt != 2 || v2.Env.LastError != "boom" || string(v2.Env.Payload) != `{"n":1}` {
		t.Fatalf("re-encoded envelope wrong: %s -> %+v", out, v2)
	}
}

func TestDeadRecordIsValidAndBounded(t *testing.T) {
	at := time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)
	big := strings.Repeat("x", 70000)
	r := NewDeadRecord(big, "", ReasonInvalid, 0, "oversize", at)
	var back DeadRecord
	if err := json.Unmarshal([]byte(r.JSON()), &back); err != nil {
		t.Fatalf("record is not valid JSON: %v", err)
	}
	if len(back.Envelope) > DeadEnvelopeBytes || !back.Truncated || back.EnvelopeBytes != 70000 {
		t.Fatalf("oversize original: len=%d truncated=%v bytes=%d", len(back.Envelope), back.Truncated, back.EnvelopeBytes)
	}
	// Control bytes are the worst case after JSON escaping: 6 bytes each.
	ctl := NewDeadRecord(strings.Repeat("\x01", 10000), "", ReasonInvalid, 0, "x", at)
	if n := len(ctl.JSON()); n > 26000 {
		t.Fatalf("a control-byte original makes a %d byte record, want at most about 25 KiB", n)
	}
	// Invalid UTF-8 and a cut inside a multi-byte character still give a valid, bounded string.
	odd := NewDeadRecord(strings.Repeat("\xff\xe2\x82", 3000), "", ReasonInvalid, 0, "x", at)
	var o DeadRecord
	if err := json.Unmarshal([]byte(odd.JSON()), &o); err != nil || !utf8.ValidString(o.Envelope) || len(o.Envelope) > DeadEnvelopeBytes {
		t.Fatalf("invalid UTF-8 original: err=%v valid=%v len=%d", err, utf8.ValidString(o.Envelope), len(o.Envelope))
	}
	small := NewDeadRecord(`{"a":1}`, "ID", ReasonPermanent, 1, "http 404", at)
	if small.Truncated || small.Envelope != `{"a":1}` || small.ID != "ID" {
		t.Fatalf("a small original is kept whole: %+v", small)
	}
}

func TestRetryDelay(t *testing.T) {
	want := []time.Duration{30 * time.Second, 2 * time.Minute, 8 * time.Minute, 32 * time.Minute}
	for i, w := range want {
		for _, j := range []float64{-0.2, 0, 0.2} {
			got := RetryDelay(i+1, clock.FixedJitter(j))
			lo, hi := time.Duration(float64(w)*0.8), time.Duration(float64(w)*1.2)
			if got < lo-time.Millisecond || got > hi+time.Millisecond {
				t.Errorf("attempt %d jitter %v: %s outside [%s, %s]", i+1, j, got, lo, hi)
			}
		}
	}
	if got := RetryDelay(9, clock.FixedJitter(0.2)); got > time.Hour {
		t.Errorf("the delay is capped at one hour, got %s", got)
	}
}

func TestWriteBackoffConstants(t *testing.T) {
	want := []time.Duration{1, 2, 4, 8, 16, 30, 30, 30}
	for n, w := range want {
		if got := Backoff(n, clock.FixedJitter(0)); got != w*time.Second {
			t.Errorf("Backoff(%d) = %s, want %s", n, got, w*time.Second)
		}
	}
	if got := Backoff(0, clock.FixedJitter(5)); got > 1200*time.Millisecond {
		t.Errorf("the jitter is clamped to +20%%, got %s", got)
	}
	if got := Backoff(100, nil); got != BackoffCap {
		t.Errorf("a huge n stays at the cap, got %s", got)
	}
}

func TestWriteErrorTaxonomy(t *testing.T) {
	transient := []error{errConn, errors.New(errOOM), errors.New(errAbort), errors.New("LOADING Redis is loading the dataset in memory"), errors.New("BUSY Redis is busy running a script"), &net.OpError{Op: "read", Err: errors.New("i/o timeout")}}
	for _, e := range transient {
		if c := Classify(e); c.Kind != KindTransient {
			t.Errorf("%v: want transient, got %+v", e, c)
		}
	}
	for _, e := range []error{errors.New(errWrongType), errors.New("ERR something else"), errors.New("weird")} {
		if c := Classify(e); c.Kind != KindDeterministic {
			t.Errorf("%v: want deterministic, got %+v", e, c)
		}
	}
	for _, e := range []error{errors.New("NOPERM this user has no permissions"), errors.New("WRONGPASS invalid username-password pair")} {
		if c := Classify(e); c.Kind != KindAuth {
			t.Errorf("%v: want auth, got %+v", e, c)
		}
	}
	if c := Classify(errors.New(errOOM)); !c.OOM {
		t.Error("OOM must be flagged")
	}
	if c := Classify(errConn); !c.Conn {
		t.Error("a lost connection must be flagged")
	}
	if c := Classify(nil); c.Kind != KindDeterministic || c.Conn {
		t.Error("nil is the zero class")
	}
}

func TestPasswordFile(t *testing.T) {
	dir := t.TempDir()
	write := func(s string) string {
		p := filepath.Join(dir, "pw")
		if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	for in, want := range map[string]string{"secret": "secret", "secret\n": "secret", "secret\n\n": "secret\n", "a b\n": "a b"} {
		if got, err := ReadPassword(write(in)); err != nil || got != want {
			t.Errorf("ReadPassword(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	if _, err := ReadPassword(write("\n")); err == nil {
		t.Error("an empty password must be an error")
	}
	if _, err := ReadPassword(filepath.Join(dir, "absent")); err == nil {
		t.Error("a missing file must be an error")
	}
}

func TestCommandTimeout(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	var conns []net.Conn
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			conns = append(conns, c) // accepted, never answered
		}
	}()
	s := NewRedisStore(ln.Addr().String(), RedisUser, "pw", 200*time.Millisecond)
	defer s.Close()
	start := time.Now()
	_, err = s.Type(t.Context(), "a:jobs:q")
	if err == nil {
		t.Fatal("a command against a non-replying server must fail")
	}
	if el := time.Since(start); el > 3*time.Second {
		t.Fatalf("the command took %s with a 200ms bound", el)
	}
	if c := Classify(err); !c.Conn || c.Kind != KindTransient {
		t.Fatalf("a timeout is a transient connection error, got %+v (%v)", c, err)
	}
	ln.Close()
	<-done
	for _, c := range conns {
		c.Close()
	}
}
