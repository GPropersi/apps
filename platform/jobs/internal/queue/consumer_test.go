package queue

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/dispatch"
)

func (h *harness) put(app string, raws ...string) { h.st.push(app+":jobs:queue", raws...) } // oldest first

func (h *harness) status0() []string { return h.status.history() }

func retryable(code int) func(dispatch.Request) dispatch.Result {
	return func(dispatch.Request) dispatch.Result {
		return dispatch.Result{Class: dispatch.ClassRetryable, HTTPStatus: code, Err: "unavailable"}
	}
}

func TestConsumerPassOrder(t *testing.T) {
	h := newHarness(t)
	var phases []string
	h.c.trace = func(p string) { phases = append(phases, p) }
	h.c.pass()
	want := []string{"drain", "promote", "recover", "take"}
	if strings.Join(phases, ",") != strings.Join(want, ",") {
		t.Fatalf("phases = %v, want %v", phases, want)
	}
}

func TestConsumerIdleWait(t *testing.T) {
	h := newHarness(t)
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan struct{})
	go func() { h.c.Run(ctx); close(done) }()
	waitFor(t, func() bool { return h.st.count("LINDEX") >= 1 })
	time.Sleep(30 * time.Millisecond)
	n := h.st.count("LINDEX")
	time.Sleep(30 * time.Millisecond)
	if got := h.st.count("LINDEX"); got != n {
		t.Fatalf("an idle consumer must wait on the clock, LINDEX went %d -> %d without time moving", n, got)
	}
	waitFor(t, func() bool { return h.clk.Pending() >= 2 }) // the ticker and the idle wait
	h.clk.Advance(IdleWait)
	waitFor(t, func() bool { return h.st.count("LINDEX") > n })
	cancel()
	<-done
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("condition not reached")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestGateConditions(t *testing.T) {
	blocked := map[string]func(h *harness){
		"window holds":    func(h *harness) { h.reg.setWindow(WindowHold) },
		"window invalid":  func(h *harness) { h.reg.setWindow(WindowInvalid) },
		"secret missing":  func(h *harness) { h.removeSecret("a1") },
		"job in flight":   func(h *harness) { h.reg.mark("a1", "j", true) },
		"cap slots taken": func(h *harness) { h.reg.maxSlots = 0 },
	}
	for name, setup := range blocked {
		t.Run(name, func(t *testing.T) {
			h := newHarness(t)
			h.put("a1", env("j", "1"))
			setup(h)
			h.quiet(4)
			if n := h.st.count("LMOVE"); n != 0 {
				t.Fatalf("a blocked head must not be moved, LMOVE ran %d times", n)
			}
			if len(h.q("a1")) != 1 || len(h.caller.calls()) != 0 || len(h.reg.results()) != 0 {
				t.Fatalf("nothing may run or be recorded: queue=%v calls=%d records=%v", h.q("a1"), len(h.caller.calls()), h.reg.results())
			}
			if s, _, _ := h.reg.held(); s != 0 {
				t.Fatalf("a refused gate must not pin a cap slot (%d held)", s)
			}
		})
	}
	h := newHarness(t)
	h.put("a1", env("j", "1"))
	h.settle(func() bool { return len(h.reg.results()) == 1 })
	if h.reg.results()[0] != "ok" || len(h.q("a1")) != 0 || len(h.proc("a1")) != 0 {
		t.Fatalf("all gates open: want one ok run, got %v queue=%v proc=%v", h.reg.results(), h.q("a1"), h.proc("a1"))
	}
	if r := h.caller.calls()[0]; r.Trigger != "queue" || r.Attempt != 1 || r.Job != "j" || r.Port != 8080 {
		t.Fatalf("request = %+v", r)
	}
}

