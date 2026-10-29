package queue

import (
	"github.com/gpropersi/apps/platform/jobs/internal/mask"
)

// takeAll gives every enabled, unparked app one turn, round-robin, and reports whether anything was taken.
func (c *Consumer) takeAll() bool {
	apps := c.enabledApps()
	if len(apps) == 0 {
		return false
	}
	start := c.rr % len(apps)
	c.rr++
	took := false
	for i := range apps {
		if c.down() {
			break
		}
		if c.takeApp(apps[(start+i)%len(apps)]) {
			took = true
		}
	}
	return took
}

// hasMoveBack reports a pending move-back: until it lands the item is not in the queue, so a later item must not
// jump ahead of it.
func (st *appState) hasMoveBack() bool {
	for _, w := range st.pending {
		if w.kind == wBack {
			return true
		}
	}
	return false
}

// gateOK applies the take-time conditions to a valid head: its jobs-secret is readable now and the window.env read
// is valid and allows the job for its timeout. (The app is enabled and unparked, and the job is not in flight,
// which TryAcquire checks.) A head that fails is not taken: no cap slot, no LMOVE, no attempt, nothing recorded.
func (c *Consumer) gateOK(app string, env *Envelope) (JobSpec, bool) {
	spec, ok := c.cfg.Registry.Job(app, env.Job)
	if !ok || !c.secretReadable(app) {
		return spec, false
	}
	return spec, c.cfg.Registry.WindowGate(spec.Timeout) == WindowAllow
}

// takeApp takes at most one item of one app. It reports whether an item was moved to processing.
func (c *Consumer) takeApp(app string) bool {
	st := c.st(app)
	if st.parked != nil || !st.recovered || st.recovering > 0 || st.hasMoveBack() || c.now().Before(st.nextTake) {
		return false
	}
	queue, proc := qkey(app, "queue"), qkey(app, "processing")
	raw, found, err := c.s.LIndexLast(c.root, queue)
	c.observe(err)
	if err != nil {
		c.takeErr(st, "LINDEX", err)
		return false
	}
	if !found {
		st.takeFails = 0
		return false
	}
	v := Validate(raw, c.declaredFor(app))
	var release func()
	var spec JobSpec
	if v.Valid() {
		var ok bool
		if spec, ok = c.gateOK(app, v.Env); !ok {
			return false // waits at the head; head-of-line waiting is intentional
		}
		if release, ok = c.cfg.Registry.TryAcquire(app, v.Env.Job); !ok {
			return false
		}
	}
	// An invalid, oversize or undeclared head skips the gate: it has no usable job timeout or in-flight state.
	if c.afterPeek != nil {
		c.afterPeek(app)
	}
	moved, found, err := c.s.LMove(c.root, queue, proc, "RIGHT", "LEFT")
	c.observe(err)
	if err != nil || !found {
		if release != nil { // a nil reply or an error must not pin a cap slot while it backs off
			release()
		}
		if err != nil {
			if Classify(err).Conn {
				// The LMOVE may have been applied: an item could sit in processing with nothing tracking it, so
				// recovery must run again.
				st.recovered = false
			}
			c.takeErr(st, "LMOVE", err)
		}
		return false
	}
	st.takeFails = 0
	c.wroteOK()
	if moved == raw {
		if !v.Valid() {
			c.deadFromTake(st, moved, v)
			return true
		}
		c.dispatchRun(task{app: app, raw: moved, env: v.Env, spec: spec, release: release})
		return true
	}
	// The right end changed between the peek and the LMOVE: what moved is a new head. Nothing may run on a gate
	// evaluated for a different job.
	if release != nil {
		release()
	}
	c.logf("lmove mismatch app=%s: the moved item differs from the peeked one, re-gating it", app)
	v2 := Validate(moved, c.declaredFor(app))
	if !v2.Valid() {
		c.deadFromTake(st, moved, v2)
		return true
	}
	if spec2, ok := c.gateOK(app, v2.Env); ok {
		if rel2, ok := c.cfg.Registry.TryAcquire(app, v2.Env.Job); ok {
			c.dispatchRun(task{app: app, raw: moved, env: v2.Env, spec: spec2, release: rel2})
			return true
		}
	}
	c.moveBack(st, moved, v2)
	return true
}

