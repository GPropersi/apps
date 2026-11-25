package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"github.com/gpropersi/apps/apps/birthdays/internal/app/db"
	"github.com/gpropersi/apps/apps/birthdays/internal/platform"
)

func laClock(t *testing.T, y int, m time.Month, d, h int) func() time.Time {
	t.Helper()
	zone, err := platform.ScheduleZone()
	if err != nil {
		t.Fatal(err)
	}
	return fixedClock(time.Date(y, m, d, h, 0, 0, 0, zone))
}

func newJobs(store *fakeStore) *Jobs {
	return &Jobs{Store: store, Tx: store, Queue: &fakeQueue{}, Notifs: &fakeSender{},
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
}

func TestDeclaredJobsMatchTheHandlers(t *testing.T) {
	declared, err := platform.DeclaredJobs(appYAMLForTest)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(declared, ","); got != "reminder-scan,send-reminder" {
		t.Fatalf("declared jobs = %q, want reminder-scan,send-reminder", got)
	}
	if err := platform.VerifyJobs(declared, newJobs(newFakeStore()).Funcs()); err != nil {
		t.Fatal(err)
	}
}

func TestAppYAMLDeclaresTheReminderContract(t *testing.T) {
	y := string(appYAMLForTest)
	for _, want := range []string{
		"notifs: true", "memory_cap: 64m",
		"name: reminder-scan", `schedule: "0 7 * * *"`, "timeout: 55s", "catch_up: true",
		"name: send-reminder", "timeout: 45s",
	} {
		if !strings.Contains(y, want) {
			t.Errorf("app.yaml lacks %q", want)
		}
	}
}

func TestJobsHandlerAuthAndSuccess(t *testing.T) {
	j := newJobs(newFakeStore())
	h, err := platform.JobsHandler([]byte("s3cret"), j.Funcs())
	if err != nil {
		t.Fatal(err)
	}
	for _, job := range []string{"reminder-scan", "send-reminder"} {
		body := `{"v":1,"run_id":"R1","job":"` + job + `","trigger":"queue","attempt":1,"queue_id":"01Z","payload":{}}`
		post := func(auth string) int {
			r := httptest.NewRequest(http.MethodPost, "/_jobs/"+job, strings.NewReader(body))
			if auth != "" {
				r.Header.Set("Authorization", auth)
			}
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, r)
			return rec.Code
		}
		if code := post(""); code != 401 {
			t.Fatalf("%s: no bearer = %d, want 401", job, code)
		}
		// An empty scan and an unreadable send payload (dropped: a retry cannot fix it) both answer 200.
		if code := post("Bearer s3cret"); code != 200 {
			t.Fatalf("%s: with the bearer = %d, want 200", job, code)
		}
	}
}

// ---------------------------------------------------------------- scan

type scanFx struct {
	store *fakeStore
	q     *fakeQueue
	n     *fakeSender
	j     *Jobs
}

func newScanFx(t *testing.T, y int, m time.Month, d, h int) *scanFx {
	t.Helper()
	store := newFakeStore()
	store.users["sam@example.test"] = db.User{ID: 1, Email: "sam@example.test"}
	f := &scanFx{store: store, q: &fakeQueue{}, n: &fakeSender{}}
	f.j = newJobs(store)
	f.j.Queue, f.j.Notifs, f.j.Now = f.q, f.n, laClock(t, y, m, d, h)
	return f
}

func (f *scanFx) add(month, day int16, offsets ...int16) int64 {
	id := int64(len(f.store.birthdays) + 1)
	f.store.birthdays = append(f.store.birthdays, fBirthday{ID: id, OwnerID: 1, Name: fmt.Sprintf("B%d", id), Month: month, Day: day})
	f.store.reminders = append(f.store.reminders, fReminder{BirthdayID: id, UserID: 1, Offsets: offsets})
	return id
}

func (f *scanFx) scan(t *testing.T) {
	t.Helper()
	if err := f.j.ReminderScan(context.Background(), platform.JobRequest{}); err != nil {
		t.Fatal(err)
	}
}

