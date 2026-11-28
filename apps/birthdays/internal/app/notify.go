package app

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/gpropersi/apps/apps/birthdays/internal/app/db"
	"github.com/gpropersi/apps/apps/birthdays/internal/platform"
)

const (
	maxDestinations  = 10
	notifsSetupName  = "Birthdays"
	cleanupTimeout   = 5 * time.Second
	signingSecretLen = 32
)

// Notifier is the part of the 4irl-notifs client the notification settings routes use; *platform.NotifsClient
// satisfies it and tests fake it. A nil Notifier answers every notify call 500 notify_unavailable.
type Notifier = platform.Notifier

// destinationJSON is D from the HTTP API contract. It never carries the URL.
type destinationJSON struct {
	ID    int64  `json:"id"`
	Kind  string `json:"kind"`
	Label string `json:"label"`
	Hint  string `json:"hint"`
	Stale bool   `json:"stale"`
}

// noStore marks a response as uncacheable: notify answers can carry one-time secrets.
func noStore(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) setupURL(userID string) string {
	return platform.NotifsSetupURL(s.NotifsAppID, userID, notifsSetupName)
}

// notifyUnavailable answers 500 notify_unavailable and logs the step and the status code only: never the error text
// (it can echo a request value), an email, a URL or a secret.
func (s *Server) notifyUnavailable(w http.ResponseWriter, r *http.Request, op string, err error) {
	attrs := []any{"method", r.Method, "path", r.URL.Path, "step", op}
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

func destJSON(id int64, kind, label, hint string, stale bool) destinationJSON {
	return destinationJSON{ID: id, Kind: kind, Label: label, Hint: hint, Stale: stale}
}

func (s *Server) handleNtfy(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	if s.Notifs == nil {
		s.notifyUnavailable(w, r, "ntfy", nil)
		return
	}
	var userID, password string
	// One transaction under a per-user advisory lock: a concurrent first call waits, then sees the stored id and never
	// provisions again (a second provision would issue a fresh token and invalidate the first). This is the one place
	// a notifs call sits inside a transaction; it holds one pool connection for one 10 s-bounded call.
	err := s.Tx.InTx(r.Context(), func(q db.Querier) error {
		ctx := r.Context()
		if err := q.LockUserNtfy(ctx, v.user.ID); err != nil {
			return err
		}
		cur, err := q.GetNtfyUser(ctx, v.user.ID)
		if err != nil {
			return err
		}
		if cur.Valid && cur.String != "" {
			userID = cur.String
			return nil
		}
		p, err := s.Notifs.Provision(ctx, v.email)
		if err != nil {
			return err
		}
		if p.UserID == "" {
			return platform.ErrNotifsRetryable
		}
		if err := q.SetNtfyUser(ctx, db.SetNtfyUserParams{NtfyUserID: pgtype.Text{String: p.UserID, Valid: true}, UserID: v.user.ID}); err != nil {
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
	v.user.NtfyUserID = pgtype.Text{String: userID, Valid: true}
	set, err := s.settingsFor(r.Context(), v.user)
	if err != nil {
		s.internal(w, r, "settings", err)
		return
	}
	var pw *string
	if password != "" {
		pw = &password
	}
	writeJSON(w, http.StatusOK, map[string]any{"user_id": userID, "setup_url": s.setupURL(userID), "password": pw, "settings": set})
}

func (s *Server) handleNtfyReset(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	if !v.user.NtfyUserID.Valid {
		writeError(w, http.StatusConflict, "ntfy_not_set_up")
		return
	}
	if s.Notifs == nil {
		s.notifyUnavailable(w, r, "ntfy reset", nil)
		return
	}
	res, err := s.Notifs.ResetPassword(r.Context(), v.email)
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
		userID = v.user.NtfyUserID.String
	}
	set, err := s.settingsFor(r.Context(), v.user)
	if err != nil {
		s.internal(w, r, "settings", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"password": res.Password, "setup_url": s.setupURL(userID), "settings": set})
}

func (s *Server) handleListDestinations(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	rows, err := s.Store.ListDestinations(r.Context(), v.user.ID)
	if err != nil {
		s.internal(w, r, "list destinations", err)
		return
	}
	out := make([]destinationJSON, 0, len(rows))
	for _, d := range rows {
		out = append(out, destJSON(d.ID, d.Kind, d.Label, d.Hint, d.Stale))
	}
	writeJSON(w, http.StatusOK, map[string]any{"destinations": out})
}

// validDestination checks the kind, label and URL through the shared rules and returns the 400 code on failure.
func validDestination(kind, label, rawURL string) (cleanLabel, code string) {
	clean, err := platform.ValidDestination(kind, label, rawURL)
	switch {
	case err == nil:
		return clean, ""
	case errors.Is(err, platform.ErrInvalidLabel):
		return "", "invalid_label"
	default: // ErrInvalidURL and anything unforeseen: fail closed
		return "", "invalid_url"
	}
}

func (s *Server) handlePostDestination(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	var body struct {
		Kind  string `json:"kind"`
		Label string `json:"label"`
		URL   string `json:"url"`
	}
	if ok, handled := decodeBody(w, r, &body); !ok {
		if !handled {
			writeError(w, http.StatusBadRequest, "invalid_url")
		}
		return
	}
	if body.Kind != "discord" && body.Kind != "webhook" {
		writeError(w, http.StatusBadRequest, "invalid_url")
		return
	}
	label, code := validDestination(body.Kind, body.Label, body.URL)
	if code != "" {
		writeError(w, http.StatusBadRequest, code)
		return
	}
	ctx := r.Context()
	if n, err := s.Store.CountDestinations(ctx, v.user.ID); err != nil {
		s.internal(w, r, "count destinations", err)
		return
	} else if n >= maxDestinations {
		writeError(w, http.StatusConflict, "too_many_destinations")
		return
	}
	if s.Notifs == nil {
		s.notifyUnavailable(w, r, "create destination", nil)
		return
	}

	in := platform.PersonalDestinationInput{Label: label, Type: body.Kind}
	signingSecret := ""
	if body.Kind == "discord" {
		in.Secrets = map[string]string{"webhook_url": body.URL}
	} else {
		raw := make([]byte, signingSecretLen)
		if _, err := rand.Read(raw); err != nil {
			s.internal(w, r, "signing secret", errors.New("random source failed"))
			return
		}
		signingSecret = base64.RawURLEncoding.EncodeToString(raw)
		in.Secrets = map[string]string{"url": body.URL, "signing_secret": signingSecret}
	}
	notifsID, err := s.Notifs.CreatePersonalDestination(ctx, v.email, in)
	if err != nil {
		var ne *platform.NotifsError
		if errors.As(err, &ne) && ne.Status == http.StatusBadRequest {
			if strings.Contains(ne.Message, "must resolve to public addresses") {
				writeError(w, http.StatusBadRequest, "url_not_public")
			} else {
				writeError(w, http.StatusBadRequest, "invalid_url")
			}
			return
		}
		s.notifyUnavailable(w, r, "create destination", err)
		return
	}

	var row db.InsertDestinationRow
	full := false
	err = s.Tx.InTx(ctx, func(q db.Querier) error {
		// The count check and insert run under the user's row lock so two parallel adds cannot both pass the limit.
		if _, err := q.LockUser(ctx, v.user.ID); err != nil {
			return err
		}
		n, err := q.CountDestinations(ctx, v.user.ID)
		if err != nil {
			return err
		}
		if n >= maxDestinations {
			full = true
			return nil
		}
		row, err = q.InsertDestination(ctx, db.InsertDestinationParams{UserID: v.user.ID, NotifsID: notifsID, Kind: body.Kind,
			Label: label, Hint: platform.DestinationHint(body.URL)})
		return err
	})
	if err != nil || full {
		// The remote destination was created but not stored: remove it so it is not orphaned (best effort).
		cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cleanupTimeout)
		defer cancel()
		if derr := s.Notifs.DeletePersonalDestination(cctx, v.email, notifsID); derr != nil {
			s.Logger.Warn("notify cleanup failed", "step", "delete orphan destination", "status", platform.NotifsStatus(derr))
		}
		if full {
			writeError(w, http.StatusConflict, "too_many_destinations")
			return
		}
		s.internal(w, r, "store destination", err)
		return
	}
	set, err := s.settingsFor(ctx, v.user)
	if err != nil {
		s.internal(w, r, "settings", err)
		return
	}
	resp := map[string]any{"destination": destJSON(row.ID, row.Kind, row.Label, row.Hint, row.Stale), "settings": set}
	if signingSecret != "" {
		resp["signing_secret"] = signingSecret
	}
	writeJSON(w, http.StatusCreated, resp)
}

func (s *Server) handleCheckDestination(w http.ResponseWriter, r *http.Request) {
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
		if s.Notifs == nil {
			s.notifyUnavailable(w, r, "check destination", nil)
			return
		}
		ok, err := s.Notifs.LookupPersonalDestinations(ctx, v.email, []int64{d.NotifsID})
		if err != nil {
			s.notifyUnavailable(w, r, "check destination", err)
			return
		}
		// Only a deliverable id (enabled and opted in) clears the flag; opt-in is never changed here.
		if ok[d.NotifsID] {
			n, err := s.Store.SetOwnDestinationStale(ctx, db.SetOwnDestinationStaleParams{Stale: false, DestinationID: id, UserID: v.user.ID})
			if err != nil {
				s.internal(w, r, "clear stale", err)
				return
			}
			if n == 0 { // deleted concurrently
				writeError(w, http.StatusNotFound, "not_found")
				return
			}
			d.Stale = false
		}
	}
	set, err := s.settingsFor(ctx, v.user)
	if err != nil {
		s.internal(w, r, "settings", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"destination": destJSON(d.ID, d.Kind, d.Label, d.Hint, d.Stale), "settings": set})
}

func (s *Server) handleDeleteDestination(w http.ResponseWriter, r *http.Request) {
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
	if s.Notifs == nil {
		s.notifyUnavailable(w, r, "delete destination", nil)
		return
	}
	// A delivery-api 404 means it is already gone there, so the local row still goes; any other failure keeps the row.
	if err := s.Notifs.DeletePersonalDestination(ctx, v.email, d.NotifsID); err != nil && platform.NotifsStatus(err) != http.StatusNotFound {
		s.notifyUnavailable(w, r, "delete destination", err)
		return
	}
	if _, err := s.Store.DeleteOwnDestination(ctx, db.DeleteOwnDestinationParams{DestinationID: id, UserID: v.user.ID}); err != nil {
		s.internal(w, r, "delete destination row", err)
		return
	}
	set, err := s.settingsFor(ctx, v.user)
	if err != nil {
		s.internal(w, r, "settings", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"settings": set})
}
