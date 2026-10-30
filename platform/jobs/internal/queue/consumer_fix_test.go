package queue

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/dispatch"
)

func permanent400(dispatch.Request) dispatch.Result {
	return dispatch.Result{Class: dispatch.ClassPermanent, HTTPStatus: 400, Err: "bad"}
}

// A partial EXEC (LREM applied, LPUSH refused) must not be mistaken for a landed write by the LPOS shortcut.
func TestPartialExecIsRerunNotShortcut(t *testing.T) {
	h := newHarness(t)
	h.caller.fn = permanent400
	fired := false
	h.c.beforeExec = func(string) {
		if !fired {
			fired = true
			h.st.setString("a1:jobs:dead", "oops") // retyped between the TYPE check and the EXEC
		}
	}
	h.put("a1", env("j", "1"))
	h.settle(func() bool { st, _ := h.notes.counts(); return st == 1 })
	if len(h.proc("a1")) != 0 || len(h.reg.results()) != 0 {
		t.Fatalf("the LREM applied and nothing landed: proc=%v records=%v", h.proc("a1"), h.reg.results())
	}
	h.st.clearString("a1:jobs:dead")
	h.clk.Advance(ProbeEvery)
	h.settle(func() bool { return len(h.dead("a1")) == 1 && len(h.reg.results()) == 1 })
	h.quiet(3)
	if n := len(h.dead("a1")); n != 1 {
		t.Fatalf("exactly one dead record expected, got %d", n)
	}
	if got := h.reg.results(); len(got) != 1 || got[0] != "dead_lettered" {
		t.Fatalf("records = %v", got)
	}
	if n := h.st.count("LPOS"); n != 0 {
		t.Fatalf("the LPOS shortcut must not run after a partial EXEC, ran %d times", n)
	}
	if _, alerts := h.notes.counts(); alerts != 1 {
		t.Fatalf("one dead-letter alert expected, got %d", alerts)
	}
}

// An LMOVE whose reply is lost may have moved an item into processing: recovery must run again.
func TestLostLmoveReplyTriggersRecovery(t *testing.T) {
	h := newHarness(t)
	h.put("a1", env("j", "1"))
	h.st.lmoveLostOnce = true
	h.c.pass()
	if len(h.proc("a1")) != 1 || len(h.q("a1")) != 0 {
		t.Fatalf("the LMOVE applied: proc=%v queue=%v", h.proc("a1"), h.q("a1"))
	}
	h.reg.setWindow(WindowHold) // recovery runs, nothing is taken
	h.clk.Advance(35 * time.Second)
	h.settle(func() bool { return len(h.proc("a1")) == 0 && len(h.q("a1")) == 1 })
	if v := Validate(h.q("a1")[0], declaredJ); !v.Valid() || v.Env.Attempt != 2 {
		t.Fatalf("the stranded item returns with attempt + 1: %+v", v)
	}
}

// A cancelled root context (shutdown) is not a Redis fault: no park, no alert.
func TestCancelledContextDoesNotPark(t *testing.T) {
	h := newHarness(t)
	h.put("a1", env("j", "1"))
	ctx, cancel := context.WithCancel(context.Background())
	h.c.root = ctx
	h.st.setFail(func(cmd string, _ []string) error {
		if cmd == "LMOVE" {
			cancel()
			return context.Canceled
		}
		return nil
	})
	h.quiet(3)
	if h.c.apps["a1"].parked != nil {
		t.Fatal("shutdown must not park the app")
	}
	if st, alerts := h.notes.counts(); st != 0 || alerts != 0 {
		t.Fatalf("shutdown must not alert: %v", h.notes.state)
	}
}

