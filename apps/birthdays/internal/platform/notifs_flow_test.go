package platform

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestNotifsSetupURLEscapes(t *testing.T) {
	got := NotifsSetupURL("apps_demo", "u_1", "My App")
	want := "https://notifs-setup.4irl.app/?app=apps_demo&user=u_1&name=My+App"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	got = NotifsSetupURL("a&b", "x y", "café & co")
	want = "https://notifs-setup.4irl.app/?app=a%26b&user=x+y&name=caf%C3%A9+%26+co"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestNotifsClassifiers(t *testing.T) {
	ne := &NotifsError{Status: http.StatusUnprocessableEntity, Message: "error: " + MsgNoPublisher + " (x)"}
	wrapped := fmt.Errorf("send: %w", ne)

	if NotifsStatus(wrapped) != 422 || NotifsStatus(errors.New("x")) != 0 || NotifsStatus(nil) != 0 {
		t.Error("NotifsStatus")
	}
	if !IsNotifsErr(wrapped) || !IsNotifsErr(ErrNotifsUnconfigured) || !IsNotifsErr(fmt.Errorf("w: %w", ErrNotifsRetryable)) {
		t.Error("IsNotifsErr should match notifs errors")
	}
	if IsNotifsErr(errors.New("db down")) || IsNotifsErr(nil) {
		t.Error("IsNotifsErr matched a non-notifs error")
	}
	if !IsNotifsMsg(wrapped, MsgNoPublisher) || IsNotifsMsg(wrapped, MsgNoDestMatched) {
		t.Error("IsNotifsMsg substring")
	}
	if IsNotifsMsg(&NotifsError{Status: 400, Message: MsgNoPublisher}, MsgNoPublisher) {
		t.Error("IsNotifsMsg must require status 422")
	}
	if IsNotifsMsg(errors.New(MsgNoPublisher), MsgNoPublisher) || IsNotifsMsg(nil, MsgNoPublisher) {
		t.Error("IsNotifsMsg matched a non-notifs error")
	}
}

func TestNotifsMessageConstants(t *testing.T) {
	if MsgNoPublisher != "app has no ntfy publisher" ||
		MsgNoPersonalDst != "personal destination not available for recipient" ||
		MsgNoDestMatched != "no destination matched" {
		t.Fatal("message constants changed")
	}
}

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func TestTestLimiter(t *testing.T) {
	c := &clock{t: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}
	l := NewTestLimiter(30*time.Second, func() time.Time { return c.now() })

	if _, ok := l.Allow("a"); !ok {
		t.Fatal("first call refused")
	}
	c.t = c.t.Add(10 * time.Second)
	wait, ok := l.Allow("a")
	if ok || wait != 20*time.Second {
		t.Fatalf("repeat: ok=%v wait=%v", ok, wait)
	}
	if _, ok := l.Allow("b"); !ok {
		t.Fatal("independent key refused")
	}
	c.t = c.t.Add(20*time.Second - time.Nanosecond)
	if _, ok := l.Allow("a"); ok {
		t.Fatal("allowed just before the cooldown ends")
	}
	c.t = c.t.Add(time.Nanosecond) // exactly +30 s since "a" was recorded
	if _, ok := l.Allow("a"); !ok {
		t.Fatal("refused at exactly the cooldown")
	}
}

func TestTestLimiterPrunesExpired(t *testing.T) {
	c := &clock{t: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}
	l := NewTestLimiter(30*time.Second, c.now)
	l.Allow("a")
	l.Allow("b")
	c.t = c.t.Add(31 * time.Second)
	l.Allow("c")
	l.mu.Lock()
	n := len(l.seen)
	l.mu.Unlock()
	if n != 1 {
		t.Fatalf("expired entries kept: %d", n)
	}
}

func TestTestLimiterConcurrentOneWinner(t *testing.T) {
	c := &clock{t: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}
	l := NewTestLimiter(30*time.Second, c.now)
	var wins atomic.Int32
	var wg sync.WaitGroup
	start := make(chan struct{})
	for range 20 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			if _, ok := l.Allow("same"); ok {
				wins.Add(1)
			}
		}()
	}
	close(start)
	wg.Wait()
	if wins.Load() != 1 {
		t.Fatalf("wins = %d, want exactly 1", wins.Load())
	}
}

