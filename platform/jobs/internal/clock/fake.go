package clock

import (
	"sort"
	"sync"
	"time"
)

// tickerBuffer is the fake ticker's channel capacity, so a test that advances several periods at once can
// read every tick (a real ticker would drop them for a slow reader).
const tickerBuffer = 1024

// Fake is a deterministic Clock for tests. Time moves only on Advance; timers fire in deadline order (ties by
// creation order), never early, and a stopped ticker never fires again.
type Fake struct {
	mu     sync.Mutex
	now    time.Time
	seq    int
	timers []*fakeTimer
	// onFire, when set, is called (under no lock) for every fire, in order. Tests of this package use it.
	onFire func(seq int, deadline time.Time)
}

type fakeTimer struct {
	seq      int
	deadline time.Time
	period   time.Duration // 0 for a one-shot
	ch       chan time.Time
	stopped  bool
}

// NewFake returns a Fake whose Now() is start.
func NewFake(start time.Time) *Fake {
	return &Fake{now: start}
}

// Now returns the fake time.
func (f *Fake) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now
}

// After returns a channel that receives once the fake time reaches now+d. d <= 0 fires immediately.
func (f *Fake) After(d time.Duration) <-chan time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	ch := make(chan time.Time, 1)
	if d <= 0 {
		ch <- f.now
		return ch
	}
	f.seq++
	f.timers = append(f.timers, &fakeTimer{seq: f.seq, deadline: f.now.Add(d), ch: ch})
	return ch
}

// NewTicker returns a ticker that fires once per elapsed period of fake time. It panics when d <= 0, like
// time.NewTicker.
func (f *Fake) NewTicker(d time.Duration) Ticker {
	if d <= 0 {
		panic("clock: non-positive interval for NewTicker")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.seq++
	t := &fakeTimer{seq: f.seq, deadline: f.now.Add(d), period: d, ch: make(chan time.Time, tickerBuffer)}
	f.timers = append(f.timers, t)
	return &fakeTicker{f: f, t: t}
}

// Jump moves the fake wall clock by d without firing any timer, like an NTP step or a resume from suspend: real
// timers run on the monotonic clock and do not notice. The next Advance fires the timers that are now overdue.
func (f *Fake) Jump(d time.Duration) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.now = f.now.Add(d)
}

// Pending returns the number of armed timers and tickers (tests use it to wait for a goroutine to arm one).
func (f *Fake) Pending() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, t := range f.timers {
		if !t.stopped {
			n++
		}
	}
	return n
}

// Advance moves the fake time forward by d, firing every timer whose deadline falls in (now, now+d] in
// deadline order. Now() reads the timer's deadline while it fires and now+d afterwards.
func (f *Fake) Advance(d time.Duration) {
	if d < 0 {
		panic("clock: negative Advance")
	}
	f.mu.Lock()
	target := f.now.Add(d)
	f.mu.Unlock()
	for {
		f.mu.Lock()
		t := f.nextDue(target)
		if t == nil {
			if target.After(f.now) { // never move time backwards under a concurrent Advance
				f.now = target
			}
			f.mu.Unlock()
			return
		}
		if t.deadline.After(f.now) {
			f.now = t.deadline
		}
		fired := t.deadline
		seq := t.seq
		select {
		case t.ch <- fired:
		default: // a full ticker buffer drops the tick, like a real ticker
		}
		if t.period > 0 {
			t.deadline = t.deadline.Add(t.period)
		} else {
			t.stopped = true
		}
		f.prune()
		hook := f.onFire
		f.mu.Unlock()
		if hook != nil {
			hook(seq, fired)
		}
	}
}

// nextDue returns the live timer with the earliest deadline <= target (lowest seq on a tie), or nil.
// The caller holds f.mu.
func (f *Fake) nextDue(target time.Time) *fakeTimer {
	live := make([]*fakeTimer, 0, len(f.timers))
	for _, t := range f.timers {
		if !t.stopped && !t.deadline.After(target) {
			live = append(live, t)
		}
	}
	if len(live) == 0 {
		return nil
	}
	sort.Slice(live, func(i, j int) bool {
		if live[i].deadline.Equal(live[j].deadline) {
			return live[i].seq < live[j].seq
		}
		return live[i].deadline.Before(live[j].deadline)
	})
	return live[0]
}

// prune drops stopped timers. The caller holds f.mu.
func (f *Fake) prune() {
	kept := f.timers[:0]
	for _, t := range f.timers {
		if !t.stopped {
			kept = append(kept, t)
		}
	}
	f.timers = kept
}

type fakeTicker struct {
	f *Fake
	t *fakeTimer
}

func (k *fakeTicker) C() <-chan time.Time { return k.t.ch }

func (k *fakeTicker) Stop() {
	k.f.mu.Lock()
	defer k.f.mu.Unlock()
	k.t.stopped = true
	for drained := false; !drained; { // like Go 1.23 tickers: no stale tick is readable after Stop
		select {
		case <-k.t.ch:
		default:
			drained = true
		}
	}
	k.f.prune()
}
