// Package health is the runner's container healthcheck: runner.tsv must hold one well-formed line whose
// heartbeat_at is fresh.
package health

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
)

// MaxAge is the oldest heartbeat that still counts as healthy.
const MaxAge = 60 * time.Second

// maxFileBytes bounds the read; a runner.tsv line is far below this.
const maxFileBytes = 4096

// Check returns nil only when the file at path holds exactly one line of exactly six tab-separated fields and its
// heartbeat_at (field 2, RFC3339 UTC with Z) is less than MaxAge old by clk and not in the future. Fail closed: every
// other case is an error naming the reason.
func Check(clk clock.Clock, path string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read runner.tsv: %w", err)
	}
	if len(b) == 0 || len(b) > maxFileBytes {
		return errors.New("runner.tsv is empty or too large")
	}
	line := strings.TrimSuffix(string(b), "\n")
	if strings.Contains(line, "\n") {
		return errors.New("runner.tsv has more than one line")
	}
	fields := strings.Split(line, "\t")
	if len(fields) != 6 {
		return fmt.Errorf("runner.tsv has %d fields, want 6", len(fields))
	}
	if !strings.HasSuffix(fields[1], "Z") {
		return errors.New("heartbeat_at is not UTC (Z)")
	}
	hb, err := time.Parse(time.RFC3339, fields[1])
	if err != nil {
		return errors.New("heartbeat_at is not RFC3339")
	}
	age := clk.Now().Sub(hb)
	if age < 0 {
		return fmt.Errorf("heartbeat_at is in the future by %s", -age)
	}
	if age >= MaxAge {
		return fmt.Errorf("heartbeat_at is %s old, limit %s", age.Truncate(time.Second), MaxAge)
	}
	return nil
}