func (f *scanFx) keys() []string {
	var out []string
	for _, c := range f.q.calls {
		out = append(out, c.key)
	}
	return out
}

func TestScanDueDates(t *testing.T) {
	// Today in LA is 2026-11-20.
	cases := []struct {
		name          string
		month, day    int16
		offsets       []int16
		want          []string
		y             int
		mo            time.Month
		d, h          int
		prepareSentAs *fSent
	}{
		{name: "offset 0 on the day", month: 11, day: 20, offsets: []int16{0}, want: []string{"rem-1-1-2026-11-20-0"}},
		{name: "offset 1, the day before", month: 11, day: 21, offsets: []int16{1}, want: []string{"rem-1-1-2026-11-21-1"}},
		{name: "offset 7, a week before", month: 11, day: 27, offsets: []int16{7}, want: []string{"rem-1-1-2026-11-27-7"}},
		{name: "only the due offsets of several", month: 11, day: 21, offsets: []int16{7, 1, 0}, want: []string{"rem-1-1-2026-11-21-1"}},
		{name: "duplicate offsets are deduped", month: 11, day: 21, offsets: []int16{1, 1}, want: []string{"rem-1-1-2026-11-21-1"}},
		{name: "not yet due", month: 11, day: 29, offsets: []int16{7}, want: nil},
		{name: "missed by 2 days is still sent", month: 11, day: 25, offsets: []int16{7}, want: []string{"rem-1-1-2026-11-25-7"}},
		{name: "missed by 3 days is not", month: 11, day: 24, offsets: []int16{7}, want: nil},
		{name: "offset 0 with the occurrence before today waits for next year", month: 11, day: 19, offsets: []int16{0}, want: nil},
		{name: "offset 1 whose occurrence is already past", month: 11, day: 19, offsets: []int16{1}, want: nil},
		{name: "year rollover", month: 1, day: 2, offsets: []int16{7}, want: []string{"rem-1-1-2027-01-02-7"}, y: 2026, mo: 12, d: 26, h: 7},
		{name: "Feb 29 in a common year reminds for Feb 28", month: 2, day: 29, offsets: []int16{1}, want: []string{"rem-1-1-2027-02-28-1"}, y: 2027, mo: 2, d: 27, h: 7},
		{name: "Feb 29 in a leap year", month: 2, day: 29, offsets: []int16{1}, want: []string{"rem-1-1-2028-02-29-1"}, y: 2028, mo: 2, d: 28, h: 7},
		{name: "offset 14 due on its day", month: 12, day: 4, offsets: []int16{14}, want: []string{"rem-1-1-2026-12-04-14"}},
		{name: "offset 14 sent 2 days late", month: 12, day: 2, offsets: []int16{14}, want: []string{"rem-1-1-2026-12-02-14"}},
		{name: "offset 14 not sent 3 days late", month: 12, day: 1, offsets: []int16{14}, want: nil},
		{name: "offset 364 crosses the year boundary", month: 11, day: 19, offsets: []int16{364}, want: []string{"rem-1-1-2027-11-19-364"}},
		{name: "offset 14 on a birthday 10 days away was missed this year", month: 11, day: 30, offsets: []int16{14}, want: nil},
		{name: "Feb 29 with offset 14 in a common year", month: 2, day: 29, offsets: []int16{14}, want: []string{"rem-1-1-2027-02-28-14"}, y: 2027, mo: 2, d: 14, h: 7},
		{name: "already sent is skipped", month: 11, day: 21, offsets: []int16{1}, want: nil,
			prepareSentAs: &fSent{BirthdayID: 1, UserID: 1, Occurrence: Date{2026, 11, 21}, OffsetDays: 1, Outcome: "failed"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			y, mo, d, h := tc.y, tc.mo, tc.d, tc.h
			if y == 0 {
				y, mo, d, h = 2026, 11, 20, 7
			}
			f := newScanFx(t, y, mo, d, h)
			f.add(tc.month, tc.day, tc.offsets...)
			if tc.prepareSentAs != nil {
				f.store.remSent = append(f.store.remSent, *tc.prepareSentAs)
			}
			f.scan(t)
			if got := strings.Join(f.keys(), ","); got != strings.Join(tc.want, ",") {
				t.Fatalf("queued %q, want %q", got, strings.Join(tc.want, ","))
			}
		})
	}
}