func TestTestMessage(t *testing.T) {
	now := time.Unix(1700000000, 123)
	m := TestMessage("T", "B", "a@example.test", "ntfy", "ntfy-0123456789abcdef", nil, now)
	if m.Channel != "all" || m.Recipient != "a@example.test" || m.Via != "ntfy" || m.Title != "T" || m.Body != "B" {
		t.Fatalf("fields: %+v", m)
	}
	if !regexp.MustCompile(`^test-ntfy-0123456789abcdef-\d+$`).MatchString(m.IdempotencyKey) {
		t.Fatalf("key shape: %q", m.IdempotencyKey)
	}
	m2 := TestMessage("T", "B", "a@example.test", "ntfy", "ntfy-0123456789abcdef", nil, now.Add(time.Nanosecond))
	if m.IdempotencyKey == m2.IdempotencyKey {
		t.Fatal("key not unique per call")
	}
	long := TestMessage("T", "B", "r", "personal", "dst-123456-0123456789abcdef", []int64{7}, now)
	if len(long.IdempotencyKey) >= 200 || strings.IndexFunc(long.IdempotencyKey, func(r rune) bool { return r < 0x20 || r > 0x7e }) >= 0 {
		t.Fatalf("key not printable ASCII under 200: %q", long.IdempotencyKey)
	}
	if len(long.PersonalDestinationIDs) != 1 || long.PersonalDestinationIDs[0] != 7 {
		t.Fatalf("ids: %v", long.PersonalDestinationIDs)
	}
}

type stubNotifier struct {
	Notifier // nil: any method the test does not expect panics
	sends    []Message
	sendErrs []error
	ensure   int
	ensureEr error
}

func (s *stubNotifier) Send(_ context.Context, m Message) (Result, error) {
	s.sends = append(s.sends, m)
	i := len(s.sends) - 1
	if i < len(s.sendErrs) && s.sendErrs[i] != nil {
		return Result{}, s.sendErrs[i]
	}
	return Result{Status: 202}, nil
}

func (s *stubNotifier) EnsurePublisher(context.Context) error {
	s.ensure++
	return s.ensureEr
}

func noPub() error { return &NotifsError{Status: 422, Message: MsgNoPublisher} }

func TestSendWithPublisher(t *testing.T) {
	m := Message{IdempotencyKey: "k"}
	ctx := context.Background()

	t.Run("ok first time", func(t *testing.T) {
		s := &stubNotifier{}
		res, err := SendWithPublisher(ctx, s, m)
		if err != nil || res.Status != 202 || len(s.sends) != 1 || s.ensure != 0 {
			t.Fatalf("res=%+v err=%v sends=%d ensure=%d", res, err, len(s.sends), s.ensure)
		}
	})
	t.Run("no publisher then mint then resend same key", func(t *testing.T) {
		s := &stubNotifier{sendErrs: []error{noPub()}}
		res, err := SendWithPublisher(ctx, s, m)
		if err != nil || res.Status != 202 || len(s.sends) != 2 || s.ensure != 1 || s.sends[0].IdempotencyKey != s.sends[1].IdempotencyKey {
			t.Fatalf("res=%+v err=%v sends=%d ensure=%d", res, err, len(s.sends), s.ensure)
		}
	})
	t.Run("mint 429 returned", func(t *testing.T) {
		s := &stubNotifier{sendErrs: []error{noPub()}, ensureEr: &NotifsError{Status: 429, Message: "slow down"}}
		_, err := SendWithPublisher(ctx, s, m)
		if NotifsStatus(err) != 429 || len(s.sends) != 1 {
			t.Fatalf("err=%v sends=%d", err, len(s.sends))
		}
	})
	t.Run("second no publisher not looped", func(t *testing.T) {
		s := &stubNotifier{sendErrs: []error{noPub(), noPub()}}
		_, err := SendWithPublisher(ctx, s, m)
		if !IsNotifsMsg(err, MsgNoPublisher) || len(s.sends) != 2 || s.ensure != 1 {
			t.Fatalf("err=%v sends=%d ensure=%d", err, len(s.sends), s.ensure)
		}
	})
	t.Run("other errors untouched", func(t *testing.T) {
		other := &NotifsError{Status: 422, Message: MsgNoDestMatched}
		s := &stubNotifier{sendErrs: []error{other}}
		_, err := SendWithPublisher(ctx, s, m)
		if !errors.Is(err, other) || len(s.sends) != 1 || s.ensure != 0 {
			t.Fatalf("err=%v sends=%d ensure=%d", err, len(s.sends), s.ensure)
		}
	})
}
