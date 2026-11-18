package app

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
	"unicode/utf16"
)

type dateVectors struct {
	Occurrence []struct {
		Month int16  `json:"month"`
		Day   int16  `json:"day"`
		From  string `json:"from"`
		Want  string `json:"want"`
	} `json:"occurrence"`
	DaysUntil []struct {
		From string `json:"from"`
		To   string `json:"to"`
		Want int    `json:"want"`
	} `json:"daysUntil"`
	Turning []struct {
		Year       *int16 `json:"year"`
		Occurrence string `json:"occurrence"`
		Want       *int   `json:"want"`
	} `json:"turning"`
	ValidDate []struct {
		Month int16  `json:"month"`
		Day   int16  `json:"day"`
		Year  *int16 `json:"year"`
		Want  bool   `json:"want"`
	} `json:"validDate"`
	TintIndex []struct {
		Name string `json:"name"`
		Want int    `json:"want"`
	} `json:"tintIndex"`
}

func loadVectors(t *testing.T) dateVectors {
	t.Helper()
	raw, err := os.ReadFile("../../testdata/date-vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var v dateVectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("date-vectors.json: %v", err)
	}
	if len(v.Occurrence) == 0 || len(v.DaysUntil) == 0 || len(v.Turning) == 0 || len(v.ValidDate) == 0 || len(v.TintIndex) == 0 {
		t.Fatal("date-vectors.json has an empty section")
	}
	return v
}