func TestDispatchSkipMovesBack(t *testing.T) {
	t.Run("window closes between take and call", func(t *testing.T) {
		h := newHarness(t)
		var n atomic.Int32
		h.reg.windowFn = func() WindowVerdict {
			if n.Add(1) == 1 {
				return WindowAllow
			}
			return WindowHold
		}
		raw := env("j", "1")
		h.put("a1", raw)
		h.settle(func() bool { return len(h.q("a1")) == 1 && len(h.proc("a1")) == 0 && n.Load() >= 2 })
		if got := h.q("a1")[0]; got != raw {
			t.Fatalf("the item must return unchanged (attempt not incremented):\n got %s\nwant %s", got, raw)
		}
		if len(h.caller.calls()) != 0 || len(h.reg.results()) != 0 {
			t.Fatalf("no call and no record for a window refusal: calls=%d records=%v", len(h.caller.calls()), h.reg.results())
		}
		if s, _, _ := h.reg.held(); s != 0 {
			t.Fatalf("the slot must be freed (%d held)", s)
		}
	})
	t.Run("secret vanishes before the call", func(t *testing.T) {
		h := newHarness(t)
		raw := env("j", "1")
		h.put("a1", raw)
		h.caller.fn = func(dispatch.Request) dispatch.Result {
			h.reg.setWindow(WindowHold) // stop the retake loop
			return dispatch.Result{NoSecret: true, Err: "no secret"}
		}
		h.settle(func() bool { return len(h.reg.results()) == 1 && len(h.q("a1")) == 1 && len(h.proc("a1")) == 0 })
		if h.reg.results()[0] != "skipped_no_secret" || h.q("a1")[0] != raw {
			t.Fatalf("records=%v queue=%v", h.reg.results(), h.q("a1"))
		}
		if h.reg.records[0].Attempt != 0 {
			t.Fatalf("a skip is not an attempt: %+v", h.reg.records[0])
		}
	})
}

func TestHeadOfLine(t *testing.T) {
	h := newHarness(t)
	h.put("a1", env("j", "1"), env("j2", "2")) // j is the head
	h.reg.mark("a1", "j", true)
	h.quiet(5)
	if len(h.caller.calls()) != 0 || h.st.count("LMOVE") != 0 {
		t.Fatalf("an item behind a blocked head must wait: calls=%d", len(h.caller.calls()))
	}
	h.reg.mark("a1", "j", false)
	h.settle(func() bool { return len(h.caller.calls()) >= 1 })
	if got := h.caller.calls()[0].Job; got != "j" {
		t.Fatalf("the head runs first, got %s", got)
	}
}

func TestQueuedWindowCrossing(t *testing.T) {
	h := newHarness(t)
	h.caller.block = make(chan struct{})
	h.put("a1", env("j", "1"))
	h.settle(func() bool { return len(h.caller.calls()) == 1 })
	h.reg.setWindow(WindowHold) // the window opens while the run is in flight
	close(h.caller.block)
	h.settle(func() bool { return len(h.reg.results()) == 1 })
	if h.reg.results()[0] != "ok" || len(h.proc("a1")) != 0 {
		t.Fatalf("a run that started in the window is not cancelled: %v", h.reg.results())
	}
	h.put("a1", env("j", "2"))
	h.quiet(4)
	if len(h.caller.calls()) != 1 {
		t.Fatal("the next item waits while the window refuses")
	}
}

func TestLmoveMismatch(t *testing.T) {
	setup := func(h *harness, newer string) string {
		old := env("j", "1")
		h.put("a1", old)
		fired := false
		h.c.afterPeek = func(string) {
			if !fired {
				fired = true
				h.st.mu.Lock()
				h.st.lists["a1:jobs:queue"] = append(h.st.lists["a1:jobs:queue"], newer) // a new right end
				h.st.mu.Unlock()
			}
		}
		return old
	}
	t.Run("moved item is re-gated and runs", func(t *testing.T) {
		h := newHarness(t)
		setup(h, env("j2", "2"))
		h.settle(func() bool { return len(h.caller.calls()) >= 1 })
		if got := h.caller.calls()[0].Job; got != "j2" {
			t.Fatalf("the item that actually moved is the one that runs, got %s", got)
		}
		if !strings.Contains(h.logbuf.String(), "lmove mismatch") {
			t.Fatal("a mismatch is logged")
		}
		h.settle(func() bool { return len(h.reg.results()) >= 1 })
	})
	t.Run("moved invalid item is dead-lettered", func(t *testing.T) {
		h := newHarness(t)
		setup(h, "garbage")
		h.settle(func() bool { return len(h.dead("a1")) == 1 })
		if r := h.deadRecord("a1", 0); r.Reason != ReasonInvalid || r.Envelope != "garbage" {
			t.Fatalf("dead record = %+v", r)
		}
	})
	t.Run("moved item that the gate refuses goes back", func(t *testing.T) {
		h := newHarness(t)
		var n atomic.Int32
		h.reg.windowFn = func() WindowVerdict {
			if n.Add(1) == 1 {
				return WindowAllow
			}
			return WindowHold
		}
		newer := env("j2", "2")
		setup(h, newer)
		h.settle(func() bool {
			q := h.q("a1")
			return len(q) == 2 && len(h.proc("a1")) == 0 && q[len(q)-1] == newer
		})
		if len(h.caller.calls()) != 0 {
			t.Fatal("nothing may run on a gate evaluated for a different job")
		}
	})
}

