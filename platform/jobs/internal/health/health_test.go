package health

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
)

var base = time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)

func line(hb time.Time) string {
	return base.Add(-time.Hour).Format(time.RFC3339) + "\t" + hb.Format(time.RFC3339) + "\tok\tok\tok\tv1\n"
}

func write(t *testing.T, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "runner.tsv")
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestCheck(t *testing.T) {
	clk := clock.NewFake(base)
	cases := []struct {
		name    string
		content string
		ok      bool
	}{
		{"fresh", line(base.Add(-10 * time.Second)), true},
		{"just under 60s", line(base.Add(-59 * time.Second)), true},
		{"61s old", line(base.Add(-61 * time.Second)), false},
		{"far future", line(base.Add(48 * time.Hour)), false},
		{"empty", "", false},
		{"partial line", base.Format(time.RFC3339) + "\t" + base.Format(time.RFC3339) + "\tok\n", false},
		{"seven fields", base.Format(time.RFC3339) + "\t" + base.Format(time.RFC3339) + "\tok\tok\tok\tv\textra\n", false},
		{"garbled", "\x00\xff garbage", false},
		{"bad timestamp", "a\tnot-a-time\tok\tok\tok\tv\n", false},
		{"non-UTC offset", "a\t" + base.Format("2006-01-02T15:04:05+00:00") + "\tok\tok\tok\tv\n", false},
		{"two lines", line(base) + line(base), false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			err := Check(clk, write(t, c.content))
			if c.ok && err != nil {
				t.Fatalf("want ok, got %v", err)
			}
			if !c.ok && err == nil {
				t.Fatal("want failure, got ok")
			}
		})
	}
}

func TestCheckMissingFile(t *testing.T) {
	if err := Check(clock.NewFake(base), filepath.Join(t.TempDir(), "absent.tsv")); err == nil {
		t.Fatal("want failure for a missing file")
	}
}

func TestCheckBoundary(t *testing.T) {
	clk := clock.NewFake(base)
	if err := Check(clk, write(t, line(base.Add(-MaxAge)))); err == nil {
		t.Fatal("exactly 60s old must fail")
	}
}
