// Package logx is the runner's stdout logger: one line per event, prefixed with a UTC RFC3339 timestamp from the
// injected Clock (journald adds its own, but the line must stand alone when copied out).
package logx

import (
	"fmt"
	"io"
	"strings"
	"sync"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
)

// Logger writes whole lines with a single Write each. A nil *Logger discards everything.
type Logger struct {
	mu  sync.Mutex
	w   io.Writer
	clk clock.Clock
}

// New returns a Logger writing to w.
func New(w io.Writer, clk clock.Clock) *Logger {
	return &Logger{w: w, clk: clk}
}

// Printf formats one event. Newlines inside the message are replaced with spaces so a line is always one line.
func (l *Logger) Printf(format string, a ...any) {
	if l == nil {
		return
	}
	msg := strings.NewReplacer("\r", " ", "\n", " ").Replace(fmt.Sprintf(format, a...))
	line := l.clk.Now().UTC().Format(time.RFC3339) + " " + msg + "\n"
	l.mu.Lock()
	defer l.mu.Unlock()
	_, _ = io.WriteString(l.w, line)
}