func TestHookNilInProduction(t *testing.T) {
	c := New(Config{Clock: clock.NewFake(time.Unix(0, 0)), Store: newFakeStore()})
	if c.afterPeek != nil || c.beforeExec != nil || c.trace != nil {
		t.Fatal("test hooks must be nil in a production consumer")
	}
}

func TestSlotReleasedOnLmoveNilAndError(t *testing.T) {
	t.Run("nil reply", func(t *testing.T) {
		h := newHarness(t)
		h.put("a1", env("j", "1"))
		h.c.afterPeek = func(string) { h.st.setList("a1:jobs:queue") }
		h.quiet(2)
		s, acq, rel := h.reg.held()
		if s != 0 || acq != 1 || rel != 1 {
			t.Fatalf("slots=%d acquired=%d released=%d", s, acq, rel)
		}
	})
	t.Run("error reply", func(t *testing.T) {
		h := newHarness(t)
		h.put("a1", env("j", "1"))
		h.st.setFail(func(cmd string, _ []string) error {
			if cmd == "LMOVE" {
				return errors.New(errOOM)
			}
			return nil
		})
		h.quiet(2)
		s, acq, rel := h.reg.held()
		if s != 0 || acq != 1 || rel != 1 {
			t.Fatalf("slots=%d acquired=%d released=%d", s, acq, rel)
		}
	})
}

func TestRetrySchedule503(t *testing.T) {
	delays := []time.Duration{30 * time.Second, 2 * time.Minute, 8 * time.Minute, 32 * time.Minute}
	for n := 1; n <= 5; n++ {
		h := newHarness(t)
		h.caller.fn = retryable(503)
		h.put("a1", envAttempt("j", "1", n))
		start := h.clk.Now()
		if n <= 4 {
			h.settle(func() bool { return len(h.reg.results()) == 1 && len(h.proc("a1")) == 0 })
			z := h.st.zset("a1:jobs:delayed")
			if len(z) != 1 || h.reg.results()[0] != "retry_scheduled" {
				t.Fatalf("attempt %d: delayed=%v results=%v", n, z, h.reg.results())
			}
			if _, alerts := h.notes.counts(); alerts != 0 {
				t.Fatalf("attempt %d: a retry must not alert, got %d", n, alerts)
			}
			for member, score := range z {
				if want := start.Add(delays[n-1]).Unix(); int64(score) != want {
					t.Errorf("attempt %d: due %d, want %d (+%s)", n, int64(score), want, delays[n-1])
				}
				if v := Validate(member, declaredJ); !v.Valid() || v.Env.Attempt != n+1 || !strings.Contains(v.Env.LastError, "503") {
					t.Errorf("attempt %d: retry envelope = %+v", n, v)
				}
			}
			continue
		}
		h.settle(func() bool { return len(h.dead("a1")) == 1 })
		if r := h.deadRecord("a1", 0); r.Reason != ReasonExhausted || r.Attempts != 5 {
			t.Fatalf("attempt 5: %+v", r)
		}
		if len(h.st.zset("a1:jobs:delayed")) != 0 {
			t.Fatal("attempt 5 is never retried")
		}
		if _, alerts := h.notes.counts(); alerts != 1 {
			t.Fatalf("exhaustion sends one alert, not five: got %d", alerts)
		}
	}
}

