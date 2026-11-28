package app

import (
	"errors"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/gpropersi/apps/apps/birthdays/internal/app/db"
	"github.com/gpropersi/apps/apps/birthdays/internal/platform"
)

const (
	// testCooldown is the minimum gap between two test sends to the same target for the same person.
	testCooldown = 30 * time.Second

	testTitle = "Birthdays test notification"
	testBody  = "Reminders will reach you here."
)

func (s *Server) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// limiter is the test-send limiter, created on first use so a Server built as a struct literal works. Its clock is
// late-bound: a test that swaps Server.Now after construction is honoured.
func (s *Server) limiter() *platform.TestLimiter {
	s.limiterOnce.Do(func() {
		s.testLimiter = platform.NewTestLimiter(testCooldown, func() time.Time { return s.now() })
	})
	return s.testLimiter
}

func (s *Server) testRateLimited(w http.ResponseWriter, retryAfter time.Duration) {
	secs := max(int(math.Ceil(retryAfter.Seconds())), 1)
	w.Header().Set("Retry-After", strconv.Itoa(secs))
	writeError(w, http.StatusTooManyRequests, "rate_limited")
}

// testMessage is the one-off message both test routes send, through the same Send the reminder job uses.
func testMessage(email, target string, userID int64, now time.Time, via string, ids []int64) platform.Message {
	// key keeps the idempotency key test-<target>-<userID>-<unixnano>.
	return platform.TestMessage(testTitle, testBody, email, via, fmt.Sprintf("%s-%d", target, userID), ids, now)
}

func (s *Server) handleNtfyTest(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	if !v.user.NtfyUserID.Valid || v.user.NtfyUserID.String == "" {
		writeError(w, http.StatusConflict, "ntfy_not_set_up")
		return
	}
	if s.Notifs == nil {
		s.notifyUnavailable(w, r, "ntfy test", nil)
		return
	}
	if wait, ok := s.limiter().Allow(fmt.Sprintf("%d|ntfy", v.user.ID)); !ok {
		s.testRateLimited(w, wait)
		return
	}
	ctx := r.Context()
	m := testMessage(v.email, "ntfy", v.user.ID, s.now(), "ntfy", nil)
	_, err := platform.SendWithPublisher(ctx, s.Notifs, m)
	if err != nil {
		switch {
		case platform.IsNotifsMsg(err, platform.MsgNoDestMatched):
			writeError(w, http.StatusConflict, "ntfy_not_set_up")
		case platform.NotifsStatus(err) == http.StatusTooManyRequests:
			writeError(w, http.StatusTooManyRequests, "rate_limited")
		default:
			s.notifyUnavailable(w, r, "ntfy test", err)
		}
		return
	}
	s.writeTestOK(w, r, v.user)
}

func (s *Server) handleDestinationTest(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	ctx := r.Context()
	d, err := s.Store.GetOwnDestination(ctx, db.GetOwnDestinationParams{DestinationID: id, UserID: v.user.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		s.internal(w, r, "get destination", err)
		return
	}
	if d.Stale {
		writeError(w, http.StatusConflict, "destination_stale")
		return
	}
	if s.Notifs == nil {
		s.notifyUnavailable(w, r, "destination test", nil)
		return
	}
	if wait, ok := s.limiter().Allow(fmt.Sprintf("%d|dst-%d", v.user.ID, d.ID)); !ok {
		s.testRateLimited(w, wait)
		return
	}
	m := testMessage(v.email, fmt.Sprintf("dst-%d", d.ID), v.user.ID, s.now(), "personal", []int64{d.NotifsID})
	_, err = s.Notifs.Send(ctx, m)
	if err != nil {
		switch {
		case platform.IsNotifsMsg(err, platform.MsgNoPersonalDst):
			s.staleAfterRejectedTest(w, r, v, d)
		case platform.NotifsStatus(err) == http.StatusTooManyRequests:
			writeError(w, http.StatusTooManyRequests, "rate_limited")
		default:
			// Any other 422 and every 409 land here: a delivery-api config problem must not stale a good destination.
			s.notifyUnavailable(w, r, "destination test", err)
		}
		return
	}
	s.writeTestOK(w, r, v.user)
}

// staleAfterRejectedTest marks the destination stale only when the lookup confirms it is not deliverable, as the
// reminder job does, and commits that before answering 409.
func (s *Server) staleAfterRejectedTest(w http.ResponseWriter, r *http.Request, v viewer, d db.GetOwnDestinationRow) {
	ctx := r.Context()
	ok, err := s.Notifs.LookupPersonalDestinations(ctx, v.email, []int64{d.NotifsID})
	if err != nil {
		s.notifyUnavailable(w, r, "destination test lookup", err)
		return
	}
	if ok[d.NotifsID] {
		s.notifyUnavailable(w, r, "destination test", errors.New("rejected but deliverable"))
		return
	}
	n, err := s.Store.SetOwnDestinationStale(ctx, db.SetOwnDestinationStaleParams{Stale: true, DestinationID: d.ID, UserID: v.user.ID})
	if err != nil {
		s.internal(w, r, "stale destination", err)
		return
	}
	if n == 0 { // deleted concurrently
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	writeError(w, http.StatusConflict, "destination_stale")
}

func (s *Server) writeTestOK(w http.ResponseWriter, r *http.Request, u db.User) {
	set, err := s.settingsFor(r.Context(), u)
	if err != nil {
		s.internal(w, r, "settings", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"settings": set})
}
