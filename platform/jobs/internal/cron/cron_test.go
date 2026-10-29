package cron

import (
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

const tablePath = "../../../registry/cron-cases.table"

type tableRow struct {
	line  int
	valid bool
	cron  string
	note  string
}

// readTable applies the exact reader rules in the table's header (shared with the bash reader): no trimming
// anywhere, a blank line is zero-length (a whitespace-only line is malformed), a comment has # in column 1,
// LF line ends only, exactly 2 tabs per data line, verdict exactly valid|invalid, the cron wrapped in double
// quotes with no quote inside, a non-empty note.
func parseTable(b []byte) ([]tableRow, []string) {
	var rows []tableRow
	var problems []string
	lines := strings.Split(string(b), "\n")
	if lines[len(lines)-1] == "" { // the final LF
		lines = lines[:len(lines)-1]
	}
	for i, line := range lines {
		n := i + 1
		if line == "" || line[0] == '#' {
			continue
		}
		if strings.Contains(line, "\r") {
			problems = append(problems, fmt.Sprintf("line %d is malformed: CR in a data line", n))
			continue
		}
		if strings.Count(line, "\t") != 2 {
			problems = append(problems, fmt.Sprintf("line %d is malformed: want exactly 2 tabs", n))
			continue
		}
		parts := strings.Split(line, "\t")
		verdict, quoted, note := parts[0], parts[1], parts[2]
		if verdict != "valid" && verdict != "invalid" {
			problems = append(problems, fmt.Sprintf("line %d is malformed: verdict %q", n, verdict))
			continue
		}
		if len(quoted) < 2 || quoted[0] != '"' || quoted[len(quoted)-1] != '"' || strings.Contains(quoted[1:len(quoted)-1], `"`) {
			problems = append(problems, fmt.Sprintf("line %d is malformed: cron must be wrapped in double quotes with none inside", n))
			continue
		}
		if note == "" {
			problems = append(problems, fmt.Sprintf("line %d is malformed: empty note", n))
			continue
		}
		rows = append(rows, tableRow{line: n, valid: verdict == "valid", cron: quoted[1 : len(quoted)-1], note: note})
	}
	return rows, problems
}

func TestCronCasesTableAgreesWithBash(t *testing.T) {
	b, err := os.ReadFile(tablePath)
	if err != nil {
		t.Fatalf("reading the shared fixture: %v", err)
	}
	rows, problems := parseTable(b)
	for _, p := range problems {
		t.Errorf("%s %s", tablePath, p)
	}
	if len(rows) < 30 {
		t.Fatalf("cron-cases.table has %d data rows, need at least 30", len(rows))
	}
	for _, r := range rows {
		_, err := Parse(r.cron)
		if r.valid && err != nil {
			t.Errorf("line %d %q (%s): want valid, got %v", r.line, r.cron, r.note, err)
		}
		if !r.valid && err == nil {
			t.Errorf("line %d %q (%s): want invalid, parsed", r.line, r.cron, r.note)
		}
	}
}

var la = mustLoc("America/Los_Angeles")

func mustLoc(name string) *time.Location {
	l, err := time.LoadLocation(name)
	if err != nil {
		panic(err)
	}
	return l
}

func mustParse(t *testing.T, expr string) *Schedule {
	t.Helper()
	s, err := Parse(expr)
	if err != nil {
		t.Fatalf("Parse(%q): %v", expr, err)
	}
	return s
}

func at(y int, m time.Month, d, h, mi int) time.Time {
	return time.Date(y, m, d, h, mi, 0, 0, la)
}

func TestNextBasics(t *testing.T) {
	cases := []struct {
		expr  string
		after time.Time
		want  time.Time
	}{
		{"0 7 * * *", at(2026, 5, 4, 6, 59), at(2026, 5, 4, 7, 0)},
		{"0 7 * * *", at(2026, 5, 4, 7, 0), at(2026, 5, 5, 7, 0)},
		{"*/15 * * * *", at(2026, 5, 4, 7, 14), at(2026, 5, 4, 7, 15)},
		{"0-30/10 * * * *", at(2026, 5, 4, 7, 30), at(2026, 5, 4, 8, 0)},
		{"30 3 * * *", at(2026, 5, 4, 3, 30).Add(30 * time.Second), at(2026, 5, 5, 3, 30)},
		{"0 0 29 2 *", at(2026, 5, 4, 0, 0), at(2028, 2, 29, 0, 0)},
		{"0 7 * * 7", at(2026, 5, 4, 0, 0), at(2026, 5, 10, 7, 0)}, // 2026-05-10 is a Sunday
		{"0 7 * * 0", at(2026, 5, 4, 0, 0), at(2026, 5, 10, 7, 0)},
		{"0 7 * 1 *", at(2026, 5, 4, 0, 0), at(2027, 1, 1, 7, 0)},
	}
	for _, c := range cases {
		got := mustParse(t, c.expr).Next(c.after, la)
		if !got.Equal(c.want) {
			t.Errorf("Next(%q, %v) = %v, want %v", c.expr, c.after, got, c.want)
		}
	}
}

func TestNextIsStrictlyAfterAndInLoc(t *testing.T) {
	s := mustParse(t, "* * * * *")
	after := time.Date(2026, 5, 4, 14, 0, 0, 0, time.UTC)
	got := s.Next(after, la)
	if !got.Equal(after.Add(time.Minute)) || got.Location() != la {
		t.Fatalf("Next = %v (%v)", got, got.Location())
	}
}

func TestOrRuleDayOfMonthAndDayOfWeek(t *testing.T) {
	s := mustParse(t, "0 9 1 * 1")
	// 2026-03-01 is a Sunday: fires on the 1st, then every Monday, not on other days.
	want := []time.Time{
		at(2026, 3, 1, 9, 0), at(2026, 3, 2, 9, 0), at(2026, 3, 9, 9, 0),
		at(2026, 3, 16, 9, 0), at(2026, 3, 23, 9, 0), at(2026, 3, 30, 9, 0),
		at(2026, 4, 1, 9, 0), // a Wednesday: the 1st
		at(2026, 4, 6, 9, 0),
	}
	cur := at(2026, 2, 28, 23, 0)
	for _, w := range want {
		cur = s.Next(cur, la)
		if !cur.Equal(w) {
			t.Fatalf("got %v, want %v", cur, w)
		}
	}
}

func TestStarFieldUsesAndRule(t *testing.T) {
	// day-of-month restricted, day-of-week "*": both must match, so only the 15th.
	s := mustParse(t, "0 0 15 * *")
	if got := s.Next(at(2026, 5, 16, 0, 0), la); !got.Equal(at(2026, 6, 15, 0, 0)) {
		t.Fatalf("got %v", got)
	}
	// "*/2" starts with a star: Vixie treats it as unrestricted for the OR rule, so the AND rule applies.
	s = mustParse(t, "0 0 */2 * 1")
	got := s.Next(at(2026, 5, 1, 0, 0), la) // */2 from 1 is the odd days; Mondays in May 2026 are 4, 11, 18, 25; both: 11 and 25.
	if !got.Equal(at(2026, 5, 11, 0, 0)) {
		t.Fatalf("got %v", got)
	}
}

func TestDSTSpringForwardGapDoesNotRun(t *testing.T) {
	// 2026-03-08: 02:00-03:00 does not exist in America/Los_Angeles.
	s := mustParse(t, "30 2 * * *")
	got := s.Next(at(2026, 3, 8, 0, 0), la)
	if !got.Equal(at(2026, 3, 9, 2, 30)) {
		t.Fatalf("gap time ran: got %v", got)
	}
	// The hour after the gap is unaffected.
	s = mustParse(t, "30 3 * * *")
	if got := s.Next(at(2026, 3, 8, 0, 0), la); !got.Equal(at(2026, 3, 8, 3, 30)) {
		t.Fatalf("got %v", got)
	}
	// And the day before still runs.
	s = mustParse(t, "30 2 * * *")
	if got := s.Next(at(2026, 3, 7, 0, 0), la); !got.Equal(at(2026, 3, 7, 2, 30)) {
		t.Fatalf("got %v", got)
	}
}

func TestDSTAutumnRepeatedHourRunsOnce(t *testing.T) {
	// 2026-11-01: 01:00-02:00 happens twice. The first occurrence is PDT (UTC-7).
	s := mustParse(t, "30 1 * * *")
	first := s.Next(at(2026, 11, 1, 0, 0), la)
	wantFirst := time.Date(2026, 11, 1, 8, 30, 0, 0, time.UTC)
	if !first.Equal(wantFirst) {
		t.Fatalf("first occurrence: got %v, want %v", first.UTC(), wantFirst)
	}
	// Strictly after the first occurrence the next fire is the next day, not the repeated 01:30 PST.
	second := s.Next(first, la)
	if want := at(2026, 11, 2, 1, 30); !second.Equal(want) {
		t.Fatalf("repeated hour ran twice: got %v, want %v", second, want)
	}
	// Every-minute schedule: the repeated hour is covered exactly once across the fall-back.
	every := mustParse(t, "* 1 1 11 *")
	count := 0
	cur := time.Date(2026, 11, 1, 6, 0, 0, 0, time.UTC)
	for {
		cur = every.Next(cur, la)
		if cur.IsZero() || cur.After(time.Date(2026, 11, 1, 12, 0, 0, 0, time.UTC)) {
			break
		}
		count++
	}
	if count != 60 {
		t.Fatalf("01:00-01:59 fired %d times on the fall-back day, want 60 (once)", count)
	}
}

func TestNextNoFire(t *testing.T) {
	// February 30 never exists.
	if got := mustParse(t, "0 0 30 2 *").Next(at(2026, 1, 1, 0, 0), la); !got.IsZero() {
		t.Fatalf("got %v", got)
	}
}

func TestParseErrorsNameTheField(t *testing.T) {
	_, err := Parse("0 24 * * *")
	if err == nil || !strings.Contains(err.Error(), "hour") {
		t.Fatalf("err = %v", err)
	}
	_, err = Parse("0 7 * *")
	if err == nil || !strings.Contains(err.Error(), "5 fields") {
		t.Fatalf("err = %v", err)
	}
}

func TestParseTableRejectsMalformedRows(t *testing.T) {
	bad := map[string]string{
		"one tab":              "valid\t\"* * * * *\"\n",
		"three tabs":           "valid\t\"* * * * *\"\tnote\textra\n",
		"unknown verdict":      "maybe\t\"* * * * *\"\tn\n",
		"unquoted cron":        "valid\t* * * * *\tn\n",
		"quote inside":         "valid\t\"* * \"x\" * *\"\tn\n",
		"empty note":           "valid\t\"* * * * *\"\t\n",
		"CR line end":          "valid\t\"* * * * *\"\tn\r\n",
		"whitespace-only line": " \n",
		"indented comment":     " # c\n",
		"padded verdict":       " valid\t\"* * * * *\"\tn\n",
	}
	for name, content := range bad {
		if rows, problems := parseTable([]byte(content)); len(problems) != 1 || len(rows) != 0 {
			t.Errorf("%s: rows=%v problems=%v, want one problem", name, rows, problems)
		}
	}
	good := "# comment\n\nvalid\t\"* * * * *\"\tn\ninvalid\t\"@daily\"\tm"
	if rows, problems := parseTable([]byte(good)); len(problems) != 0 || len(rows) != 2 || !rows[0].valid || rows[1].valid {
		t.Errorf("good table: rows=%v problems=%v", rows, problems)
	}
}
