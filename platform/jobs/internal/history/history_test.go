package history

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
)

var t0 = time.Date(2026, 3, 4, 15, 0, 7, 0, time.UTC)

func sampleRun() Run {
	return Run{
		RunID: "01HZZZZZZZZZZZZZZZZZZZZZZZ", App: "a", Job: "j", Trigger: "schedule",
		ScheduledFor: t0, Started: t0.Add(time.Second), Ended: t0.Add(3 * time.Second),
		HTTPStatus: 500, Result: "failed", Attempt: 1, Err: "boom",
	}
}

func TestRunLineParsesBackToDocumentedColumns(t *testing.T) {
	cols := strings.Split(strings.TrimSuffix(FormatRun(sampleRun()), "\n"), "\t")
	want := []string{"01HZZZZZZZZZZZZZZZZZZZZZZZ", "a", "j", "schedule", "2026-03-04T15:00:07Z", "2026-03-04T15:00:08Z",
		"2026-03-04T15:00:10Z", "2000", "failed", "500", "1", "boom"}
	if len(cols) != len(want) {
		t.Fatalf("columns = %d: %q", len(cols), cols)
	}
	for i := range want {
		if cols[i] != want[i] {
			t.Errorf("column %d = %q, want %q", i, cols[i], want[i])
		}
	}
}

func TestEmptyFieldsPrintDash(t *testing.T) {
	r := sampleRun()
	r.ScheduledFor, r.HTTPStatus, r.Err = time.Time{}, 0, ""
	cols := strings.Split(strings.TrimSuffix(FormatRun(r), "\n"), "\t")
	if cols[4] != "-" || cols[9] != "-" || cols[11] != "-" {
		t.Fatalf("columns = %q", cols)
	}
}

func TestLongErrorWithTabsAndNewlinesIsOneShortLine(t *testing.T) {
	r := sampleRun()
	r.Err = strings.Repeat("ab\tcd\nef", 100)
	line := FormatRun(r)
	if strings.Count(line, "\n") != 1 || !strings.HasSuffix(line, "\n") {
		t.Fatalf("not a single line: %q", line)
	}
	cols := strings.Split(strings.TrimSuffix(line, "\n"), "\t")
	if len(cols) != 12 {
		t.Fatalf("tabs in the error leaked into columns: %d", len(cols))
	}
	if len([]rune(cols[11])) != 300 || strings.ContainsAny(cols[11], "\t\n") {
		t.Fatalf("error column = %d runes %q", len([]rune(cols[11])), cols[11][:20])
	}
	if len(line) >= 4096 {
		t.Fatalf("line is %d bytes", len(line))
	}
	// four-byte characters: 300 runes is 1200 bytes, still well under 4 KiB
	r.Err = strings.Repeat("\U0001F600", 500)
	if l := FormatRun(r); len(l) >= 4096 {
		t.Fatalf("line is %d bytes", len(l))
	}
}

func TestAppendRunWritesPerUTCDateAndConcurrentAppendsStayWhole(t *testing.T) {
	dir := t.TempDir()
	w, err := NewWriter(dir)
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			r := sampleRun()
			r.RunID = fmt.Sprintf("run%02d", i)
			if err := w.AppendRun(r); err != nil {
				t.Error(err)
			}
		}(i)
	}
	wg.Wait()
	next := sampleRun()
	next.Ended = time.Date(2026, 3, 5, 0, 0, 1, 0, time.UTC)
	next.Started = next.Ended
	if err := w.AppendRun(next); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "runs-2026-03-04.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
	if len(lines) != 20 {
		t.Fatalf("lines = %d", len(lines))
	}
	for _, l := range lines {
		if len(strings.Split(l, "\t")) != 12 {
			t.Fatalf("torn line %q", l)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "runs-2026-03-05.tsv")); err != nil {
		t.Fatal("the next UTC day must go to its own file")
	}
}

