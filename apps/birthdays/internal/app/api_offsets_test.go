package app

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
)

const samHead = `"name":"Sam","month":11,"day":21`

// meDefaults reads default_offsets through GET /api/me.
func (hn *harness) meDefaults(email string) []int16 {
	hn.t.Helper()
	rec := hn.as(email, "GET", "/api/me", "")
	hn.wantStatus(rec, 200, "")
	var got struct {
		Settings struct {
			AutoRemind     bool    `json:"auto_remind"`
			DefaultOffsets []int16 `json:"default_offsets"`
		}
	}
	decode(hn.t, rec.Body.String(), &got)
	return got.Settings.DefaultOffsets
}

func TestSettingsAndRemindersAcceptEveryAllowedOffset(t *testing.T) {
	hn := newHarness(t)
	b := hn.create(alice, sam)
	path := fmt.Sprintf("/api/birthdays/%d/reminders", b.ID)
	all := []int{0, 1}
	for w := 7; w <= 364; w += 7 {
		all = append(all, w)
	}
	for _, o := range all {
		hn.wantStatus(hn.as(alice, "PATCH", "/api/settings", fmt.Sprintf(`{"default_offsets":[%d]}`, o)), 200, "")
		if got := hn.meDefaults(alice); !slices.Equal(got, []int16{int16(o)}) {
			t.Fatalf("PATCH [%d] stored %v", o, got)
		}
		hn.wantStatus(hn.as(alice, "PUT", path, fmt.Sprintf(`{"offsets":[%d]}`, o)), 200, "")
		if got := hn.store.reminders[0].Offsets; !slices.Equal(got, []int16{int16(o)}) {
			t.Fatalf("PUT [%d] stored %v", o, got)
		}
	}
	// Every integer outside A is rejected on both endpoints.
	for o := -1; o <= 400; o++ {
		if slices.Contains(all, o) {
			continue
		}
		hn.wantStatus(hn.as(alice, "PATCH", "/api/settings", fmt.Sprintf(`{"default_offsets":[%d]}`, o)), 400, "invalid_offsets")
		hn.wantStatus(hn.as(alice, "PUT", path, fmt.Sprintf(`{"offsets":[%d]}`, o)), 400, "invalid_offsets")
	}
	for body, want := range map[string][]int16{
		`[14]`: {14}, `[364]`: {364}, `[0,1,14]`: {14, 1, 0}, `[1,14,0,7,14]`: {14, 7, 1, 0},
	} {
		hn.wantStatus(hn.as(alice, "PATCH", "/api/settings", `{"default_offsets":`+body+`}`), 200, "")
		if got := hn.meDefaults(alice); !slices.Equal(got, want) {
			t.Fatalf("PATCH %s stored %v, want %v", body, got, want)
		}
	}
}