func mustDate(t *testing.T, s string) Date {
	t.Helper()
	d, err := ParseDate(s)
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func TestOccurrenceVectors(t *testing.T) {
	for _, c := range loadVectors(t).Occurrence {
		got := Occurrence(c.Month, c.Day, mustDate(t, c.From))
		if got.String() != c.Want {
			t.Errorf("Occurrence(%d, %d, %s) = %s, want %s", c.Month, c.Day, c.From, got, c.Want)
		}
	}
}

func TestDaysUntilVectors(t *testing.T) {
	for _, c := range loadVectors(t).DaysUntil {
		if got := DaysUntil(mustDate(t, c.From), mustDate(t, c.To)); got != c.Want {
			t.Errorf("DaysUntil(%s, %s) = %d, want %d", c.From, c.To, got, c.Want)
		}
	}
}

func TestTurningVectors(t *testing.T) {
	for _, c := range loadVectors(t).Turning {
		got := Turning(c.Year, mustDate(t, c.Occurrence))
		switch {
		case got == nil && c.Want == nil:
		case got == nil || c.Want == nil:
			t.Errorf("Turning(%v, %s) = %v, want %v", c.Year, c.Occurrence, got, c.Want)
		case *got != *c.Want:
			t.Errorf("Turning(%v, %s) = %d, want %d", c.Year, c.Occurrence, *got, *c.Want)
		}
	}
}

func TestValidDateVectors(t *testing.T) {
	for _, c := range loadVectors(t).ValidDate {
		if got := ValidDate(c.Month, c.Day, c.Year); got != c.Want {
			t.Errorf("ValidDate(%d, %d, %v) = %v, want %v", c.Month, c.Day, c.Year, got, c.Want)
		}
	}
}

// tintIndexRef is the reference for the avatar tint (the Step 8 web helper must agree): h = h*31 + code over the
// UTF-16 units of the name, unsigned 32-bit, index h % 6. The fixture rows are checked against it here, so a row
// computed by another rule fails this test rather than the web test.
func tintIndexRef(name string) int {
	var h uint32
	for _, u := range utf16.Encode([]rune(name)) {
		h = h*31 + uint32(u)
	}
	return int(h % 6)
}

func TestTintIndexVectorsMatchTheStatedHash(t *testing.T) {
	for _, c := range loadVectors(t).TintIndex {
		if got := tintIndexRef(c.Name); got != c.Want {
			t.Errorf("tintIndex(%q) = %d, fixture says %d", c.Name, got, c.Want)
		}
	}
}

func TestOccurrenceInvariantsOverAFullLeapCycle(t *testing.T) {
	// Every (month, day) from every day of 1900-2200 (covers the 100 and 400 rules): the result is never before from,
	// is at most one year ahead, is a valid civil date, and a Feb 29 birthday only lands on Feb 29 in a leap year, else
	// on Feb 28. The leap oracle is the standard library's (day 0 of March is the last day of February).
	from := Date{Year: 1900, Month: 1, Day: 1}
	for i := 0; i < 301*366; i++ {
		d := from.AddDays(i)
		for _, md := range [][2]int16{{2, 29}, {2, 28}, {12, 31}, {1, 1}, {3, 1}} {
			occ := Occurrence(md[0], md[1], d)
			if occ.Before(d) {
				t.Fatalf("Occurrence(%v, %s) = %s is before from", md, d, occ)
			}
			if n := DaysUntil(d, occ); n < 0 || n > 365 {
				t.Fatalf("Occurrence(%v, %s) = %s is %d days away", md, d, occ, n)
			}
			if _, err := ParseDate(occ.String()); err != nil {
				t.Fatalf("Occurrence(%v, %s) = %s is not a real date", md, d, occ)
			}
			if md == [2]int16{2, 29} {
				want := 28
				if time.Date(occ.Year, time.March, 0, 0, 0, 0, 0, time.UTC).Day() == 29 {
					want = 29
				}
				if occ.Month != 2 || occ.Day != want {
					t.Fatalf("Feb 29 birthday from %s landed on %s", d, occ)
				}
			}
		}
	}
}

// TestEmitValidDateSweepForTheDatabaseCheck writes the fixture's validDate rows plus an exhaustive sweep, each with
// ValidDate's answer, as SQL VALUES tuples "(month, day, year, want)" to the file named by DATE_SWEEP_OUT. test_image.sh
// runs every tuple through the real table CHECKs and compares, so the Go validator and the DB cannot drift. Without the
// variable it is skipped (it only exists to feed that script, which fails when the file is missing or empty).
func TestEmitValidDateSweepForTheDatabaseCheck(t *testing.T) {
	out := os.Getenv("DATE_SWEEP_OUT")
	if out == "" {
		t.Skip("DATE_SWEEP_OUT not set (test_image.sh sets it)")
	}
	var rows []string
	add := func(m, d int16, y *int16) {
		year := "NULL"
		if y != nil {
			year = fmt.Sprint(*y)
		}
		rows = append(rows, fmt.Sprintf("(%d,%d,%s,%v)", m, d, year, ValidDate(m, d, y)))
	}
	for _, c := range loadVectors(t).ValidDate {
		add(c.Month, c.Day, c.Year)
	}
	years := []int16{1899, 1900, 1904, 1999, 2000, 2023, 2024, 2100, 2200, 2201}
	for m := int16(-1); m <= 14; m++ {
		for d := int16(-1); d <= 33; d++ {
			add(m, d, nil)
			for i := range years {
				add(m, d, &years[i])
			}
		}
	}
	if err := os.WriteFile(out, []byte(strings.Join(rows, ",\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestDateHelpers(t *testing.T) {
	if _, err := ParseDate("2026-02-30"); err == nil {
		t.Error("ParseDate accepted Feb 30")
	}
	if _, err := ParseDate("not a date"); err == nil {
		t.Error("ParseDate accepted junk")
	}
	d := Date{Year: 2028, Month: 2, Day: 28}
	if got := d.AddDays(1); got != (Date{2028, 2, 29}) {
		t.Errorf("AddDays(1) = %s", got)
	}
	if got := d.AddDays(-2); got != (Date{2028, 2, 26}) {
		t.Errorf("AddDays(-2) = %s", got)
	}
	if got := (Date{Year: 5, Month: 3, Day: 9}).String(); got != "0005-03-09" {
		t.Errorf("String = %q", got)
	}
}