func TestOutcomeMapping(t *testing.T) {
	cases := []struct {
		name   string
		res    dispatch.Result
		record string
		dead   string
		delay  bool
		alert  bool
	}{
		{"ok", dispatch.Result{Class: dispatch.ClassOK, HTTPStatus: 200}, "ok", "", false, false},
		{"permanent 404", dispatch.Result{Class: dispatch.ClassPermanent, HTTPStatus: 404, Err: "not found"}, "dead_lettered", ReasonPermanent, false, true},
		{"retryable 500", dispatch.Result{Class: dispatch.ClassRetryable, HTTPStatus: 500, Err: "boom"}, "retry_scheduled", "", true, false},
		{"timeout", dispatch.Result{Class: dispatch.ClassRetryable, Timeout: true, Err: "timeout"}, "retry_scheduled", "", true, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := newHarness(t)
			h.caller.fn = func(dispatch.Request) dispatch.Result { return c.res }
			h.put("a1", env("j", "1"))
			h.settle(func() bool { return len(h.reg.results()) == 1 && len(h.proc("a1")) == 0 })
			if got := h.reg.results()[0]; got != c.record {
				t.Fatalf("record %s, want %s", got, c.record)
			}
			if (len(h.dead("a1")) == 1) != (c.dead != "") || (len(h.st.zset("a1:jobs:delayed")) == 1) != c.delay {
				t.Fatalf("dead=%v delayed=%v", h.dead("a1"), h.st.zset("a1:jobs:delayed"))
			}
			if c.dead != "" {
				if r := h.deadRecord("a1", 0); r.Reason != c.dead || r.Attempts != 1 {
					t.Fatalf("dead record %+v", r)
				}
			}
			_, alerts := h.notes.counts()
			if (alerts == 1) != c.alert {
				t.Fatalf("alerts=%d, want alert=%v", alerts, c.alert)
			}
			if s, _, _ := h.reg.held(); s != 0 {
				t.Fatalf("slot still held after the write landed: %d", s)
			}
		})
	}
}

func TestInvalidHeadSkipsGate(t *testing.T) {
	h := newHarness(t)
	h.reg.setWindow(WindowHold)
	h.reg.maxSlots = 0
	h.put("a1", "garbage")
	h.settle(func() bool { return len(h.dead("a1")) == 1 })
	if r := h.deadRecord("a1", 0); r.Reason != ReasonInvalid || r.Attempts != 0 {
		t.Fatalf("dead record %+v", r)
	}
	if _, acq, _ := h.reg.held(); acq != 0 {
		t.Fatal("an invalid head needs no cap slot")
	}
	if len(h.proc("a1")) != 0 || len(h.q("a1")) != 0 {
		t.Fatalf("queue=%v processing=%v", h.q("a1"), h.proc("a1"))
	}
}

func TestParkAndUnpark(t *testing.T) {
	h := newHarness(t)
	h.addApp("a2", "j")
	h.caller.fn = func(r dispatch.Request) dispatch.Result {
		if r.App == "a1" {
			return dispatch.Result{Class: dispatch.ClassPermanent, HTTPStatus: 400, Err: "bad"}
		}
		return dispatch.Result{Class: dispatch.ClassOK, HTTPStatus: 200}
	}
	h.st.setString("a1:jobs:dead", "oops") // a wrong-type destination
	raw := env("j", "1")
	h.put("a1", raw)
	h.settle(func() bool { st, _ := h.notes.counts(); return st == 1 })
	if !strings.Contains(h.notes.state[0], "parked") {
		t.Fatalf("alert = %q", h.notes.state[0])
	}
	if got := h.proc("a1"); len(got) != 1 || got[0] != raw {
		t.Fatalf("the item stays in processing: %v", got)
	}
	if s, _, _ := h.reg.held(); s != 0 {
		t.Fatalf("a parked app holds no slot (%d)", s)
	}
	h.put("a2", env("j", "2"))
	h.settle(func() bool { return len(h.reg.results()) >= 1 })
	if h.reg.results()[0] != "ok" {
		t.Fatalf("other apps are unaffected: %v", h.reg.results())
	}
	h.put("a1", env("j2", "3"))
	h.quiet(5)
	if len(h.q("a1")) != 1 {
		t.Fatal("a parked app is not taken from")
	}
	h.clk.Advance(ProbeEvery)
	h.quiet(3)
	if st, _ := h.notes.counts(); st != 1 {
		t.Fatalf("a failed probe alerts nothing more, state alerts = %v", h.notes.state)
	}
	h.st.clearString("a1:jobs:dead")
	h.clk.Advance(ProbeEvery)
	h.settle(func() bool { return len(h.dead("a1")) == 1 })
	if st, _ := h.notes.counts(); st != 2 || !strings.Contains(h.notes.state[1], "served again") {
		t.Fatalf("alerts = %v", h.notes.state)
	}
	h.settle(func() bool { return len(h.proc("a1")) == 0 && len(h.q("a1")) == 0 })
}

