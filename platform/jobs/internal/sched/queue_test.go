package sched

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/dispatch"
	"github.com/gpropersi/apps/platform/jobs/internal/queue"
)

func TestQueueRegistryAdapterSharesSlotAndMark(t *testing.T) {
	e := newEnv(t, laTime(6, 59, 0), goodWindow, oneJob("0 7 * * *", "30s", false))
	e.run()
	q := e.s.QueueRegistry()
	if apps := q.Apps(); len(apps) != 1 || apps[0] != "aa" {
		t.Fatalf("apps = %v", apps)
	}
	if spec, ok := q.Job("aa", "j"); !ok || spec.Port != 8080 || spec.Timeout != 30*time.Second {
		t.Fatalf("job = %+v %v", spec, ok)
	}
	if _, ok := q.Job("aa", "nope"); ok {
		t.Fatal("an undeclared job must not resolve")
	}
	release, ok := q.TryAcquire("aa", "j")
	if !ok {
		t.Fatal("first acquire")
	}
	if _, ok := q.TryAcquire("aa", "j"); ok {
		t.Fatal("the in-flight mark is shared: the same job cannot be acquired twice")
	}
	if e.s.tryStart(jobKey{"aa", "j"}) {
		t.Fatal("the scheduler must see the queue's in-flight mark")
	}
	if len(e.s.sem) != 1 {
		t.Fatalf("the queue holds a cap slot: %d", len(e.s.sem))
	}
	release()
	if len(e.s.sem) != 0 {
		t.Fatalf("release frees the slot: %d", len(e.s.sem))
	}
	if !e.s.tryStart(jobKey{"aa", "j"}) {
		t.Fatal("release frees the mark")
	}
	e.s.finish(jobKey{"aa", "j"})
}

func TestQueueRegistryTryAcquireNeverBlocksOnFullCap(t *testing.T) {
	e := newEnv(t, laTime(6, 59, 0), goodWindow, oneJob("0 7 * * *", "30s", false))
	e.run()
	for i := 0; i < MaxConcurrent; i++ {
		e.s.sem <- struct{}{}
	}
	done := make(chan bool)
	go func() { _, ok := e.s.QueueRegistry().TryAcquire("aa", "j"); done <- ok }()
	select {
	case ok := <-done:
		if ok {
			t.Fatal("a full cap must refuse")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("TryAcquire blocked")
	}
	if !e.s.tryStart(jobKey{"aa", "j"}) {
		t.Fatal("a refused acquire must not leave the in-flight mark behind")
	}
	e.s.finish(jobKey{"aa", "j"})
}

func TestQueueRegistryWindowGate(t *testing.T) {
	e := newEnv(t, laTime(6, 59, 0), goodWindow, oneJob("0 7 * * *", "30s", false))
	e.run()
	q := e.s.QueueRegistry()
	if v := q.WindowGate(time.Second); v == queue.WindowInvalid {
		t.Fatal("a good window.env must be readable")
	}
	e.writeWindow("garbage")
	if v := q.WindowGate(time.Second); v != queue.WindowInvalid {
		t.Fatalf("an unreadable window.env refuses everything, got %v", v)
	}
}

func TestScheduledFailureAlertsThroughRunAlerter(t *testing.T) {
	e := newEnv(t, laTime(6, 59, 0), goodWindow, oneJob("0 7 * * *", "30s", false))
	e.fc.fn = func(context.Context, dispatch.Request) dispatch.Result {
		return dispatch.Result{Class: dispatch.ClassPermanent, HTTPStatus: 500, Err: "boom"}
	}
	e.run()
	e.advTo(laTime(7, 1, 0))
	waitFor(t, "the failure alert", func() bool { return len(e.notif.runAlerts()) == 1 })
	if got := e.notif.runAlerts()[0]; !strings.HasPrefix(got, "aa/j/failed") {
		t.Fatalf("alert = %q", got)
	}
}