func TestScanUsesTheLosAngelesDate(t *testing.T) {
	// 2026-11-21 02:00 UTC is still 2026-11-20 in Los Angeles.
	f := newScanFx(t, 2026, 11, 20, 18)
	f.j.Now = fixedClock(time.Date(2026, 11, 21, 2, 0, 0, 0, time.UTC))
	f.add(11, 21, 1) // due: tomorrow in LA
	f.add(11, 22, 1) // not due: that would be the UTC reading
	f.scan(t)
	if got := strings.Join(f.keys(), ","); got != "rem-1-1-2026-11-21-1" {
		t.Fatalf("queued %q", got)
	}
}

func TestScanPayloadIsIdsOnly(t *testing.T) {
	f := newScanFx(t, 2026, 11, 20, 7)
	f.add(11, 21, 1)
	f.scan(t)
	raw, _ := json.Marshal(f.q.calls[0].payload)
	if string(raw) != `{"birthday_id":1,"user_id":1,"occurrence":"2026-11-21","offset_days":1}` {
		t.Fatalf("payload = %s", raw)
	}
}

func TestScanTwiceQueuesOnce(t *testing.T) {
	f := newScanFx(t, 2026, 11, 20, 7)
	f.add(11, 21, 1)
	f.scan(t)
	f.scan(t)
	if len(f.q.calls) != 1 {
		t.Fatalf("queued %d, want 1 (the duplicate key is a no-op)", len(f.q.calls))
	}
}

func TestScanStopsAtTheEnqueueCap(t *testing.T) {
	f := newScanFx(t, 2026, 11, 20, 7)
	for i := 0; i < 905; i++ {
		f.add(11, 21, 1)
	}
	f.scan(t)
	if len(f.q.calls) != 900 {
		t.Fatalf("queued %d, want the cap 900", len(f.q.calls))
	}
}

func TestScanQueueFullStopsCleanly(t *testing.T) {
	f := newScanFx(t, 2026, 11, 20, 7)
	var logs strings.Builder
	f.j.Logger = slog.New(slog.NewTextHandler(&logs, nil))
	f.add(11, 21, 1)
	f.add(11, 21, 1)
	f.add(11, 21, 1)
	f.q.fullAfter = 1
	f.scan(t) // returns nil; the next scan re-finds the rest
	if len(f.q.calls) != 1 {
		t.Fatalf("queued %d, want 1: the scan must stop at the first ErrQueueFull", len(f.q.calls))
	}
	if !strings.Contains(logs.String(), "queue full") || !strings.Contains(logs.String(), "remaining=2") {
		t.Fatalf("the remainder was not logged: %s", logs.String())
	}
}

func TestScanQueueErrorIsReturned(t *testing.T) {
	f := newScanFx(t, 2026, 11, 20, 7)
	f.add(11, 21, 1)
	f.q.err = errBoom
	if err := f.j.ReminderScan(context.Background(), platform.JobRequest{}); !errors.Is(err, errBoom) {
		t.Fatalf("err = %v, want the queue error", err)
	}
}

func TestScanUnconfiguredNotifsQueuesNothing(t *testing.T) {
	f := newScanFx(t, 2026, 11, 20, 7)
	f.add(11, 21, 1)
	f.n.configErr = platform.ErrNotifsUnconfigured
	if err := f.j.ReminderScan(context.Background(), platform.JobRequest{}); !errors.Is(err, platform.ErrNotifsUnconfigured) {
		t.Fatalf("err = %v, want ErrNotifsUnconfigured", err)
	}
	if len(f.q.calls) != 0 {
		t.Fatal("an unconfigured scan must queue nothing")
	}
	f.j.Notifs = nil
	if err := f.j.ReminderScan(context.Background(), platform.JobRequest{}); !errors.Is(err, platform.ErrNotifsUnconfigured) {
		t.Fatalf("nil notifs: err = %v", err)
	}
}

