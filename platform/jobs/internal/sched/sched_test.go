package sched

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/dispatch"
	"github.com/gpropersi/apps/platform/jobs/internal/history"
)

func oneJob(schedule, timeout string, catchUp bool) map[string]string {
	return map[string]string{"aa": appYAML("aa", jobYAML("j", schedule, timeout, catchUp))}
}

func blockingCaller(gate chan struct{}) func(context.Context, dispatch.Request) dispatch.Result {
	return func(ctx context.Context, r dispatch.Request) dispatch.Result {
		select {
		case <-gate:
		case <-ctx.Done():
		}
		return okResult
	}
}

func TestFiresAtCronTimePlusFnvOffsetInLosAngeles(t *testing.T) {
	e := newEnv(t, laTime(6, 59, 0), goodWindow, oneJob("0 7 * * *", "30s", false))
	e.run()
	off := fnvOffset("aa/j")
	want := laTime(7, 0, 0).Add(off)

	e.advTo(want.Add(-time.Second))
	if n := e.fc.count(); n != 0 {
		t.Fatalf("%d calls before the fire time", n)
	}
	e.advTo(want)
	waitFor(t, "the call", func() bool { return e.fc.count() == 1 })
	req := e.fc.requests()[0]
	if !req.ScheduledFor.Equal(want) || req.Trigger != "schedule" || req.Attempt != 1 || req.App != "aa" ||
		req.Job != "j" || req.Port != 8080 || req.Timeout != 30*time.Second {
		t.Fatalf("request = %+v, want scheduled_for %s", req, want)
	}
	rec := e.waitRun("aa", "j", "ok")
	if rec[cScheduledFor] != utc(want) || rec[cTrigger] != "schedule" || rec[cHTTP] != "200" || rec[cAttempt] != "1" || rec[cError] != "-" {
		t.Fatalf("record = %q", rec)
	}
	next := utc(laTime(7, 0, 0).Add(24 * time.Hour).Add(off))
	waitFor(t, "jobs.tsv next_due", func() bool {
		r := e.jobRow("aa", "j")
		return r != nil && r[4] == "ok" && r[7] == next && r[8] == "ok" && r[2] == "0 7 * * *" && r[3] == "false"
	})
	logs := e.logs.String()
	for _, frag := range []string{"run start app=aa job=j trigger=schedule run_id=", "run end app=aa job=j trigger=schedule run_id=", " result=ok http=200 dur_ms="} {
		if !strings.Contains(logs, frag) {
			t.Errorf("log lacks %q:\n%s", frag, logs)
		}
	}
	if !strings.Contains(logs, "2026-03-04T") {
		t.Errorf("log lines are not stamped with a UTC time:\n%s", logs)
	}
}

func TestOverlappingFireIsSkippedWhileTheJobRuns(t *testing.T) {
	e := newEnv(t, laTime(6, 59, 0), goodWindow, oneJob("0 7,8 * * *", "5m", false))
	gate := make(chan struct{})
	e.fc.fn = blockingCaller(gate)
	e.run()
	off := fnvOffset("aa/j")
	e.advTo(laTime(7, 0, 0).Add(off))
	waitFor(t, "first call", func() bool { return e.fc.count() == 1 })
	e.advTo(laTime(8, 0, 0).Add(off))
	skip := e.waitRun("aa", "j", "skipped_overlap")
	if skip[cDuration] != "0" || skip[cAttempt] != "0" || skip[cScheduledFor] != utc(laTime(8, 0, 0).Add(off)) {
		t.Fatalf("skip record = %q", skip)
	}
	if e.fc.count() != 1 {
		t.Fatalf("the overlapping fire called the app: %d calls", e.fc.count())
	}
	close(gate)
	e.waitRun("aa", "j", "ok")
}

func TestQueuedRunHoldingSingleFlightMakesScheduledFireSkip(t *testing.T) {
	e := newEnv(t, laTime(6, 59, 0), goodWindow, oneJob("0 7,8 * * *", "5m", false))
	e.run()
	off := fnvOffset("aa/j")
	if !e.s.tryStart(jobKey{"aa", "j"}) { // what the Step 7 consumer does for a queued run
		t.Fatal("single-flight should be free")
	}
	if e.s.tryStart(jobKey{"aa", "j"}) {
		t.Fatal("single-flight handed out twice")
	}
	e.advTo(laTime(7, 0, 0).Add(off))
	e.waitRun("aa", "j", "skipped_overlap")
	e.s.finish(jobKey{"aa", "j"})
	e.advTo(laTime(8, 0, 0).Add(off))
	e.waitRun("aa", "j", "ok")
	if e.fc.count() != 1 {
		t.Fatalf("calls = %d", e.fc.count())
	}
}

