package clock

import (
	crand "crypto/rand"
	"math/rand/v2"
	"time"
)

const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// NewULID returns a 26-character ULID: a 48-bit millisecond timestamp followed by 80 random bits, in Crockford
// base32. It lives here because only this file may touch a random source.
func NewULID(now time.Time) string {
	var b [16]byte
	ms := uint64(now.UnixMilli())
	for i := 0; i < 6; i++ {
		b[i] = byte(ms >> (8 * uint(5-i)))
	}
	_, _ = crand.Read(b[6:])
	var out [26]byte
	for i := range out {
		var v byte
		for k := 0; k < 5; k++ {
			bit := i*5 + k - 2 // 130 bits: two zero bits in front of the 128
			v <<= 1
			if bit >= 0 {
				v |= (b[bit/8] >> (7 - uint(bit%8))) & 1
			}
		}
		out[i] = crockford[v]
	}
	return string(out[:])
}

// Real is the production Clock, backed by the time package.
type Real struct{}

// Now returns the current wall-clock time. Round(0) strips the monotonic reading, so the difference of two Now
// values is a wall-clock difference and an NTP step or a resume from suspend is visible to the scheduler.
func (Real) Now() time.Time { return time.Now().Round(0) }

// After wraps time.After.
func (Real) After(d time.Duration) <-chan time.Time { return time.After(d) }

// NewTicker wraps time.NewTicker.
func (Real) NewTicker(d time.Duration) Ticker { return realTicker{t: time.NewTicker(d)} }

type realTicker struct{ t *time.Ticker }

func (r realTicker) C() <-chan time.Time { return r.t.C }
func (r realTicker) Stop()               { r.t.Stop() }

// RandomJitter is the production Jitter: uniform in [-MaxJitter, +MaxJitter).
func RandomJitter() float64 {
	return (rand.Float64()*2 - 1) * MaxJitter
}