func TestCreateWithOffsets(t *testing.T) {
	hn := newHarness(t)
	b := hn.create(alice, `{`+samHead+`,"offsets":[14,1]}`) // auto_remind is false
	if !slices.Equal(b.ReminderOffsets, []int16{14, 1}) || !slices.Equal(hn.store.reminders[0].Offsets, []int16{14, 1}) {
		t.Fatalf("created %v, stored %v", b.ReminderOffsets, hn.store.reminders)
	}
	if got := hn.meDefaults(alice); !slices.Equal(got, []int16{14, 1}) {
		t.Fatalf("default after create = %v, want [14 1]", got)
	}

	// Unsorted and duplicated input is stored and returned farthest-first.
	b = hn.create(bob, `{`+samHead+`,"offsets":[1,14,0,7,14]}`)
	if !slices.Equal(b.ReminderOffsets, []int16{14, 7, 1, 0}) {
		t.Fatalf("reminder_offsets = %v, want [14 7 1 0]", b.ReminderOffsets)
	}
	if got := hn.meDefaults(bob); !slices.Equal(got, []int16{14, 7, 1, 0}) {
		t.Fatalf("default = %v, want [14 7 1 0]", got)
	}

	// An empty array means off, even with auto_remind on, and changes neither the default nor auto_remind.
	hn.wantStatus(hn.as(carol, "PATCH", "/api/settings", `{"auto_remind":true,"default_offsets":[7]}`), 200, "")
	b = hn.create(carol, `{`+samHead+`,"offsets":[]}`)
	if len(b.ReminderOffsets) != 0 || len(hn.store.reminders) != 2 || !slices.Equal(hn.meDefaults(carol), []int16{7}) {
		t.Fatalf("offsets [] created %v, reminders %d, default %v", b.ReminderOffsets, len(hn.store.reminders), hn.meDefaults(carol))
	}
	if !hn.store.users[carol].AutoRemind {
		t.Fatal("offsets [] changed auto_remind")
	}

	// remind:null counts as absent: offsets-only.
	b = hn.create(alice, `{`+samHead+`,"remind":null,"offsets":[1]}`)
	if !slices.Equal(b.ReminderOffsets, []int16{1}) || !slices.Equal(hn.meDefaults(alice), []int16{1}) {
		t.Fatalf("remind:null + offsets = %v, default %v, want [1] for both", b.ReminderOffsets, hn.meDefaults(alice))
	}

	// No offsets key: the old path copies the defaults and does not rewrite them.
	hn.wantStatus(hn.as(alice, "PATCH", "/api/settings", `{"default_offsets":[7,1]}`), 200, "")
	b = hn.create(alice, `{`+samHead+`,"remind":true}`)
	if !slices.Equal(b.ReminderOffsets, []int16{7, 1}) || !slices.Equal(hn.meDefaults(alice), []int16{7, 1}) {
		t.Fatalf("no offsets: created %v, default %v", b.ReminderOffsets, hn.meDefaults(alice))
	}
}

func TestCreateOffsetsRejected(t *testing.T) {
	hn := newHarness(t)
	for _, extra := range []string{`"offsets":[2]`, `"offsets":null`, `"offsets":"x"`, `"offsets":[1.5]`, `"offsets":[8]`,
		`"remind":true,"offsets":[1]`, `"remind":false,"offsets":[]`} {
		hn.wantStatus(hn.as(alice, "POST", "/api/birthdays", `{`+samHead+`,`+extra+`}`), 400, "invalid_offsets")
	}
	if len(hn.store.birthdays) != 0 || len(hn.store.reminders) != 0 {
		t.Fatal("a rejected create left rows")
	}
	if got := hn.meDefaults(alice); !slices.Equal(got, []int16{14, 7, 1}) {
		t.Fatalf("default changed to %v", got)
	}
	// Name and date errors win over any offsets error.
	hn.wantStatus(hn.as(alice, "POST", "/api/birthdays", `{"name":"  ","month":11,"day":21,"offsets":"x"}`), 400, "invalid_name")
	hn.wantStatus(hn.as(alice, "POST", "/api/birthdays", `{"name":"  ","month":11,"day":21,"offsets":[2]}`), 400, "invalid_name")
	hn.wantStatus(hn.as(alice, "POST", "/api/birthdays", `{"name":"A","month":13,"day":21,"offsets":"x"}`), 400, "invalid_date")
}

func TestCreateCapLeavesDefaultUnchanged(t *testing.T) {
	hn := newHarness(t)
	for i := 0; i < 500; i++ {
		hn.create(alice, sam)
	}
	hn.wantStatus(hn.as(alice, "POST", "/api/birthdays", `{`+samHead+`,"offsets":[28]}`), 409, "too_many_birthdays")
	if got := hn.meDefaults(alice); !slices.Equal(got, []int16{14, 7, 1}) {
		t.Fatalf("a 409 changed the default to %v", got)
	}
	// An invalid offsets value is reported before the cap.
	hn.wantStatus(hn.as(alice, "POST", "/api/birthdays", `{`+samHead+`,"offsets":[2]}`), 400, "invalid_offsets")
}

