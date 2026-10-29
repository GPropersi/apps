package clock

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

var start = time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)

func recv(t *testing.T, ch <-chan time.Time) time.Time {
	t.Helper()
	select {
	case v := <-ch:
		return v
	default:
		t.Fatal("channel has nothing to receive")
		return time.Time{}
	}
}

func empty(t *testing.T, ch <-chan time.Time, what string) {
	t.Helper()
	select {
	case v := <-ch:
		t.Fatalf("%s fired early at %v", what, v)
	default:
	}
}

func TestAfterFiresOnlyOnAdvanceNeverEarly(t *testing.T) {
	f := NewFake(start)
	ch := f.After(10 * time.Second)
	empty(t, ch, "After")
	f.Advance(9 * time.Second)
	empty(t, ch, "After")
	f.Advance(time.Second)
	if got := recv(t, ch); !got.Equal(start.Add(10 * time.Second)) {
		t.Fatalf("After delivered %v", got)
	}
	f.Advance(time.Hour)
	empty(t, ch, "After (one-shot)")
}

func TestAfterNonPositiveFiresImmediately(t *testing.T) {
	f := NewFake(start)
	recv(t, f.After(0))
	recv(t, f.After(-time.Second))
}

func TestTickerFiresOncePerElapsedPeriod(t *testing.T) {
	f := NewFake(start)
	tk := f.NewTicker(15 * time.Second)
	f.Advance(14 * time.Second)
	empty(t, tk.C(), "ticker")
	f.Advance(time.Second)
	recv(t, tk.C())
	f.Advance(45 * time.Second)
	for i := 1; i <= 3; i++ {
		want := start.Add(time.Duration(15*(i+1)) * time.Second)
		if got := recv(t, tk.C()); !got.Equal(want) {
			t.Fatalf("tick %d at %v, want %v", i, got, want)
		}
	}
	empty(t, tk.C(), "ticker")
}

func TestStoppedTickerNeverFiresAgain(t *testing.T) {
	f := NewFake(start)
	tk := f.NewTicker(time.Second)
	f.Advance(time.Second)
	recv(t, tk.C())
	tk.Stop()
	f.Advance(time.Hour)
	empty(t, tk.C(), "stopped ticker")
	if f.Pending() != 0 {
		t.Fatalf("Pending = %d after Stop", f.Pending())
	}
}

func TestNowFollowsAdvance(t *testing.T) {
	f := NewFake(start)
	f.Advance(4 * time.Minute)
	f.Advance(time.Minute)
	if !f.Now().Equal(start.Add(5 * time.Minute)) {
		t.Fatalf("Now = %v", f.Now())
	}
}

func TestTimersFireInDeadlineOrderTiesByCreation(t *testing.T) {
	f := NewFake(start)
	var order []int
	f.onFire = func(seq int, _ time.Time) { order = append(order, seq) }
	f.After(30 * time.Second)     // seq 1
	f.After(10 * time.Second)     // seq 2
	f.NewTicker(10 * time.Second) // seq 3, fires at 10s and 20s and 30s
	f.After(10 * time.Second)     // seq 4
	f.Advance(time.Minute)
	want := []int{2, 3, 4, 3, 1, 3, 3, 3, 3} // the ticker fires at 10s..60s; at 30s seq 1 wins the tie
	if len(order) != len(want) {
		t.Fatalf("fire order %v, want %v", order, want)
	}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("fire order %v, want %v", order, want)
		}
	}
}

func TestNowReadsDeadlineWhileFiring(t *testing.T) {
	f := NewFake(start)
	var seen []time.Time
	f.onFire = func(_ int, d time.Time) { seen = append(seen, d) }
	f.After(time.Second)
	f.After(3 * time.Second)
	f.Advance(10 * time.Second)
	if len(seen) != 2 || !seen[0].Equal(start.Add(time.Second)) || !seen[1].Equal(start.Add(3*time.Second)) {
		t.Fatalf("deadlines %v", seen)
	}
	if !f.Now().Equal(start.Add(10 * time.Second)) {
		t.Fatalf("Now = %v", f.Now())
	}
}

func TestRandomJitterStaysWithinTwentyPercent(t *testing.T) {
	sawNeg, sawPos := false, false
	for i := 0; i < 20000; i++ {
		j := RandomJitter()
		if j < -MaxJitter || j > MaxJitter {
			t.Fatalf("jitter %v outside +-%v", j, MaxJitter)
		}
		sawNeg = sawNeg || j < 0
		sawPos = sawPos || j > 0
	}
	if !sawNeg || !sawPos {
		t.Fatal("production jitter never varied in sign")
	}
}

func TestFixedJitter(t *testing.T) {
	if got := FixedJitter(0.1)(); got != 0.1 {
		t.Fatalf("FixedJitter = %v", got)
	}
}

func TestRealClockBasics(t *testing.T) {
	var c Clock = Real{}
	if time.Since(c.Now()) > time.Minute {
		t.Fatal("Real.Now is far from the wall clock")
	}
	select {
	case <-c.After(time.Millisecond):
	case <-time.After(5 * time.Second):
		t.Fatal("Real.After never fired")
	}
	tk := c.NewTicker(time.Millisecond)
	select {
	case <-tk.C():
	case <-time.After(5 * time.Second):
		t.Fatal("Real ticker never fired")
	}
	tk.Stop()
}

// forbidden are the direct time and randomness entry points only real.go may use.
var forbidden = regexp.MustCompile(`\btime\.(Now|After|AfterFunc|Tick|NewTicker|NewTimer|Sleep|Since|Until)\b|context\.With(Timeout|Deadline)\(|"math/rand(/v2)?"|"crypto/rand"`)

func TestNoDirectTimeUse(t *testing.T) {
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	checked := 0
	err = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		if filepath.Base(path) == "real.go" && filepath.Base(filepath.Dir(path)) == "clock" {
			return nil
		}
		checked++
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for i, line := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "//") {
				continue
			}
			if m := forbidden.FindString(line); m != "" {
				t.Errorf("%s:%d uses %q directly; go through clock.Clock/clock.Jitter", path, i+1, m)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if checked == 0 {
		t.Fatal("scanned no Go files; the guard is not looking at the module")
	}
}
