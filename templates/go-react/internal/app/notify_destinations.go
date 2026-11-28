package app

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"

	"github.com/gpropersi/apps/apps/tmplgoreact/internal/app/db"
	"github.com/gpropersi/apps/apps/tmplgoreact/internal/platform"
)

const (
	maxDestinations  = 10
	cleanupTimeout   = 5 * time.Second
	signingSecretLen = 32
)

// errTooManyDestinations is the in-transaction signal that the cap was reached (answered 409, nothing created).
var errTooManyDestinations = errors.New("too many destinations")

// destinationJSON is D from the wire contract. It never carries the URL or a signing secret.
type destinationJSON struct {
	ID    int64  `json:"id"`
	Kind  string `json:"kind"`
	Label string `json:"label"`
	Hint  string `json:"hint"`
	Stale bool   `json:"stale"`
}

func pathID(r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil || id < 1 {
		return 0, false
	}
	return id, true
}

// ownDestination is the start of every route that names a destination: the normalised identity, the capped body (ignored
// but read so the 4 KiB cap answers 413), the numeric id and the row, scoped to the caller's email. Anything missing,
// non-numeric or another person's is 404 not_found.
func (s *Server) ownDestination(w http.ResponseWriter, r *http.Request) (string, db.GetOwnDestinationRow, bool) {
	email, ok := s.notifyPreamble(w, r)
	if !ok {
		return "", db.GetOwnDestinationRow{}, false
	}
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return "", db.GetOwnDestinationRow{}, false
	}
	d, err := s.Store.GetOwnDestination(r.Context(), db.GetOwnDestinationParams{DestinationID: id, Email: email})
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		writeError(w, http.StatusNotFound, "not_found")
		return "", db.GetOwnDestinationRow{}, false
	case err != nil:
		s.internal(w, r, "get destination", err)
		return "", db.GetOwnDestinationRow{}, false
	}
	return email, d, true
}

func (s *Server) handleListDestinations(w http.ResponseWriter, r *http.Request) {
	email, ok := s.notifyEmail(w, r)
	if !ok {
		return
	}
	rows, err := s.Store.ListDestinations(r.Context(), email)
	if err != nil {
		s.internal(w, r, "list destinations", err)
		return
	}
	out := make([]destinationJSON, 0, len(rows))
	for _, d := range rows {
		out = append(out, destinationJSON{ID: d.ID, Kind: d.Kind, Label: d.Label, Hint: d.Hint, Stale: d.Stale})
	}
	writeJSON(w, http.StatusOK, map[string]any{"destinations": out})
}

// validDestination maps the shared rules to the 400 code; anything unforeseen fails closed as invalid_url.
func validDestination(kind, label, rawURL string) (cleanLabel, code string) {
	clean, err := platform.ValidDestination(kind, label, rawURL)
	switch {
	case err == nil:
		return clean, ""
	case errors.Is(err, platform.ErrInvalidLabel):
		return "", "invalid_label"
	default:
		return "", "invalid_url"
	}
}

// handleDestinationCreate adds a Discord or webhook destination.
//
// The count check, the remote create and the insert all run in one transaction under the per-person advisory lock, so
// concurrent adds cannot pass the cap together and a request that gives up while waiting for the lock never creates a
// remote destination. If the remote destination was created but the local insert or the commit fails, the remote one is
// deleted again (best effort, on a detached context bounded by cleanupTimeout).
//
// Known limits: a create that fails ambiguously (timeout after delivery-api stored it) leaves no id to clean up, and a
// commit that errors after committing makes the cleanup delete the remote copy of a stored row; the check and test
// routes then mark that row stale, so the person re-adds it.
//
// A webhook's signing_secret is generated here, sent to delivery-api and returned once in the 201; it is never stored or
// logged.
func (s *Server) handleDestinationCreate(w http.ResponseWriter, r *http.Request) {
	email, payload, ok := s.notifyPreambleBody(w, r)
	if !ok {
		return
	}
	var body struct {
		Kind  string `json:"kind"`
		Label string `json:"label"`
		URL   string `json:"url"`
	}
	if err := json.Unmarshal(payload, &body); err != nil || (body.Kind != "discord" && body.Kind != "webhook") {
		writeError(w, http.StatusBadRequest, "invalid_url")
		return
	}
	label, code := validDestination(body.Kind, body.Label, body.URL)
	if code != "" {
		writeError(w, http.StatusBadRequest, code)
		return
	}
	if s.Notifs == nil || s.Tx == nil {
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

	ctx := r.Context()
	var row db.InsertDestinationRow
	var notifsID int64
	var createErr error
	err := s.Tx.InTx(ctx, func(q db.Querier) error {
		if err := q.LockNotifsEmail(ctx, email); err != nil {
			return err
		}
		n, err := q.CountDestinations(ctx, email)
		if err != nil {
			return err
		}
		if n >= maxDestinations {
			return errTooManyDestinations
		}
		id, err := s.Notifs.CreatePersonalDestination(ctx, email, in)
		if err != nil {
			createErr = err
			return err
		}
		notifsID = id
		row, err = q.InsertDestination(ctx, db.InsertDestinationParams{Email: email, NotifsID: id, Kind: body.Kind,
			Label: label, Hint: platform.DestinationHint(body.URL)})
		return err
	})
	switch {
	case err == nil:
	case errors.Is(err, errTooManyDestinations):
		writeError(w, http.StatusConflict, "too_many_destinations")
		return
	case createErr != nil:
		s.createFailed(w, r, createErr)
		return
	default:
		if notifsID != 0 {
			// The remote destination exists but was not stored: remove it so it is not orphaned.
			cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), cleanupTimeout)
			defer cancel()
			if derr := s.Notifs.DeletePersonalDestination(cctx, email, notifsID); derr != nil {
				s.Logger.Warn("notify cleanup failed", "step", "delete orphan destination", "status", platform.NotifsStatus(derr))
			}
		}
		s.internal(w, r, "store destination", err)
		return
	}
	out := map[string]any{"destination": destinationJSON{ID: row.ID, Kind: row.Kind, Label: row.Label, Hint: row.Hint, Stale: row.Stale}}
	if signingSecret != "" {
		out["signing_secret"] = signingSecret
	}
	s.addPhone(out, r, email, "create destination")
	writeJSON(w, http.StatusCreated, out)
}

