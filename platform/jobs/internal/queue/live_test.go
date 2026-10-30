//go:build live

package queue

import (
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/gpropersi/apps/platform/jobs/internal/dispatch"
)

// TestLive runs against the real Redis that test_jobs_live.sh starts (same image and flags as platform/data/compose.yaml)
// with the real runner and app users. Every subtest starts from FLUSHALL.
func TestLive(t *testing.T) {
	t.Run("NoPermBoundary", liveNoPermBoundary)
	t.Run("EnqueueOrder", liveEnqueueOrder)
	t.Run("LremRawItem", liveLremRawItem)
	t.Run("PromotionAtomic", livePromotionAtomic)
	t.Run("DelayedBound1000", liveDelayedBound)
	t.Run("BulkLenRejected", liveBulkLen)
	t.Run("OversizeAndInvalidHead", liveInvalidHeads)
	t.Run("LmoveMismatch", liveLmoveMismatch)
	t.Run("OomRejectedLmove", liveOomLmove)
	t.Run("OomAbortedRetryExec", liveOomRetry)
	t.Run("OomAbortedDeadLetter", liveOomDead)
	t.Run("OomPromotionExec", liveOomPromotion)
	t.Run("RedisDown", liveRedisDown)
	t.Run("RedisInvalid", liveRedisInvalid)
	t.Run("DeadLetterAtomic", liveDeadLetterAtomic)
	t.Run("CompletionWriteRetry", liveCompletionWriteRetry)
	t.Run("WrongTypeParksApp", liveWrongType)
	t.Run("LostExecReply", liveLostExec)
	t.Run("RecoveryOnEnable", liveRecoveryOnEnable)
	t.Run("CrashExhaustion", liveCrashExhaustion)
}

func isNoPerm(err error) bool { return err != nil && strings.Contains(err.Error(), "NOPERM") }

func liveNoPermBoundary(t *testing.T) {
	l := newLive(t)
	runner := rawClient(l.cfg.addr, RedisUser, l.cfg.runnerPW)
	defer runner.Close()
	// Positive controls: the commands the consumer needs work on a :jobs: key, including the reserved namespace.
	for _, key := range []string{"x:jobs:queue", "x:cache:jobs:1"} {
		if err := runner.LPush(l.ctx, key, "v").Err(); err != nil {
			t.Fatalf("runner must reach %s: %v", key, err)
		}
	}
	if err := runner.Do(l.ctx, "TYPE", "x:jobs:queue").Err(); err != nil {
		t.Fatalf("runner TYPE: %v", err)
	}
	if err := runner.ZAdd(l.ctx, "x:jobs:delayed", redis.Z{Score: 1, Member: "m"}).Err(); err != nil {
		t.Fatalf("runner ZADD: %v", err)
	}
	if _, err := runner.TxPipelined(l.ctx, func(p redis.Pipeliner) error { p.LRem(l.ctx, "x:jobs:queue", 1, "v"); return nil }); err != nil {
		t.Fatalf("runner MULTI/EXEC: %v", err)
	}
	if err := runner.Do(l.ctx, "LPOS", "x:cache:jobs:1", "v").Err(); err != nil {
		t.Fatalf("runner LPOS: %v", err)
	}
	denied := [][]any{
		{"LPUSH", "x:cache:other", "v"}, {"GET", "admin"}, {"SCAN", "0"}, {"KEYS", "*"}, {"EVAL", "return 1", "0"},
		{"FLUSHALL"}, {"CONFIG", "GET", "maxmemory"}, {"DBSIZE"}, {"RANDOMKEY"}, {"SUBSCRIBE", "c"}, {"ACL", "LIST"},
	}
	for _, cmd := range denied {
		if err := runner.Do(l.ctx, cmd...).Err(); !isNoPerm(err) {
			t.Errorf("runner %v: want NOPERM, got %v", cmd, err)
		}
	}
	// The app user: its own :jobs: keys work, another app's and SCAN do not.
	app := rawClient(l.cfg.addr, l.cfg.app, l.cfg.appPW)
	defer app.Close()
	if err := app.LPush(l.ctx, l.cfg.app+":jobs:queue", "v").Err(); err != nil {
		t.Fatalf("app user must enqueue to its own queue: %v", err)
	}
	for _, cmd := range [][]any{{"LPUSH", l.cfg.other + ":jobs:queue", "v"}, {"SCAN", "0"}, {"LRANGE", l.cfg.other + ":jobs:dead", "0", "-1"}} {
		if err := app.Do(l.ctx, cmd...).Err(); !isNoPerm(err) {
			t.Errorf("app user %v: want NOPERM, got %v", cmd, err)
		}
	}
}

