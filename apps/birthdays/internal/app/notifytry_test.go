package app

import (
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gpropersi/apps/apps/birthdays/internal/platform"
)

const (
	ntfyTestPath = "/api/notify/ntfy/test"
)

// useClock injects a controllable clock and returns a pointer to the current instant.
func useClock(hn *harness) *time.Time {
	now := time.Date(2026, 11, 27, 12, 0, 0, 0, time.UTC)
	hn.srv.Now = func() time.Time { return now }
	return &now
}

func destTestPath(id int64) string { return fmt.Sprintf("/api/notify/destinations/%d/test", id) }

// phoneReady provisions alice's phone.
func phoneReady(hn *harness) {
	hn.t.Helper()
	hn.wantStatus(hn.as(alice, "POST", "/api/notify/ntfy", `{}`), 200, "")
}

func TestNtfyTestSendsToThePhoneOnly(t *testing.T) {
	hn := newHarness(t)
	now := useClock(hn)
	phoneReady(hn)
	hn.addDest(alice, "webhook", webhookURL)
	reminders, runs := len(hn.store.reminders), len(hn.store.jobRuns)

	rec := hn.as("  Alice@Example.TEST ", "POST", ntfyTestPath, `{}`)
	hn.wantStatus(rec, 200, "")
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("ntfy test response is cacheable")
	}
	var got struct {
		Settings notifySettings `json:"settings"`
	}
	decode(t, rec.Body.String(), &got)
	if !got.Settings.Ntfy || got.Settings.Destinations != 1 {
		t.Fatalf("settings = %+v", got.Settings)
	}
	if len(hn.notifs.sends) != 1 {
		t.Fatalf("sends = %d, want 1", len(hn.notifs.sends))
	}
	m := hn.notifs.sends[0]
	if m.Via != "ntfy" || len(m.PersonalDestinationIDs) != 0 || m.Recipient != alice || m.Channel != "all" ||
		m.Title != testTitle || m.Body != testBody {
		t.Fatalf("message = %+v", m)
	}
	if len(hn.store.reminders) != reminders || len(hn.store.jobRuns) != runs {
		t.Fatal("a test send wrote reminder or job-run records")
	}

	*now = now.Add(31 * time.Second)
	hn.wantStatus(hn.as(alice, "POST", ntfyTestPath, `{}`), 200, "")
	if len(hn.notifs.sends) != 2 || hn.notifs.sends[0].IdempotencyKey == hn.notifs.sends[1].IdempotencyKey {
		t.Fatalf("two clicks must use different keys: %+v", hn.notifs.sends)
	}
	for _, s := range hn.notifs.sends {
		if len(s.IdempotencyKey) >= 200 || strings.ContainsFunc(s.IdempotencyKey, func(r rune) bool { return r < 0x20 || r > 0x7e }) {
			t.Fatalf("key %q is not short printable ASCII", s.IdempotencyKey)
		}
	}
}

func TestNtfyTestNotSetUpIsConflictAndDoesNotStartTheCooldown(t *testing.T) {
	hn := newHarness(t)
	useClock(hn)
	hn.wantStatus(hn.as(alice, "POST", ntfyTestPath, `{}`), 409, "ntfy_not_set_up")
	if len(hn.notifs.sends) != 0 {
		t.Fatal("sent without a phone")
	}
	phoneReady(hn)
	hn.wantStatus(hn.as(alice, "POST", ntfyTestPath, `{}`), 200, "") // not rate limited by the rejected call
}

func TestNtfyTestNilNotifierIsNotifyUnavailable(t *testing.T) {
	hn := newHarness(t)
	phoneReady(hn)
	hn.srv.Notifs = nil
	hn.wantStatus(hn.as(alice, "POST", ntfyTestPath, `{}`), 500, "notify_unavailable")
}