// ---------------------------------------------------------------- send

type sendFx struct {
	t     *testing.T
	store *fakeStore
	n     *fakeSender
	j     *Jobs
	p     reminderPayload
	qid   string
}

// newSendFx: Sam (id 1, ntfy set up) owns birthday 1 on Nov 21 1995, reminders at offset 1; today is 2026-11-20.
func newSendFx(t *testing.T) *sendFx {
	t.Helper()
	store := newFakeStore()
	store.users["sam@example.test"] = db.User{ID: 1, Email: "sam@example.test", NtfyUserID: pgtype.Text{String: "nu1", Valid: true}}
	store.birthdays = []fBirthday{{ID: 1, OwnerID: 1, Name: "Sam Rivera", Month: 11, Day: 21, Year: pgtype.Int2{Int16: 1995, Valid: true}}}
	store.reminders = []fReminder{{BirthdayID: 1, UserID: 1, Offsets: []int16{1}}}
	f := &sendFx{t: t, store: store, n: &fakeSender{}, qid: "01QUEUE000000000000000001",
		p: reminderPayload{BirthdayID: 1, UserID: 1, Occurrence: "2026-11-21", OffsetDays: 1}}
	f.j = newJobs(store)
	f.j.Notifs, f.j.Now = f.n, laClock(t, 2026, 11, 20, 8)
	return f
}

func (f *sendFx) run() error {
	f.t.Helper()
	raw, _ := json.Marshal(f.p)
	qid := f.qid
	err := f.j.SendReminder(context.Background(), platform.JobRequest{RunID: "R1", Job: "send-reminder", Trigger: "queue", QueueID: &qid, Payload: raw})
	if len(f.n.calls) > 4 {
		f.t.Fatalf("notifs calls = %v, the cap is four", f.n.calls)
	}
	return err
}

func (f *sendFx) mustRun() {
	f.t.Helper()
	if err := f.run(); err != nil {
		f.t.Fatalf("send: %v", err)
	}
}

func (f *sendFx) wantRows(outcomes ...string) {
	f.t.Helper()
	var got []string
	for _, r := range f.store.remSent {
		got = append(got, r.Outcome)
	}
	if strings.Join(got, ",") != strings.Join(outcomes, ",") {
		f.t.Fatalf("reminders_sent = %v, want %v", got, outcomes)
	}
	if len(outcomes) > 0 && len(f.store.jobRuns) != len(outcomes) {
		f.t.Fatalf("job_runs = %d, want %d", len(f.store.jobRuns), len(outcomes))
	}
	if len(outcomes) == 0 && len(f.store.jobRuns) != 0 {
		f.t.Fatalf("job_runs = %d, want none", len(f.store.jobRuns))
	}
}

func (f *sendFx) wantCalls(calls ...string) {
	f.t.Helper()
	if strings.Join(f.n.calls, ",") != strings.Join(calls, ",") {
		f.t.Fatalf("notifs calls = %v, want %v", f.n.calls, calls)
	}
}

func (f *sendFx) addDest(notifsID int64, stale bool) int64 {
	id := int64(len(f.store.dests) + 100)
	f.store.dests = append(f.store.dests, fDest{ID: id, UserID: 1, NotifsID: notifsID, Kind: "discord", Label: "d", Hint: "abc", Stale: stale})
	return id
}

func (f *sendFx) setNtfy(on bool) {
	u := f.store.users["sam@example.test"]
	u.NtfyUserID = pgtype.Text{String: "nu1", Valid: on}
	f.store.users["sam@example.test"] = u
}

func nerr(status int, msg string) error { return &platform.NotifsError{Status: status, Message: msg} }

var (
	errNoPublisher   = nerr(422, "app has no ntfy publisher")
	errNoPersonalDst = nerr(422, "personal destination not available for recipient")
)

