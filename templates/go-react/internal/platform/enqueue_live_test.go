//go:build live

package platform

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

// These tests need a real Redis with an app ACL user scoped to ~<app>:* (the rule new-db.sh applies). Step 9's image
// test starts that Redis and exports:
//
//	TLIVE_ADDR      host:port of Redis
//	TLIVE_ADMIN_PW  password of the `admin` user (inspection and cleanup only)
//	TLIVE_APP       the app name (the key prefix is "<app>:")
//	TLIVE_APP_PW    password of the app's Redis user, whose name equals the app name
//	TLIVE_ALLOW_FLUSH  must be 1: the tests FLUSHALL, so only ever point them at a throwaway Redis
//
// Run: go test -tags live -count=1 ./internal/platform/ -run Live
type liveEnv struct {
	addr, adminPW, app, appPW string
}

func loadLive(t *testing.T) liveEnv {
	t.Helper()
	get := func(k string) string {
		v := os.Getenv(k)
		if v == "" {
			t.Fatalf("%s is not set: run these tests through the template image test", k)
		}
		return v
	}
	return liveEnv{addr: get("TLIVE_ADDR"), adminPW: get("TLIVE_ADMIN_PW"), app: get("TLIVE_APP"), appPW: get("TLIVE_APP_PW")}
}

func (l liveEnv) client(user, pw string) *redis.Client {
	return redis.NewClient(&redis.Options{Addr: l.addr, Username: user, Password: pw, Protocol: 2, DisableIdentity: true,
		MaxRetries: -1, PoolSize: 2, DialTimeout: 2 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second})
}

func (l liveEnv) enqueuer(t *testing.T, prefix string, jobs ...string) (*Enqueuer, *redis.Client) {
	t.Helper()
	app := l.client(l.app, l.appPW)
	t.Cleanup(func() { app.Close() })
	e, err := NewEnqueuer(app, prefix, jobs)
	if err != nil {
		t.Fatal(err)
	}
	return e, app
}

func liveReset(t *testing.T, l liveEnv) *redis.Client {
	t.Helper()
	if os.Getenv("TLIVE_ALLOW_FLUSH") != "1" {
		t.Fatal("these tests run FLUSHALL on TLIVE_ADDR: set TLIVE_ALLOW_FLUSH=1 only for a throwaway Redis")
	}
	admin := l.client("admin", l.adminPW)
	t.Cleanup(func() { admin.FlushAll(context.Background()); admin.Close() })
	if err := admin.FlushAll(context.Background()).Err(); err != nil {
		t.Fatalf("admin FLUSHALL: %v", err)
	}
	return admin
}

func TestLiveLPushLandsInTheAppQueueOnly(t *testing.T) {
	l := loadLive(t)
	admin := liveReset(t, l)
	ctx := context.Background()
	e, _ := l.enqueuer(t, l.app+":", "add-note")
	id, err := e.Enqueue(ctx, "add-note", map[string]string{"title": "x"})
	if err != nil {
		t.Fatal(err)
	}
	keys, err := admin.Keys(ctx, "*").Result()
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 1 || keys[0] != l.app+":jobs:queue" {
		t.Fatalf("keys after enqueue = %v, want only %s:jobs:queue", keys, l.app)
	}
	items, err := admin.LRange(ctx, l.app+":jobs:queue", 0, -1).Result()
	if err != nil || len(items) != 1 {
		t.Fatalf("queue = %v, %v", items, err)
	}
	// The runner's validator rules (platform/jobs/internal/queue/envelope.go): 26-char id of [0-9A-Za-z], a job
	// matching the name regex, payload present, an RFC3339 enqueued_at, v == 1.
	var env struct {
		V          int             `json:"v"`
		ID         string          `json:"id"`
		Job        string          `json:"job"`
		Payload    json.RawMessage `json:"payload"`
		EnqueuedAt string          `json:"enqueued_at"`
	}
	if err := json.Unmarshal([]byte(items[0]), &env); err != nil {
		t.Fatal(err)
	}
	if env.V != 1 || env.ID != id || len(env.ID) != 26 || !testJobRE.MatchString(env.Job) || len(env.Payload) == 0 {
		t.Fatalf("envelope %+v", env)
	}
	if _, err := time.Parse(time.RFC3339, env.EnqueuedAt); err != nil || !strings.HasSuffix(env.EnqueuedAt, "Z") {
		t.Fatalf("enqueued_at %q: %v", env.EnqueuedAt, err)
	}
}

