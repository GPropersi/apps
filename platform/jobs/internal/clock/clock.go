// Package clock is the one place the runner touches wall-clock time, timers and randomness.
//
// Every other package takes a Clock (and a Jitter) so tests advance time deterministically and never sleep.
// TestNoDirectTimeUse fails when a non-test file outside real.go calls time.Now, time.After, time.NewTicker,
// time.Sleep, time.Tick, time.NewTimer, time.AfterFunc or a random source directly.
package clock

import "time"

// Clock covers reads and timers.
type Clock interface {
	// Now returns the current time.
	Now() time.Time
	// After returns a channel that receives once, after d.
	After(d time.Duration) <-chan time.Time
	// NewTicker returns a repeating ticker with period d (d must be > 0).
	NewTicker(d time.Duration) Ticker
}

// Ticker is a stoppable repeating channel. After Stop returns, the ticker never fires again.
type Ticker interface {
	C() <-chan time.Time
	Stop()
}

// Jitter returns a factor in [-0.2, +0.2] to scale a delay by (delay * (1 + factor)).
type Jitter func() float64

// MaxJitter is the largest magnitude a Jitter may return.
const MaxJitter = 0.2

// FixedJitter returns a Jitter that always returns f (tests).
func FixedJitter(f float64) Jitter {
	return func() float64 { return f }
}