func TestCreateOffsetsShareTheTransaction(t *testing.T) {
	// wantCalls is the fake's call log inside the failed request: the writes that ran before the failure.
	for name, c := range map[string]struct {
		set       func(*fakeStore)
		wantCalls string
	}{
		"upsert fails (birthday insert already applied)": {func(s *fakeStore) { s.failUpsertRem = errors.New("boom") },
			"tx-begin,upsert-reminder,tx-end"},
		"settings update fails (upsert already applied)": {func(s *fakeStore) { s.failUpdSettings = errors.New("boom") },
			"tx-begin,upsert-reminder,update-settings,tx-end"},
		"failure after the default was written": {func(s *fakeStore) { s.failAfterUpdSettings = errors.New("boom") },
			"tx-begin,upsert-reminder,update-settings,tx-end"},
	} {
		hn := newHarness(t)
		hn.wantStatus(hn.as(alice, "PATCH", "/api/settings", `{"default_offsets":[7]}`), 200, "") // differs from the POSTed set
		var log []string
		hn.store.calls = &log
		c.set(hn.store)
		hn.wantStatus(hn.as(alice, "POST", "/api/birthdays", `{`+samHead+`,"offsets":[28,1]}`), 500, "")
		hn.store.calls = nil
		hn.store.failUpsertRem, hn.store.failUpdSettings, hn.store.failAfterUpdSettings = nil, nil, nil
		if got := strings.Join(log, ","); got != c.wantCalls {
			t.Errorf("%s: calls %q, want %q", name, got, c.wantCalls)
		}
		if len(hn.store.birthdays) != 0 || len(hn.store.reminders) != 0 {
			t.Errorf("%s: left birthdays %d, reminders %d", name, len(hn.store.birthdays), len(hn.store.reminders))
		}
		if got := hn.meDefaults(alice); !slices.Equal(got, []int16{7}) {
			t.Errorf("%s: default = %v, want unchanged [7]", name, got)
		}
	}
}

// The 54-value CHECK literal in the migration must be exactly the set the Go predicate accepts.
func TestMigrationCheckLiteralMatchesAllowedOffsets(t *testing.T) {
	raw, err := os.ReadFile("../../migrations/00002_custom_reminder_offsets.sql")
	if err != nil {
		t.Fatal(err)
	}
	up, _, _ := strings.Cut(string(raw), "-- +goose Down")
	m := regexp.MustCompile(`offsets <@ ARRAY\[([0-9,]+)\]`).FindStringSubmatch(up)
	if m == nil {
		t.Fatal("no CHECK literal in the Up section")
	}
	in := map[int]bool{}
	for _, f := range strings.Split(m[1], ",") {
		n, err := strconv.Atoi(f)
		if err != nil || in[n] {
			t.Fatalf("bad or duplicate literal element %q", f)
		}
		in[n] = true
	}
	for o := -400; o <= 800; o++ {
		if in[o] != allowedOffset(o) {
			t.Errorf("offset %d: migration literal says %t, allowedOffset says %t", o, in[o], allowedOffset(o))
		}
	}
}

func TestReplaceIgnoresRemindAndOffsets(t *testing.T) {
	hn := newHarness(t)
	b := hn.create(alice, `{`+samHead+`,"offsets":[1]}`) // reminder [1]; the default becomes [1]
	hn.wantStatus(hn.as(alice, "PATCH", "/api/settings", `{"default_offsets":[7,1]}`), 200, "")
	path := fmt.Sprintf("/api/birthdays/%d", b.ID)
	for _, extra := range []string{`"remind":true,"offsets":[14]`, `"remind":true,"offsets":"x"`} {
		hn.wantStatus(hn.as(alice, "PUT", path, `{"name":"Sam2","month":11,"day":21,`+extra+`}`), 200, "")
		d, _ := hn.detail(alice, b.ID)
		if d.Birthday.Name != "Sam2" {
			t.Fatalf("%s: the PUT did not apply (name %q)", extra, d.Birthday.Name)
		}
		if !slices.Equal(d.Birthday.ReminderOffsets, []int16{1}) || !slices.Equal(hn.meDefaults(alice), []int16{7, 1}) {
			t.Fatalf("%s changed reminders %v or default %v", extra, d.Birthday.ReminderOffsets, hn.meDefaults(alice))
		}
	}
}