func TestNtfyTestSendErrorMapping(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want int
		code string
	}{
		{"no destination matched", nerr(422, msgNoDestMatched), 409, "ntfy_not_set_up"},
		{"delivery 429", nerr(429, "slow down"), 429, "rate_limited"},
		{"503", nerr(503, "down"), 500, "notify_unavailable"},
		{"unconfigured", platform.ErrNotifsUnconfigured, 500, "notify_unavailable"},
		{"retryable", platform.ErrNotifsRetryable, 500, "notify_unavailable"},
		{"other 422", nerr(422, "something else"), 500, "notify_unavailable"},
		{"409", nerr(409, "conflict"), 500, "notify_unavailable"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			hn := newHarness(t)
			phoneReady(hn)
			hn.notifs.sendErrs = []error{c.err}
			hn.wantStatus(hn.as(alice, "POST", ntfyTestPath, `{}`), c.want, c.code)
			if len(hn.notifs.sends) != 1 || hn.notifs.ensurePublishers != 0 {
				t.Fatalf("sends=%d ensures=%d", len(hn.notifs.sends), hn.notifs.ensurePublishers)
			}
		})
	}
}

func TestNtfyTestNoPublisherPath(t *testing.T) {
	noPub := nerr(422, msgNoPublisher)
	cases := []struct {
		name       string
		sendErrs   []error
		ensureErr  error
		want       int
		code       string
		wantSends  int
		wantEnsure int
	}{
		{"mint then resend succeeds", []error{noPub, nil}, nil, 200, "", 2, 1},
		{"ensure 429", []error{noPub}, nerr(429, "x"), 429, "rate_limited", 1, 1},
		{"ensure 503", []error{noPub}, nerr(503, "x"), 500, "notify_unavailable", 1, 1},
		{"resend no match", []error{noPub, nerr(422, msgNoDestMatched)}, nil, 409, "ntfy_not_set_up", 2, 1},
		{"resend 429", []error{noPub, nerr(429, "x")}, nil, 429, "rate_limited", 2, 1},
		{"second no publisher", []error{noPub, noPub}, nil, 500, "notify_unavailable", 2, 1},
		{"resend 503", []error{noPub, nerr(503, "x")}, nil, 500, "notify_unavailable", 2, 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			hn := newHarness(t)
			phoneReady(hn)
			hn.notifs.sendErrs = c.sendErrs
			hn.notifs.ensurePublisherErr = c.ensureErr
			hn.wantStatus(hn.as(alice, "POST", ntfyTestPath, `{}`), c.want, c.code)
			if len(hn.notifs.sends) != c.wantSends || hn.notifs.ensurePublishers != c.wantEnsure {
				t.Fatalf("sends=%d ensures=%d, want %d and %d", len(hn.notifs.sends), hn.notifs.ensurePublishers, c.wantSends, c.wantEnsure)
			}
			if c.wantSends == 2 && hn.notifs.sends[0].IdempotencyKey != hn.notifs.sends[1].IdempotencyKey {
				t.Fatal("the resend must reuse the key")
			}
		})
	}
}

func TestDestinationTestSendsToThatDestinationOnly(t *testing.T) {
	hn := newHarness(t)
	useClock(hn)
	first := hn.addDest(alice, "webhook", webhookURL)
	hn.addDest(alice, "discord", discordURL)
	reminders, runs := len(hn.store.reminders), len(hn.store.jobRuns)

	rec := hn.as(alice, "POST", destTestPath(first.Destination.ID), `{}`)
	hn.wantStatus(rec, 200, "")
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("destination test response is cacheable")
	}
	var got struct {
		Settings notifySettings `json:"settings"`
	}
	decode(t, rec.Body.String(), &got)
	if got.Settings.Destinations != 2 {
		t.Fatalf("settings = %+v", got.Settings)
	}
	if len(hn.notifs.sends) != 1 {
		t.Fatalf("sends = %d", len(hn.notifs.sends))
	}
	m := hn.notifs.sends[0]
	if m.Via != "personal" || len(m.PersonalDestinationIDs) != 1 || m.PersonalDestinationIDs[0] != 901 || m.Recipient != alice ||
		m.Channel != "all" || m.Title != testTitle || m.Body != testBody {
		t.Fatalf("message = %+v", m)
	}
	if len(hn.store.reminders) != reminders || len(hn.store.jobRuns) != runs {
		t.Fatal("a test send wrote reminder or job-run records")
	}
}