func TestEncodeDoesNotInflateHTMLChars(t *testing.T) {
	payload := `"` + strings.Repeat("<&>", 19000) + `"` // 57002 bytes; escaped it would be about 6x larger
	e := Envelope{V: 1, ID: "00000000000000000000000001", Job: "j", Payload: json.RawMessage(payload), EnqueuedAt: "2026-03-01T11:00:00Z"}
	out := e.Encode(2, "http 503: unavailable")
	if len(out) > MaxEnvelopeBytes {
		t.Fatalf("encoded %d bytes, over the %d limit", len(out), MaxEnvelopeBytes)
	}
	if strings.Contains(out, `\`+`u003c`) {
		t.Fatal("HTML escaping must be off")
	}
	v := Validate(out, declaredJ)
	if !v.Valid() || v.Env.Attempt != 2 || string(v.Env.Payload) != payload || v.Env.LastError == "" {
		t.Fatalf("round trip failed: valid=%v reason=%s", v.Valid(), v.Reason)
	}
}

// ---- contract-table gaps (review B, section 1) ----

func TestRecoveryWaitsForInFlightAndPendingWrite(t *testing.T) {
	toggle := func(h *harness) {
		h.removeSecret("a1") // leaves enabled
		h.quiet(2)
		h.addApp("a1", "j", "j2") // and comes back
	}
	t.Run("in-flight item", func(t *testing.T) {
		h := newHarness(t)
		h.caller.block = make(chan struct{})
		h.put("a1", env("j", "1"))
		h.settle(func() bool { return len(h.caller.calls()) == 1 })
		toggle(h)
		h.quiet(4)
		if n := h.st.count("LRANGE"); n != 1 {
			t.Fatalf("recovery must wait for the in-flight item, LRANGE ran %d times", n)
		}
		close(h.caller.block)
		h.settle(func() bool { return len(h.reg.results()) == 1 && len(h.proc("a1")) == 0 })
		h.quiet(3)
		if n := h.st.count("LRANGE"); n != 2 {
			t.Fatalf("recovery runs once the item is done, LRANGE ran %d times", n)
		}
	})
	t.Run("pending write", func(t *testing.T) {
		h := newHarness(t)
		fail := true
		h.st.setFail(func(cmd string, _ []string) error {
			if cmd == "LREM" && fail {
				return errors.New(errOOM)
			}
			return nil
		})
		h.put("a1", env("j", "1"))
		h.settle(func() bool { return h.st.count("LREM") >= 1 })
		toggle(h)
		h.quiet(4)
		if n := h.st.count("LRANGE"); n != 1 {
			t.Fatalf("recovery must wait for the pending write, LRANGE ran %d times", n)
		}
		if len(h.proc("a1")) != 1 {
			t.Fatalf("the item stays in processing until the write lands: %v", h.proc("a1"))
		}
		fail = false
		h.clk.Advance(35 * time.Second)
		h.settle(func() bool { return len(h.reg.results()) == 1 && len(h.proc("a1")) == 0 })
		h.quiet(3)
		if n := h.st.count("LRANGE"); n != 2 {
			t.Fatalf("recovery runs after the write lands, LRANGE ran %d times", n)
		}
	})
}

func TestHeadOfLineOtherAppsServed(t *testing.T) {
	h := newHarness(t)
	h.addApp("a2", "j")
	h.put("a1", env("j", "1"))
	h.reg.mark("a1", "j", true) // a1's head is blocked
	h.put("a2", env("j", "2"))
	h.settle(func() bool { return len(h.reg.results()) >= 1 })
	if r := h.caller.calls(); len(r) != 1 || r[0].App != "a2" {
		t.Fatalf("a2 is served while a1's head waits: %+v", r)
	}
	if len(h.q("a1")) != 1 {
		t.Fatalf("a1's head stays queued: %v", h.q("a1"))
	}
}

func TestParkedAppIsNotPromotedOrRecoveredUntilUnparked(t *testing.T) {
	h := newHarness(t)
	h.caller.fn = permanent400
	h.st.setString("a1:jobs:dead", "oops")
	h.put("a1", env("j", "1"))
	h.settle(func() bool { st, _ := h.notes.counts(); return st == 1 })
	h.st.zadd("a1:jobs:delayed", 1000, env("j", "7")) // long due
	before := h.st.count("LRANGE")
	h.clk.Advance(5 * PromoteEvery)
	h.quiet(4)
	if len(h.st.zset("a1:jobs:delayed")) != 1 || len(h.q("a1")) != 0 {
		t.Fatalf("a parked app is not promoted: delayed=%v queue=%v", h.st.zset("a1:jobs:delayed"), h.q("a1"))
	}
	if n := h.st.count("LRANGE"); n != before {
		t.Fatalf("a parked app is not recovered, LRANGE %d -> %d", before, n)
	}
	h.st.clearString("a1:jobs:dead")
	h.clk.Advance(ProbeEvery)
	h.settle(func() bool { return len(h.dead("a1")) >= 1 && h.st.count("LRANGE") > before })
	h.clk.Advance(2 * PromoteEvery)
	h.settle(func() bool { return len(h.st.zset("a1:jobs:delayed")) == 0 })
}
