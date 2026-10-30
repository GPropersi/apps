package queue

import (
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
)

// Backoff returns the delay before retry number n (0-based): 1s, 2s, 4s, ... capped at 30s, scaled by (1 + jitter).
// The completion writes, the take-phase errors and the Redis reconnect all use it. The jitter is clamped to the
// contract's +-20%.
func Backoff(n int, j clock.Jitter) time.Duration {
	d := BackoffCap
	if n < 6 { // 1s << 5 is already 32s
		d = BackoffInitial << uint(n)
		if d > BackoffCap {
			d = BackoffCap
		}
	}
	return scale(d, j)
}

func scale(d time.Duration, j clock.Jitter) time.Duration {
	f := 0.0
	if j != nil {
		f = j()
	}
	if f > clock.MaxJitter {
		f = clock.MaxJitter
	}
	if f < -clock.MaxJitter {
		f = -clock.MaxJitter
	}
	return time.Duration(float64(d) * (1 + f))
}

// RetryDelay is the delay before the retry that follows failed attempt n (1-4): 30s x 4^(n-1), +-20% jitter, at
// most one hour.
func RetryDelay(attempt int, j clock.Jitter) time.Duration {
	d := 30 * time.Second
	for i := 1; i < attempt; i++ {
		d *= 4
		if d > time.Hour {
			break
		}
	}
	d = scale(d, j)
	if d > time.Hour {
		d = time.Hour
	}
	return d
}

func (c *Consumer) backoff(n int) time.Duration { return Backoff(n, c.cfg.Jitter) }

// setRedis moves redis_state and alerts once per change.
func (c *Consumer) setRedis(state, why string) {
	if state == c.redisState {
		return
	}
	prev := c.redisState
	c.redisState = state
	if c.cfg.Status != nil {
		c.cfg.Status.SetRedis(state)
	}
	c.logf("redis state=%s prev=%s why=%q", state, prev, why)
	switch state {
	case "down":
		c.notify("Redis is unreachable, queued jobs are paused (scheduled jobs keep running): " + text(why))
	case "invalid":
		c.notify("Redis rejected the runner user (NOPERM or WRONGPASS), queued jobs are paused (scheduled jobs keep running): " + text(why))
	case "ok":
		c.notify("Redis is reachable again, queued jobs resume")
	}
}

// observe feeds the outcome of every store call into the connection state: a connection error moves redis_state
// to down, NOPERM/WRONGPASS to invalid, and any success back to ok. OOM is alert-only: redis_state stays ok.
func (c *Consumer) observe(err error) {
	if err == nil {
		c.markOK()
		return
	}
	cl := Classify(err)
	switch {
	case cl.Conn:
		c.enterBad("down", err)
	case cl.Kind == KindAuth:
		c.enterBad("invalid", err)
	default: // the server answered with an error: it is reachable and accepted the credentials
		c.redisFails = 0
		if c.redisState != "ok" {
			c.setRedis("ok", "")
		}
	}
}

func (c *Consumer) enterBad(state string, err error) {
	if c.redisState == "ok" {
		c.redisFails = 0
		c.redisNext = c.now().Add(c.backoff(0))
	}
	c.setRedis(state, err.Error())
}

func (c *Consumer) markOK() {
	c.redisFails = 0
	if c.redisState != "ok" {
		c.setRedis("ok", "")
	}
}

// wroteOK clears an OOM condition. Only a write command that Redis accepted proves it again takes writes; reads
// succeed under OOM and must not end it.
func (c *Consumer) wroteOK() {
	if c.oomActive {
		c.oomActive = false
		c.notify("Redis accepts writes again after an OOM rejection")
	}
}

// noteOOM alerts once per state change and logs every backoff cycle.
func (c *Consumer) noteOOM(app, cmd string, attempt int, next time.Duration) {
	c.logf("OOM app=%s command=%s attempt=%d next_delay=%s", app, cmd, attempt, next)
	if !c.oomActive {
		c.oomActive = true
		c.notify("Redis is out of memory (OOM): queue writes for " + app + " are being retried, nothing is lost")
	}
}

// down reports whether Redis work should stop for now.
func (c *Consumer) down() bool { return c.redisState != "ok" }

// redisGate lets a pass use Redis. While the state is down or invalid it probes once per backoff period.
func (c *Consumer) redisGate() bool {
	if c.redisState == "ok" {
		return true
	}
	now := c.now()
	if now.Before(c.redisNext) {
		return false
	}
	_, err := c.s.Type(c.root, probeKey)
	c.observe(err)
	if err != nil {
		c.redisFails++
		c.redisNext = now.Add(c.backoff(c.redisFails))
		c.logf("redis probe failed state=%s attempt=%d next=%s err=%q", c.redisState, c.redisFails, c.redisNext.UTC().Format(time.RFC3339), text(err.Error()))
		return false
	}
	return true
}
