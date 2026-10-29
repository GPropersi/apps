package clock

import (
	"strings"
	"testing"
)

// A monotonic reading would make Sub() ignore a wall-clock step, so the scheduler's jump detection would never
// fire in production.
func TestRealNowHasNoMonotonicReading(t *testing.T) {
	now := Real{}.Now()
	if s := now.String(); strings.Contains(s, "m=") {
		t.Fatalf("Real.Now() carries a monotonic reading: %q", s)
	}
}
