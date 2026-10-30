package queue

import (
	"fmt"
	"sort"
	"strconv"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/dispatch"
	"github.com/gpropersi/apps/platform/jobs/internal/history"
)

type writeKind int

const (
	// wDone removes a finished item from processing.
	wDone writeKind = iota
	// wRetry removes the item from processing and schedules it in <app>:jobs:delayed.
	wRetry
	// wDead removes the item from processing and records it in <app>:jobs:dead.
	wDead
	// wBack returns an item from processing to the head of the queue without changing it (gate-fail).
	wBack
	// wRequeue returns a recovered item to the head of the queue with attempt + 1.
	wRequeue
)

type outcome int

const (
	outLanded outcome = iota
	outRetry
	outPark
)

// write is one completion write: the Redis change that follows a run, a dead-letter decision or a recovery step.
type write struct {
	app  string
	job  string // "-" when unknown
	raw  string // the exact bytes in processing; every LREM uses them
	kind writeKind

	// retry / requeue
	newRaw string
	due    time.Time

	// dead
	reason    string
	attempts  int
	lastError string
	envID     string
	deadAt    time.Time

	rec         history.Run // written once, when the write lands (zero Result: nothing to record)
	alertResult string      // non-empty: send a run alert when the write lands
	alertMsg    string

	release   func() // frees the cap slot and the in-flight mark; nil when none is held
	recovery  bool   // counts in appState.recovering
	newBusy   bool   // no worker was dispatched for it, so addWrite counts it in appState.busy
	attempted bool   // a first attempt was made: every later one checks LPOS first
	partial   bool   // an EXEC applied some commands but not all: the LPOS shortcut is unsound, the whole block is rerun
	fails     int    // consecutive failed attempts, for the backoff
	notBefore time.Time
}

// task is one queued run handed to a worker.
type task struct {
	app     string
	raw     string
	env     *Envelope
	spec    JobSpec
	release func()
}

// result is what a worker hands back.
type result struct {
	task     task
	runID    string
	res      dispatch.Result
	started  time.Time
	ended    time.Time
	gateFail bool
	rec      history.Run // the skip record of a gate-fail
}

type parkInfo struct {
	cmd       string
	err       string
	since     time.Time
	nextProbe time.Time
	lastLog   time.Time
}

// ---- workers ----

// dispatchRun starts a worker for a valid item that holds a cap slot and the in-flight mark.
func (c *Consumer) dispatchRun(t task) {
	c.st(t.app).busy++
	c.wg.Add(1)
	go c.work(t)
}

func (c *Consumer) work(t task) {
	defer c.wg.Done()
	r := result{task: t}
	switch c.cfg.Registry.WindowGate(t.spec.Timeout) {
	case WindowAllow:
		runID := c.newID()
		r.runID, r.started = runID, c.now()
		enq, _ := time.Parse(time.RFC3339, t.env.EnqueuedAt)
		r.res = c.cfg.Caller.Call(c.root, dispatch.Request{
			App: t.app, Port: t.spec.Port, Job: t.env.Job, Timeout: t.spec.Timeout, RunID: runID,
			Trigger: "queue", Attempt: t.env.Attempt, QueueID: t.env.ID, EnqueuedAt: enq, Payload: t.env.Payload,
		})
		r.ended = c.now()
		if r.res.NoSecret {
			r.gateFail = true
			r.rec = c.skipRec(t, "skipped_no_secret", r.res.Err)
		}
	case WindowInvalid:
		r.gateFail = true
		r.rec = c.skipRec(t, "refused_config", "window.env invalid")
	default: // the window now refuses this job: it waits at the head, nothing is recorded
		r.gateFail = true
	}
	select {
	case c.results <- r:
	case <-c.root.Done():
		if t.release != nil {
			t.release()
		}
	}
}

func (c *Consumer) skipRec(t task, result, why string) history.Run {
	now := c.now()
	return history.Run{
		RunID: c.newID(), App: t.app, Job: t.env.Job, Trigger: "queue", Started: now, Ended: now,
		Result: result, Attempt: 0, Err: text(why),
	}
}

