package platform

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

// fakeRedis records every command so a test can assert "zero Redis commands" and exactly which key was written.
type fakeRedis struct {
	llen     int64
	llenErr  error
	pushErr  error
	commands []string
	pushed   map[string][]string

	keys        map[string]string        // dedupe keys currently set
	ttls        map[string]time.Duration // ttl each key was set with
	setErr      error
	delCtxErrs  []error // ctx.Err() seen by each Del
	delCtxHasDL []bool  // whether each Del context carried a deadline
}

func (f *fakeRedis) SetNX(_ context.Context, key string, value any, expiration time.Duration) *redis.BoolCmd {
	f.commands = append(f.commands, "SETNX "+key)
	if f.setErr != nil {
		return redis.NewBoolResult(false, f.setErr)
	}
	if f.keys == nil {
		f.keys, f.ttls = map[string]string{}, map[string]time.Duration{}
	}
	if _, ok := f.keys[key]; ok {
		return redis.NewBoolResult(false, nil)
	}
	f.keys[key], f.ttls[key] = value.(string), expiration
	return redis.NewBoolResult(true, nil)
}

func (f *fakeRedis) Del(ctx context.Context, keys ...string) *redis.IntCmd {
	for _, k := range keys {
		f.commands = append(f.commands, "DEL "+k)
		delete(f.keys, k)
	}
	f.delCtxErrs = append(f.delCtxErrs, ctx.Err())
	_, hasDL := ctx.Deadline()
	f.delCtxHasDL = append(f.delCtxHasDL, hasDL)
	return redis.NewIntResult(int64(len(keys)), nil)
}

func (f *fakeRedis) LLen(_ context.Context, key string) *redis.IntCmd {
	f.commands = append(f.commands, "LLEN "+key)
	return redis.NewIntResult(f.llen, f.llenErr)
}

func (f *fakeRedis) LPush(_ context.Context, key string, values ...any) *redis.IntCmd {
	f.commands = append(f.commands, "LPUSH "+key)
	if f.pushErr != nil {
		return redis.NewIntResult(0, f.pushErr)
	}
	if f.pushed == nil {
		f.pushed = map[string][]string{}
	}
	for _, v := range values {
		f.pushed[key] = append(f.pushed[key], string(v.([]byte)))
	}
	return redis.NewIntResult(int64(len(f.pushed[key])), nil)
}

func newTestEnqueuer(t *testing.T, f *fakeRedis) *Enqueuer {
	t.Helper()
	e, err := NewEnqueuer(f, "myapp:", []string{"add-note", "other-job"})
	if err != nil {
		t.Fatal(err)
	}
	e.now = func() time.Time { return time.Date(2026, 11, 8, 12, 30, 45, 0, time.UTC) }
	return e
}

func TestConformance07OversizeEnqueueIsRefusedAndWritesNothing(t *testing.T) {
	f := &fakeRedis{}
	e := newTestEnqueuer(t, f)
	_, err := e.Enqueue(context.Background(), "add-note", strings.Repeat("a", MaxEnvelopeBytes))
	if !errors.Is(err, ErrEnvelopeTooLarge) {
		t.Fatalf("err = %v, want ErrEnvelopeTooLarge", err)
	}
	if len(f.pushed) != 0 {
		t.Errorf("wrote %v", f.pushed)
	}
	// The limit is on the whole serialized envelope: find the largest payload that fits and check both sides of it.
	fits := func(n int) bool {
		g := &fakeRedis{}
		_, err := newTestEnqueuer(t, g).Enqueue(context.Background(), "add-note", strings.Repeat("a", n))
		if err != nil && !errors.Is(err, ErrEnvelopeTooLarge) {
			t.Fatal(err)
		}
		return err == nil
	}
	lo, hi := 0, MaxEnvelopeBytes
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if fits(mid) {
			lo = mid
		} else {
			hi = mid - 1
		}
	}
	g := &fakeRedis{}
	if _, err := newTestEnqueuer(t, g).Enqueue(context.Background(), "add-note", strings.Repeat("a", lo)); err != nil {
		t.Fatal(err)
	}
	if got := len(g.pushed["myapp:jobs:queue"][0]); got != MaxEnvelopeBytes {
		t.Errorf("largest accepted envelope is %d bytes, want exactly %d", got, MaxEnvelopeBytes)
	}
}

func TestConformance08FullQueueIsRefusedAndWritesNothing(t *testing.T) {
	for n, wantErr := range map[int64]bool{999: false, 1000: true, 1001: true} {
		f := &fakeRedis{llen: n}
		_, err := newTestEnqueuer(t, f).Enqueue(context.Background(), "add-note", nil)
		if wantErr != errors.Is(err, ErrQueueFull) {
			t.Errorf("LLEN %d: err = %v, want full=%v", n, err, wantErr)
		}
		if wantErr && len(f.pushed) != 0 {
			t.Errorf("LLEN %d: wrote %v", n, f.pushed)
		}
	}
}