func TestFourthConcurrentRunWaitsThenIsSkippedForCap(t *testing.T) {
	jobs := strings.Join([]string{
		jobYAML("j1", "0 7 * * *", "5m", false), jobYAML("j2", "0 7 * * *", "5m", false),
		jobYAML("j3", "0 7 * * *", "5m", false), jobYAML("j4", "0 7 * * *", "5m", false),
	}, "")
	e := newEnv(t, laTime(6, 59, 0), goodWindow, map[string]string{"aa": appYAML("aa", jobs)})
	gate := make(chan struct{})
	e.fc.fn = blockingCaller(gate)
	e.run()
	e.advTo(laTime(7, 1, 0))
	waitFor(t, "3 in flight and one waiting", func() bool { return e.fc.count() == 3 && e.s.capWaiting.Load() == 1 })
	if got := e.runsWhere("", "", "skipped_cap"); len(got) != 0 {
		t.Fatalf("skipped before the 60s wait: %q", got)
	}
	e.adv(CapWait)
	skip := e.waitRun("aa", "", "skipped_cap")
	if e.fc.count() != 3 {
		t.Fatalf("the 4th run reached the app: %d calls", e.fc.count())
	}
	close(gate)
	waitFor(t, "3 ok runs", func() bool { return len(e.runsWhere("", "", "ok")) == 3 })
	if skip[cJob] == "" || skip[cDuration] != "0" {
		t.Fatalf("skip record = %q", skip)
	}
}

func TestBackupWindowRefusesFiresInsideAndOverlappingIt(t *testing.T) {
	cases := []struct {
		name, schedule, timeout string
		start                   time.Time
		fire                    time.Time
	}{
		{"inside the window", "40 3 * * *", "5s", laTime(3, 39, 0), laTime(3, 40, 0)},
		{"timeout would cross the start", "10 3 * * *", "30m", laTime(3, 9, 0), laTime(3, 10, 0)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e := newEnv(t, c.start, goodWindow, oneJob(c.schedule, c.timeout, false))
			e.run()
			off := fnvOffset("aa/j")
			e.advTo(c.fire.Add(off))
			rec := e.waitRun("aa", "j", "skipped_window")
			if !strings.Contains(rec[cError], "03:30-05:00 America/Los_Angeles") {
				t.Fatalf("the skip does not name the window: %q", rec[cError])
			}
			e.advTo(laTime(5, 30, 0)) // a plain job is never retried or deferred
			if e.fc.count() != 0 {
				t.Fatalf("a refused job ran %d times", e.fc.count())
			}
		})
	}
}

func TestRefusedCatchUpJobRunsOnceAtWindowEndPlusOffset(t *testing.T) {
	e := newEnv(t, laTime(3, 9, 0), goodWindow, oneJob("10 3 * * *", "30m", true))
	e.run()
	off := fnvOffset("aa/j")
	e.advTo(laTime(3, 10, 0).Add(off))
	e.waitRun("aa", "j", "skipped_window")
	end := laTime(5, 0, 0).Add(off)
	e.advTo(end.Add(-time.Second))
	if e.fc.count() != 0 {
		t.Fatalf("ran before the window ended")
	}
	e.advTo(end)
	waitFor(t, "the deferred call", func() bool { return e.fc.count() == 1 })
	req := e.fc.requests()[0]
	if req.Trigger != "catch_up" || !req.ScheduledFor.Equal(laTime(3, 10, 0).Add(off)) {
		t.Fatalf("request = %+v", req)
	}
	rec := e.waitRun("aa", "j", "ok")
	if rec[cTrigger] != "catch_up" {
		t.Fatalf("record = %q", rec)
	}
	e.advTo(laTime(6, 30, 0))
	if e.fc.count() != 1 {
		t.Fatalf("the deferred run happened %d times", e.fc.count())
	}
}