// handleResult turns a worker's outcome into a completion write.
func (c *Consumer) handleResult(r result) {
	t := r.task
	st := c.st(t.app)
	w := &write{app: t.app, job: t.env.Job, raw: t.raw, release: t.release, envID: t.env.ID}
	if r.gateFail {
		// The item goes back to the queue head without incrementing attempt, and the slot and mark are freed at
		// once: the move-back is a completion write with no slot held.
		if w.release != nil {
			w.release()
			w.release = nil
		}
		w.kind = wBack
		w.rec = r.rec
		if r.rec.Result == "" {
			c.logf("gate-fail app=%s job=%s id=%s: the window refuses the job now, returning it to the queue head", t.app, t.env.Job, t.env.ID)
		} else {
			// A gate-fail that leaves a record must not loop hot if the gate keeps disagreeing with the take-time check.
			st.nextTake = c.now().Add(c.backoff(st.takeFails))
			st.takeFails++
		}
		c.addWrite(st, w)
		return
	}
	env := t.env
	attempt := env.Attempt
	cause := r.res.Err
	if r.res.HTTPStatus > 0 && !r.res.Timeout {
		cause = fmt.Sprintf("http %d: %s", r.res.HTTPStatus, r.res.Err)
	}
	cause = text(cause)
	rec := history.Run{
		RunID: r.runID, App: t.app, Job: env.Job, Trigger: "queue", Started: r.started, Ended: r.ended,
		HTTPStatus: r.res.HTTPStatus, Attempt: attempt,
	}
	switch r.res.Class {
	case dispatch.ClassOK:
		w.kind = wDone
		rec.Result = "ok"
	case dispatch.ClassRetryable:
		if attempt >= MaxAttempts {
			c.makeDead(w, ReasonExhausted, attempt, cause, &rec)
			break
		}
		w.kind, w.attempts = wRetry, attempt
		w.due = c.now().Add(RetryDelay(attempt, c.cfg.Jitter))
		w.newRaw = env.Encode(attempt+1, cause)
		rec.Result, rec.Err = "retry_scheduled", cause
	default: // permanent, and anything unclassified
		c.makeDead(w, ReasonPermanent, attempt, cause, &rec)
	}
	w.rec = rec
	c.addWrite(st, w)
}