func TestSendSent(t *testing.T) {
	f := newSendFx(t)
	f.mustRun()
	f.wantCalls("send")
	f.wantRows("sent")
	m := f.n.sent[0]
	if m.IdempotencyKey != "rem-1-1-2026-11-21-1" || m.Channel != "all" || m.Recipient != "sam@example.test" || m.Via != "ntfy" {
		t.Fatalf("message = %+v", m)
	}
	if m.Title != "Sam Rivera's birthday is tomorrow" || m.Body != "Saturday, November 21 - turns 31" {
		t.Fatalf("wording = %q / %q", m.Title, m.Body)
	}
	if f.store.jobRuns[f.qid] != "send-reminder" {
		t.Fatalf("job_runs = %v", f.store.jobRuns)
	}
}

func TestSendVia(t *testing.T) {
	cases := []struct {
		name     string
		ntfy     bool
		dests    []bool // stale flags
		wantVia  string
		wantIDs  []int64
		noTarget bool
	}{
		{name: "ntfy only", ntfy: true, wantVia: "ntfy"},
		{name: "both", ntfy: true, dests: []bool{false}, wantVia: "both", wantIDs: []int64{501}},
		{name: "personal only", dests: []bool{false, false}, wantVia: "personal", wantIDs: []int64{501, 502}},
		{name: "a stale destination is not counted or sent", ntfy: true, dests: []bool{true}, wantVia: "ntfy"},
		{name: "only stale and no ntfy is nowhere to send", dests: []bool{true}, noTarget: true},
		{name: "nothing at all is nowhere to send", noTarget: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newSendFx(t)
			f.setNtfy(tc.ntfy)
			for i, st := range tc.dests {
				f.addDest(int64(501+i), st)
			}
			f.mustRun()
			if tc.noTarget {
				f.wantCalls()
				f.wantRows()
				return
			}
			m := f.n.sent[0]
			if m.Via != tc.wantVia || fmt.Sprint(m.PersonalDestinationIDs) != fmt.Sprint(tc.wantIDs) {
				t.Fatalf("via=%q ids=%v, want %q %v", m.Via, m.PersonalDestinationIDs, tc.wantVia, tc.wantIDs)
			}
			f.wantRows("sent")
		})
	}
}

func TestSendNowhereToSendIsSentOnceADestinationExists(t *testing.T) {
	f := newSendFx(t)
	f.setNtfy(false)
	f.mustRun()
	f.wantRows()
	f.addDest(501, false) // the person sets one up; the next scan re-enqueues inside the window
	f.qid = "01QUEUE000000000000000002"
	f.mustRun()
	f.wantRows("sent")
	if f.n.sent[0].Via != "personal" {
		t.Fatalf("via = %q", f.n.sent[0].Via)
	}
}

func TestSendSkips(t *testing.T) {
	cases := []struct {
		name  string
		setup func(f *sendFx)
	}{
		{"viewer lost access", func(f *sendFx) { f.store.birthdays[0].OwnerID = 2 }},
		{"offset no longer set", func(f *sendFx) { f.store.reminders[0].Offsets = []int16{7} }},
		{"reminders turned off", func(f *sendFx) { f.store.reminders = nil }},
		{"occurrence already past", func(f *sendFx) { f.j.Now = laClock(f.t, 2026, 11, 22, 8) }},
		{"birthday date edited after the scan", func(f *sendFx) { f.store.birthdays[0].Day = 22 }},
		{"Feb 29 edited to Mar 1 after the scan", func(f *sendFx) {
			f.j.Now = laClock(f.t, 2027, 2, 27, 8)
			f.p.Occurrence = "2027-02-28"
			// The scan saw a Feb 29 birthday (occurrence Feb 28 in 2027); it is now Mar 1.
			f.store.birthdays[0].Month, f.store.birthdays[0].Day = 3, 1
		}},
		{"Feb 29 edited to Feb 27 after the scan", func(f *sendFx) {
			f.j.Now = laClock(f.t, 2027, 2, 26, 8)
			f.p.Occurrence = "2027-02-28"
			f.store.birthdays[0].Month, f.store.birthdays[0].Day = 2, 27
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newSendFx(t)
			tc.setup(f)
			f.mustRun()
			f.wantCalls()
			f.wantRows("skipped")
		})
	}
}