func TestDeferredCatchUpRunSurvivesARestart(t *testing.T) {
	e := newEnv(t, laTime(3, 39, 0), goodWindow, oneJob("40 3 * * *", "5s", true))
	e.run()
	off := fnvOffset("aa/j")
	e.advTo(laTime(3, 40, 0).Add(off))
	e.waitRun("aa", "j", "skipped_window")
	end := laTime(5, 0, 0).Add(off)
	waitFor(t, "the deferral in schedule.tsv", func() bool {
		b, _ := os.ReadFile(filepath.Join(e.state, "schedule.tsv"))
		cols := strings.Split(strings.TrimSuffix(string(b), "\n"), "\t")
		return len(cols) == 5 && cols[3] == utc(end) && cols[4] == utc(laTime(3, 40, 0).Add(off))
	})
	e.restart()
	e.advTo(end.Add(-time.Second))
	if e.fc.count() != 0 {
		t.Fatal("ran before the window ended")
	}
	e.advTo(end)
	rec := e.waitRun("aa", "j", "ok")
	if rec[cTrigger] != "catch_up" || rec[cScheduledFor] != utc(laTime(3, 40, 0).Add(off)) {
		t.Fatalf("record = %q", rec)
	}
	waitFor(t, "the deferral cleared in schedule.tsv", func() bool {
		b, _ := os.ReadFile(filepath.Join(e.state, "schedule.tsv"))
		return strings.Count(strings.TrimSuffix(string(b), "\n"), "\t") == 2
	})
	e.advTo(laTime(6, 30, 0))
	if got := len(e.runsWhere("aa", "j", "ok")); got != 1 || e.fc.count() != 1 {
		t.Fatalf("%d ok records and %d calls, want exactly one", got, e.fc.count())
	}
	if got := e.runsWhere("aa", "j", "skipped_missed"); len(got) != 0 {
		t.Fatalf("unexpected skipped_missed: %q", got)
	}
}