// makeDead turns w into a dead-letter write and fills the record and the alert.
func (c *Consumer) makeDead(w *write, reason string, attempts int, lastError string, rec *history.Run) {
	w.kind, w.reason, w.attempts, w.lastError = wDead, reason, attempts, text(lastError)
	w.deadAt = c.now()
	rec.Result, rec.Err = "dead_lettered", reason+": "+w.lastError
	w.alertResult = "dead_lettered"
	w.alertMsg = fmt.Sprintf("queued job %s/%s dead-lettered (%s) after attempt %d: %s [id %s]", w.app, w.job, reason, attempts, w.lastError, orDash(w.envID))
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func (c *Consumer) addWrite(st *appState, w *write) {
	if w.recovery {
		st.recovering++
	}
	if w.newBusy {
		st.busy++
	}
	if st.parked != nil && w.release != nil { // a parked app holds no slot or mark
		w.release()
		w.release = nil
	}
	st.pending = append(st.pending, w)
}

// newDeadWrite builds the dead-letter of an item that is already in processing and has no run (an invalid head, a
// recovered item). busy is counted here because no worker was dispatched for it.
func (c *Consumer) newDeadWrite(app, raw string, v Verdict, reason string, attempts int, lastError string, recovery bool) *write {
	now := c.now()
	w := &write{app: app, job: orDash(v.Job), raw: raw, envID: v.ID, recovery: recovery, newBusy: true}
	rec := history.Run{
		RunID: c.newID(), App: app, Job: w.job, Trigger: "queue", Started: now, Ended: now, Attempt: attempts,
	}
	c.makeDead(w, reason, attempts, lastError, &rec)
	w.rec = rec
	return w
}

// ---- running the writes ----

// runWrites performs the pending completion writes, one app at a time, strictly in order within an app. It reports
// whether a write landed.
func (c *Consumer) runWrites() bool {
	progress := false
	names := make([]string, 0, len(c.apps))
	for name, st := range c.apps {
		if len(st.pending) > 0 {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	for _, name := range names {
		st := c.apps[name]
		for len(st.pending) > 0 && st.parked == nil && !c.down() {
			w := st.pending[0]
			if c.now().Before(w.notBefore) {
				break
			}
			if c.attempt(st, w) != outLanded {
				break
			}
			c.land(st, w)
			progress = true
		}
	}
	return progress
}

// land finishes a write that took effect: it records the run once, sends the alert, frees the slot and mark and
// forgets the write.
func (c *Consumer) land(st *appState, w *write) {
	for i, p := range st.pending {
		if p == w {
			st.pending = append(st.pending[:i], st.pending[i+1:]...)
			break
		}
	}
	if w.release != nil {
		w.release()
		w.release = nil
	}
	if w.recovery && st.recovering > 0 {
		st.recovering--
	}
	if st.busy > 0 {
		st.busy--
	}
	if w.rec.Result != "" {
		c.cfg.Registry.Record(w.rec)
		c.logf("run end app=%s job=%s trigger=queue run_id=%s result=%s http=%d attempt=%d", w.app, w.job, w.rec.RunID, w.rec.Result, w.rec.HTTPStatus, w.rec.Attempt)
	}
	if w.alertResult != "" {
		c.alertRun(w.app, w.job, w.alertResult, w.alertMsg)
	}
}

// expectedType returns the Redis type a destination key must have (or be missing).
func expectedType(kind string) string {
	if kind == "delayed" {
		return "zset"
	}
	return "list"
}

// typeCheck refuses a destination key of the wrong type before an EXEC, so the common case applies nothing.
func (c *Consumer) typeCheck(app, kind string) error {
	key := qkey(app, kind)
	t, err := c.s.Type(c.root, key)
	c.observe(err)
	if err != nil {
		return err
	}
	if t != "none" && t != expectedType(kind) {
		return fmt.Errorf("WRONGTYPE key %s holds %s, want %s", key, t, expectedType(kind))
	}
	return nil
}

// attempt performs one try of a completion write.
func (c *Consumer) attempt(st *appState, w *write) outcome {
	app := w.app
	ctx := c.root
	if w.attempted && !w.partial {
		// Ambiguous-write check before every retry: a lost reply may hide a write the server applied. The consumer is
		// the only writer of processing, so an item that is gone means the write took effect.
		found, err := c.s.LPos(ctx, qkey(app, "processing"), w.raw)
		c.observe(err)
		if err != nil {
			return c.writeErr(st, w, "LPOS", err)
		}
		if !found {
			c.logf("write landed app=%s kind=%d: the item is no longer in processing", app, w.kind)
			return outLanded
		}
	}
	w.attempted = true
	proc := qkey(app, "processing")
	switch w.kind {
	case wDone:
		// Note: LPOS and LREM work by value, so the ambiguity check assumes the raw values in processing are unique;
		// two identical items would let LPOS see the second copy of a write whose reply was lost.
		_, err := c.s.LRem(ctx, proc, w.raw)
		c.observe(err)
		if err != nil {
			return c.writeErr(st, w, "LREM", err)
		}
		c.wroteOK()
		return outLanded
	case wRetry:
		if err := c.typeCheck(app, "delayed"); err != nil {
			return c.writeErr(st, w, "TYPE", err)
		}
		n, err := c.s.ZCard(ctx, qkey(app, "delayed"))
		c.observe(err)
		if err != nil {
			return c.writeErr(st, w, "ZCARD", err)
		}
		if n >= DelayedMax {
			// Dead-letter instead; the record replaces the retry_scheduled one that has not been written yet.
			rec := w.rec
			c.makeDead(w, ReasonOverflow, w.attempts, fmt.Sprintf("delayed set holds %d entries (limit %d)", n, DelayedMax), &rec)
			w.rec = rec
			return c.attempt(st, w)
		}
		cmds := []Cmd{
			{Name: "LREM", Args: []string{proc, "1", w.raw}},
			{Name: "ZADD", Args: []string{qkey(app, "delayed"), strconv.FormatInt(w.due.Unix(), 10), w.newRaw}},
		}
		return c.execBlock(st, w, cmds)
	case wDead:
		if err := c.typeCheck(app, "dead"); err != nil {
			return c.writeErr(st, w, "TYPE", err)
		}
		dead := qkey(app, "dead")
		rec := NewDeadRecord(w.raw, w.envID, w.reason, w.attempts, w.lastError, w.deadAt)
		cmds := []Cmd{
			{Name: "LREM", Args: []string{proc, "1", w.raw}},
			{Name: "LPUSH", Args: []string{dead, rec.JSON()}},
			{Name: "LTRIM", Args: []string{dead, "0", strconv.Itoa(DeadKeep - 1)}},
		}
		return c.execBlock(st, w, cmds)
	default: // wBack, wRequeue
		if err := c.typeCheck(app, "queue"); err != nil {
			return c.writeErr(st, w, "TYPE", err)
		}
		item := w.raw
		if w.kind == wRequeue {
			item = w.newRaw
		}
		cmds := []Cmd{
			{Name: "LREM", Args: []string{proc, "1", w.raw}},
			{Name: "RPUSH", Args: []string{qkey(app, "queue"), item}},
		}
		return c.execBlock(st, w, cmds)
	}
}

// execBlock runs one MULTI/EXEC and inspects the reply of every command: a command that fails at run time fails
// alone while the others apply, so the overall error is not enough.
func (c *Consumer) execBlock(st *appState, w *write, cmds []Cmd) outcome {
	if c.beforeExec != nil {
		c.beforeExec(w.app)
	}
	replies, err := c.s.Exec(c.root, cmds)
	c.observe(err)
	if err != nil {
		return c.writeErr(st, w, "EXEC", err)
	}
	var applied, failed []string
	var first error
	for i, e := range replies {
		if e == nil {
			applied = append(applied, cmds[i].Name)
			continue
		}
		failed = append(failed, cmds[i].Name+": "+text(e.Error()))
		if first == nil {
			first = e
		}
	}
	if first == nil {
		c.wroteOK()
		return outLanded
	}
	if len(applied) > 0 {
		w.partial = true
		c.logf("partial EXEC applied app=%s applied=%v failed=%v item: %s", w.app, applied, failed, rawSummary(w.raw))
	}
	// A reply was received, so the write is not ambiguous: it is not retried through the LPOS shortcut. After a
	// partial apply the item may already be gone from processing although the write did not land, so the whole block
	// is rerun instead (LREM then returns 0 and the missing commands apply).
	return c.park(st, w, "EXEC", first)
}

// writeErr sorts an error of a completion write: transient and auth errors back off, anything else parks the app.
func (c *Consumer) writeErr(st *appState, w *write, cmd string, err error) outcome {
	if c.root.Err() != nil { // shutting down: a cancelled call is not a Redis fault, so no park and no alert
		return outRetry
	}
	cl := Classify(err)
	if cl.Kind == KindDeterministic {
		return c.park(st, w, cmd, err)
	}
	delay := c.backoff(w.fails)
	w.fails++
	w.notBefore = c.now().Add(delay)
	if cl.OOM {
		c.noteOOM(w.app, cmd, w.fails, delay)
	} else {
		c.logf("write retry app=%s command=%s attempt=%d next_delay=%s err=%q", w.app, cmd, w.fails, delay, text(err.Error()))
	}
	return outRetry
}

// ---- parking ----

// park stops serving an app after a deterministic error: the consumer stops taking, promoting and recovering for
// it, holds no slot or mark for it, sends one alert and leaves the item in processing. Others keep being served.
func (c *Consumer) park(st *appState, w *write, cmd string, err error) outcome {
	now := c.now()
	raw := rawSummary(w.raw)
	if st.parked != nil {
		if now.Sub(st.parked.lastLog) >= ProbeEvery || st.parked.lastLog.IsZero() {
			st.parked.lastLog = now
			c.logf("still parked app=%s command=%s err=%q item: %s", st.name, cmd, text(err.Error()), raw)
		}
		return outPark
	}
	st.parked = &parkInfo{cmd: cmd, err: text(err.Error()), since: now, nextProbe: now.Add(ProbeEvery), lastLog: now}
	st.recovered = false
	for _, p := range st.pending {
		if p.release != nil {
			p.release()
			p.release = nil
		}
	}
	c.logf("parked app=%s command=%s err=%q item: %s", st.name, cmd, text(err.Error()), raw)
	c.notify(fmt.Sprintf("app %s is parked: %s failed with %s. Its queue is not served until the key is repaired (inspect it as admin and restore a list or sorted set); other apps are unaffected", st.name, cmd, text(err.Error())))
	return outPark
}

func (c *Consumer) unpark(st *appState, why string) {
	if st.parked == nil {
		return
	}
	st.parked = nil
	st.recovered = false
	st.nextTake = time.Time{}
	c.logf("unparked app=%s why=%s", st.name, why)
	c.notify(fmt.Sprintf("app %s is served again (%s)", st.name, why))
}

// probeParked retries each parked app once per ProbeEvery: the oldest pending write, or a type check of its keys.
func (c *Consumer) probeParked() {
	if c.down() {
		return
	}
	names := make([]string, 0)
	for name, st := range c.apps {
		if st.parked != nil && !c.now().Before(st.parked.nextProbe) {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	for _, name := range names {
		st := c.apps[name]
		st.parked.nextProbe = c.now().Add(ProbeEvery)
		if len(st.pending) > 0 {
			w := st.pending[0]
			w.notBefore = time.Time{}
			// The park left the item in processing; if an operator cleared it, LPOS finds it gone and the write is
			// treated as landed, which un-parks the app.
			if !w.partial { // after a partial EXEC the LPOS shortcut would lose the item
				w.attempted = true
			}
			if c.attempt(st, w) == outLanded {
				st.parked.lastLog = c.now()
				c.unpark(st, "the pending write succeeded")
				c.land(st, w)
			}
			continue
		}
		if c.keysHealthy(st.name) {
			c.unpark(st, "its keys have the expected types")
		}
	}
}

func (c *Consumer) keysHealthy(app string) bool {
	for _, kind := range []string{"queue", "processing", "delayed", "dead"} {
		t, err := c.s.Type(c.root, qkey(app, kind))
		c.observe(err)
		if err != nil {
			return false
		}
		if t != "none" && t != expectedType(kind) {
			c.logf("still parked app=%s key=%s type=%s", app, qkey(app, kind), t)
			return false
		}
	}
	return true
}