func TestDestinationTestValidation(t *testing.T) {
	hn := newHarness(t)
	useClock(hn)
	d := hn.addDest(alice, "webhook", webhookURL)
	path := destTestPath(d.Destination.ID)

	hn.store.dests[0].Stale = true
	hn.wantStatus(hn.as(alice, "POST", path, `{}`), 409, "destination_stale")
	hn.store.dests[0].Stale = false
	hn.wantStatus(hn.as(bob, "POST", path, `{}`), 404, "not_found")
	hn.wantStatus(hn.as(alice, "POST", destTestPath(999), `{}`), 404, "not_found")
	hn.wantStatus(hn.as(alice, "POST", "/api/notify/destinations/abc/test", `{}`), 404, "not_found")
	if len(hn.notifs.sends) != 0 {
		t.Fatal("a rejected request reached delivery")
	}
	// None of those rejections started the cooldown.
	hn.wantStatus(hn.as(alice, "POST", path, `{}`), 200, "")

	hn2 := newHarness(t)
	d2 := hn2.addDest(alice, "webhook", webhookURL)
	hn2.srv.Notifs = nil
	hn2.wantStatus(hn2.as(alice, "POST", destTestPath(d2.Destination.ID), `{}`), 500, "notify_unavailable")
}

func TestDestinationTestSendErrorMapping(t *testing.T) {
	cases := []struct {
		name  string
		err   error
		want  int
		code  string
		stale bool
	}{
		{"429", nerr(429, "x"), 429, "rate_limited", false},
		{"503", nerr(503, "x"), 500, "notify_unavailable", false},
		{"no destination matched", nerr(422, msgNoDestMatched), 500, "notify_unavailable", false},
		{"409", nerr(409, "destination disabled"), 500, "notify_unavailable", false},
		{"unconfigured", platform.ErrNotifsUnconfigured, 500, "notify_unavailable", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			hn := newHarness(t)
			d := hn.addDest(alice, "webhook", webhookURL)
			hn.notifs.sendErrs = []error{c.err}
			hn.wantStatus(hn.as(alice, "POST", destTestPath(d.Destination.ID), `{}`), c.want, c.code)
			if hn.store.dests[0].Stale != c.stale || hn.notifs.lookups != 0 || hn.notifs.ensurePublishers != 0 || len(hn.notifs.sends) != 1 {
				t.Fatalf("stale=%v lookups=%d ensures=%d sends=%d", hn.store.dests[0].Stale, hn.notifs.lookups, hn.notifs.ensurePublishers, len(hn.notifs.sends))
			}
		})
	}
}

func TestDestinationTestPersonalUnavailable(t *testing.T) {
	unavailable := nerr(422, msgNoPersonalDst)

	t.Run("confirmed undeliverable marks it stale", func(t *testing.T) {
		hn := newHarness(t)
		d := hn.addDest(alice, "webhook", webhookURL)
		hn.notifs.sendErrs = []error{unavailable}
		hn.wantStatus(hn.as(alice, "POST", destTestPath(d.Destination.ID), `{}`), 409, "destination_stale")
		if !hn.store.dests[0].Stale || len(hn.notifs.sends) != 1 || hn.notifs.lookedUp[0][0] != 901 {
			t.Fatalf("stale=%v sends=%d lookedUp=%v", hn.store.dests[0].Stale, len(hn.notifs.sends), hn.notifs.lookedUp)
		}
		var list struct {
			Destinations []struct {
				Stale bool `json:"stale"`
			} `json:"destinations"`
		}
		decode(t, hn.as(alice, "GET", "/api/notify/destinations", "").Body.String(), &list)
		if len(list.Destinations) != 1 || !list.Destinations[0].Stale {
			t.Fatalf("list = %+v", list)
		}
	})
	t.Run("lookup says deliverable", func(t *testing.T) {
		hn := newHarness(t)
		d := hn.addDest(alice, "webhook", webhookURL)
		hn.notifs.deliverable = map[int64]bool{901: true}
		hn.notifs.sendErrs = []error{unavailable}
		hn.wantStatus(hn.as(alice, "POST", destTestPath(d.Destination.ID), `{}`), 500, "notify_unavailable")
		if hn.store.dests[0].Stale {
			t.Fatal("a deliverable destination was marked stale")
		}
	})
	t.Run("lookup error", func(t *testing.T) {
		hn := newHarness(t)
		d := hn.addDest(alice, "webhook", webhookURL)
		hn.notifs.lookupErr = nerr(503, "x")
		hn.notifs.sendErrs = []error{unavailable}
		hn.wantStatus(hn.as(alice, "POST", destTestPath(d.Destination.ID), `{}`), 500, "notify_unavailable")
		if hn.store.dests[0].Stale {
			t.Fatal("a failed lookup marked the row stale")
		}
	})
	t.Run("row deleted before the stale write", func(t *testing.T) {
		hn := newHarness(t)
		d := hn.addDest(alice, "webhook", webhookURL)
		hn.notifs.onLookup = func() { hn.store.dests = nil }
		hn.notifs.sendErrs = []error{unavailable}
		hn.wantStatus(hn.as(alice, "POST", destTestPath(d.Destination.ID), `{}`), 404, "not_found")
	})
}