func TestSendFeb29IsNotSkippedInACommonYear(t *testing.T) {
	f := newSendFx(t)
	f.j.Now = laClock(t, 2027, 2, 27, 8)
	f.p.Occurrence = "2027-02-28"
	f.store.birthdays[0].Month, f.store.birthdays[0].Day, f.store.birthdays[0].Year = 2, 29, pgtype.Int2{}
	f.mustRun()
	f.wantRows("sent")
	if f.n.sent[0].Body != "Sunday, February 28" {
		t.Fatalf("body = %q (no age without a year)", f.n.sent[0].Body)
	}
}

func TestSendGoneRowsAreANoOp(t *testing.T) {
	f := newSendFx(t)
	f.store.birthdays = nil
	f.mustRun()
	f.wantCalls()
	f.wantRows()

	f = newSendFx(t)
	delete(f.store.users, "sam@example.test")
	f.mustRun()
	f.wantCalls()
	f.wantRows()
}

func TestSendExistingRowIsANoOp(t *testing.T) {
	f := newSendFx(t)
	f.store.remSent = []fSent{{BirthdayID: 1, UserID: 1, Occurrence: Date{2026, 11, 21}, OffsetDays: 1, Outcome: "failed"}}
	f.mustRun()
	f.wantCalls()
	if len(f.store.remSent) != 1 || f.store.remSent[0].Outcome != "failed" {
		t.Fatalf("rows = %+v", f.store.remSent)
	}
}

func TestSendRerunIsIdempotent(t *testing.T) {
	f := newSendFx(t)
	f.mustRun()
	f.mustRun() // the same queue id again
	f.wantCalls("send")
	f.wantRows("sent")
}

func TestSendRollbackThenRetryReusesTheKey(t *testing.T) {
	f := newSendFx(t)
	f.store.failRemSent = errBoom
	if err := f.run(); !errors.Is(err, errBoom) {
		t.Fatalf("err = %v, want the record error", err)
	}
	f.wantRows()
	f.store.failRemSent = nil
	f.mustRun()
	f.wantRows("sent")
	if len(f.n.sent) != 2 || f.n.sent[0].IdempotencyKey != f.n.sent[1].IdempotencyKey {
		t.Fatalf("the retry must reuse the idempotency key: %+v", f.n.sent)
	}
}

func TestSendRetryableErrorsRecordNothing(t *testing.T) {
	cases := map[string]error{
		"500":          nerr(500, "boom"),
		"503":          nerr(503, ""),
		"429":          nerr(429, "rate limited"),
		"408":          nerr(408, "request timeout"),
		"425":          nerr(425, "too early"),
		"401":          nerr(401, "unauthorized"),
		"403 json":     nerr(403, "forbidden"),
		"403 non-json": nerr(403, ""),
		"network":      fmt.Errorf("%w: notifs send: network", platform.ErrNotifsRetryable),
		"unconfigured": platform.ErrNotifsUnconfigured,
	}
	for name, sendErr := range cases {
		t.Run(name, func(t *testing.T) {
			f := newSendFx(t)
			f.n.sendResults = []error{sendErr}
			if err := f.run(); err == nil {
				t.Fatal("want an error so the runner retries")
			}
			f.wantCalls("send")
			f.wantRows()
		})
	}
}

func TestSendRejectionsAreRecordedFailed(t *testing.T) {
	for name, sendErr := range map[string]error{
		"400": nerr(400, "bad"), "409": nerr(409, "conflict"), "404": nerr(404, "no"), "422 other": nerr(422, "something else"),
	} {
		t.Run(name, func(t *testing.T) {
			f := newSendFx(t)
			f.n.sendResults = []error{sendErr}
			f.mustRun()
			f.wantCalls("send")
			f.wantRows("failed")
		})
	}
}