func TestFirstValidWindowKeepsPersistedLastFiredSoMissedRunsAreHandled(t *testing.T) {
	// The runner starts with an invalid window.env, so next_due is first computed in UTC. The fixed file selects
	// Tokyo, where the fire time is earlier: both jobs were missed and must not be silently forgotten.
	start := time.Date(2026, 3, 4, 23, 0, 0, 0, time.UTC)
	tokyo := "BACKUP_WINDOW_START=03:30\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=Asia/Tokyo\n"
	jobs := jobYAML("j", "0 7 * * *", "30s", true) + jobYAML("k", "0 7 * * *", "30s", false)
	e := newEnv(t, start, "garbage\n", map[string]string{"aa": appYAML("aa", jobs)})
	if err := os.MkdirAll(e.state, 0o700); err != nil {
		t.Fatal(err)
	}
	last := utc(time.Date(2026, 3, 4, 8, 0, 0, 0, time.UTC))
	if err := os.WriteFile(filepath.Join(e.state, "schedule.tsv"), []byte("aa\tj\t"+last+"\naa\tk\t"+last+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	e.run()
	if len(e.runs()) != 0 || e.fc.count() != 0 {
		t.Fatal("nothing is due while the window file is invalid")
	}
	e.writeWindow(tokyo)
	e.adv(ReloadEvery)
	tokyoFire := func(job string) string { // 07:00 on 5 March in Tokyo is 22:00 UTC on 4 March
		return utc(time.Date(2026, 3, 4, 22, 0, 0, 0, time.UTC).Add(fnvOffset("aa/" + job)))
	}
	rec := e.waitRun("aa", "j", "ok")
	if rec[cTrigger] != "catch_up" || rec[cScheduledFor] != tokyoFire("j") {
		t.Fatalf("catch-up record = %q", rec)
	}
	missed := e.waitRun("aa", "k", "skipped_missed")
	if missed[cScheduledFor] != tokyoFire("k") {
		t.Fatalf("missed record = %q", missed)
	}
	e.adv(ReloadEvery)
	if got := len(e.runs()); got != 2 || e.fc.count() != 1 {
		t.Fatalf("%d records and %d calls, want one record per job and one call", got, e.fc.count())
	}
}

func TestShortJobBeforeTheWindowRuns(t *testing.T) {
	e := newEnv(t, laTime(2, 59, 0), goodWindow, oneJob("0 3 * * *", "5m", false))
	e.run()
	e.advTo(laTime(3, 1, 0))
	e.waitRun("aa", "j", "ok")
}

func TestBadWindowFileRefusesEverythingAndAlertsOnce(t *testing.T) {
	e := newEnv(t, laTime(6, 58, 0), "this is not a window file\n", oneJob("* * * * *", "5s", false))
	e.run()
	if r := e.runner(); len(r) != 6 || r[2] != "invalid" {
		t.Fatalf("runner.tsv = %q", r)
	}
	e.advTo(laTime(7, 1, 0))
	waitFor(t, "refused_config records", func() bool { return len(e.runsWhere("aa", "j", "refused_config")) >= 2 })
	if e.fc.count() != 0 {
		t.Fatalf("%d runs with a bad window file", e.fc.count())
	}
	e.waitJobState("aa", "j", "window_refused")
	if m := e.notif.messages(); len(m) != 1 || !strings.Contains(m[0], "invalid") {
		t.Fatalf("alerts = %q, want exactly one", m)
	}
	e.writeWindow(goodWindow)
	e.adv(ReloadEvery)
	waitFor(t, "window_state ok", func() bool { r := e.runner(); return len(r) == 6 && r[2] == "ok" })
	e.waitJobState("aa", "j", "ok")
	if m := e.notif.messages(); len(m) != 2 || !strings.Contains(m[1], "valid again") {
		t.Fatalf("alerts = %q, want a recovery notice", m)
	}
	e.advTo(laTime(7, 3, 0))
	e.waitRun("aa", "j", "ok")
}

func TestWindowChangesTakeEffectWithoutRestart(t *testing.T) {
	t.Run("hours, replaced by temp and rename", func(t *testing.T) {
		e := newEnv(t, laTime(6, 58, 0), goodWindow, oneJob("0 7 * * *", "5s", false))
		e.run()
		e.writeWindow("BACKUP_WINDOW_START=06:00\nBACKUP_WINDOW_END=08:00\nBACKUP_WINDOW_TZ=America/Los_Angeles\n")
		e.advTo(laTime(7, 1, 0))
		e.waitRun("aa", "j", "skipped_window")
		if e.fc.count() != 0 {
			t.Fatal("ran inside the new window")
		}
	})
	t.Run("zone", func(t *testing.T) {
		e := newEnv(t, laTime(6, 59, 0), goodWindow, oneJob("0 7 * * *", "5s", false))
		e.run()
		off := fnvOffset("aa/j")
		waitFor(t, "initial next_due", func() bool {
			r := e.jobRow("aa", "j")
			return r != nil && r[7] == utc(laTime(7, 0, 0).Add(off))
		})
		e.writeWindow("BACKUP_WINDOW_START=03:30\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=America/New_York\n")
		e.adv(ReloadEvery)
		nyNext := time.Date(2026, 3, 5, 7, 0, 0, 0, mustLoc("America/New_York")).Add(off)
		waitFor(t, "next_due in the new zone", func() bool {
			r := e.jobRow("aa", "j")
			return r != nil && r[7] == utc(nyNext)
		})
	})
}

func TestMissedRunsOnRestartCatchUpOrAreRecorded(t *testing.T) {
	jobs := jobYAML("j", "0 7 * * *", "30s", true) + jobYAML("k", "0 7 * * *", "30s", false)
	e := newEnv(t, laTime(6, 0, 0), goodWindow, map[string]string{"aa": appYAML("aa", jobs)})
	e.run()
	if !strings.Contains(e.logs.String(), "schedule_state=absent") {
		t.Fatalf("a first start must log schedule_state=absent:\n%s", e.logs.String())
	}
	if len(e.runs()) != 0 || e.fc.count() != 0 {
		t.Fatal("a first start must not catch up anything")
	}
	b, err := os.ReadFile(filepath.Join(e.state, "schedule.tsv"))
	if err != nil || strings.Count(string(b), "\n") != 2 {
		t.Fatalf("schedule.tsv after first start = %q (%v)", b, err)
	}
	e.stop()
	e.fake.Advance(2 * time.Hour) // the runner is down across 07:00
	e.stopOnce = sync.Once{}
	e.run()
	if !strings.Contains(e.logs.String(), "schedule_state=present rows=2") {
		t.Fatalf("restart must read schedule.tsv:\n%s", e.logs.String())
	}
	rec := e.waitRun("aa", "j", "ok")
	if rec[cTrigger] != "catch_up" || rec[cScheduledFor] != utc(laTime(7, 0, 0).Add(fnvOffset("aa/j"))) {
		t.Fatalf("catch-up record = %q", rec)
	}
	missed := e.waitRun("aa", "k", "skipped_missed")
	if missed[cScheduledFor] != utc(laTime(7, 0, 0).Add(fnvOffset("aa/k"))) {
		t.Fatalf("missed record = %q", missed)
	}
	if e.fc.count() != 1 || e.fc.requests()[0].Job != "j" {
		t.Fatalf("calls = %+v", e.fc.requests())
	}
	e.adv(ReloadEvery)
	if got := len(e.runs()); got != 2 {
		t.Fatalf("%d records, want one per job", got)
	}
}

func TestMissedRunScanReadsPersistedLastFired(t *testing.T) {
	jobs := jobYAML("j", "0 7 * * *", "30s", true) + jobYAML("k", "0 7 * * *", "30s", false)
	e := newEnv(t, laTime(8, 0, 0), goodWindow, map[string]string{"aa": appYAML("aa", jobs)})
	if err := os.MkdirAll(e.state, 0o700); err != nil {
		t.Fatal(err)
	}
	prev := laTime(7, 0, 0).Add(-24 * time.Hour)
	rows := "aa\tj\t" + utc(prev.Add(fnvOffset("aa/j"))) + "\naa\tk\t" + utc(prev.Add(fnvOffset("aa/k"))) + "\n"
	if err := os.WriteFile(filepath.Join(e.state, "schedule.tsv"), []byte(rows), 0o600); err != nil {
		t.Fatal(err)
	}
	e.run()
	e.waitRun("aa", "j", "ok")
	e.waitRun("aa", "k", "skipped_missed")
}

func TestClockJumpOverTwoMinutesTriggersTheMissedScan(t *testing.T) {
	jobs := jobYAML("j", "0 7 * * *", "30s", true) + jobYAML("k", "0 7 * * *", "30s", false)
	e := newEnv(t, laTime(6, 0, 0), goodWindow, map[string]string{"aa": appYAML("aa", jobs)})
	e.run()
	e.fake.Jump(2 * time.Hour)
	e.adv(ReloadEvery)
	rec := e.waitRun("aa", "j", "ok")
	if rec[cTrigger] != "catch_up" {
		t.Fatalf("record = %q", rec)
	}
	e.waitRun("aa", "k", "skipped_missed")
	if !strings.Contains(e.logs.String(), "clock jump detected") {
		t.Fatalf("the jump was not logged:\n%s", e.logs.String())
	}
}

// A dense schedule after a long outage has more missed fires than one scan covers: the marker moves past the scanned
// range, so later scans do not regenerate the same skipped_missed record.
func TestCatchUpScanCapDoesNotRepeatSkippedMissed(t *testing.T) {
	e := newEnv(t, laTime(6, 0, 0), goodWindow, oneJob("* * * * *", "30s", false))
	e.run()
	e.stop()
	e.fake.Advance(5 * 24 * time.Hour) // 7200 missed fires, more than maxCatchUpScan
	e.stopOnce = sync.Once{}
	e.run()
	e.waitRun("aa", "j", "skipped_missed")
	if !strings.Contains(e.logs.String(), "scan_capped=") {
		t.Fatalf("the capped scan was not logged:\n%s", e.logs.String())
	}
	e.adv(2 * ReloadEvery)
	if got := e.runsWhere("aa", "j", "skipped_missed"); len(got) != 1 {
		t.Fatalf("%d skipped_missed records, want exactly one: %q", len(got), got)
	}
}

// A run cut off by the runner's own shutdown is `interrupted` and sends no alert.
func TestShutdownRecordsInterruptedWithoutAlert(t *testing.T) {
	e := newEnv(t, laTime(6, 59, 0), goodWindow, oneJob("0 7 * * *", "30s", false))
	e.fc.fn = func(ctx context.Context, r dispatch.Request) dispatch.Result {
		<-ctx.Done()
		return dispatch.Result{Class: dispatch.ClassRetryable, Err: "context canceled"}
	}
	e.run()
	e.advTo(laTime(7, 1, 0))
	waitFor(t, "the run to be in flight", func() bool { return e.fc.count() == 1 })
	e.stop()
	if got := e.runsWhere("aa", "j", "interrupted"); len(got) != 1 {
		t.Fatalf("interrupted records = %q", got)
	}
	if got := e.runsWhere("aa", "j", "failed"); len(got) != 0 {
		t.Fatalf("a shutdown must not record failed: %q", got)
	}
	if a, m := e.notif.runAlerts(), e.notif.messages(); len(a) != 0 || len(m) != 0 {
		t.Fatalf("a shutdown must not alert: alerts=%q messages=%q", a, m)
	}
}

func TestSmallClockStepIsNotAJump(t *testing.T) {
	e := newEnv(t, laTime(6, 59, 0), goodWindow, oneJob("0 7 * * *", "30s", false))
	e.run()
	// 06:59:00 + jump + the 30s step lands one second after the fire time, with a step well under 2 minutes
	e.fake.Jump(ReloadEvery + fnvOffset("aa/j") + time.Second)
	e.adv(ReloadEvery)
	rec := e.waitRun("aa", "j", "ok")
	if rec[cTrigger] != "schedule" {
		t.Fatalf("record = %q", rec)
	}
	if got := e.runsWhere("aa", "j", "skipped_missed"); len(got) != 0 || strings.Contains(e.logs.String(), "clock jump") {
		t.Fatal("a small step was treated as a jump")
	}
}

func TestRegistryReloadByContentHash(t *testing.T) {
	t.Run("added job starts and an unchanged registry is not reapplied", func(t *testing.T) {
		e := newEnv(t, laTime(6, 59, 0), goodWindow, oneJob("0 9 * * *", "30s", false))
		e.run()
		e.writeApp("bb", appYAML("bb", jobYAML("x", "0 7 * * *", "30s", false)))
		e.adv(ReloadEvery)
		waitFor(t, "bb/x in jobs.tsv", func() bool { return e.jobRow("bb", "x") != nil })
		reloads := strings.Count(e.logs.String(), "registry reload")
		e.adv(2 * ReloadEvery)
		if got := strings.Count(e.logs.String(), "registry reload"); got != reloads {
			t.Fatalf("an unchanged registry was reloaded again (%d -> %d)", reloads, got)
		}
		e.advTo(laTime(7, 1, 0))
		e.waitRun("bb", "x", "ok")
	})
	t.Run("changed schedule recomputes next_due", func(t *testing.T) {
		e := newEnv(t, laTime(6, 59, 0), goodWindow, oneJob("0 9 * * *", "30s", false))
		e.run()
		off := fnvOffset("aa/j")
		waitFor(t, "9:00 next_due", func() bool { r := e.jobRow("aa", "j"); return r != nil && r[7] == utc(laTime(9, 0, 0).Add(off)) })
		e.writeApp("aa", appYAML("aa", jobYAML("j", "0 8 * * *", "30s", false)))
		e.adv(ReloadEvery)
		waitFor(t, "8:00 next_due", func() bool {
			r := e.jobRow("aa", "j")
			return r != nil && r[7] == utc(laTime(8, 0, 0).Add(off)) && r[2] == "0 8 * * *"
		})
	})
	t.Run("removed app stops scheduling and its in-flight run finishes", func(t *testing.T) {
		e := newEnv(t, laTime(6, 59, 0), goodWindow, oneJob("0 7,8 * * *", "5m", false))
		gate := make(chan struct{})
		e.fc.fn = blockingCaller(gate)
		e.run()
		off := fnvOffset("aa/j")
		e.advTo(laTime(7, 0, 0).Add(off))
		waitFor(t, "run in flight", func() bool { return e.fc.count() == 1 })
		e.removeApp("aa")
		e.adv(ReloadEvery)
		waitFor(t, "row dropped", func() bool { return e.jobRow("aa", "j") == nil })
		waitFor(t, "schedule.tsv row dropped", func() bool {
			b, _ := os.ReadFile(filepath.Join(e.state, "schedule.tsv"))
			return !strings.Contains(string(b), "aa\tj\t")
		})
		close(gate)
		rec := e.waitRun("aa", "j", "ok") // the in-flight run still completes and is recorded
		if rec[cTrigger] != "schedule" {
			t.Fatalf("record = %q", rec)
		}
		e.advTo(laTime(8, 1, 0))
		if e.fc.count() != 1 {
			t.Fatalf("a removed job fired again: %d calls", e.fc.count())
		}
	})
	t.Run("invalid app is disabled, flagged and alerted once; fixing clears it", func(t *testing.T) {
		e := newEnv(t, laTime(6, 59, 0), goodWindow, oneJob("0 9 * * *", "30s", false))
		e.run()
		e.writeApp("bb", "schema_version: 1\nname: b\nbogus: yes\n")
		e.adv(ReloadEvery)
		waitFor(t, "config_state invalid", func() bool { r := e.runner(); return len(r) == 6 && r[3] == "invalid" })
		e.waitJobState("bb", "-", "disabled_invalid_config")
		if m := e.notif.messages(); len(m) != 1 || !strings.Contains(m[0], "app bb is disabled") {
			t.Fatalf("alerts = %q", m)
		}
		e.adv(2 * ReloadEvery)
		if m := e.notif.messages(); len(m) != 1 {
			t.Fatalf("alert repeated: %q", m)
		}
		e.writeApp("bb", appYAML("bb"))
		e.adv(ReloadEvery)
		waitFor(t, "config_state ok", func() bool { r := e.runner(); return len(r) == 6 && r[3] == "ok" })
		waitFor(t, "placeholder row gone", func() bool { return e.jobRow("bb", "-") == nil })
	})
	t.Run("removing the invalid app clears config_state", func(t *testing.T) {
		e := newEnv(t, laTime(6, 59, 0), goodWindow, map[string]string{"bb": "not: valid\n"})
		e.run()
		waitFor(t, "config_state invalid", func() bool { r := e.runner(); return len(r) == 6 && r[3] == "invalid" })
		e.removeApp("bb")
		e.adv(ReloadEvery)
		waitFor(t, "config_state ok", func() bool { r := e.runner(); return len(r) == 6 && r[3] == "ok" })
	})
}

const testSecret = "testsecretvalue"

func realDispatcher(e *env, srv *httptest.Server, secrets string) {
	d := dispatch.New(e.fake, secrets, "test")
	d.URL = func(app string, port int, job string) string { return srv.URL + "/_jobs/" + job }
	e.caller = d
}

func writeSecret(t *testing.T, dir, app, secret string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(dir, app), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, app, "jobs-secret"), []byte(secret+"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
}

func assertNoSecretAnywhere(t *testing.T, e *env) {
	t.Helper()
	if strings.Contains(e.logs.String(), testSecret) {
		t.Errorf("the secret is in the log:\n%s", e.logs.String())
	}
	for _, m := range e.notif.messages() {
		if strings.Contains(m, testSecret) {
			t.Errorf("the secret is in an alert: %q", m)
		}
	}
	files, _ := filepath.Glob(filepath.Join(e.hist, "*"))
	state, _ := filepath.Glob(filepath.Join(e.state, "*"))
	for _, f := range append(files, state...) {
		if b, err := os.ReadFile(f); err == nil && strings.Contains(string(b), testSecret) {
			t.Errorf("the secret is in %s", f)
		}
	}
}

func TestMissingSecretSkipsDisablesAndAlertsOncePerChange(t *testing.T) {
	var hits atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits.Add(1) }))
	defer srv.Close()
	secrets := t.TempDir()
	// The timeout is long on purpose: the job's deadline runs on the fake clock but the request is real I/O, and the
	// test advances the fake clock another 30s step right after the fire. A 30s deadline could expire before the
	// response arrived on a loaded host and turn the "ok" record into a timeout.
	e := newEnv(t, laTime(6, 59, 0), goodWindow, oneJob("* * * * *", "10m", false))
	realDispatcher(e, srv, secrets)
	e.run()
	e.advTo(laTime(7, 3, 0))
	waitFor(t, "skipped_no_secret records", func() bool { return len(e.runsWhere("aa", "j", "skipped_no_secret")) >= 2 })
	e.waitJobState("aa", "j", "disabled_no_secret")
	if hits.Load() != 0 {
		t.Fatal("a request was made without a secret")
	}
	if m := e.notif.messages(); len(m) != 1 || !strings.Contains(m[0], "aa/j") {
		t.Fatalf("alerts = %q, want exactly one for several fires", m)
	}
	writeSecret(t, secrets, "aa", testSecret)
	e.advTo(laTime(7, 5, 0))
	e.waitRun("aa", "j", "ok")
	e.waitJobState("aa", "j", "ok")
	if m := e.notif.messages(); len(m) != 2 {
		t.Fatalf("alerts = %q, want a recovery notice", m)
	}
	assertNoSecretAnywhere(t, e)
}