func TestTestCooldown(t *testing.T) {
	t.Run("repeat is 429 with Retry-After and no second send", func(t *testing.T) {
		hn := newHarness(t)
		now := useClock(hn)
		phoneReady(hn)
		hn.wantStatus(hn.as(alice, "POST", ntfyTestPath, `{}`), 200, "")
		*now = now.Add(12400 * time.Millisecond)
		rec := hn.as(alice, "POST", ntfyTestPath, `{}`)
		hn.wantStatus(rec, 429, "rate_limited")
		if got := rec.Header().Get("Retry-After"); got != "18" {
			t.Fatalf("Retry-After = %q, want 18", got)
		}
		if len(hn.notifs.sends) != 1 {
			t.Fatalf("sends = %d", len(hn.notifs.sends))
		}
		*now = now.Add(17600 * time.Millisecond) // exactly 30 s after the first
		hn.wantStatus(hn.as(alice, "POST", ntfyTestPath, `{}`), 200, "")
	})
	t.Run("a failed send counts", func(t *testing.T) {
		hn := newHarness(t)
		useClock(hn)
		phoneReady(hn)
		hn.notifs.sendErrs = []error{nerr(503, "x")}
		hn.wantStatus(hn.as(alice, "POST", ntfyTestPath, `{}`), 500, "notify_unavailable")
		hn.wantStatus(hn.as(alice, "POST", ntfyTestPath, `{}`), 429, "rate_limited")
		if len(hn.notifs.sends) != 1 {
			t.Fatalf("sends = %d", len(hn.notifs.sends))
		}
	})
	t.Run("a failed destination send counts and Retry-After is at least 1 s", func(t *testing.T) {
		hn := newHarness(t)
		now := useClock(hn)
		d := hn.addDest(alice, "webhook", webhookURL)
		hn.notifs.sendErrs = []error{nerr(503, "x")}
		hn.wantStatus(hn.as(alice, "POST", destTestPath(d.Destination.ID), `{}`), 500, "notify_unavailable")
		*now = now.Add(29900 * time.Millisecond)
		rec := hn.as(alice, "POST", destTestPath(d.Destination.ID), `{}`)
		hn.wantStatus(rec, 429, "rate_limited")
		if got := rec.Header().Get("Retry-After"); got != "1" {
			t.Fatalf("Retry-After = %q, want 1", got)
		}
		if len(hn.notifs.sends) != 1 {
			t.Fatalf("sends = %d", len(hn.notifs.sends))
		}
	})
	t.Run("expired entries are pruned", func(t *testing.T) {
		hn := newHarness(t)
		now := useClock(hn)
		phoneReady(hn)
		hn.wantStatus(hn.as(alice, "POST", ntfyTestPath, `{}`), 200, "")
		*now = now.Add(testCooldown)
		hn.wantStatus(hn.as(bob, "POST", "/api/notify/ntfy", `{}`), 200, "")
		hn.wantStatus(hn.as(bob, "POST", ntfyTestPath, `{}`), 200, "")
		hn.srv.testMu.Lock()
		n := len(hn.srv.testSeen)
		hn.srv.testMu.Unlock()
		if n != 1 {
			t.Fatalf("limiter holds %d entries, want 1 (alice's expired entry pruned)", n)
		}
	})
	t.Run("targets and people are independent", func(t *testing.T) {
		hn := newHarness(t)
		useClock(hn)
		phoneReady(hn)
		d := hn.addDest(alice, "webhook", webhookURL)
		d2 := hn.addDest(alice, "discord", discordURL)
		hn.wantStatus(hn.as(alice, "POST", ntfyTestPath, `{}`), 200, "")
		hn.wantStatus(hn.as(alice, "POST", destTestPath(d.Destination.ID), `{}`), 200, "")
		hn.wantStatus(hn.as(alice, "POST", destTestPath(d2.Destination.ID), `{}`), 200, "")
		hn.wantStatus(hn.as(alice, "POST", destTestPath(d.Destination.ID), `{}`), 429, "rate_limited")
		hn.wantStatus(hn.as(bob, "POST", "/api/notify/ntfy", `{}`), 200, "")
		hn.wantStatus(hn.as(bob, "POST", ntfyTestPath, `{}`), 200, "")
		if len(hn.notifs.sends) != 4 {
			t.Fatalf("sends = %d, want 4", len(hn.notifs.sends))
		}
	})
	t.Run("concurrent calls on one target send once", func(t *testing.T) {
		hn := newHarness(t)
		useClock(hn)
		phoneReady(hn)
		const n = 20
		codes := make([]int, n)
		var wg sync.WaitGroup
		for i := range n {
			wg.Add(1)
			go func() {
				defer wg.Done()
				codes[i] = hn.as(alice, "POST", ntfyTestPath, `{}`).Code
			}()
		}
		wg.Wait()
		ok, limited := 0, 0
		for _, c := range codes {
			switch c {
			case http.StatusOK:
				ok++
			case http.StatusTooManyRequests:
				limited++
			}
		}
		if ok != 1 || limited != n-1 || len(hn.notifs.sends) != 1 {
			t.Fatalf("ok=%d limited=%d sends=%d, want 1, %d, 1", ok, limited, len(hn.notifs.sends), n-1)
		}
	})
}

