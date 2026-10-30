package queue

import (
	"fmt"
)

// recoverApps runs recovery for each enabled, unparked app that is due for it, before that app's next peek.
//
// Trigger, per app: on runner start, and on each transition of the app to enabled (a disabled app whose file or
// secret was fixed, an app added after start, an app un-parked after a deterministic write error). The flag is
// cleared whenever the app leaves enabled or is parked (enabledApps does that) and set when recovery has run.
// Recovery waits while the runner holds an in-flight queued item or a pending completion write for the app, so an
// item whose result write is still pending is never re-delivered.
func (c *Consumer) recoverApps() {
	for _, app := range c.enabledApps() {
		if c.down() {
			return
		}
		st := c.st(app)
		if st.parked != nil || st.recovered || st.busy > 0 || len(st.pending) > 0 || c.now().Before(st.nextTake) {
			continue
		}
		c.recoverApp(st)
	}
}

// recoverApp reads the app's processing list and queues one completion write per leftover item. Items go through
// the same Validate as the take path: an invalid, oversize (never parsed) or undeclared item is dead-lettered with
// its normal reason and never given attempt + 1; a valid one goes back to the head of the queue with attempt + 1,
// or is dead-lettered with retries_exhausted when that would exceed MaxAttempts. The list is read leftmost (newest)
// first and pushed in that order, so the oldest ends at the head of the queue.
func (c *Consumer) recoverApp(st *appState) {
	app := st.name
	items, err := c.s.LRangeAll(c.root, qkey(app, "processing"))
	c.observe(err)
	if err != nil {
		c.takeErr(st, "LRANGE", err)
		return
	}
	st.recovered = true
	if len(items) > 0 {
		c.logf("recovery app=%s items=%d", app, len(items))
	}
	declared := c.declaredFor(app)
	for _, raw := range items {
		v := Validate(raw, declared)
		if !v.Valid() {
			c.addWrite(st, c.newDeadWrite(app, raw, v, v.Reason, 0, v.Detail, true))
			continue
		}
		n := v.Env.Attempt
		if n+1 > MaxAttempts {
			c.addWrite(st, c.newDeadWrite(app, raw, v, ReasonExhausted, n, fmt.Sprintf("runner crashed during attempt %d", n), true))
			continue
		}
		w := &write{
			app: app, job: v.Env.Job, raw: raw, kind: wRequeue, envID: v.ID, recovery: true, newBusy: true,
			newRaw: v.Env.Encode(n+1, fmt.Sprintf("runner crashed during attempt %d", n)),
		}
		c.addWrite(st, w)
	}
}