func liveEnqueueOrder(t *testing.T) {
	l := newLive(t)
	app := rawClient(l.cfg.addr, l.cfg.app, l.cfg.appPW)
	defer app.Close()
	q, proc := l.cfg.app+":jobs:queue", l.cfg.app+":jobs:processing"
	for _, id := range []string{"1", "2", "3"} {
		if err := app.LPush(l.ctx, q, env("j", id)).Err(); err != nil {
			t.Fatal(err)
		}
	}
	for _, id := range []string{"1", "2", "3"} {
		head, found, err := l.store.LIndexLast(l.ctx, q)
		if err != nil || !found || head != env("j", id) {
			t.Fatalf("enqueue order: want %s at the head, got %q (found=%v, err=%v); queue=%q", id, head, found, err, l.lrange(q))
		}
		moved, ok, err := l.store.LMove(l.ctx, q, proc, "RIGHT", "LEFT")
		if err != nil || !ok || moved != head {
			t.Fatalf("LMOVE returned %q ok=%v err=%v, want the peeked %q", moved, ok, err, head)
		}
	}
	if got := l.lrange(proc); len(got) != 3 || got[0] != env("j", "3") || got[2] != env("j", "1") {
		t.Fatalf("processing must hold the newest at the left end: %q", got)
	}
}

func liveLremRawItem(t *testing.T) {
	l := newLive(t)
	proc := "zz:jobs:processing" // not an app's list, so recovery never touches it
	odd := "{\"v\":1,\"x\":\"quote\\\" newline\n tab\t \x00\xff\xfe\"}"
	l.putAdmin(proc, odd, odd, "other")
	n, err := l.store.LRem(l.ctx, proc, odd)
	if err != nil || n != 1 {
		t.Fatalf("LREM of a raw item with odd bytes: n=%d err=%v", n, err)
	}
	if got := l.lrange(proc); len(got) != 2 || got[0] != "other" || got[1] != odd {
		t.Fatalf("exactly one copy must go: %q", got)
	}
	// End to end: the runner adds attempt and last_error to the retry copy, yet the original raw item leaves processing.
	l.caller.fn = retryable(503)
	raw := env("j", "9")
	l.putAdmin("a1:jobs:queue", raw)
	l.settle(func() bool { return len(l.reg.results()) == 1 })
	if p := l.processingOf("a1"); len(p) != 0 {
		t.Fatalf("processing must be empty after a retry was scheduled: %q", p)
	}
	d := l.delayedOf("a1")
	if len(d) != 1 || d[0] == raw || !strings.Contains(d[0], `"attempt":2`) {
		t.Fatalf("delayed = %q", d)
	}
}

func livePromotionAtomic(t *testing.T) {
	l := newLive(t)
	now := l.clk.Now().Unix()
	l.putAdmin("a1:jobs:queue", env("j", "q"))
	l.must("ZADD", "a1:jobs:delayed", now-20, envAttempt("j", "d1", 2), now-10, envAttempt("j2", "d2", 2), now+3600, envAttempt("j", "future", 2))
	l.c.promoteDue = true
	l.c.promote()
	q := l.queueOf("a1")
	if len(q) != 3 {
		t.Fatalf("two promoted plus the existing item: %q", q)
	}
	if left := l.delayedOf("a1"); len(left) != 1 || !strings.Contains(left[0], "future") {
		t.Fatalf("only the future item stays delayed: %q", left)
	}
	// Each promoted item moved in one MULTI/EXEC: nothing is in both places and nothing was lost.
	for _, m := range q {
		if strings.Contains(m, "future") {
			t.Fatalf("a future item was promoted: %q", q)
		}
	}
	// A promoted retry runs next: it is at the right end, ahead of the older queue item.
	if head := Validate(q[len(q)-1], declaredJ); head.Env == nil || head.Env.Attempt != 2 {
		t.Fatalf("the head must be a promoted retry: %q", q)
	}
	l.settle(func() bool { return len(l.caller.calls()) >= 1 })
	if first := l.caller.calls()[0]; first.Attempt != 2 {
		t.Fatalf("the first run must be the promoted retry (attempt 2), got %+v", first)
	}
}