func TestConformance09UndeclaredJobIsRefusedBeforeAnyRedisCommand(t *testing.T) {
	f := &fakeRedis{}
	_, err := newTestEnqueuer(t, f).Enqueue(context.Background(), "nope", map[string]int{"a": 1})
	if !errors.Is(err, ErrUndeclaredJob) {
		t.Fatalf("err = %v, want ErrUndeclaredJob", err)
	}
	if len(f.commands) != 0 {
		t.Fatalf("redis commands issued: %v", f.commands)
	}
}

func TestConformance10RedisErrorsSurface(t *testing.T) {
	cases := map[string]*fakeRedis{
		"OOM on LPUSH":    {pushErr: errors.New("OOM command not allowed when used memory > 'maxmemory'")},
		"NOPERM on LPUSH": {pushErr: errors.New("NOPERM this user has no permissions to access one of the keys used as arguments")},
		"NOPERM on LLEN":  {llenErr: errors.New("NOPERM this user has no permissions to run the 'llen' command")},
		"connection":      {llenErr: errors.New("dial tcp: connection refused")},
	}
	for name, f := range cases {
		_, err := newTestEnqueuer(t, f).Enqueue(context.Background(), "add-note", nil)
		if err == nil {
			t.Fatalf("%s: no error", name)
		}
		keyword := strings.Fields(name)[0]
		if keyword != "connection" && !strings.Contains(err.Error(), keyword) {
			t.Errorf("%s: error text lost the Redis error: %v", name, err)
		}
		if len(f.pushed) != 0 {
			t.Errorf("%s: wrote %v", name, f.pushed)
		}
	}
	cause := errors.New("OOM x")
	_, err := newTestEnqueuer(t, &fakeRedis{pushErr: cause}).Enqueue(context.Background(), "add-note", nil)
	if !errors.Is(err, cause) {
		t.Error("errors.Is does not reach the Redis error")
	}
}

