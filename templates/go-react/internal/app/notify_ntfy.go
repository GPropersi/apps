package app

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"math"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/gpropersi/apps/apps/tmplgoreact/internal/app/db"
	"github.com/gpropersi/apps/apps/tmplgoreact/internal/platform"
)

const testBody = "Notifications will reach you here."

// internal answers 500 internal and logs the step and the error class only (an error text can carry an email, a URL or a
// secret).
func (s *Server) internal(w http.ResponseWriter, r *http.Request, step string, err error) {
	s.Logger.Error("request failed", "method", r.Method, "path", r.URL.Path, "step", step, "class", errClass(err))
	writeError(w, http.StatusInternalServerError, "internal")
}

// notifyUnavailable answers 500 notify_unavailable and logs the step and the status code or class only: never the error
// text, an email, a URL or a secret. A nil err means no notifier is configured.
func (s *Server) notifyUnavailable(w http.ResponseWriter, r *http.Request, step string, err error) {
	attrs := []any{"method", r.Method, "path", r.URL.Path, "step", step}
	var ne *platform.NotifsError
	switch {
	case errors.As(err, &ne):
		attrs = append(attrs, "status", ne.Status)
	case errors.Is(err, platform.ErrNotifsUnconfigured):
		attrs = append(attrs, "class", "unconfigured")
	case err == nil:
		attrs = append(attrs, "class", "no_client")
	default:
		attrs = append(attrs, "class", "unavailable")
	}
	s.Logger.Error("notify failed", attrs...)
	writeError(w, http.StatusInternalServerError, "notify_unavailable")
}

// addPhone adds the phone state to out after a mutation has completed, read through s.Store (never inside a transaction).
// A failed read never fails the response: it is logged (step and class) and phone is omitted.
func (s *Server) addPhone(out map[string]any, r *http.Request, email, step string) {
	p, err := s.phoneState(r.Context(), email)
	if err != nil {
		s.Logger.Error("phone state read failed", "step", step, "class", errClass(err))
		return
	}
	out["phone"] = p
}

func (s *Server) setupURL(userID string) string {
	return platform.NotifsSetupURL(s.NotifsAppID, userID, s.NotifsName)
}

// testTitle is the title of a test notification: the app name from app.yaml, verbatim.
func (s *Server) testTitle() string { return s.NotifsName + " test notification" }

// emailDigest is the bounded, non-identifying token that stands for an email in an idempotency key.
func emailDigest(email string) string {
	sum := sha256.Sum256([]byte(email))
	return hex.EncodeToString(sum[:])[:16]
}

func (s *Server) testRateLimited(w http.ResponseWriter, retryAfter time.Duration) {
	secs := max(int(math.Ceil(retryAfter.Seconds())), 1)
	w.Header().Set("Retry-After", strconv.Itoa(secs))
	writeError(w, http.StatusTooManyRequests, "rate_limited")
}

// notifyPreamble is the start of every ntfy write: the normalised identity, then the capped body (ignored, but read so
// the 4 KiB cap answers 413).
func (s *Server) notifyPreamble(w http.ResponseWriter, r *http.Request) (string, bool) {
	email, _, ok := s.notifyPreambleBody(w, r)
	return email, ok
}

// notifyPreambleBody is notifyPreamble for a route that also uses the body.
func (s *Server) notifyPreambleBody(w http.ResponseWriter, r *http.Request) (string, []byte, bool) {
	email, ok := s.notifyEmail(w, r)
	if !ok {
		return "", nil, false
	}
	body, tooLarge := readBody(r)
	if tooLarge {
		writeError(w, http.StatusRequestEntityTooLarge, "too_large")
		return "", nil, false
	}
	return email, body, true
}

