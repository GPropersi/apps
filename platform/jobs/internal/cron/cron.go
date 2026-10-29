// Package cron parses and matches the platform's 5-field cron schedules.
//
// The grammar is the one platform/registry/validate-app-yaml.sh accepts (shared fixture
// platform/registry/cron-cases.table): a comma list of items, each "*", N or N-M with an optional /step;
// numbers without leading zeros; N <= M; a step (>= 1, at most the field's max minus min) only after "*" or a
// range. Matching follows Vixie cron: day-of-week 0-7 (0 and 7 are Sunday) and, when both day-of-month and
// day-of-week are restricted (neither field starts with "*"), a day matches if either matches.
package cron

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type fieldSpec struct {
	name   string
	lo, hi int
}

var fieldSpecs = [5]fieldSpec{
	{"minute", 0, 59},
	{"hour", 0, 23},
	{"day-of-month", 1, 31},
	{"month", 1, 12},
	{"day-of-week", 0, 7},
}

const (
	cronNum = `(0|[1-9][0-9]{0,5})`
	// item = ("*" | N | N-M) with an optional /step, exactly validate-app-yaml.sh's CRON_ITEM.
	cronItem = `(\*|` + cronNum + `(-` + cronNum + `)?)(/` + cronNum + `)?`
)

var itemRE = regexp.MustCompile(`^` + cronItem + `$`)

// maxSearchDays bounds Next: 8 years covers a "0 0 29 2 *" schedule across a non-leap century gap.
const maxSearchDays = 366 * 8

// Schedule is a parsed cron expression.
type Schedule struct {
	expr    string
	minutes [60]bool
	hours   [24]bool
	doms    [32]bool // index 1-31
	months  [13]bool // index 1-12
	dows    [7]bool  // 0 = Sunday (7 folded in)
	domStar bool
	dowStar bool
}

// String returns the expression the schedule was parsed from.
func (s *Schedule) String() string { return s.expr }

// Parse parses a 5-field expression. Fields are separated by whitespace. Any defect is an error.
func Parse(expr string) (*Schedule, error) {
	// ASCII blanks only, like bash `read -a` (strings.Fields would also split on Unicode spaces).
	fields := strings.FieldsFunc(expr, func(r rune) bool { return r == ' ' || r == '\t' || r == '\n' })
	if len(fields) != 5 {
		// Report a bad field shape first, like the bash validator, then the count.
		for i, f := range fields {
			if i < 5 {
				if _, err := parseField(i, f); err != nil {
					return nil, err
				}
			}
		}
		return nil, fmt.Errorf("schedule must have exactly 5 fields, got %d", len(fields))
	}
	s := &Schedule{expr: expr}
	for i, f := range fields {
		vals, err := parseField(i, f)
		if err != nil {
			return nil, err
		}
		for _, v := range vals {
			switch i {
			case 0:
				s.minutes[v] = true
			case 1:
				s.hours[v] = true
			case 2:
				s.doms[v] = true
			case 3:
				s.months[v] = true
			case 4:
				s.dows[v%7] = true
			}
		}
	}
	s.domStar = strings.HasPrefix(fields[2], "*")
	s.dowStar = strings.HasPrefix(fields[4], "*")
	return s, nil
}

// parseField returns the values (not yet folded: day-of-week may contain 7) a field selects.
func parseField(idx int, field string) ([]int, error) {
	spec := fieldSpecs[idx]
	bad := func(format string, a ...any) ([]int, error) {
		return nil, fmt.Errorf("%s field %q %s", spec.name, field, fmt.Sprintf(format, a...))
	}
	var out []int
	for _, item := range strings.Split(field, ",") {
		if !itemRE.MatchString(item) {
			return bad("is not a cron field")
		}
		base, stepStr, hasStep := strings.Cut(item, "/")
		lo, hi := spec.lo, spec.hi
		switch {
		case base == "*":
			// whole field
		case strings.Contains(base, "-"):
			as, bs, _ := strings.Cut(base, "-")
			a, _ := strconv.Atoi(as)
			b, _ := strconv.Atoi(bs)
			if a < spec.lo || a > spec.hi || b < spec.lo || b > spec.hi {
				return bad("is out of range (must be %d-%d)", spec.lo, spec.hi)
			}
			if a > b {
				return bad("has a reversed range %q", base)
			}
			lo, hi = a, b
		default:
			if hasStep {
				return bad("has a step %q on a single number", "/"+stepStr)
			}
			n, _ := strconv.Atoi(base)
			if n < spec.lo || n > spec.hi {
				return bad("is out of range (must be %d-%d)", spec.lo, spec.hi)
			}
			lo, hi = n, n
		}
		step := 1
		if hasStep {
			n, _ := strconv.Atoi(stepStr)
			if n < 1 {
				return bad("has a step of zero")
			}
			if n > spec.hi-spec.lo {
				return bad("has a step %q larger than the range %d-%d", "/"+stepStr, spec.lo, spec.hi)
			}
			step = n
		}
		for v := lo; v <= hi; v += step {
			out = append(out, v)
		}
	}
	return out, nil
}

// dayMatches applies the Vixie day rule to a civil date.
func (s *Schedule) dayMatches(month time.Month, day int, wd time.Weekday) bool {
	if !s.months[int(month)] {
		return false
	}
	domOK := s.doms[day]
	dowOK := s.dows[int(wd)]
	if s.domStar || s.dowStar {
		return domOK && dowOK
	}
	return domOK || dowOK
}

// instants returns the earliest real instant whose wall clock in loc reads the given civil time, and false
// when the wall time does not exist (spring-forward gap). A repeated wall time (autumn fall-back) resolves
// to the first occurrence.
func instants(year int, month time.Month, day, hour, minute int, loc *time.Location) (time.Time, bool) {
	civil := time.Date(year, month, day, hour, minute, 0, 0, time.UTC)
	var best time.Time
	found := false
	seen := map[int]bool{}
	for _, probe := range []time.Duration{-36 * time.Hour, 36 * time.Hour} {
		_, off := civil.Add(probe).In(loc).Zone()
		if seen[off] {
			continue
		}
		seen[off] = true
		cand := civil.Add(-time.Duration(off) * time.Second)
		l := cand.In(loc)
		if l.Year() != year || l.Month() != month || l.Day() != day || l.Hour() != hour || l.Minute() != minute {
			continue
		}
		if !found || cand.Before(best) {
			best, found = cand, true
		}
	}
	return best, found
}

// Next returns the first fire instant strictly after `after`, evaluated in loc, at second 0 of the cron
// minute (the runner adds its per-job offset itself). It returns the zero Time when no fire exists within
// eight years. A time in a spring-forward gap does not fire that day; a repeated autumn time fires once, at
// the first occurrence.
func (s *Schedule) Next(after time.Time, loc *time.Location) time.Time {
	local := after.In(loc)
	day := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, time.UTC)
	for i := 0; i <= maxSearchDays; i, day = i+1, day.AddDate(0, 0, 1) {
		y, m, d := day.Date()
		if !s.dayMatches(m, d, day.Weekday()) {
			continue
		}
		for h := 0; h < 24; h++ {
			if !s.hours[h] {
				continue
			}
			for mi := 0; mi < 60; mi++ {
				if !s.minutes[mi] {
					continue
				}
				t, ok := instants(y, m, d, h, mi, loc)
				if ok && t.After(after) {
					return t.In(loc)
				}
			}
		}
	}
	return time.Time{}
}