func TestAmbiguousWriteLposCheck(t *testing.T) {
	retry := func(t *testing.T, apply bool) *harness {
		h := newHarness(t)
		h.caller.fn = retryable(503)
		var n atomic.Int32
		h.st.failExec = func([]Cmd) (bool, error) {
			if n.Add(1) == 1 {
				return apply, errConn
			}
			return true, nil
		}
		h.put("a1", env("j", "1"))
		h.settle(func() bool { return len(h.caller.calls()) == 1 && n.Load() == 1 })
		for i := 0; i < 4 && len(h.reg.results()) == 0; i++ {
			h.clk.Advance(2 * time.Second)
			h.settle(func() bool { return true })
			time.Sleep(5 * time.Millisecond)
		}
		h.settle(func() bool { return len(h.reg.results()) == 1 })
		return h
	}
	t.Run("reply lost after the write applied", func(t *testing.T) {
		h := retry(t, true)
		if got := h.st.count("EXEC"); got != 1 {
			t.Fatalf("the applied write must not be repeated, EXEC ran %d times", got)
		}
		if len(h.st.zset("a1:jobs:delayed")) != 1 || len(h.proc("a1")) != 0 || h.st.count("LPOS") < 1 {
			t.Fatalf("delayed=%v proc=%v lpos=%d", h.st.zset("a1:jobs:delayed"), h.proc("a1"), h.st.count("LPOS"))
		}
	})
	t.Run("write never applied", func(t *testing.T) {
		h := retry(t, false)
		if got := h.st.count("EXEC"); got != 2 {
			t.Fatalf("an unapplied write is retried once, EXEC ran %d times", got)
		}
		if len(h.st.zset("a1:jobs:delayed")) != 1 || len(h.proc("a1")) != 0 {
			t.Fatalf("delayed=%v proc=%v", h.st.zset("a1:jobs:delayed"), h.proc("a1"))
		}
	})
}

func TestRecoveryTrigger(t *testing.T) {
	h := newHarness(t)
	h.reg.setWindow(WindowHold) // recovery runs, nothing is taken
	h.st.setList("a1:jobs:processing", envAttempt("j", "1", 1))
	h.quiet(4)
	if n := h.st.count("LRANGE"); n != 1 {
		t.Fatalf("recovery runs once at start, LRANGE ran %d times", n)
	}
	if q := h.q("a1"); len(q) != 1 || Validate(q[0], declaredJ).Env.Attempt != 2 {
		t.Fatalf("leftover item must return with attempt + 1: %v", q)
	}
	h.removeSecret("a1") // the app leaves enabled
	h.quiet(2)
	h.addApp("a1", "j", "j2") // and comes back
	h.st.setList("a1:jobs:processing", envAttempt("j", "9", 1))
	h.quiet(4)
	if n := h.st.count("LRANGE"); n != 2 {
		t.Fatalf("recovery runs again on the transition to enabled, LRANGE ran %d times", n)
	}
}

func TestRecoveryOrderAndExhaustion(t *testing.T) {
	h := newHarness(t)
	h.reg.setWindow(WindowHold)
	newest := envAttempt("j", "1", 1)
	oldest := envAttempt("j2", "2", 2)
	exhausted := envAttempt("j", "3", 5)
	undeclared := strings.Replace(envAttempt("j", "4", 1), `"job":"j"`, `"job":"zzz"`, 1)
	h.st.setList("a1:jobs:processing", newest, "garbage", exhausted, undeclared, oldest) // leftmost is newest
	h.settle(func() bool { return len(h.proc("a1")) == 0 })
	q := h.q("a1") // left to right; the right end is the head
	if len(q) != 2 {
		t.Fatalf("queue = %v", q)
	}
	head := Validate(q[1], declaredJ)
	next := Validate(q[0], declaredJ)
	if head.Env.Job != "j2" || head.Env.Attempt != 3 || next.Env.Job != "j" || next.Env.Attempt != 2 {
		t.Fatalf("the oldest must end at the head with attempt + 1: head=%+v next=%+v", head.Env, next.Env)
	}
	if !strings.Contains(head.Env.LastError, "runner crashed during attempt 2") {
		t.Fatalf("last_error = %q", head.Env.LastError)
	}
	reasons := map[string]DeadRecord{}
	for i := range h.dead("a1") {
		r := h.deadRecord("a1", i)
		reasons[r.Reason] = r
	}
	if len(reasons) != 3 {
		t.Fatalf("want 3 dead records, got %v", reasons)
	}
	if r := reasons[ReasonExhausted]; r.Attempts != 5 || !strings.Contains(r.LastError, "runner crashed during attempt 5") {
		t.Errorf("exhausted: %+v", r)
	}
	if r := reasons[ReasonInvalid]; r.Attempts != 0 || r.Envelope != "garbage" {
		t.Errorf("invalid: %+v", r)
	}
	if r := reasons[ReasonUndeclare]; r.Attempts != 0 {
		t.Errorf("undeclared: %+v", r)
	}
}