// handleNtfy sets the person up for phone push, or returns the existing setup (password null).
//
// Provision runs inside one transaction under a per-person advisory lock: a concurrent first call waits, then sees the
// stored id and never provisions again (a second provision would issue a fresh password and invalidate the first). It
// holds one pooled connection for one bounded notifs call; the pool is 2 connections against a role limit of 3, so do
// not raise it. Inside the closure every query uses q, never s.Store.
//
// If Provision succeeds but the local write (or the commit) then fails, the answer is 500 internal and the one-time
// password is lost (never logged or returned). Recovery: tap Set up again (the repeat provision returns password null
// and writes the missing row), then Generate for a new password.
func (s *Server) handleNtfy(w http.ResponseWriter, r *http.Request) {
	email, ok := s.notifyPreamble(w, r)
	if !ok {
		return
	}
	if s.Notifs == nil || s.Tx == nil {
		s.notifyUnavailable(w, r, "ntfy", nil)
		return
	}
	var userID, password string
	err := s.Tx.InTx(r.Context(), func(q db.Querier) error {
		ctx := r.Context()
		if err := q.LockNotifsEmail(ctx, email); err != nil {
			return err
		}
		cur, err := q.GetNtfyUserID(ctx, email)
		if err == nil && cur != "" {
			userID = cur
			return nil
		}
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		p, err := s.Notifs.Provision(ctx, email)
		if err != nil {
			return err
		}
		if p.UserID == "" {
			return platform.ErrNotifsRetryable
		}
		if err := q.SetNtfyUserID(ctx, db.SetNtfyUserIDParams{Email: email, NtfyUserID: p.UserID}); err != nil {
			return err
		}
		userID, password = p.UserID, p.Password
		return nil
	})
	if err != nil {
		if platform.IsNotifsErr(err) {
			s.notifyUnavailable(w, r, "ntfy provision", err)
			return
		}
		s.internal(w, r, "ntfy provision store", err)
		return
	}
	var pw *string
	if password != "" {
		pw = &password
	}
	out := map[string]any{"user_id": userID, "setup_url": s.setupURL(userID), "password": pw}
	s.addPhone(out, r, email, "ntfy")
	writeJSON(w, http.StatusOK, out)
}

// storedNtfyUser reads the person's ntfy id; ok is false (and the 409 is written) when they are not set up.
func (s *Server) storedNtfyUser(w http.ResponseWriter, r *http.Request, email, step string) (id string, ok bool) {
	id, err := s.Store.GetNtfyUserID(r.Context(), email)
	switch {
	case errors.Is(err, pgx.ErrNoRows), err == nil && id == "":
		writeError(w, http.StatusConflict, "ntfy_not_set_up")
		return "", false
	case err != nil:
		s.internal(w, r, step, err)
		return "", false
	}
	return id, true
}

func (s *Server) handleNtfyReset(w http.ResponseWriter, r *http.Request) {
	email, ok := s.notifyPreamble(w, r)
	if !ok {
		return
	}
	stored, ok := s.storedNtfyUser(w, r, email, "ntfy reset user")
	if !ok {
		return
	}
	if s.Notifs == nil {
		s.notifyUnavailable(w, r, "ntfy reset", nil)
		return
	}
	res, err := s.Notifs.ResetPassword(r.Context(), email)
	if err != nil {
		switch platform.NotifsStatus(err) {
		case http.StatusNotFound:
			writeError(w, http.StatusConflict, "ntfy_not_set_up")
		case http.StatusTooManyRequests:
			writeError(w, http.StatusTooManyRequests, "rate_limited")
		default:
			s.notifyUnavailable(w, r, "ntfy reset", err)
		}
		return
	}
	if res.Password == "" {
		// The old password is already invalid: never show the person a blank one.
		s.notifyUnavailable(w, r, "ntfy reset", platform.ErrNotifsRetryable)
		return
	}
	userID := res.UserID
	if userID == "" {
		userID = stored
	}
	out := map[string]any{"password": res.Password, "setup_url": s.setupURL(userID)}
	s.addPhone(out, r, email, "ntfy reset")
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleNtfyTest(w http.ResponseWriter, r *http.Request) {
	email, ok := s.notifyPreamble(w, r)
	if !ok {
		return
	}
	// Preconditions come before the limiter so they never start the cooldown.
	if _, ok := s.storedNtfyUser(w, r, email, "ntfy test user"); !ok {
		return
	}
	if s.Notifs == nil {
		s.notifyUnavailable(w, r, "ntfy test", nil)
		return
	}
	if wait, ok := s.testLimiter().Allow(email + "|ntfy"); !ok {
		s.testRateLimited(w, wait)
		return
	}
	m := platform.TestMessage(s.testTitle(), testBody, email, "ntfy", "ntfy-"+emailDigest(email), nil, s.now())
	if _, err := platform.SendWithPublisher(r.Context(), s.Notifs, m); err != nil {
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
	out := map[string]any{}
	s.addPhone(out, r, email, "ntfy test")
	writeJSON(w, http.StatusOK, out)
}