func TestLiveFullQueueRefusesAt1000(t *testing.T) {
	l := loadLive(t)
	admin := liveReset(t, l)
	ctx := context.Background()
	for i := 0; i < MaxQueueLen; i++ {
		if err := admin.LPush(ctx, l.app+":jobs:queue", "x").Err(); err != nil {
			t.Fatal(err)
		}
	}
	e, _ := l.enqueuer(t, l.app+":", "add-note")
	if _, err := e.Enqueue(ctx, "add-note", nil); !errors.Is(err, ErrQueueFull) {
		t.Fatalf("err = %v, want ErrQueueFull", err)
	}
	if n, _ := admin.LLen(ctx, l.app+":jobs:queue").Result(); n != MaxQueueLen {
		t.Fatalf("queue length %d, want %d", n, MaxQueueLen)
	}
}

func TestLiveEnqueueUniqueQueuesOnceAndKeepsKeysInThePrefix(t *testing.T) {
	l := loadLive(t)
	admin := liveReset(t, l)
	ctx := context.Background()
	e, _ := l.enqueuer(t, l.app+":", "add-note")
	id, queued, err := e.EnqueueUnique(ctx, "add-note", "rem-1:2026", nil, time.Hour)
	if err != nil || !queued || id == "" {
		t.Fatalf("first call = %q %v %v, want queued", id, queued, err)
	}
	if _, queued, err := e.EnqueueUnique(ctx, "add-note", "rem-1:2026", nil, time.Hour); err != nil || queued {
		t.Fatalf("second call queued=%v err=%v, want a no-op", queued, err)
	}
	if n, _ := admin.LLen(ctx, l.app+":jobs:queue").Result(); n != 1 {
		t.Fatalf("queue length %d, want 1", n)
	}
	key := l.app + ":jobs:dedupe:add-note:rem-1:2026"
	if got, _ := admin.Get(ctx, key).Result(); got != id {
		t.Fatalf("dedupe key holds %q, want the job id %q", got, id)
	}
	if ttl, _ := admin.TTL(ctx, key).Result(); ttl <= 0 || ttl > time.Hour {
		t.Fatalf("dedupe key ttl = %v, want within (0, 1h]", ttl)
	}
	// An enqueuer on another prefix is refused by the ACL (already at the LLEN room check, before any SET), and a
	// refused call must leave nothing behind.
	other, _ := l.enqueuer(t, "zz"+l.app+":", "add-note")
	if _, _, err := other.EnqueueUnique(ctx, "add-note", "k", nil, time.Hour); err == nil || !strings.Contains(err.Error(), "NOPERM") {
		t.Fatalf("err = %v, want NOPERM", err)
	}
	if keys, _ := admin.Keys(ctx, "zz*").Result(); len(keys) != 0 {
		t.Fatalf("keys left by the refused call: %v", keys)
	}
	// The app's ACL must permit both commands EnqueueUnique issues on the dedupe key, and refuse them outside the prefix.
	_, app := l.enqueuer(t, l.app+":", "add-note")
	if ok, err := app.SetNX(ctx, l.app+":jobs:dedupe:x", "id", time.Minute).Result(); err != nil || !ok {
		t.Fatalf("SetNX in prefix = %v, %v", ok, err)
	}
	if err := app.Del(ctx, l.app+":jobs:dedupe:x").Err(); err != nil {
		t.Fatalf("Del in prefix: %v", err)
	}
	if err := app.Del(ctx, "zz"+l.app+":jobs:dedupe:x").Err(); err == nil || !strings.Contains(err.Error(), "NOPERM") {
		t.Fatalf("Del outside prefix err = %v, want NOPERM", err)
	}
	if err := app.SetNX(ctx, "zz"+l.app+":jobs:dedupe:x", "id", time.Minute).Err(); err == nil || !strings.Contains(err.Error(), "NOPERM") {
		t.Fatalf("SetNX outside prefix err = %v, want NOPERM", err)
	}
}

func TestLiveNoPermOutsideThePrefix(t *testing.T) {
	l := loadLive(t)
	admin := liveReset(t, l)
	ctx := context.Background()
	// An enqueuer pointed at another app's prefix: the ACL must refuse and the error text must say NOPERM.
	e, _ := l.enqueuer(t, "zz"+l.app+":", "add-note")
	_, err := e.Enqueue(ctx, "add-note", nil)
	if err == nil || !strings.Contains(err.Error(), "NOPERM") {
		t.Fatalf("err = %v, want NOPERM", err)
	}
	if keys, _ := admin.Keys(ctx, "*").Result(); len(keys) != 0 {
		t.Fatalf("keys written: %v", keys)
	}
}
