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

	msgNoDestMatched = "no destination matched"
	testTitle        = "Birthdays test notification"
	testBody         = "Reminders will reach you here."
)

func (s *Server) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// allowTest is the test-send limiter. Lookup and record are one locked step so concurrent requests on one target cannot
// both pass. It is in-process (reset by a restart, not shared across replicas), which is accepted for a 30 s anti-spam
// guard. When refused it returns how long until the target may be tested again.
func (s *Server) allowTest(key string) (retryAfter time.Duration, ok bool) {
	now := s.now()
	s.testMu.Lock()
	defer s.testMu.Unlock()
	for k, started := range s.testSeen {
		if !now.Before(started.Add(testCooldown)) {
			delete(s.testSeen, k)
		}
	}
	if started, seen := s.testSeen[key]; seen {
		return started.Add(testCooldown).Sub(now), false
	}
	if s.testSeen == nil {
		s.testSeen = map[string]time.Time{}
	}
	s.testSeen[key] = now
	return 0, true
}

func (s *Server) testRateLimited(w http.ResponseWriter, retryAfter time.Duration) {
	secs := max(int(math.Ceil(retryAfter.Seconds())), 1)
	w.Header().Set("Retry-After", strconv.Itoa(secs))
	writeError(w, http.StatusTooManyRequests, "rate_limited")
}

// testMessage is the one-off message both test routes send, through the same Send the reminder job uses.
func testMessage(email, target string, userID int64, now time.Time, via string, ids []int64) platform.Message {
	return platform.Message{
		Channel:                "all",
		IdempotencyKey:         fmt.Sprintf("test-%s-%d-%d", target, userID, now.UnixNano()), // unique per click: a fixed key would dedupe
		Recipient:              email,
		Via:                    via,
		PersonalDestinationIDs: ids,
		Title:                  testTitle,
		Body:                   testBody,
	}
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
	if wait, ok := s.allowTest(fmt.Sprintf("%d|ntfy", v.user.ID)); !ok {
		s.testRateLimited(w, wait)
		return
	}
	ctx := r.Context()
	m := testMessage(v.email, "ntfy", v.user.ID, s.now(), "ntfy", nil)
	_, err := s.Notifs.Send(ctx, m)
	if isNotifsMsg(err, msgNoPublisher) {
		if perr := s.Notifs.EnsurePublisher(ctx); perr != nil {
			if notifsStatus(perr) == http.StatusTooManyRequests {
				writeError(w, http.StatusTooManyRequests, "rate_limited")
				return
			}
			s.notifyUnavailable(w, r, "ntfy test publisher", perr)
			return
		}
		_, err = s.Notifs.Send(ctx, m) // same key; a second missing publisher falls through to 500, no loop
	}
	if err != nil {
		switch {
		case isNotifsMsg(err, msgNoDestMatched):
			writeError(w, http.StatusConflict, "ntfy_not_set_up")
		case notifsStatus(err) == http.StatusTooManyRequests:
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
	if wait, ok := s.allowTest(fmt.Sprintf("%d|dst-%d", v.user.ID, d.ID)); !ok {
		s.testRateLimited(w, wait)
		return
	}
	m := testMessage(v.email, fmt.Sprintf("dst-%d", d.ID), v.user.ID, s.now(), "personal", []int64{d.NotifsID})
	_, err = s.Notifs.Send(ctx, m)
	if err != nil {
		switch {
		case isNotifsMsg(err, msgNoPersonalDst):
			s.staleAfterRejectedTest(w, r, v, d)
		case notifsStatus(err) == http.StatusTooManyRequests:
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
