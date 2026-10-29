package window

import (
	"testing"
	"time"
)

func TestRefusesAndEndOn(t *testing.T) {
	w, err := Parse([]byte("BACKUP_WINDOW_START=03:30\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=America/Los_Angeles\n"))
	if err != nil {
		t.Fatal(err)
	}
	at := func(h, m, s int) time.Time { return time.Date(2026, 3, 4, h, m, s, 0, w.Loc) }
	cases := []struct {
		name    string
		fire    time.Time
		timeout time.Duration
		want    bool
	}{
		{"inside", at(3, 40, 0), 5 * time.Second, true},
		{"at start", at(3, 30, 0), time.Second, true},
		{"last second inside", at(4, 59, 59), time.Second, true},
		{"at end", at(5, 0, 0), time.Hour, false},
		{"before, ends before start", at(3, 0, 0), 29 * time.Minute, false},
		{"before, ends exactly at start", at(3, 0, 0), 30 * time.Minute, false},
		{"before, crosses start", at(3, 10, 0), 30 * time.Minute, true},
		{"after the window", at(7, 0, 0), time.Hour, false},
		{"earlier in the day, short", at(1, 0, 0), time.Minute, false},
	}
	for _, c := range cases {
		if got := w.Refuses(c.fire, c.timeout); got != c.want {
			t.Errorf("%s: Refuses = %v, want %v", c.name, got, c.want)
		}
	}
	if got := w.EndOn(at(3, 10, 0)); !got.Equal(at(5, 0, 0)) {
		t.Errorf("EndOn = %v", got)
	}
	if got := w.StartOn(at(23, 0, 0)); !got.Equal(at(3, 30, 0)) {
		t.Errorf("StartOn = %v", got)
	}
}