var (
	testULIDRE = regexp.MustCompile(`^[0-9A-HJKMNP-TV-Z]{26}$`)
	testJobRE  = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,62}$`)
)

func TestConformance11EnvelopeShape(t *testing.T) {
	type want struct {
		payload string
		in      any
	}
	for _, w := range []want{{`{"title":"hi"}`, map[string]string{"title": "hi"}}, {`null`, nil}, {`[1,2]`, []int{1, 2}}} {
		f := &fakeRedis{}
		id, err := newTestEnqueuer(t, f).Enqueue(context.Background(), "add-note", w.in)
		if err != nil {
			t.Fatal(err)
		}
		items := f.pushed["myapp:jobs:queue"]
		if len(items) != 1 {
			t.Fatalf("pushed %v", f.pushed)
		}
		var raw map[string]json.RawMessage
		if err := json.Unmarshal([]byte(items[0]), &raw); err != nil {
			t.Fatal(err)
		}
		if len(raw) != 5 {
			t.Errorf("envelope has fields %v, want exactly v,id,job,payload,enqueued_at", raw)
		}
		var env struct {
			V          int
			ID, Job    string
			EnqueuedAt string `json:"enqueued_at"`
		}
		if err := json.Unmarshal([]byte(items[0]), &env); err != nil {
			t.Fatal(err)
		}
		if env.V != 1 || env.ID != id || !testULIDRE.MatchString(env.ID) || env.Job != "add-note" || !testJobRE.MatchString(env.Job) {
			t.Errorf("envelope %+v (id returned %q)", env, id)
		}
		if env.EnqueuedAt != "2026-11-08T12:30:45Z" {
			t.Errorf("enqueued_at = %q, want RFC3339 UTC Z", env.EnqueuedAt)
		}
		if string(raw["payload"]) != w.payload {
			t.Errorf("payload = %s, want %s", raw["payload"], w.payload)
		}
	}
}

func TestHTMLCharactersAreNotEscapedSoTheSizeMatchesTheRunner(t *testing.T) {
	f := &fakeRedis{}
	if _, err := newTestEnqueuer(t, f).Enqueue(context.Background(), "add-note", strings.Repeat("<", 60000)); err != nil {
		t.Fatalf("60000 '<' bytes must fit: %v", err)
	}
	if !strings.Contains(f.pushed["myapp:jobs:queue"][0], strings.Repeat("<", 100)) {
		t.Error("payload was HTML-escaped")
	}
}

func TestEachEnqueueGetsANewID(t *testing.T) {
	f := &fakeRedis{}
	e := newTestEnqueuer(t, f)
	a, _ := e.Enqueue(context.Background(), "add-note", nil)
	b, _ := e.Enqueue(context.Background(), "add-note", nil)
	if a == "" || a == b {
		t.Fatalf("ids %q %q", a, b)
	}
}

func TestConformance12NoKeyOutsideThePrefixIsWritten(t *testing.T) {
	f := &fakeRedis{}
	e := newTestEnqueuer(t, f)
	for _, job := range []string{"add-note", "other-job"} {
		if _, err := e.Enqueue(context.Background(), job, nil); err != nil {
			t.Fatal(err)
		}
	}
	for _, c := range f.commands {
		if !strings.HasSuffix(c, " myapp:jobs:queue") {
			t.Errorf("command %q touches a key other than myapp:jobs:queue", c)
		}
	}
	if strings.Count(strings.Join(f.commands, "\n"), "LPUSH") != 2 {
		t.Errorf("commands %v", f.commands)
	}
}

func TestPayloadThatCannotBeEncodedWritesNothing(t *testing.T) {
	f := &fakeRedis{}
	if _, err := newTestEnqueuer(t, f).Enqueue(context.Background(), "add-note", make(chan int)); err == nil {
		t.Fatal("no error")
	}
	if len(f.commands) != 0 {
		t.Fatalf("commands %v", f.commands)
	}
}

func TestNewEnqueuerFailsClosed(t *testing.T) {
	f := &fakeRedis{}
	if _, err := NewEnqueuer(nil, "a:", nil); err == nil {
		t.Error("nil client accepted")
	}
	for _, p := range []string{"", "a", "a:b:", ":", "a b:"} {
		if _, err := NewEnqueuer(f, p, nil); err == nil {
			t.Errorf("prefix %q accepted", p)
		}
	}
	if _, err := NewEnqueuer(f, "a:", []string{"Bad Name"}); err == nil {
		t.Error("invalid job name accepted")
	}
	e, err := NewEnqueuer(f, "a:", nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.Enqueue(context.Background(), "x", nil); !errors.Is(err, ErrUndeclaredJob) {
		t.Errorf("an app with no declared jobs must refuse every enqueue: %v", err)
	}
}

func TestNewRedisClientOptions(t *testing.T) {
	c := NewRedisClient(Config{RedisHost: "redis", RedisPort: 6379, RedisUser: "u", RedisPassword: "p", RedisKeyPrefix: "a:"})
	defer c.Close()
	o := c.Options()
	if o.PoolSize != 2 || o.DialTimeout == 0 || o.ReadTimeout == 0 || o.WriteTimeout == 0 || o.MaxRetries != 0 || o.Addr != "redis:6379" {
		t.Fatalf("options %+v", o)
	}
}

const testDedupeKey = "myapp:jobs:dedupe:add-note:rem-1"

func TestEnqueueUniqueQueuesOnceForTheSameKey(t *testing.T) {
	f := &fakeRedis{}
	e := newTestEnqueuer(t, f)
	id, queued, err := e.EnqueueUnique(context.Background(), "add-note", "rem-1", map[string]int{"a": 1}, 20*time.Hour)
	if err != nil || !queued || !testULIDRE.MatchString(id) {
		t.Fatalf("first call = %q %v %v", id, queued, err)
	}
	if f.keys[testDedupeKey] != id || f.ttls[testDedupeKey] != 20*time.Hour {
		t.Fatalf("dedupe key = %q ttl %v, want the job id and 20h (keys %v)", f.keys[testDedupeKey], f.ttls[testDedupeKey], f.keys)
	}
	id2, queued, err := e.EnqueueUnique(context.Background(), "add-note", "rem-1", map[string]int{"a": 1}, 20*time.Hour)
	if err != nil || queued || id2 != "" {
		t.Fatalf("second call = %q %v %v, want a no-op", id2, queued, err)
	}
	if got := len(f.pushed["myapp:jobs:queue"]); got != 1 {
		t.Fatalf("queued %d jobs, want 1", got)
	}
	if _, queued, _ := e.EnqueueUnique(context.Background(), "add-note", "rem-2", nil, time.Hour); !queued {
		t.Fatal("a different key must queue")
	}
	if _, queued, _ := e.EnqueueUnique(context.Background(), "other-job", "rem-1", nil, time.Hour); !queued {
		t.Fatal("the same key under another job must queue")
	}
	for _, c := range f.commands {
		if !strings.Contains(c, " myapp:") {
			t.Errorf("command %q touches a key outside the prefix", c)
		}
	}
}

func TestEnqueueUniqueFullQueueStoresNoKey(t *testing.T) {
	f := &fakeRedis{llen: MaxQueueLen}
	_, queued, err := newTestEnqueuer(t, f).EnqueueUnique(context.Background(), "add-note", "rem-1", nil, time.Hour)
	if !errors.Is(err, ErrQueueFull) || queued {
		t.Fatalf("err = %v queued = %v, want ErrQueueFull", err, queued)
	}
	if len(f.keys) != 0 || len(f.pushed) != 0 {
		t.Fatalf("stored keys %v / pushed %v", f.keys, f.pushed)
	}
	for _, c := range f.commands {
		if strings.HasPrefix(c, "SETNX") {
			t.Fatalf("SET issued on a full queue: %v", f.commands)
		}
	}
}

func TestEnqueueUniqueLPushFailureDeletesTheKeyOnAFreshContext(t *testing.T) {
	f := &fakeRedis{pushErr: errors.New("OOM x")}
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // the caller's context is already dead when the cleanup runs
	_, queued, err := newTestEnqueuer(t, f).EnqueueUnique(ctx, "add-note", "rem-1", nil, time.Hour)
	if err == nil || queued || !strings.Contains(err.Error(), "OOM") {
		t.Fatalf("err = %v queued = %v, want the LPUSH error", err, queued)
	}
	if _, ok := f.keys[testDedupeKey]; ok {
		t.Fatal("the dedupe key survived a failed LPUSH")
	}
	if len(f.delCtxErrs) != 1 || f.delCtxErrs[0] != nil || !f.delCtxHasDL[0] {
		t.Fatalf("Del contexts: errs %v deadlines %v, want one live context with a deadline", f.delCtxErrs, f.delCtxHasDL)
	}
	// A retry (healthy Redis) can enqueue again.
	f.pushErr = nil
	if _, queued, err := newTestEnqueuer(t, f).EnqueueUnique(context.Background(), "add-note", "rem-1", nil, time.Hour); err != nil || !queued {
		t.Fatalf("retry = %v %v, want queued", queued, err)
	}
}

func TestEnqueueUniqueRefusesBadInputBeforeAnyRedisCommand(t *testing.T) {
	cases := map[string]struct {
		job, key string
		ttl      time.Duration
		want     error
	}{
		"undeclared job": {"nope", "k", time.Hour, ErrUndeclaredJob},
		"empty key":      {"add-note", "", time.Hour, ErrInvalidDedupeKey},
		"space in key":   {"add-note", "a b", time.Hour, ErrInvalidDedupeKey},
		"glob in key":    {"add-note", "a*", time.Hour, ErrInvalidDedupeKey},
		"long key":       {"add-note", strings.Repeat("a", 129), time.Hour, ErrInvalidDedupeKey},
		"ttl too short":  {"add-note", "k", time.Second - 1, ErrInvalidDedupeKey},
		"zero ttl":       {"add-note", "k", 0, ErrInvalidDedupeKey},
		"ttl too long":   {"add-note", "k", 7*24*time.Hour + time.Second, ErrInvalidDedupeKey},
	}
	for name, c := range cases {
		f := &fakeRedis{}
		_, queued, err := newTestEnqueuer(t, f).EnqueueUnique(context.Background(), c.job, c.key, nil, c.ttl)
		if !errors.Is(err, c.want) || queued {
			t.Errorf("%s: err = %v queued = %v, want %v", name, err, queued, c.want)
		}
		if len(f.commands) != 0 {
			t.Errorf("%s: redis commands issued: %v", name, f.commands)
		}
	}
	for _, ok := range []struct {
		key string
		ttl time.Duration
	}{{"a", time.Second}, {strings.Repeat("A", 128), 7 * 24 * time.Hour}, {"A.b_c:d-e", time.Hour}} {
		if _, queued, err := newTestEnqueuer(t, &fakeRedis{}).EnqueueUnique(context.Background(), "add-note", ok.key, nil, ok.ttl); err != nil || !queued {
			t.Errorf("key %q ttl %v refused: %v", ok.key, ok.ttl, err)
		}
	}
}

func TestEnqueueUniqueOversizeAndSetErrorStoreNothing(t *testing.T) {
	f := &fakeRedis{}
	if _, _, err := newTestEnqueuer(t, f).EnqueueUnique(context.Background(), "add-note", "k", strings.Repeat("a", MaxEnvelopeBytes), time.Hour); !errors.Is(err, ErrEnvelopeTooLarge) {
		t.Fatalf("err = %v, want ErrEnvelopeTooLarge", err)
	}
	if len(f.commands) != 0 {
		t.Fatalf("commands %v", f.commands)
	}
	g := &fakeRedis{setErr: errors.New("NOPERM nope")}
	_, queued, err := newTestEnqueuer(t, g).EnqueueUnique(context.Background(), "add-note", "k", nil, time.Hour)
	if err == nil || queued || !strings.Contains(err.Error(), "NOPERM") {
		t.Fatalf("err = %v queued = %v", err, queued)
	}
	if len(g.pushed) != 0 {
		t.Fatalf("pushed %v after a failed SET", g.pushed)
	}
}