func liveDelayedBound(t *testing.T) {
	l := newLive(t)
	if _, err := l.admin.Pipelined(l.ctx, func(p redis.Pipeliner) error {
		for i := 0; i < DelayedMax-1; i++ {
			p.ZAdd(l.ctx, "a1:jobs:delayed", redis.Z{Score: 4102444800, Member: "m" + strconv.Itoa(i)})
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	l.caller.block = make(chan struct{})
	l.caller.fn = retryable(503)
	l.putAdmin("a1:jobs:queue", env("j", "1"), env("j2", "2"), env("j3", "3"))
	l.settle(func() bool { return len(l.caller.calls()) == 3 })
	close(l.caller.block) // three results arrive together
	l.settle(func() bool { return len(l.reg.results()) == 3 })
	if n := len(l.delayedOf("a1")); n != DelayedMax {
		t.Fatalf("the delayed set must stop at %d, has %d", DelayedMax, n)
	}
	var retries, dead int
	for _, r := range l.reg.results() {
		switch r {
		case "retry_scheduled":
			retries++
		case "dead_lettered":
			dead++
		}
	}
	if retries != 1 || dead != 2 || len(l.deadOf("a1")) != 2 {
		t.Fatalf("want one retry and two overflows, got retries=%d dead=%d dead list=%q", retries, dead, l.deadOf("a1"))
	}
	for i := 0; i < 2; i++ {
		if r := l.deadRec("a1", i); r.Reason != ReasonOverflow {
			t.Fatalf("dead record %d = %+v", i, r)
		}
	}
}

func liveBulkLen(t *testing.T) {
	l := newLive(t)
	runner := rawClient(l.cfg.addr, RedisUser, l.cfg.runnerPW)
	defer runner.Close()
	big := strings.Repeat("x", 1<<20+1)
	if err := runner.LPush(l.ctx, "x:jobs:big", big).Err(); err == nil {
		t.Fatal("an LPUSH over 1 MB must be rejected by --proto-max-bulk-len")
	}
	if n := l.must("EXISTS", "x:jobs:big"); n != int64(0) {
		t.Fatalf("the rejected value must not be stored (EXISTS=%v)", n)
	}
	if err := runner.LPush(l.ctx, "x:jobs:ok", strings.Repeat("x", 900000)).Err(); err != nil {
		t.Fatalf("a value under the limit is accepted (control): %v", err)
	}
}

func liveInvalidHeads(t *testing.T) {
	l := newLive(t)
	l.reg.setWindow(WindowHold) // an invalid head needs no window, no slot and no in-flight wait
	l.reg.maxSlots = 0
	big := strings.Repeat("x", 70*1024)
	undeclared := strings.Replace(env("j", "u"), `"job":"j"`, `"job":"gone"`, 1)
	l.putAdmin("a1:jobs:queue", big, "not json", undeclared)
	l.settle(func() bool { return len(l.deadOf("a1")) == 3 })
	if len(l.queueOf("a1")) != 0 || len(l.processingOf("a1")) != 0 {
		t.Fatalf("queue=%q processing=%q", l.queueOf("a1"), l.processingOf("a1"))
	}
	reasons := map[string]int{}
	for i := 0; i < 3; i++ {
		r := l.deadRec("a1", i)
		reasons[r.Reason]++
		if r.Attempts != 0 {
			t.Errorf("record %d: %+v", i, r)
		}
		if r.EnvelopeBytes == 70*1024 && (!r.Truncated || len(r.Envelope) > DeadEnvelopeBytes) {
			t.Errorf("the 70 KB original must be cut and flagged: truncated=%v len=%d", r.Truncated, len(r.Envelope))
		}
	}
	if reasons[ReasonInvalid] != 2 || reasons[ReasonUndeclare] != 1 {
		t.Fatalf("reasons = %v", reasons)
	}
	if _, acq, _ := l.reg.held(); acq != 0 || len(l.caller.calls()) != 0 {
		t.Fatalf("acquired=%d calls=%d: no slot and no call for an invalid head", acq, len(l.caller.calls()))
	}
}

func liveLmoveMismatch(t *testing.T) {
	t.Run("a different valid job is re-gated and runs", func(t *testing.T) {
		l := newLive(t)
		l.putAdmin("a1:jobs:queue", env("j", "1"))
		fired := false
		l.c.afterPeek = func(string) {
			if !fired {
				fired = true
				l.must("RPUSH", "a1:jobs:queue", env("j2", "2"))
			}
		}
		l.settle(func() bool { return len(l.caller.calls()) >= 1 })
		if got := l.caller.calls()[0].Job; got != "j2" {
			t.Fatalf("the moved item runs, not the peeked one: %s", got)
		}
	})
	t.Run("a held moved item returns to the queue head", func(t *testing.T) {
		l := newLive(t)
		l.putAdmin("a1:jobs:queue", env("j", "1"))
		moved := env("j2", "2")
		fired := false
		l.c.afterPeek = func(string) {
			if !fired {
				fired = true
				l.must("RPUSH", "a1:jobs:queue", moved)
				l.reg.mark("a1", "j2", true) // j2 is in flight, so its gate refuses
			}
		}
		l.settle(func() bool { q := l.queueOf("a1"); return len(q) == 2 && len(l.processingOf("a1")) == 0 })
		q := l.queueOf("a1")
		if q[0] != moved && q[len(q)-1] != moved {
			t.Fatalf("queue = %q", q)
		}
		if q[len(q)-1] != moved {
			t.Fatalf("the returned item must again be the rightmost one: %q", q)
		}
		if len(l.caller.calls()) != 0 {
			t.Fatal("nothing may run on the peeked item's gate")
		}
	})
	t.Run("an invalid moved item is dead-lettered", func(t *testing.T) {
		l := newLive(t)
		l.putAdmin("a1:jobs:queue", env("j", "1"))
		fired := false
		l.c.afterPeek = func(string) {
			if !fired {
				fired = true
				l.must("RPUSH", "a1:jobs:queue", "garbage")
			}
		}
		l.settle(func() bool { return len(l.deadOf("a1")) == 1 })
		if r := l.deadRec("a1", 0); r.Reason != ReasonInvalid || r.Envelope != "garbage" {
			t.Fatalf("dead = %+v", r)
		}
	})
}

func liveOomLmove(t *testing.T) {
	l := newLive(t)
	l.putAdmin("a1:jobs:queue", env("j", "1"))
	l.oomOn()
	for i := 0; i < 3; i++ {
		l.quiet(2)
		l.clk.Advance(35 * time.Second)
	}
	if len(l.queueOf("a1")) != 1 || len(l.processingOf("a1")) != 0 {
		t.Fatalf("the rejected LMOVE leaves the item in the queue: queue=%q processing=%q", l.queueOf("a1"), l.processingOf("a1"))
	}
	if s, _, _ := l.reg.held(); s != 0 {
		t.Fatalf("a rejected LMOVE must not pin a slot: %d", s)
	}
	if st, _ := l.notes.counts(); st != 1 || !strings.Contains(l.notes.state[0], "OOM") {
		t.Fatalf("one OOM alert per state change: %q", l.notes.state)
	}
	if strings.Count(l.logbuf.String(), "OOM app=a1 command=LMOVE") < 2 {
		t.Fatalf("every backoff cycle logs the OOM:\n%s", l.logbuf.String())
	}
	if got := l.status.history(); len(got) != 0 {
		t.Fatalf("OOM is alert-only, redis_state stays ok: %v", got)
	}
	l.oomOff()
	l.settleAdv(func() bool { return len(l.reg.results()) == 1 })
	if st, _ := l.notes.counts(); st != 2 {
		t.Fatalf("one more alert when writes work again: %q", l.notes.state)
	}
}

func liveOomRetry(t *testing.T) {
	l := newLive(t)
	l.caller.block = make(chan struct{})
	l.caller.fn = retryable(503)
	l.putAdmin("a1:jobs:queue", env("j", "1"))
	l.settle(func() bool { return len(l.caller.calls()) == 1 })
	l.oomOn()
	close(l.caller.block)
	for i := 0; i < 3; i++ {
		l.quiet(3)
		// Stay under the 30s retry delay: once the write lands the item must sit in the delayed set, not be promoted
		// and taken again inside the same pass.
		l.clk.Advance(5 * time.Second)
	}
	if len(l.processingOf("a1")) != 1 || len(l.delayedOf("a1")) != 0 || len(l.reg.results()) != 0 {
		t.Fatalf("an aborted EXEC applies nothing: processing=%q delayed=%q records=%v", l.processingOf("a1"), l.delayedOf("a1"), l.reg.results())
	}
	if s, _, _ := l.reg.held(); s != 1 {
		t.Fatalf("the item stays in flight (slot held) while its write is pending: %d", s)
	}
	l.oomOff()
	l.settleAdv(func() bool { return len(l.reg.results()) == 1 })
	if len(l.processingOf("a1")) != 0 || len(l.delayedOf("a1")) != 1 {
		t.Fatalf("processing=%q delayed=%q", l.processingOf("a1"), l.delayedOf("a1"))
	}
	if s, _, _ := l.reg.held(); s != 0 {
		t.Fatalf("slot after the write: %d", s)
	}
}

func liveOomDead(t *testing.T) {
	l := newLive(t)
	l.caller.block = make(chan struct{})
	l.caller.fn = func(dispatch.Request) dispatch.Result {
		return dispatch.Result{Class: dispatch.ClassPermanent, HTTPStatus: 404, Err: "gone"}
	}
	raw := env("j", "1")
	l.putAdmin("a1:jobs:queue", raw)
	l.settle(func() bool { return len(l.caller.calls()) == 1 })
	l.oomOn()
	close(l.caller.block)
	for i := 0; i < 3; i++ {
		l.quiet(3)
		l.clk.Advance(35 * time.Second)
	}
	if p := l.processingOf("a1"); len(p) != 1 || p[0] != raw || len(l.deadOf("a1")) != 0 {
		t.Fatalf("an aborted dead-letter leaves the item in processing and the dead list unchanged: processing=%q dead=%q", p, l.deadOf("a1"))
	}
	l.oomOff()
	l.settleAdv(func() bool { return len(l.reg.results()) == 1 })
	if len(l.deadOf("a1")) != 1 || len(l.processingOf("a1")) != 0 {
		t.Fatalf("exactly one dead record afterwards: dead=%q processing=%q", l.deadOf("a1"), l.processingOf("a1"))
	}
}

func liveOomPromotion(t *testing.T) {
	l := newLive(t)
	due := envAttempt("j", "d", 2)
	l.must("ZADD", "a1:jobs:delayed", l.clk.Now().Unix()-5, due)
	l.oomOn()
	l.c.promote()
	if len(l.queueOf("a1")) != 0 || len(l.delayedOf("a1")) != 1 {
		t.Fatalf("an aborted promotion keeps the item delayed: queue=%q delayed=%q", l.queueOf("a1"), l.delayedOf("a1"))
	}
	l.oomOff()
	l.c.promote()
	if q := l.queueOf("a1"); len(q) != 1 || q[0] != due || len(l.delayedOf("a1")) != 0 {
		t.Fatalf("queue=%q delayed=%q", q, l.delayedOf("a1"))
	}
}

func liveRedisDown(t *testing.T) {
	l := newLive(t)
	l.c.pass()
	l.proxy.Stop()
	l.putAdmin("a1:jobs:queue", env("j", "1"))
	l.quiet(3)
	if got := l.status.history(); len(got) != 1 || got[0] != "down" {
		t.Fatalf("status = %v", got)
	}
	if st, _ := l.notes.counts(); st != 1 {
		t.Fatalf("one alert for down: %q", l.notes.state)
	}
	if len(l.caller.calls()) != 0 {
		t.Fatal("nothing runs while Redis is down")
	}
	l.proxy.Start(t)
	l.settleAdv(func() bool { return len(l.reg.results()) == 1 })
	if got := l.status.history(); len(got) != 2 || got[1] != "ok" {
		t.Fatalf("status = %v", got)
	}
	if st, _ := l.notes.counts(); st != 2 {
		t.Fatalf("one alert for the recovery: %q", l.notes.state)
	}
}

func liveRedisInvalid(t *testing.T) {
	l := newLive(t)
	l.c.pass()
	l.must("ACL", "SETUSER", RedisUser, "resetpass", ">changed-"+l.cfg.runnerPW)
	l.must("CLIENT", "KILL", "USER", RedisUser)
	l.settleAdv(func() bool { h := l.status.history(); return len(h) > 0 && h[len(h)-1] == "invalid" })
	if st, _ := l.notes.counts(); st < 1 {
		t.Fatalf("an alert for invalid: %q", l.notes.state)
	}
	l.must("ACL", "SETUSER", RedisUser, "resetpass", ">"+l.cfg.runnerPW)
	l.settleAdv(func() bool { h := l.status.history(); return h[len(h)-1] == "ok" })
}

func liveDeadLetterAtomic(t *testing.T) {
	l := newLive(t)
	for i := 0; i < DeadKeep+5; i++ {
		l.must("LPUSH", "a1:jobs:dead", `{"old":`+strconv.Itoa(i)+`}`)
	}
	l.caller.fn = func(dispatch.Request) dispatch.Result {
		return dispatch.Result{Class: dispatch.ClassPermanent, HTTPStatus: 404, Err: "gone"}
	}
	raw := env("j", "7")
	l.putAdmin("a1:jobs:queue", raw)
	l.settle(func() bool { return len(l.reg.results()) == 1 })
	dead := l.deadOf("a1")
	if len(dead) != DeadKeep {
		t.Fatalf("the dead list is capped at %d, has %d", DeadKeep, len(dead))
	}
	if r := l.deadRec("a1", 0); r.Reason != ReasonPermanent || r.Attempts != 1 || r.Envelope != raw || !strings.Contains(r.LastError, "404") {
		t.Fatalf("newest record = %+v", r)
	}
	if len(l.processingOf("a1")) != 0 {
		t.Fatal("processing must be empty")
	}
	_, alerts := l.notes.counts()
	if alerts != 1 {
		t.Fatalf("one dead-letter alert, got %d", alerts)
	}
}

func liveCompletionWriteRetry(t *testing.T) {
	l := newLive(t)
	l.caller.block = make(chan struct{})
	l.caller.fn = retryable(503)
	raw := env("j", "1")
	l.putAdmin("a1:jobs:queue", raw)
	l.settle(func() bool { return len(l.caller.calls()) == 1 })
	l.proxy.Stop() // the connection drops between the HTTP result and the write
	close(l.caller.block)
	l.quiet(4)
	if p := l.processingOf("a1"); len(p) != 1 || len(l.reg.results()) != 0 {
		t.Fatalf("the write is pending: processing=%q records=%v", p, l.reg.results())
	}
	if s, _, _ := l.reg.held(); s != 1 {
		t.Fatalf("slot and mark are held while the write is pending: %d", s)
	}
	l.proxy.Start(t)
	l.settleAdv(func() bool { return len(l.reg.results()) == 1 })
	if len(l.processingOf("a1")) != 0 || len(l.delayedOf("a1")) != 1 {
		t.Fatalf("processing=%q delayed=%q", l.processingOf("a1"), l.delayedOf("a1"))
	}
	if s, _, _ := l.reg.held(); s != 0 {
		t.Fatalf("slot after the write: %d", s)
	}
}

func liveWrongType(t *testing.T) {
	permanent := func(r dispatch.Request) dispatch.Result {
		if r.App == "a1" {
			return dispatch.Result{Class: dispatch.ClassPermanent, HTTPStatus: 400, Err: "bad"}
		}
		return dispatch.Result{Class: dispatch.ClassOK, HTTPStatus: 200}
	}
	// parkAndRepair retypes key, expects the app to park (alert text "parked", the item stays in processing, a second
	// app is still served), then repairs the key and expects un-park, recovery of the write and a "served again" alert.
	parkAndRepair := func(t *testing.T, key string, fn func(dispatch.Request) dispatch.Result, landed func(l *live) bool) {
		l := newLive(t)
		l.caller.fn = fn
		l.must("SET", key, "oops")
		raw := env("j", "1")
		l.putAdmin("a1:jobs:queue", raw)
		l.settle(func() bool { st, _ := l.notes.counts(); return st == 1 })
		if !strings.Contains(l.notes.state[0], "parked") || !strings.Contains(l.logbuf.String(), "parked app=a1") {
			t.Fatalf("alert=%q", l.notes.state)
		}
		if p := l.processingOf("a1"); len(p) != 1 || p[0] != raw {
			t.Fatalf("the TYPE pre-check applies nothing: processing=%q", p)
		}
		l.putAdmin("a2:jobs:queue", env("j", "2"))
		l.settle(func() bool { return len(l.reg.results()) >= 1 })
		if l.reg.results()[0] != "ok" {
			t.Fatalf("a second app keeps being served: %v", l.reg.results())
		}
		l.must("DEL", key)
		l.clk.Advance(ProbeEvery)
		l.settle(func() bool { return landed(l) })
		if len(l.processingOf("a1")) != 0 {
			t.Fatal("processing must be empty after the repair")
		}
		if st, _ := l.notes.counts(); st != 2 || !strings.Contains(l.notes.state[1], "served again") {
			t.Fatalf("alerts = %q", l.notes.state)
		}
	}
	t.Run("dead key retyped", func(t *testing.T) {
		parkAndRepair(t, "a1:jobs:dead", permanent, func(l *live) bool { return len(l.deadOf("a1")) == 1 })
	})
	t.Run("delayed key retyped", func(t *testing.T) {
		parkAndRepair(t, "a1:jobs:delayed", func(r dispatch.Request) dispatch.Result {
			if r.App == "a1" {
				return dispatch.Result{Class: dispatch.ClassRetryable, HTTPStatus: 503, Err: "unavailable"}
			}
			return dispatch.Result{Class: dispatch.ClassOK, HTTPStatus: 200}
		}, func(l *live) bool { return len(l.delayedOf("a1")) == 1 })
	})
	t.Run("retyped between TYPE and EXEC logs the partial EXEC", func(t *testing.T) {
		l := newLive(t)
		l.caller.fn = permanent
		fired := false
		l.c.beforeExec = func(string) {
			if !fired {
				fired = true
				l.must("SET", "a1:jobs:dead", "oops")
			}
		}
		l.putAdmin("a1:jobs:queue", env("j", "1"))
		l.settle(func() bool { st, _ := l.notes.counts(); return st == 1 })
		if !strings.Contains(l.logbuf.String(), "partial EXEC applied") {
			t.Fatalf("a partial EXEC must be logged:\n%s", l.logbuf.String())
		}
		if !strings.Contains(l.notes.state[0], "parked") {
			t.Fatalf("alerts = %q", l.notes.state)
		}
	})
}

func liveLostExec(t *testing.T) {
	run := func(t *testing.T, fn func(dispatch.Request) dispatch.Result) *live {
		l := newLive(t)
		l.caller.block = make(chan struct{})
		l.caller.fn = fn
		l.putAdmin("a1:jobs:queue", env("j", "1"))
		l.settle(func() bool { return len(l.caller.calls()) == 1 })
		l.proxy.armExec.Store(true)
		close(l.caller.block)
		l.settleAdv(func() bool { return len(l.reg.results()) == 1 && len(l.processingOf("a1")) == 0 })
		if l.proxy.armExec.Load() {
			t.Fatal("the proxy never saw an EXEC")
		}
		// Keep running after the settle point so a late duplicate write would show in the counts below.
		for i := 0; i < 3; i++ {
			l.c.pass()
			time.Sleep(3 * time.Millisecond)
		}
		l.clk.Advance(20 * time.Second) // under the 30s first retry delay, so nothing is promoted and retaken
		for i := 0; i < 3; i++ {
			l.c.pass()
			time.Sleep(3 * time.Millisecond)
		}
		return l
	}
	t.Run("retry schedule", func(t *testing.T) {
		l := run(t, retryable(503))
		if n := len(l.delayedOf("a1")); n != 1 {
			t.Fatalf("exactly one delayed entry, got %d", n)
		}
		if got := l.reg.results(); len(got) != 1 || got[0] != "retry_scheduled" {
			t.Fatalf("records = %v", got)
		}
		if _, alerts := l.notes.counts(); alerts != 0 {
			t.Fatalf("a retry sends no run alert (%d)", alerts)
		}
		if !strings.Contains(l.logbuf.String(), "write landed") {
			t.Fatalf("the LPOS shortcut must be logged:\n%s", l.logbuf.String())
		}
	})
	t.Run("dead letter", func(t *testing.T) {
		l := run(t, func(dispatch.Request) dispatch.Result {
			return dispatch.Result{Class: dispatch.ClassPermanent, HTTPStatus: 404, Err: "gone"}
		})
		if n := len(l.deadOf("a1")); n != 1 {
			t.Fatalf("exactly one dead record, got %d", n)
		}
		if got := l.reg.results(); len(got) != 1 || got[0] != "dead_lettered" {
			t.Fatalf("records = %v", got)
		}
		if _, alerts := l.notes.counts(); alerts != 1 {
			t.Fatalf("one dead-letter alert, got %d", alerts)
		}
		if !strings.Contains(l.logbuf.String(), "write landed") {
			t.Fatalf("the LPOS shortcut must be logged:\n%s", l.logbuf.String())
		}
	})
}

func liveRecoveryOnEnable(t *testing.T) {
	l := newLive(t)
	l.removeSecret("a1") // the app is disabled
	big := strings.Repeat("x", 70*1024)
	undeclared := strings.Replace(env("j", "u"), `"job":"j"`, `"job":"gone"`, 1)
	valid := envAttempt("j", "v", 1)
	left := []string{valid, big, "not json", undeclared}
	l.putAdmin("a1:jobs:processing", left...)
	l.reg.setWindow(WindowHold)
	l.quiet(4)
	if got := l.processingOf("a1"); len(got) != 4 {
		t.Fatalf("a disabled app's items are left untouched: %q", got)
	}
	l.addApp("a1", "j", "j2") // the secret is back: the app transitions to enabled
	l.settle(func() bool { return len(l.processingOf("a1")) == 0 })
	if q := l.queueOf("a1"); len(q) != 1 || !strings.Contains(q[0], `"attempt":2`) {
		t.Fatalf("only the valid envelope returns, with attempt + 1: %q", q)
	}
	if n := len(l.deadOf("a1")); n != 3 {
		t.Fatalf("invalid, oversize and undeclared are dead-lettered: %q", l.deadOf("a1"))
	}
	for i := 0; i < 3; i++ {
		if r := l.deadRec("a1", i); r.Attempts != 0 || (r.Reason != ReasonInvalid && r.Reason != ReasonUndeclare) {
			t.Errorf("record %d = %+v", i, r)
		}
	}
}

func liveCrashExhaustion(t *testing.T) {
	l := newLive(t)
	l.putAdmin("a1:jobs:queue", env("j", "1"))
	block := make(chan struct{})
	defer close(block) // before the consumers' wg.Wait cleanups, which would otherwise wait on blocked workers
	for round := 1; round <= 6; round++ {
		reg := newFakeReg()
		reg.declare("a1", "j")
		reg.declare("a1", "j2")
		caller := &fakeCaller{block: block}
		c := l.buildConsumer(l.store, reg, caller)
		l.c = c
		if round <= 5 {
			l.settle(func() bool { return len(caller.calls()) == 1 })
			if got := caller.calls()[0].Attempt; got != round {
				t.Fatalf("round %d ran attempt %d", round, got)
			}
			// the process "crashes" here: this consumer is abandoned with the item in processing
			if p := l.processingOf("a1"); len(p) != 1 {
				t.Fatalf("round %d: processing=%q", round, p)
			}
			continue
		}
		l.settle(func() bool { return len(l.deadOf("a1")) == 1 })
	}
	r := l.deadRec("a1", 0)
	if r.Reason != ReasonExhausted || r.Attempts != 5 || !strings.Contains(r.LastError, "runner crashed during attempt 5") {
		t.Fatalf("dead record = %+v", r)
	}
	if len(l.processingOf("a1")) != 0 || len(l.queueOf("a1")) != 0 {
		t.Fatalf("queue=%q processing=%q", l.queueOf("a1"), l.processingOf("a1"))
	}
}
