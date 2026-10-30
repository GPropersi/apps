package main

import (
	"fmt"
	"io"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/health"
)

// runHealthcheck returns 0 only when runner.tsv has a fresh heartbeat; the reason goes to stderr.
func runHealthcheck(cfg config, clk clock.Clock, stderr io.Writer) int {
	if err := health.Check(clk, cfg.runnerTSV()); err != nil {
		fmt.Fprintf(stderr, "unhealthy: %s\n", err.Error())
		return 1
	}
	return 0
}