func TestRealDispatcherOutcomesAreRecordedWithoutLeakingTheSecret(t *testing.T) {
	var redirHits, afterRedirect atomic.Int32
	slowStarted := make(chan struct{})
	var slowOnce sync.Once
	mux := http.NewServeMux()
	mux.HandleFunc("/_jobs/auth", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "denied for "+r.Header.Get("Authorization"), http.StatusUnauthorized)
	})
	for path, code := range map[string]int{"/_jobs/redir": http.StatusMovedPermanently, "/_jobs/redir302": http.StatusFound, "/_jobs/redir307": http.StatusTemporaryRedirect} {
		code := code
		mux.HandleFunc(path, func(w http.ResponseWriter, r *http.Request) {
			redirHits.Add(1)
			http.Redirect(w, r, "/followed", code)
		})
	}
	mux.HandleFunc("/followed", func(w http.ResponseWriter, r *http.Request) { afterRedirect.Add(1) })
	mux.HandleFunc("/_jobs/slow", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		slowOnce.Do(func() { close(slowStarted) })
		select {
		case <-r.Context().Done():
		case <-time.After(10 * time.Second):
		}
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	secrets := t.TempDir()
	writeSecret(t, secrets, "aa", testSecret)
	// The timeout is long on purpose: the fake clock is advanced past every fire offset (up to 59s) before the
	// requests are necessarily sent, so a short deadline could expire before a request reached its handler and
	// turn the 401/3xx records into timeouts (or leave /_jobs/slow never entered). The slow job's deadline is
	// crossed explicitly below, once its handler is running.
	jobs := jobYAML("auth", "0 7 * * *", "10m", false) + jobYAML("redir", "0 7 * * *", "10m", false) +
		jobYAML("redir302", "0 7 * * *", "10m", false) + jobYAML("redir307", "0 7 * * *", "10m", false) +
		jobYAML("slow", "0 7 * * *", "10m", false)
	e := newEnv(t, laTime(6, 59, 0), goodWindow, map[string]string{"aa": appYAML("aa", jobs)})
	realDispatcher(e, srv, secrets)
	e.run()
	e.advTo(laTime(7, 1, 0))

	auth := e.waitRun("aa", "auth", "failed")
	if auth[cHTTP] != "401" || !strings.Contains(auth[cError], "denied for Bearer ***") {
		t.Fatalf("401 record = %q", auth)
	}
	for job, status := range map[string]string{"redir": "301", "redir302": "302", "redir307": "307"} {
		redir := e.waitRun("aa", job, "failed")
		if redir[cHTTP] != status {
			t.Fatalf("%s record = %q", status, redir)
		}
	}
	if redirHits.Load() != 3 || afterRedirect.Load() != 0 {
		t.Fatalf("a redirect was followed (%d, %d)", redirHits.Load(), afterRedirect.Load())
	}
	// The dispatcher arms its fake-clock deadline before it sends the request, so once the handler is running the
	// timer exists and this advance cannot pass it by.
	select {
	case <-slowStarted:
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for the /_jobs/slow handler to start")
	}
	waitFor(t, "the dispatcher deadline armed", func() bool { return e.fake.Pending() >= 2 })
	e.adv(11 * time.Minute)
	slow := e.waitRun("aa", "slow", "timeout")
	if slow[cHTTP] != "-" || !strings.HasPrefix(slow[cError], "timeout after 10m") {
		t.Fatalf("timeout record = %q", slow)
	}
	assertNoSecretAnywhere(t, e)
}

func TestHeartbeatAdvancesWhileRedisIsDownAndTheWindowIsInvalid(t *testing.T) {
	e := newEnv(t, laTime(6, 58, 0), "garbage\n", oneJob("0 9 * * *", "30s", false))
	e.run()
	e.status.SetRedis("down")
	waitFor(t, "state written", func() bool { r := e.runner(); return len(r) == 6 && r[2] == "invalid" && r[4] == "down" })
	for i := 1; i <= 4; i++ {
		e.fake.Advance(history.HeartbeatEvery)
		want := utc(e.start.Add(time.Duration(i) * history.HeartbeatEvery))
		waitFor(t, "heartbeat "+want, func() bool { r := e.runner(); return len(r) == 6 && r[1] == want })
	}
}
