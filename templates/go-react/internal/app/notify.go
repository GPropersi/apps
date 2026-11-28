package app

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/gpropersi/apps/apps/tmplgoreact/internal/platform"
)

// testCooldown is how long one person must wait between test sends to the same target.
const testCooldown = 30 * time.Second

// phoneJSON is the phone-notification state the web shows: whether ntfy is set up and how many destinations exist.
type phoneJSON struct {
	Ntfy              bool `json:"ntfy"`
	Destinations      int  `json:"destinations"`
	StaleDestinations int  `json:"stale_destinations"`
}

// meJSON is the GET /api/me answer. Phone is present only when notifs is on and the phone-state read worked.
type meJSON struct {
	Email  string     `json:"email"`
	Notifs bool       `json:"notifs"`
	Phone  *phoneJSON `json:"phone,omitempty"`
}

// noStore keeps every /api response (including 401) out of caches: it carries personal state and one-time secrets.
func noStore(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

// notifyEmail is the identity in the form 4irl-notifs and the notify tables use: trimmed and lower-cased. It answers 401
// when nothing is left. email() stays as it was, so created_by keeps its behaviour.
func (s *Server) notifyEmail(w http.ResponseWriter, r *http.Request) (string, bool) {
	email, ok := s.EmailOf(r)
	email = strings.ToLower(strings.TrimSpace(email))
	if !ok || email == "" {
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return "", false
	}
	return email, true
}

// phoneState reads one person's phone state. A person with no notifs_users row is simply not set up.
func (s *Server) phoneState(ctx context.Context, email string) (phoneJSON, error) {
	var p phoneJSON
	if _, err := s.Store.GetNtfyUserID(ctx, email); err == nil {
		p.Ntfy = true
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return phoneJSON{}, fmt.Errorf("ntfy user: %w", err)
	}
	counts, err := s.Store.GetDestinationCounts(ctx, email)
	if err != nil {
		return phoneJSON{}, fmt.Errorf("destination counts: %w", err)
	}
	p.Destinations, p.StaleDestinations = int(counts.Total), int(counts.Stale)
	return p, nil
}

// now is the server clock; tests set Now.
func (s *Server) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// testLimiter is the per-person, per-target test-send cooldown, created on first use with a late-bound clock.
func (s *Server) testLimiter() *platform.TestLimiter {
	s.limiterOnce.Do(func() {
		s.limiter = platform.NewTestLimiter(testCooldown, func() time.Time { return s.now() })
	})
	return s.limiter
}

// errClass names an error's type for logs, which never carry the error text of a notify failure.
func errClass(err error) string { return fmt.Sprintf("%T", err) }