func TestSendPublisher422(t *testing.T) {
	t.Run("mint then resend sends", func(t *testing.T) {
		f := newSendFx(t)
		f.n.sendResults = []error{errNoPublisher, nil}
		f.mustRun()
		f.wantCalls("send", "mint", "send")
		f.wantRows("sent")
	})
	for name, mintErr := range map[string]error{
		"409": nerr(409, "x"), "404": nerr(404, "app has no approved binding"), "429": nerr(429, "x"), "500": nerr(500, "x"),
		"network": fmt.Errorf("%w: notifs", platform.ErrNotifsRetryable), "unconfigured": platform.ErrNotifsUnconfigured,
	} {
		t.Run("mint "+name+" is an error, never failed", func(t *testing.T) {
			f := newSendFx(t)
			f.n.sendResults = []error{errNoPublisher}
			f.n.publisher = mintErr
			if err := f.run(); err == nil {
				t.Fatal("want an error")
			}
			f.wantCalls("send", "mint")
			f.wantRows()
		})
	}
	t.Run("a second publisher 422 mints only once", func(t *testing.T) {
		f := newSendFx(t)
		f.n.sendResults = []error{errNoPublisher, errNoPublisher}
		if err := f.run(); err == nil {
			t.Fatal("want an error")
		}
		f.wantCalls("send", "mint", "send")
		f.wantRows()
	})
	t.Run("a personal 422 after the mint only looks up and stales, then errors", func(t *testing.T) {
		f := newSendFx(t)
		local := f.addDest(501, false)
		f.n.sendResults = []error{errNoPublisher, errNoPersonalDst}
		if err := f.run(); err == nil {
			t.Fatal("want an error")
		}
		f.wantCalls("send", "mint", "send", "lookup")
		f.wantRows()
		if !f.store.dests[0].Stale || f.store.dests[0].ID != local {
			t.Fatalf("destination not staled: %+v", f.store.dests)
		}
	})
}

func TestSendPersonal422(t *testing.T) {
	t.Run("lookup fails: error, nothing staled or recorded", func(t *testing.T) {
		f := newSendFx(t)
		f.addDest(501, false)
		f.n.sendResults = []error{errNoPersonalDst}
		f.n.lookupErr = nerr(500, "x")
		if err := f.run(); err == nil {
			t.Fatal("want an error")
		}
		f.wantCalls("send", "lookup")
		f.wantRows()
		if f.store.dests[0].Stale {
			t.Fatal("nothing may be staled when the lookup fails")
		}
	})
	t.Run("nothing non-deliverable: failed, no retry", func(t *testing.T) {
		f := newSendFx(t)
		f.addDest(501, false)
		f.n.sendResults = []error{errNoPersonalDst}
		f.n.deliverable = map[int64]bool{501: true}
		f.mustRun()
		f.wantCalls("send", "lookup")
		f.wantRows("failed")
		if f.store.dests[0].Stale {
			t.Fatal("a deliverable destination must stay")
		}
	})
	t.Run("one stale, one survivor: retry with the survivor", func(t *testing.T) {
		f := newSendFx(t)
		f.addDest(501, false)
		f.addDest(502, false)
		f.n.sendResults = []error{errNoPersonalDst, nil}
		f.n.deliverable = map[int64]bool{502: true}
		f.mustRun()
		f.wantCalls("send", "lookup", "send")
		f.wantRows("sent")
		if !f.store.dests[0].Stale || f.store.dests[1].Stale {
			t.Fatalf("dests = %+v", f.store.dests)
		}
		if m := f.n.sent[1]; m.Via != "both" || fmt.Sprint(m.PersonalDestinationIDs) != "[502]" {
			t.Fatalf("retry = %+v", m)
		}
	})
	t.Run("no survivor, ntfy kept: retry ntfy-only", func(t *testing.T) {
		f := newSendFx(t)
		f.addDest(501, false)
		f.n.sendResults = []error{errNoPersonalDst, nil}
		f.mustRun()
		f.wantCalls("send", "lookup", "send")
		f.wantRows("sent")
		if m := f.n.sent[1]; m.Via != "ntfy" || len(m.PersonalDestinationIDs) != 0 {
			t.Fatalf("retry = %+v", m)
		}
	})
	t.Run("no survivor and no ntfy: nothing recorded, nothing more called", func(t *testing.T) {
		f := newSendFx(t)
		f.setNtfy(false)
		f.addDest(501, false)
		f.n.sendResults = []error{errNoPersonalDst}
		f.mustRun()
		f.wantCalls("send", "lookup")
		f.wantRows()
		if !f.store.dests[0].Stale {
			t.Fatal("the destination should be staled")
		}
		// After a destination is re-added inside the window, the next scan's job sends it.
		f.addDest(502, false)
		f.qid = "01QUEUE000000000000000002"
		f.mustRun()
		f.wantRows("sent")
	})
	t.Run("retry returns a second personal 422: failed", func(t *testing.T) {
		f := newSendFx(t)
		f.addDest(501, false)
		f.addDest(502, false)
		f.n.sendResults = []error{errNoPersonalDst, errNoPersonalDst}
		f.n.deliverable = map[int64]bool{502: true}
		f.mustRun()
		f.wantCalls("send", "lookup", "send")
		f.wantRows("failed")
	})
	t.Run("retry returns 5xx: error, ids stay stale", func(t *testing.T) {
		f := newSendFx(t)
		f.addDest(501, false)
		f.addDest(502, false)
		f.n.sendResults = []error{errNoPersonalDst, nerr(503, "")}
		f.n.deliverable = map[int64]bool{502: true}
		if err := f.run(); err == nil {
			t.Fatal("want an error")
		}
		f.wantRows()
		if !f.store.dests[0].Stale {
			t.Fatal("the staled id must stay stale")
		}
	})
	t.Run("retry returns a publisher 422: error, no mint", func(t *testing.T) {
		f := newSendFx(t)
		f.addDest(501, false)
		f.addDest(502, false)
		f.n.sendResults = []error{errNoPersonalDst, errNoPublisher}
		f.n.deliverable = map[int64]bool{502: true}
		if err := f.run(); err == nil {
			t.Fatal("want an error")
		}
		f.wantCalls("send", "lookup", "send")
		f.wantRows()
	})
}