// deadFromTake dead-lettering of an item the take path just moved to processing.
func (c *Consumer) deadFromTake(st *appState, raw string, v Verdict) {
	attempts := 0
	if v.Env != nil {
		attempts = v.Env.Attempt
	}
	c.addWrite(st, c.newDeadWrite(st.name, raw, v, v.Reason, attempts, v.Detail, false))
}

// moveBack returns a moved-but-not-runnable item to the head of the queue, unchanged.
func (c *Consumer) moveBack(st *appState, raw string, v Verdict) {
	w := &write{app: st.name, job: orDash(v.Job), raw: raw, kind: wBack, newBusy: true, envID: v.ID}
	c.addWrite(st, w)
}

// takeErr handles an error of a take-phase command: transient errors back the app off, deterministic ones park it.
func (c *Consumer) takeErr(st *appState, cmd string, err error) {
	if c.root.Err() != nil { // shutting down: a cancelled call is not a Redis fault
		return
	}
	cl := Classify(err)
	if cl.Kind == KindDeterministic {
		c.park(st, &write{app: st.name}, cmd, err)
		return
	}
	delay := c.backoff(st.takeFails)
	st.takeFails++
	st.nextTake = c.now().Add(delay)
	if cl.OOM {
		c.noteOOM(st.name, cmd, st.takeFails, delay)
		return
	}
	c.logf("take retry app=%s command=%s attempt=%d next_delay=%s err=%q", st.name, cmd, st.takeFails, delay, mask.Text(err.Error()))
}

// ---- promotion ----

// promote moves the due items of every enabled, unparked app's delayed set to the head of its queue, one MULTI/EXEC
// per item (ZREM + RPUSH), so a promoted retry runs next.
func (c *Consumer) promote() {
	for _, app := range c.enabledApps() {
		if c.down() {
			return
		}
		st := c.st(app)
		if st.parked != nil {
			continue
		}
		due, err := c.s.ZRangeDue(c.root, qkey(app, "delayed"), c.now().Unix(), promoteBatch)
		c.observe(err)
		if err != nil {
			c.promoteErr(st, "ZRANGEBYSCORE", err, "")
			continue
		}
		for _, raw := range due {
			if c.down() || st.parked != nil {
				break
			}
			if err := c.typeCheck(app, "queue"); err != nil {
				c.promoteErr(st, "TYPE", err, raw)
				break
			}
			if c.beforeExec != nil {
				c.beforeExec(app)
			}
			replies, err := c.s.Exec(c.root, []Cmd{
				{Name: "ZREM", Args: []string{qkey(app, "delayed"), raw}},
				{Name: "RPUSH", Args: []string{qkey(app, "queue"), raw}},
			})
			c.observe(err)
			if err != nil {
				c.promoteErr(st, "EXEC", err, raw)
				break
			}
			var first error
			applied := 0
			for _, e := range replies {
				if e == nil {
					applied++
				} else if first == nil {
					first = e
				}
			}
			if first != nil {
				if applied > 0 {
					c.logf("partial EXEC applied app=%s command=promote applied=%d failed=%q item: %s", app, applied, mask.Text(first.Error()), rawSummary(raw))
				}
				c.promoteErr(st, "EXEC", first, raw)
				break
			}
		}
	}
}

// promoteErr sorts an error of a promotion: transient ones wait for the next tick (the item stays in delayed),
// deterministic ones park the app.
func (c *Consumer) promoteErr(st *appState, cmd string, err error, raw string) {
	if c.root.Err() != nil { // shutting down: a cancelled call is not a Redis fault
		return
	}
	cl := Classify(err)
	if cl.Kind == KindDeterministic {
		c.park(st, &write{app: st.name, raw: raw}, cmd, err)
		return
	}
	if cl.OOM {
		c.noteOOM(st.name, "promote "+cmd, 1, PromoteEvery)
		return
	}
	c.logf("promote retry app=%s command=%s next=%s err=%q", st.name, cmd, PromoteEvery, mask.Text(err.Error()))
}
