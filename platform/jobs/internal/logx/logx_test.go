package logx

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
)

func TestLineIsUTCStampedAndSingleLine(t *testing.T) {
	var buf bytes.Buffer
	la, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Fatal(err)
	}
	l := New(&buf, clock.NewFake(time.Date(2026, 3, 4, 7, 0, 5, 0, la)))
	l.Printf("run start app=%s note=%q\nsecond", "a", "x")
	want := "2026-03-04T15:00:05Z run start app=a note=\"x\" second\n"
	if buf.String() != want {
		t.Fatalf("got %q, want %q", buf.String(), want)
	}
	if strings.Count(buf.String(), "\n") != 1 {
		t.Fatal("not a single line")
	}
	var nilLogger *Logger
	nilLogger.Printf("ignored") // a nil logger discards
}
