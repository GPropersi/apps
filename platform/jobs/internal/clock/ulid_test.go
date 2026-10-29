package clock

import (
	"regexp"
	"testing"
	"time"
)

func TestNewULIDShapeAndOrder(t *testing.T) {
	re := regexp.MustCompile(`^[0-9A-HJKMNP-TV-Z]{26}$`)
	a := NewULID(time.UnixMilli(1_700_000_000_000))
	b := NewULID(time.UnixMilli(1_700_000_000_001))
	if !re.MatchString(a) || !re.MatchString(b) {
		t.Fatalf("bad ULID shape: %q %q", a, b)
	}
	if a[:10] >= b[:10] {
		t.Fatalf("timestamp prefix must grow with time: %q %q", a[:10], b[:10])
	}
	if NewULID(time.UnixMilli(1_700_000_000_000)) == a {
		t.Fatal("two ULIDs in the same millisecond must differ")
	}
}

func TestFakeJumpMovesNowWithoutFiring(t *testing.T) {
	f := NewFake(time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC))
	ch := f.After(time.Minute)
	f.Jump(time.Hour)
	if got := f.Now(); !got.Equal(time.Date(2026, 1, 1, 1, 0, 0, 0, time.UTC)) {
		t.Fatalf("Now = %v", got)
	}
	select {
	case <-ch:
		t.Fatal("Jump must not fire timers")
	default:
	}
	f.Advance(time.Second)
	select {
	case <-ch:
	default:
		t.Fatal("overdue timer must fire on the next Advance")
	}
}