func TestSendWording(t *testing.T) {
	cases := []struct {
		name       string
		month, day int16
		occ        string
		offset     int16
		title      string
	}{
		{"today", 11, 20, "2026-11-20", 0, "Sam Rivera's birthday is today"},
		{"tomorrow", 11, 21, "2026-11-21", 1, "Sam Rivera's birthday is tomorrow"},
		{"in 6 days with offset 7", 11, 26, "2026-11-26", 7, "Sam Rivera's birthday is in 6 days"},
		{"in 7 days", 11, 27, "2026-11-27", 7, "Sam Rivera's birthday is in 7 days"},
		{"in 14 days", 12, 4, "2026-12-04", 14, "Sam Rivera's birthday is in 14 days"},
		{"in 364 days", 11, 19, "2027-11-19", 364, "Sam Rivera's birthday is in 364 days"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newSendFx(t)
			f.store.birthdays[0].Month, f.store.birthdays[0].Day = tc.month, tc.day
			f.store.reminders[0].Offsets = []int16{tc.offset}
			f.p.Occurrence, f.p.OffsetDays = tc.occ, tc.offset
			f.mustRun()
			if got := f.n.sent[0].Title; got != tc.title {
				t.Fatalf("title = %q, want %q", got, tc.title)
			}
			if want := fmt.Sprintf("rem-1-1-%s-%d", tc.occ, tc.offset); f.n.sent[0].IdempotencyKey != want {
				t.Fatalf("key = %q, want %q", f.n.sent[0].IdempotencyKey, want)
			}
		})
	}
}

func TestSendUnreadablePayloadIsDropped(t *testing.T) {
	f := newSendFx(t)
	err := f.j.SendReminder(context.Background(), platform.JobRequest{RunID: "R1", Payload: json.RawMessage(`{"birthday_id":`)})
	if err != nil {
		t.Fatalf("err = %v, want nil (a retry cannot fix it)", err)
	}
	f.wantCalls()
	f.wantRows()
}

func TestSendWithoutANotifsClientErrors(t *testing.T) {
	f := newSendFx(t)
	f.j.Notifs = nil
	if err := f.run(); !errors.Is(err, platform.ErrNotifsUnconfigured) {
		t.Fatalf("err = %v", err)
	}
}