func TestTestRoutesFailuresAreLoggedWithoutSecrets(t *testing.T) {
	hn := newHarness(t)
	useClock(hn)
	phoneReady(hn)
	d := hn.addDest(alice, "webhook", webhookURL)
	const echoed = "secrets.url " + webhookURL + " signing_secret=SIGNSECRET-echo "
	hn.notifs.sendErrs = []error{nerr(503, echoed), nerr(503, echoed)}
	hn.wantStatus(hn.as(alice, "POST", ntfyTestPath, `{}`), 500, "notify_unavailable")
	hn.wantStatus(hn.as(alice, "POST", destTestPath(d.Destination.ID), `{}`), 500, "notify_unavailable")
	hn.notifs.sendErrs = []error{nerr(422, msgNoPersonalDst+" "+echoed)}
	hn.notifs.lookupErr = nerr(503, echoed)
	hn.srv.Now = func() time.Time { return time.Date(2027, 1, 1, 0, 0, 0, 0, time.UTC) }
	hn.wantStatus(hn.as(alice, "POST", destTestPath(d.Destination.ID), `{}`), 500, "notify_unavailable")
	if hn.store.dests[0].Stale {
		t.Fatal("a failed lookup marked the row stale")
	}

	logs := hn.logs.String()
	for _, secret := range []string{webhookURL, "hooks.example.test", "SIGNSECRET", alice, "secrets.url"} {
		if strings.Contains(logs, secret) {
			t.Fatalf("the log contains %q:\n%s", secret, logs)
		}
	}
	if !strings.Contains(logs, "notify failed") {
		t.Fatal("the failures were not logged")
	}
}
