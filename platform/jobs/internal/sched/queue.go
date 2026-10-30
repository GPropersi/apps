package sched

import (
	"sort"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/history"
	"github.com/gpropersi/apps/platform/jobs/internal/queue"
)

// RunAlerter is the optional extension of Notifier that collapses run alerts per (app, job, result)
// (notify.Discord implements it). A Notifier without it only gets state-change alerts.
type RunAlerter interface {
	Alert(app, job, result, msg string)
}

// alertRun sends the alert for a failed scheduled run.
func (s *Scheduler) alertRun(app, job, result, msg string) {
	s.logf("alert %s", msg)
	if a, ok := s.cfg.Notifier.(RunAlerter); ok {
		a.Alert(app, job, result, msg)
	}
}

// QueueRegistry returns the scheduler's view for the queue consumer: the declared apps and jobs, the backup
// window, the platform-wide cap slot with the (app, job) in-flight mark (shared with scheduled runs) and the run
// record.
func (s *Scheduler) QueueRegistry() queue.Registry { return queueView{s} }

type queueView struct{ s *Scheduler }

func (q queueView) Apps() []string {
	q.s.mu.Lock()
	defer q.s.mu.Unlock()
	seen := map[string]bool{}
	var out []string
	for k := range q.s.jobs {
		if !seen[k.app] {
			seen[k.app] = true
			out = append(out, k.app)
		}
	}
	sort.Strings(out)
	return out
}

func (q queueView) Job(app, job string) (queue.JobSpec, bool) {
	q.s.mu.Lock()
	defer q.s.mu.Unlock()
	js := q.s.jobs[jobKey{app, job}]
	if js == nil {
		return queue.JobSpec{}, false
	}
	return queue.JobSpec{Port: js.port, Timeout: js.job.Timeout}, true
}

// WindowGate re-reads window.env by name (like every scheduled decision) and applies the rule for the job's
// timeout. Nothing is recorded: a queued head that is held simply waits.
func (q queueView) WindowGate(timeout time.Duration) queue.WindowVerdict {
	w, err := q.s.windowDecision()
	if err != nil {
		return queue.WindowInvalid
	}
	if w.Refuses(q.s.now(), timeout) {
		return queue.WindowHold
	}
	return queue.WindowAllow
}

// TryAcquire takes a cap slot and the in-flight mark without waiting; the consumer never queues behind the
// scheduler.
func (q queueView) TryAcquire(app, job string) (func(), bool) {
	k := jobKey{app, job}
	if !q.s.tryStart(k) {
		return nil, false
	}
	select {
	case q.s.sem <- struct{}{}:
	default:
		q.s.finish(k)
		return nil, false
	}
	return func() {
		q.s.releaseSlot()
		q.s.finish(k)
	}, true
}

func (q queueView) Record(r history.Run) { q.s.record(r) }