func TestPruneKeepsNewest30RunFiles(t *testing.T) {
	dir := t.TempDir()
	for i := 1; i <= 40; i++ {
		name := fmt.Sprintf("runs-2026-01-%02d.tsv", i)
		if i > 31 {
			name = fmt.Sprintf("runs-2026-02-%02d.tsv", i-31)
		}
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	other := []string{"jobs.tsv", "runner.tsv", "notes.txt"}
	for _, n := range other {
		if err := os.WriteFile(filepath.Join(dir, n), []byte("x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	w, err := NewWriter(dir)
	if err != nil {
		t.Fatal(err)
	}
	r := sampleRun()
	r.Ended = time.Date(2026, 3, 1, 1, 0, 0, 0, time.UTC)
	r.Started = r.Ended
	if err := w.AppendRun(r); err != nil {
		t.Fatal(err)
	}
	des, _ := os.ReadDir(dir)
	var runs []string
	for _, de := range des {
		if strings.HasPrefix(de.Name(), "runs-") {
			runs = append(runs, de.Name())
		}
	}
	sort.Strings(runs)
	if len(runs) != KeepRunFiles {
		t.Fatalf("kept %d run files", len(runs))
	}
	if runs[len(runs)-1] != "runs-2026-03-01.tsv" || runs[0] != "runs-2026-01-12.tsv" {
		t.Fatalf("kept the wrong files: first %s last %s", runs[0], runs[len(runs)-1])
	}
	for _, n := range other {
		if _, err := os.Stat(filepath.Join(dir, n)); err != nil {
			t.Fatalf("prune removed %s", n)
		}
	}
}

func countRunFiles(t *testing.T, dir string) []string {
	t.Helper()
	des, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var runs []string
	for _, de := range des {
		if strings.HasPrefix(de.Name(), "runs-") {
			runs = append(runs, de.Name())
		}
	}
	sort.Strings(runs)
	return runs
}

func runEndingOn(day time.Time) Run {
	r := sampleRun()
	r.Ended, r.Started = day, day
	return r
}

func TestPruneRunsAgainWhenTheDateRollsOver(t *testing.T) {
	dir := t.TempDir()
	for i := 1; i <= 29; i++ {
		if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf("runs-2026-01-%02d.tsv", i)), []byte("x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	w, err := NewWriter(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := w.AppendRun(runEndingOn(time.Date(2026, 3, 1, 1, 0, 0, 0, time.UTC))); err != nil {
		t.Fatal(err)
	}
	if got := countRunFiles(t, dir); len(got) != KeepRunFiles {
		t.Fatalf("after the first write: %d files", len(got))
	}
	// A later date makes it 31 files: the rollover must prune again and drop the oldest.
	if err := w.AppendRun(runEndingOn(time.Date(2026, 3, 2, 1, 0, 0, 0, time.UTC))); err != nil {
		t.Fatal(err)
	}
	got := countRunFiles(t, dir)
	if len(got) != KeepRunFiles || got[0] != "runs-2026-01-02.tsv" || got[len(got)-1] != "runs-2026-03-02.tsv" {
		t.Fatalf("after the rollover: %d files, first %s last %s", len(got), got[0], got[len(got)-1])
	}
	if err := w.AppendRun(runEndingOn(time.Date(2026, 3, 2, 2, 0, 0, 0, time.UTC))); err != nil {
		t.Fatal(err)
	}
	if got := countRunFiles(t, dir); len(got) != KeepRunFiles {
		t.Fatalf("a second write on the same day changed the file count: %d", len(got))
	}
}

func TestWorstCaseLineStaysUnder4KiBWithTwelveColumns(t *testing.T) {
	r := sampleRun()
	r.RunID = strings.Repeat("R", 26)
	r.App, r.Job = strings.Repeat("a", 63), strings.Repeat("j", 63)
	r.Err = strings.Repeat("\U0001F600", 300)
	r.HTTPStatus, r.Attempt = 599, 99
	line := FormatRun(r)
	if len(line) >= maxLineBytes {
		t.Fatalf("line is %d bytes", len(line))
	}
	cols := strings.Split(strings.TrimSuffix(line, "\n"), "\t")
	if len(cols) != 12 || len([]rune(cols[11])) != 300 {
		t.Fatalf("%d columns, error column %d runes", len(cols), len([]rune(cols[11])))
	}
}

func TestOversizedNamesAreCappedAndTheLineStaysUnder4KiB(t *testing.T) {
	r := sampleRun()
	r.App, r.Job = strings.Repeat("\U0001F600", 5000), strings.Repeat("j", 9000)
	r.Err = strings.Repeat("e", 300)
	line := FormatRun(r)
	if len(line) >= maxLineBytes || !strings.HasSuffix(line, "\n") {
		t.Fatalf("line is %d bytes", len(line))
	}
	cols := strings.Split(strings.TrimSuffix(line, "\n"), "\t")
	if len(cols) != 12 || len([]rune(cols[1])) != maxNameChars || len([]rune(cols[2])) != maxNameChars {
		t.Fatalf("%d columns, app %d runes, job %d runes", len(cols), len([]rune(cols[1])), len([]rune(cols[2])))
	}
}

func TestAppendRunIsASingleWrite(t *testing.T) {
	w, err := NewWriter(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	var sizes []int
	real := w.appendWrite
	w.appendWrite = func(f *os.File, line string) (int, error) {
		calls++
		sizes = append(sizes, len(line))
		return real(f, line)
	}
	r := sampleRun()
	r.Err = strings.Repeat("\U0001F600", 300)
	for i := 1; i <= 3; i++ {
		if err := w.AppendRun(r); err != nil {
			t.Fatal(err)
		}
		if calls != i {
			t.Fatalf("after %d appends there were %d write calls", i, calls)
		}
	}
	if sizes[0] != len(FormatRun(r)) {
		t.Fatalf("the write was %d bytes, the line is %d", sizes[0], len(FormatRun(r)))
	}
}

func TestShortWriteIsReportedWithoutANilVerb(t *testing.T) {
	w, err := NewWriter(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	w.appendWrite = func(f *os.File, line string) (int, error) { return 3, nil }
	err = w.AppendRun(sampleRun())
	if err == nil || !strings.Contains(err.Error(), "short write") || strings.Contains(err.Error(), "%!") {
		t.Fatalf("error = %v", err)
	}
}

func TestWriteJobsSortedAndParsesBack(t *testing.T) {
	dir := t.TempDir()
	w, _ := NewWriter(dir)
	rows := []JobRow{
		{App: "b", Job: "z", State: "ok"},
		{App: "a", Job: "y", Schedule: "0 7 * * *", CatchUp: true, LastResult: "ok", LastStarted: t0, LastEnded: t0.Add(time.Second), NextDue: t0.Add(24 * time.Hour), State: "window_refused"},
		{App: "a", Job: "x", State: "ok"},
	}
	if err := w.WriteJobs(rows); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(dir, "jobs.tsv"))
	lines := strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
	if len(lines) != 3 {
		t.Fatalf("lines = %q", lines)
	}
	if !strings.HasPrefix(lines[0], "a\tx\t") || !strings.HasPrefix(lines[1], "a\ty\t") || !strings.HasPrefix(lines[2], "b\tz\t") {
		t.Fatalf("not sorted by app then job: %q", lines)
	}
	want := "a\ty\t0 7 * * *\ttrue\tok\t2026-03-04T15:00:07Z\t2026-03-04T15:00:08Z\t2026-03-05T15:00:07Z\twindow_refused"
	if lines[1] != want {
		t.Fatalf("row = %q\nwant  %q", lines[1], want)
	}
	if len(strings.Split(lines[0], "\t")) != 9 {
		t.Fatalf("row 0 has %d columns", len(strings.Split(lines[0], "\t")))
	}
}

func TestJobsTSVNeverTornUnderConcurrentReads(t *testing.T) {
	dir := t.TempDir()
	w, _ := NewWriter(dir)
	big := func(n int) []JobRow {
		var rows []JobRow
		for i := 0; i < n; i++ {
			rows = append(rows, JobRow{App: "a", Job: fmt.Sprintf("job%03d", i), State: "ok", LastResult: "ok"})
		}
		return rows
	}
	if err := w.WriteJobs(big(200)); err != nil {
		t.Fatal(err)
	}
	stop := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			n := 10
			if i%2 == 0 {
				n = 200
			}
			if err := w.WriteJobs(big(n)); err != nil {
				t.Error(err)
				return
			}
		}
	}()
	for i := 0; i < 300; i++ {
		b, err := os.ReadFile(filepath.Join(dir, "jobs.tsv"))
		if err != nil {
			t.Fatal(err)
		}
		lines := strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
		if len(lines) != 10 && len(lines) != 200 {
			t.Fatalf("torn jobs.tsv with %d lines", len(lines))
		}
	}
	close(stop)
	wg.Wait()
}

func readStatus(t *testing.T, path string) []string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(b), "\n") != 1 {
		t.Fatalf("runner.tsv is not exactly one line: %q", b)
	}
	cols := strings.Split(strings.TrimSuffix(string(b), "\n"), "\t")
	if len(cols) != 6 {
		t.Fatalf("runner.tsv columns = %q", cols)
	}
	return cols
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestStatusHeartbeatAdvancesEvery15sRegardlessOfState(t *testing.T) {
	fake := clock.NewFake(t0)
	path := filepath.Join(t.TempDir(), "runner.tsv")
	st := NewStatus(fake, path, "v1", nil)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { st.Run(ctx); close(done) }()
	<-st.Ready()
	defer func() { cancel(); <-done }()

	first := readStatus(t, path)
	if first[0] != "2026-03-04T15:00:07Z" || first[1] != first[0] || first[2] != "ok" || first[3] != "ok" || first[4] != "ok" || first[5] != "v1" {
		t.Fatalf("first line = %q", first)
	}
	st.SetRedis("down")
	st.SetWindow("invalid")
	waitFor(t, "state change written", func() bool { c := readStatus(t, path); return c[2] == "invalid" && c[4] == "down" })

	last := first[1]
	for i := 1; i <= 3; i++ {
		fake.Advance(HeartbeatEvery)
		want := t0.Add(time.Duration(i) * HeartbeatEvery).UTC().Format(time.RFC3339)
		waitFor(t, "heartbeat "+want, func() bool { return readStatus(t, path)[1] == want })
		if want == last {
			t.Fatal("heartbeat did not advance")
		}
		last = want
	}
	if c := readStatus(t, path); c[0] != first[0] || c[2] != "invalid" || c[4] != "down" {
		t.Fatalf("heartbeat lost state: %q", c)
	}
}

func TestStatusUnknownValuesFailClosed(t *testing.T) {
	st := NewStatus(clock.NewFake(t0), filepath.Join(t.TempDir(), "runner.tsv"), "v1", nil)
	st.SetWindow("fine")
	st.SetConfig("")
	st.SetRedis("weird")
	sn := st.Snapshot()
	if sn.Window != "invalid" || sn.Config != "invalid" || sn.Redis != "invalid" {
		t.Fatalf("snapshot = %+v", sn)
	}
}

func TestStatusConcurrentUpdatesLoseNoField(t *testing.T) {
	fake := clock.NewFake(t0)
	path := filepath.Join(t.TempDir(), "runner.tsv")
	st := NewStatus(fake, path, "v1", nil)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { st.Run(ctx); close(done) }()
	<-st.Ready()
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(3)
		go func(i int) { defer wg.Done(); st.SetWindow([]string{"ok", "invalid"}[i%2]) }(i)
		go func(i int) { defer wg.Done(); st.SetConfig([]string{"ok", "invalid"}[i%2]) }(i)
		go func(i int) { defer wg.Done(); st.SetRedis([]string{"ok", "down", "invalid"}[i%3]) }(i)
	}
	// A reader never sees a partial line while the writer runs.
	stop := make(chan struct{})
	var rd sync.WaitGroup
	rd.Add(1)
	go func() {
		defer rd.Done()
		for {
			select {
			case <-stop:
				return
			default:
			}
			readStatus(t, path)
		}
	}()
	wg.Wait()
	close(stop)
	rd.Wait()
	st.SetWindow("invalid")
	st.SetConfig("invalid")
	st.SetRedis("down")
	waitFor(t, "final state", func() bool {
		c := readStatus(t, path)
		return c[2] == "invalid" && c[3] == "invalid" && c[4] == "down" && c[0] == "2026-03-04T15:00:07Z" && c[5] == "v1"
	})
	cancel()
	<-done
}
