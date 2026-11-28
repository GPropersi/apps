package platform

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Messages delivery-api puts in a 422 answer that the callers branch on.
const (
	MsgNoPublisher   = "app has no ntfy publisher"
	MsgNoPersonalDst = "personal destination not available for recipient"
	MsgNoDestMatched = "no destination matched"
)

const notifsSetupBase = "https://notifs-setup.4irl.app/"

// Notifier is the part of the 4irl-notifs client the notification settings routes use; *NotifsClient satisfies it and
// tests fake it.
type Notifier interface {
	Provision(ctx context.Context, email string) (Provisioned, error)
	ResetPassword(ctx context.Context, email string) (PasswordReset, error)
	CreatePersonalDestination(ctx context.Context, email string, in PersonalDestinationInput) (int64, error)
	DeletePersonalDestination(ctx context.Context, email string, id int64) error
	LookupPersonalDestinations(ctx context.Context, email string, ids []int64) (map[int64]bool, error)
	Send(ctx context.Context, m Message) (Result, error)
	EnsurePublisher(ctx context.Context) error
}

var _ Notifier = (*NotifsClient)(nil)

// NotifsSetupURL is the link to the phone-setup page for one person of one app; name is the display name it shows.
func NotifsSetupURL(appID, userID, name string) string {
	return notifsSetupBase + "?app=" + url.QueryEscape(appID) + "&user=" + url.QueryEscape(userID) +
		"&name=" + url.QueryEscape(name)
}

// NotifsStatus is the HTTP status of a *NotifsError in err's chain, or 0.
func NotifsStatus(err error) int {
	var ne *NotifsError
	if errors.As(err, &ne) {
		return ne.Status
	}
	return 0
}

// IsNotifsErr reports whether err came from the notifs client (as opposed to the database).
func IsNotifsErr(err error) bool {
	var ne *NotifsError
	return errors.As(err, &ne) || errors.Is(err, ErrNotifsUnconfigured) || errors.Is(err, ErrNotifsRetryable)
}

// IsNotifsMsg reports whether err is a 422 whose message contains msg.
func IsNotifsMsg(err error, msg string) bool {
	var ne *NotifsError
	return errors.As(err, &ne) && ne.Status == http.StatusUnprocessableEntity && strings.Contains(ne.Message, msg)
}

// TestLimiter is the test-send limiter: lookup and record are one locked step, so concurrent requests on one key
// cannot both pass. It is in-process (reset by a restart, not shared across replicas), accepted for an anti-spam guard.
type TestLimiter struct {
	cooldown time.Duration
	now      func() time.Time
	mu       sync.Mutex
	seen     map[string]time.Time
}

// NewTestLimiter returns a limiter with the given cooldown. now is called on every Allow, so a caller can pass a
// closure that reads a clock set later.
func NewTestLimiter(cooldown time.Duration, now func() time.Time) *TestLimiter {
	if now == nil {
		now = time.Now
	}
	return &TestLimiter{cooldown: cooldown, now: now, seen: map[string]time.Time{}}
}

// Allow records key and returns ok, or, when key was recorded less than the cooldown ago, how long until it may be
// used again. The key is recorded before the send, so a failed send still counts.
func (l *TestLimiter) Allow(key string) (retryAfter time.Duration, ok bool) {
	now := l.now()
	l.mu.Lock()
	defer l.mu.Unlock()
	for k, started := range l.seen {
		if !now.Before(started.Add(l.cooldown)) {
			delete(l.seen, k)
		}
	}
	if started, found := l.seen[key]; found {
		return started.Add(l.cooldown).Sub(now), false
	}
	l.seen[key] = now
	return 0, true
}

// TestMessage is the one-off message a test route sends. key distinguishes the target (never a raw email); the
// idempotency key is unique per click because a fixed key would dedupe.
func TestMessage(title, body, recipient, via, key string, personalIDs []int64, now time.Time) Message {
	return Message{
		Channel:                "all",
		IdempotencyKey:         fmt.Sprintf("test-%s-%d", key, now.UnixNano()),
		Recipient:              recipient,
		Via:                    via,
		PersonalDestinationIDs: personalIDs,
		Title:                  title,
		Body:                   body,
	}
}

// SendWithPublisher sends m; when the app has no ntfy publisher yet it mints one with EnsurePublisher and resends once
// with the same key. A failed mint is returned as is (a 429 stays a *NotifsError); a second missing publisher is
// returned as is, never looped.
func SendWithPublisher(ctx context.Context, n Notifier, m Message) (Result, error) {
	res, err := n.Send(ctx, m)
	if !IsNotifsMsg(err, MsgNoPublisher) {
		return res, err
	}
	if perr := n.EnsurePublisher(ctx); perr != nil {
		return Result{}, perr
	}
	return n.Send(ctx, m)
}