// createFailed answers a failed remote create: a delivery-api 400 is the person's URL (public-address rule or not),
// anything else is notify_unavailable.
func (s *Server) createFailed(w http.ResponseWriter, r *http.Request, err error) {
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
}

// handleDestinationCheck re-checks a stale destination: a deliverable one is un-staled. Only a stale row asks the
// notifier; a non-stale row answers unchanged with no remote call.
func (s *Server) handleDestinationCheck(w http.ResponseWriter, r *http.Request) {
	email, d, ok := s.ownDestination(w, r)
	if !ok {
		return
	}
	if d.Stale {
		if s.Notifs == nil {
			s.notifyUnavailable(w, r, "check destination", nil)
			return
		}
		found, err := s.Notifs.LookupPersonalDestinations(r.Context(), email, []int64{d.NotifsID})
		if err != nil {
			s.notifyUnavailable(w, r, "check destination", err)
			return
		}
		// Only a deliverable id clears the flag; an undeliverable one stays stale and still answers 200.
		if found[d.NotifsID] {
			n, err := s.Store.SetOwnDestinationStale(r.Context(), db.SetOwnDestinationStaleParams{Stale: false, DestinationID: d.ID, Email: email})
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
	out := map[string]any{"destination": destinationJSON{ID: d.ID, Kind: d.Kind, Label: d.Label, Hint: d.Hint, Stale: d.Stale}}
	s.addPhone(out, r, email, "check destination")
	writeJSON(w, http.StatusOK, out)
}

// handleDestinationDelete removes the remote destination first and then the local row. A failed remote delete answers
// 500 notify_unavailable and keeps the row so the person can retry; a remote 404 counts as already gone, so if the local
// delete then fails (500) the retry succeeds. destinations.notifs_id has no foreign key and no UNIQUE on purpose: the
// remote id is owned by delivery-api.
func (s *Server) handleDestinationDelete(w http.ResponseWriter, r *http.Request) {
	email, d, ok := s.ownDestination(w, r)
	if !ok {
		return
	}
	if s.Notifs == nil {
		s.notifyUnavailable(w, r, "delete destination", nil)
		return
	}
	if err := s.Notifs.DeletePersonalDestination(r.Context(), email, d.NotifsID); err != nil && platform.NotifsStatus(err) != http.StatusNotFound {
		s.notifyUnavailable(w, r, "delete destination", err)
		return
	}
	if _, err := s.Store.DeleteOwnDestination(r.Context(), db.DeleteOwnDestinationParams{DestinationID: d.ID, Email: email}); err != nil {
		s.internal(w, r, "delete destination row", err)
		return
	}
	out := map[string]any{}
	s.addPhone(out, r, email, "delete destination")
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleDestinationTest(w http.ResponseWriter, r *http.Request) {
	email, d, ok := s.ownDestination(w, r)
	if !ok {
		return
	}
	// Preconditions come before the limiter so they never start the cooldown.
	if d.Stale {
		writeError(w, http.StatusConflict, "destination_stale")
		return
	}
	if s.Notifs == nil {
		s.notifyUnavailable(w, r, "destination test", nil)
		return
	}
	target := "dst-" + strconv.FormatInt(d.ID, 10)
	if wait, ok := s.testLimiter().Allow(email + "|" + target); !ok {
		s.testRateLimited(w, wait)
		return
	}
	m := platform.TestMessage(s.testTitle(), testBody, email, "personal", target+"-"+emailDigest(email), []int64{d.NotifsID}, s.now())
	if _, err := s.Notifs.Send(r.Context(), m); err != nil {
		switch {
		case platform.IsNotifsMsg(err, platform.MsgNoPersonalDst):
			s.staleAfterRejectedTest(w, r, email, d)
		case platform.NotifsStatus(err) == http.StatusTooManyRequests:
			writeError(w, http.StatusTooManyRequests, "rate_limited")
		default:
			// Any other 422 and every 409 land here: a delivery-api config problem must not stale a good destination.
			s.notifyUnavailable(w, r, "destination test", err)
		}
		return
	}
	out := map[string]any{}
	s.addPhone(out, r, email, "destination test")
	writeJSON(w, http.StatusOK, out)
}

// staleAfterRejectedTest marks the destination stale only when the lookup confirms it is not deliverable.
func (s *Server) staleAfterRejectedTest(w http.ResponseWriter, r *http.Request, email string, d db.GetOwnDestinationRow) {
	found, err := s.Notifs.LookupPersonalDestinations(r.Context(), email, []int64{d.NotifsID})
	if err != nil {
		s.notifyUnavailable(w, r, "destination test lookup", err)
		return
	}
	if found[d.NotifsID] {
		s.notifyUnavailable(w, r, "destination test", errors.New("rejected but deliverable"))
		return
	}
	n, err := s.Store.SetOwnDestinationStale(r.Context(), db.SetOwnDestinationStaleParams{Stale: true, DestinationID: d.ID, Email: email})
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
