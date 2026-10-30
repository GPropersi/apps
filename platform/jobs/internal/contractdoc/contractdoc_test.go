// Package contractdoc holds one test: CONTRACT.md must state every constant the runner enforces, so changing a limit
// in code without the document (or the reverse) fails the build.
package contractdoc

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/gpropersi/apps/platform/jobs/internal/queue"
	"github.com/gpropersi/apps/platform/jobs/internal/sched"
)

// queueCap and valueLimit are enforced by the app-side helpers and the shared Redis, not by Go code in this module,
// so the test pins the contract's numbers here.
const (
	queueCap   = 1000
	valueLimit = "1 MB"
)

func TestContractStatesRunnerConstants(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "CONTRACT.md"))
	if err != nil {
		t.Fatalf("read CONTRACT.md: %v", err)
	}
	doc := string(raw)

	numbers := []struct {
		name string
		want string
	}{
		{"queue.MaxAttempts (max_attempts)", "`max_attempts` is " + strconv.Itoa(queue.MaxAttempts)},
		{"queue.MaxEnvelopeBytes (envelope size limit)", strconv.Itoa(queue.MaxEnvelopeBytes) + " bytes"},
		{"app-side queue cap (LLEN limit)", "`LLEN <app>:jobs:queue` is " + strconv.Itoa(queueCap) + " or more"},
		{"queue.DeadKeep (dead list cap)", "newest " + strconv.Itoa(queue.DeadKeep) + " "},
		{"sched.MaxConcurrent (platform cap)", "At most " + strconv.Itoa(sched.MaxConcurrent) + " runs are in flight"},
		{"queue.DeadEnvelopeBytes (dead-record truncation)", "truncated to " + strconv.Itoa(queue.DeadEnvelopeBytes) + " bytes"},
		{"queue.DelayedMax (delayed-set bound)", "at most " + strconv.Itoa(queue.DelayedMax) + " entries"},
		{"queue.MaxLastError (last_error cap)", "at most " + strconv.Itoa(queue.MaxLastError) + " characters"},
		{"Redis per-value limit", valueLimit},
	}
	for _, n := range numbers {
		if !strings.Contains(doc, n.want) {
			t.Errorf("CONTRACT.md is missing the constant %s: expected the text %q", n.name, n.want)
		}
	}

	reasons := []string{
		queue.ReasonExhausted, queue.ReasonInvalid, queue.ReasonUndeclare, queue.ReasonOverflow, queue.ReasonPermanent,
	}
	for _, r := range reasons {
		if !strings.Contains(doc, "`"+r+"`") {
			t.Errorf("CONTRACT.md is missing the dead-record reason %q", r)
		}
	}
}