func TestDelayedOverflowUnit(t *testing.T) {
	h := newHarness(t)
	for i := 0; i < DelayedMax; i++ {
		h.st.zadd("a1:jobs:delayed", 4102444800, env("j", strconv.Itoa(i)))
	}
	h.caller.fn = retryable(503)
	h.put("a1", env("j", "1"))
	h.settle(func() bool { return len(h.dead("a1")) == 1 })
	if r := h.deadRecord("a1", 0); r.Reason != ReasonOverflow {
		t.Fatalf("dead record %+v", r)
	}
	if n := len(h.st.zset("a1:jobs:delayed")); n != DelayedMax {
		t.Fatalf("the delayed set stays bounded at %d, has %d", DelayedMax, n)
	}
	if got := h.reg.results(); len(got) != 1 || got[0] != "dead_lettered" {
		t.Fatalf("records = %v", got)
	}
}

func TestRedisStateMapping(t *testing.T) {
	failOn := func(h *harness, cmd string, err *error) {
		h.st.setFail(func(c string, _ []string) error {
			if c == cmd {
				return *err
			}
			return nil
		})
	}
	t.Run("connection error is down and recovers", func(t *testing.T) {
		h := newHarness(t)
		e := error(errConn)
		failOn(h, "LINDEX", &e)
		h.quiet(3)
		if got := h.status0(); len(got) != 1 || got[0] != "down" {
			t.Fatalf("status = %v", got)
		}
		e = nil
		h.clk.Advance(2 * time.Second)
		h.quiet(3)
		if got := h.status0(); len(got) != 2 || got[1] != "ok" {
			t.Fatalf("status = %v", got)
		}
		if st, _ := h.notes.counts(); st != 2 {
			t.Fatalf("one alert per change, got %v", h.notes.state)
		}
	})
	t.Run("NOPERM is invalid", func(t *testing.T) {
		h := newHarness(t)
		e := errors.New("NOPERM this user has no permissions to run the 'lindex' command")
		failOn(h, "LINDEX", &e)
		h.quiet(3)
		if got := h.status0(); len(got) != 1 || got[0] != "invalid" {
			t.Fatalf("status = %v", got)
		}
	})
	t.Run("OOM is alert only", func(t *testing.T) {
		h := newHarness(t)
		h.put("a1", env("j", "1"))
		e := errors.New(errOOM)
		failOn(h, "LMOVE", &e)
		for i := 0; i < 3; i++ {
			h.quiet(2)
			h.clk.Advance(35 * time.Second)
		}
		if got := h.status0(); len(got) != 0 {
			t.Fatalf("OOM must not change redis_state: %v", got)
		}
		if st, _ := h.notes.counts(); st != 1 || !strings.Contains(h.notes.state[0], "OOM") {
			t.Fatalf("one OOM alert expected, got %v", h.notes.state)
		}
		e = nil
		h.settle(func() bool { return len(h.reg.results()) == 1 })
		if st, _ := h.notes.counts(); st != 2 {
			t.Fatalf("recovery from OOM alerts once: %v", h.notes.state)
		}
	})
	t.Run("server error reply keeps the state ok", func(t *testing.T) {
		h := newHarness(t)
		h.st.setString("a1:jobs:queue", "oops")
		h.quiet(3)
		if got := h.status0(); len(got) != 0 {
			t.Fatalf("a WRONGTYPE reply means Redis is reachable: %v", got)
		}
	})
}
