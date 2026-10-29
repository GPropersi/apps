// Package window reads the backup window (platform/backup/window.env) with the exact rules of backup.sh
// load_window, but fails closed: any defect is an error, never "disabled".
//
// Load is a function of the path and caches nothing; callers invoke it by name on every window decision.
package window

import (
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"
	_ "time/tzdata" // the runner image has no zoneinfo; the zone database is embedded
)

const (
	keyStart = "BACKUP_WINDOW_START"
	keyEnd   = "BACKUP_WINDOW_END"
	keyTZ    = "BACKUP_WINDOW_TZ"
)

var (
	hhmmRE = regexp.MustCompile(`^([01][0-9]|2[0-3]):[0-5][0-9]$`)
	tzRE   = regexp.MustCompile(`^[A-Za-z0-9_/+-]+$`)
)

// Window is a parsed, valid backup window: the half-open range [Start, End) of wall-clock minutes of the day
// in Loc. It never wraps midnight (Start < End).
type Window struct {
	Start string // "HH:MM"
	End   string // "HH:MM"
	TZ    string
	Loc   *time.Location

	startMin, endMin int
}

// Load reads and validates the window file at path.
func Load(path string) (Window, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Window{}, fmt.Errorf("window file unreadable: %w", err)
	}
	return Parse(b)
}

// Parse validates window.env content. Rules, as in backup.sh load_window: lines are read literally (no
// trimming); empty lines and lines starting with # are skipped; every other line must be KEY=VALUE with a key
// that is one of the three known ones, each at most once; START and END are HH:MM; START < END; TZ matches
// [A-Za-z0-9_/+-]+ and names a known zone.
func Parse(b []byte) (Window, error) {
	if strings.IndexByte(string(b), 0) >= 0 {
		return Window{}, fmt.Errorf("window file contains a NUL byte")
	}
	var s, e, z string
	seen := map[string]bool{}
	lines := strings.Split(string(b), "\n")
	if lines[len(lines)-1] == "" { // the final LF; an unterminated last line is still read
		lines = lines[:len(lines)-1]
	}
	for _, line := range lines {
		if line == "" || line[0] == '#' {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			return Window{}, fmt.Errorf("window file has a malformed line")
		}
		if seen[key] {
			return Window{}, fmt.Errorf("window file repeats %s", key)
		}
		seen[key] = true
		switch key {
		case keyStart:
			s = val
		case keyEnd:
			e = val
		case keyTZ:
			z = val
		default:
			return Window{}, fmt.Errorf("window file has an unknown key")
		}
	}
	for _, k := range []string{keyStart, keyEnd, keyTZ} {
		if !seen[k] {
			return Window{}, fmt.Errorf("window file is missing %s", k)
		}
	}
	if !hhmmRE.MatchString(s) {
		return Window{}, fmt.Errorf("%s %q is not HH:MM", keyStart, s)
	}
	if !hhmmRE.MatchString(e) {
		return Window{}, fmt.Errorf("%s %q is not HH:MM", keyEnd, e)
	}
	if !tzRE.MatchString(z) {
		return Window{}, fmt.Errorf("%s %q has characters outside [A-Za-z0-9_/+-]", keyTZ, z)
	}
	if !(s < e) {
		return Window{}, fmt.Errorf("window START %s must be before END %s (no midnight wrap)", s, e)
	}
	if z == "Local" {
		return Window{}, fmt.Errorf("%s %q is not an explicit zone", keyTZ, z)
	}
	loc, err := time.LoadLocation(z)
	if err != nil {
		return Window{}, fmt.Errorf("%s %q is not a known zone: %w", keyTZ, z, err)
	}
	return Window{Start: s, End: e, TZ: z, Loc: loc, startMin: minutes(s), endMin: minutes(e)}, nil
}

// StartOn returns the instant the window starts on t's civil date in the window zone.
func (w Window) StartOn(t time.Time) time.Time { return w.at(t, w.startMin) }

// EndOn returns the instant the window ends on t's civil date in the window zone.
func (w Window) EndOn(t time.Time) time.Time { return w.at(t, w.endMin) }

func (w Window) at(t time.Time, min int) time.Time {
	l := t.In(w.Loc)
	return time.Date(l.Year(), l.Month(), l.Day(), min/60, min%60, 0, 0, w.Loc)
}

// Refuses reports whether a run that begins at fire and may last timeout must not start: fire is inside
// [Start, End), or fire is before Start on the same day and fire+timeout is after Start (a run that ends exactly
// as the window opens is allowed).
func (w Window) Refuses(fire time.Time, timeout time.Duration) bool {
	if w.Contains(fire) {
		return true
	}
	start := w.StartOn(fire)
	return fire.Before(start) && fire.Add(timeout).After(start)
}

func minutes(hhmm string) int {
	return int(hhmm[0]-'0')*600 + int(hhmm[1]-'0')*60 + int(hhmm[3]-'0')*10 + int(hhmm[4]-'0')
}

// Contains reports whether t's wall-clock time in the window zone is in [Start, End): 04:59:59 is inside a
// window ending 05:00, 05:00:00 is not.
func (w Window) Contains(t time.Time) bool {
	l := t.In(w.Loc)
	m := l.Hour()*60 + l.Minute()
	return m >= w.startMin && m < w.endMin
}
