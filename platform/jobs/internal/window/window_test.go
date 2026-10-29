package window

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const good = "BACKUP_WINDOW_START=03:30\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=America/Los_Angeles\n"

func TestParseGood(t *testing.T) {
	w, err := Parse([]byte(good))
	if err != nil {
		t.Fatal(err)
	}
	if w.Start != "03:30" || w.End != "05:00" || w.TZ != "America/Los_Angeles" || w.Loc.String() != "America/Los_Angeles" {
		t.Fatalf("window = %+v", w)
	}
}

func TestParseAcceptsCommentsBlankLinesAndNoFinalNewline(t *testing.T) {
	in := "# note\n\nBACKUP_WINDOW_TZ=UTC\nBACKUP_WINDOW_START=00:00\nBACKUP_WINDOW_END=23:59"
	if _, err := Parse([]byte(in)); err != nil {
		t.Fatal(err)
	}
}

func TestParseRejectsEveryDefect(t *testing.T) {
	cases := map[string]string{
		"empty file":         "",
		"missing START":      "BACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=UTC\n",
		"missing END":        "BACKUP_WINDOW_START=03:30\nBACKUP_WINDOW_TZ=UTC\n",
		"missing TZ":         "BACKUP_WINDOW_START=03:30\nBACKUP_WINDOW_END=05:00\n",
		"duplicate key":      good + "BACKUP_WINDOW_END=06:00\n",
		"unknown key":        good + "EXTRA=1\n",
		"line without =":     good + "garbage\n",
		"indented comment":   good + " # c\n",
		"whitespace line":    good + " \n",
		"START equals END":   "BACKUP_WINDOW_START=04:00\nBACKUP_WINDOW_END=04:00\nBACKUP_WINDOW_TZ=UTC\n",
		"START after END":    "BACKUP_WINDOW_START=05:00\nBACKUP_WINDOW_END=03:30\nBACKUP_WINDOW_TZ=UTC\n",
		"midnight wrap":      "BACKUP_WINDOW_START=23:00\nBACKUP_WINDOW_END=01:00\nBACKUP_WINDOW_TZ=UTC\n",
		"bad hour":           "BACKUP_WINDOW_START=24:00\nBACKUP_WINDOW_END=25:00\nBACKUP_WINDOW_TZ=UTC\n",
		"bad minute":         "BACKUP_WINDOW_START=03:60\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=UTC\n",
		"one-digit hour":     "BACKUP_WINDOW_START=3:30\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=UTC\n",
		"padded value":       "BACKUP_WINDOW_START= 03:30\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=UTC\n",
		"CR line end":        "BACKUP_WINDOW_START=03:30\r\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=UTC\n",
		"empty zone":         "BACKUP_WINDOW_START=03:30\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=\n",
		"zone chars":         "BACKUP_WINDOW_START=03:30\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=Amer ica\n",
		"unknown zone":       "BACKUP_WINDOW_START=03:30\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=Mars/Olympus_Mons\n",
		"Local zone":         "BACKUP_WINDOW_START=03:30\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=Local\n",
		"path traversal":     "BACKUP_WINDOW_START=03:30\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=../etc/passwd\n",
		"NUL byte":           "BACKUP_WINDOW_START=03:30\x00\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=UTC\n",
		"lowercase key":      "backup_window_start=03:30\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=UTC\n",
		"START without HHMM": "BACKUP_WINDOW_START=\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=UTC\n",
	}
	for name, in := range cases {
		if w, err := Parse([]byte(in)); err == nil {
			t.Errorf("%s: parsed as %+v, want an error", name, w)
		}
	}
}

func TestLoadByPathReadsFreshEveryCall(t *testing.T) {
	p := filepath.Join(t.TempDir(), "window.env")
	if _, err := Load(p); err == nil {
		t.Fatal("missing file must be an error")
	}
	if err := os.WriteFile(p, []byte(good), 0o644); err != nil {
		t.Fatal(err)
	}
	w, err := Load(p)
	if err != nil || w.Start != "03:30" {
		t.Fatalf("Load = %+v, %v", w, err)
	}
	changed := strings.Replace(good, "03:30", "02:00", 1)
	if err := os.WriteFile(p, []byte(changed), 0o644); err != nil {
		t.Fatal(err)
	}
	w, err = Load(p)
	if err != nil || w.Start != "02:00" {
		t.Fatalf("Load after change = %+v, %v (nothing may be cached)", w, err)
	}
	if err := os.WriteFile(p, []byte("junk\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(p); err == nil {
		t.Fatal("a defective file must be an error, never disabled")
	}
}

func TestLoadRepoWindowEnv(t *testing.T) {
	w, err := Load("../../../backup/window.env")
	if err != nil {
		t.Fatalf("the tracked window.env must satisfy the reader: %v", err)
	}
	if w.TZ != "America/Los_Angeles" {
		t.Fatalf("TZ = %s", w.TZ)
	}
}

func TestContainsIsHalfOpenInTheWindowZone(t *testing.T) {
	w, err := Parse([]byte(good))
	if err != nil {
		t.Fatal(err)
	}
	la := w.Loc
	cases := []struct {
		t    time.Time
		want bool
	}{
		{time.Date(2026, 5, 4, 3, 29, 59, 0, la), false},
		{time.Date(2026, 5, 4, 3, 30, 0, 0, la), true},
		{time.Date(2026, 5, 4, 4, 59, 59, 0, la), true},
		{time.Date(2026, 5, 4, 5, 0, 0, 0, la), false},
		// 03:30 Los Angeles in July is 10:30 UTC: the zone, not UTC, decides.
		{time.Date(2026, 7, 4, 10, 30, 0, 0, time.UTC), true},
		{time.Date(2026, 7, 4, 3, 30, 0, 0, time.UTC), false},
	}
	for _, c := range cases {
		if got := w.Contains(c.t); got != c.want {
			t.Errorf("Contains(%v) = %v, want %v", c.t, got, c.want)
		}
	}
}
