package app

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/gpropersi/apps/apps/birthdays/internal/app/db"
)

const (
	maxOwnedBirthdays = 500
	maxSharesPerB     = 20
	maxGiftsPerAuthor = 50
	maxEmailLen       = 254
)

var emailPattern = regexp.MustCompile(`^[^@\s]+@[^@\s]+\.[^@\s]+$`)

// Enum values the settings columns accept (they mirror the table CHECKs).
var (
	startTabs     = []string{"auto", "add", "view"}
	listViews     = []string{"upcoming", "month", "name", "calendar"}
	calendarZooms = []string{"year", "month", "week"}
	colorSchemes  = []string{"confetti", "frosting", "candle"}
)

// settingsJSON is S from the HTTP API contract. The notify counters stay at their zero values until the notify routes
// land; ntfy comes from users.ntfy_user_id.
type settingsJSON struct {
	AutoRemind        bool    `json:"auto_remind"`
	DefaultOffsets    []int16 `json:"default_offsets"`
	StartTab          string  `json:"start_tab"`
	ListView          string  `json:"list_view"`
	CalendarZoom      string  `json:"calendar_zoom"`
	ColorScheme       string  `json:"color_scheme"`
	Ntfy              bool    `json:"ntfy"`
	Destinations      int64   `json:"destinations"`
	StaleDestinations int64   `json:"stale_destinations"`
}

type birthdayJSON struct {
	ID              int64   `json:"id"`
	Name            string  `json:"name"`
	Month           int16   `json:"month"`
	Day             int16   `json:"day"`
	Year            *int16  `json:"year"`
	IsMine          bool    `json:"is_mine"`
	OwnerEmail      string  `json:"owner_email"`
	ReminderOffsets []int16 `json:"reminder_offsets"`
}

type giftJSON struct {
	ID          int64  `json:"id"`
	Text        string `json:"text"`
	Shared      bool   `json:"shared"`
	AuthorEmail string `json:"author_email"`
	Mine        bool   `json:"mine"`
}

func nonNil(s []int16) []int16 {
	if s == nil {
		return []int16{}
	}
	return s
}

func yearPtr(y pgtype.Int2) *int16 {
	if !y.Valid {
		return nil
	}
	v := y.Int16
	return &v
}

func int2(y *int) pgtype.Int2 {
	if y == nil {
		return pgtype.Int2{}
	}
	return pgtype.Int2{Int16: int16(*y), Valid: true}
}

// viewer is the signed-in person: the lowercase identity email plus their users row.
type viewer struct {
	email string
	user  db.User
}

// ensureUser upserts the caller's users row. The Access identity is trimmed and lowercased here, once; no handler or
// query normalizes it again. It writes the error response itself when it fails.
func (s *Server) ensureUser(w http.ResponseWriter, r *http.Request) (viewer, bool) {
	email, ok := s.email(w, r)
	if !ok {
		return viewer{}, false
	}
	u, err := s.Store.UpsertUser(r.Context(), email)
	if err != nil {
		s.internal(w, r, "upsert user", err)
		return viewer{}, false
	}
	return viewer{email: email, user: u}, true
}

func (s *Server) internal(w http.ResponseWriter, r *http.Request, what string, err error) {
	s.Logger.Error("request failed", "method", r.Method, "path", r.URL.Path, "step", what, "err", err)
	writeError(w, http.StatusInternalServerError, "internal")
}

// decodeBody reads the capped body into dst. It answers 413 itself when the cap was hit and returns ok=false; a body
// that is not the expected JSON yields ok=false with handled=false so the caller picks its own 400 code.
func decodeBody(w http.ResponseWriter, r *http.Request, dst any) (ok, handled bool) {
	body, tooLarge := readBody(r)
	if tooLarge {
		writeError(w, http.StatusRequestEntityTooLarge, "too_large")
		return false, true
	}
	if err := json.Unmarshal(body, dst); err != nil {
		return false, false
	}
	return true, false
}

func pathID(r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil || id < 1 {
		return 0, false
	}
	return id, true
}

func (s *Server) settingsFor(ctx context.Context, u db.User) (settingsJSON, error) {
	counts, err := s.Store.GetDestinationCounts(ctx, u.ID)
	if err != nil {
		return settingsJSON{}, err
	}
	return settingsJSON{
		AutoRemind: u.AutoRemind, DefaultOffsets: nonNil(u.DefaultOffsets), StartTab: u.StartTab, ListView: u.ListView,
		CalendarZoom: u.CalendarZoom, ColorScheme: u.ColorScheme, Ntfy: u.NtfyUserID.Valid,
		Destinations: counts.Total, StaleDestinations: counts.Stale,
	}, nil
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	set, err := s.settingsFor(r.Context(), v.user)
	if err != nil {
		s.internal(w, r, "settings", err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"email": v.email, "settings": set})
}

// validOffsets checks every value is 0, 1 or 7 and removes duplicates (first occurrence wins). ok is false for any
// other value.
func validOffsets(in []int) (out []int16, ok bool) {
	out = []int16{}
	for _, o := range in {
		if o != 0 && o != 1 && o != 7 {
			return nil, false
		}
		if !slices.Contains(out, int16(o)) {
			out = append(out, int16(o))
		}
	}
	return out, true
}

func (s *Server) handlePatchSettings(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	var body struct {
		AutoRemind     *bool   `json:"auto_remind"`
		DefaultOffsets *[]int  `json:"default_offsets"`
		StartTab       *string `json:"start_tab"`
		ListView       *string `json:"list_view"`
		CalendarZoom   *string `json:"calendar_zoom"`
		ColorScheme    *string `json:"color_scheme"`
	}
	if ok, handled := decodeBody(w, r, &body); !ok {
		if !handled {
			writeError(w, http.StatusBadRequest, "invalid_setting")
		}
		return
	}
	if body.AutoRemind == nil && body.DefaultOffsets == nil && body.StartTab == nil && body.ListView == nil &&
		body.CalendarZoom == nil && body.ColorScheme == nil {
		writeError(w, http.StatusBadRequest, "empty")
		return
	}
	var p db.UpdateSettingsParams
	p.UserID = v.user.ID
	if body.DefaultOffsets != nil {
		offs, ok := validOffsets(*body.DefaultOffsets)
		if !ok || len(offs) == 0 {
			writeError(w, http.StatusBadRequest, "invalid_offsets")
			return
		}
		p.DefaultOffsets = offs
	}
	enum := func(dst *pgtype.Text, val *string, allowed []string) bool {
		if val == nil {
			return true
		}
		if !slices.Contains(allowed, *val) {
			return false
		}
		*dst = pgtype.Text{String: *val, Valid: true}
		return true
	}
	if !enum(&p.StartTab, body.StartTab, startTabs) || !enum(&p.ListView, body.ListView, listViews) ||
		!enum(&p.CalendarZoom, body.CalendarZoom, calendarZooms) || !enum(&p.ColorScheme, body.ColorScheme, colorSchemes) {
		writeError(w, http.StatusBadRequest, "invalid_setting")
		return
	}
	if body.AutoRemind != nil {
		p.AutoRemind = pgtype.Bool{Bool: *body.AutoRemind, Valid: true}
	}
	u, err := s.Store.UpdateSettings(r.Context(), p)
	if err != nil {
		s.internal(w, r, "update settings", err)
		return
	}
	set, err := s.settingsFor(r.Context(), u)
	if err != nil {
		s.internal(w, r, "settings", err)
		return
	}
	writeJSON(w, http.StatusOK, set)
}

// validName trims the name and checks 1-100 runes with no NUL.
func validName(name string) (string, bool) {
	name = strings.TrimSpace(name)
	n := utf8.RuneCountInString(name)
	if n < 1 || n > 100 || strings.ContainsRune(name, 0) {
		return "", false
	}
	return name, true
}

// checkDate validates month/day/year with ValidDate and returns the 400 code when it fails.
func checkDate(month, day int, year *int) (code string, ok bool) {
	if year != nil && (*year < 1900 || *year > 2200) {
		return "invalid_year", false
	}
	if month < 1 || month > 12 || day < 1 || day > 31 {
		return "invalid_date", false
	}
	var y *int16
	if year != nil {
		v := int16(*year)
		y = &v
	}
	if !ValidDate(int16(month), int16(day), y) {
		return "invalid_date", false
	}
	return "", true
}

type birthdayBody struct {
	Name   string `json:"name"`
	Month  int    `json:"month"`
	Day    int    `json:"day"`
	Year   *int   `json:"year"`
	Remind *bool  `json:"remind"`
}

// parseBirthdayBody decodes and validates a create / replace body; on failure it has written the response.
func parseBirthdayBody(w http.ResponseWriter, r *http.Request) (birthdayBody, string, bool) {
	var b birthdayBody
	raw, tooLarge := readBody(r)
	if tooLarge {
		writeError(w, http.StatusRequestEntityTooLarge, "too_large")
		return b, "", false
	}
	if err := json.Unmarshal(raw, &b); err != nil {
		code := "invalid_name"
		var te *json.UnmarshalTypeError
		if errors.As(err, &te) {
			switch te.Field {
			case "month", "day":
				code = "invalid_date"
			case "year":
				code = "invalid_year"
			}
		}
		writeError(w, http.StatusBadRequest, code)
		return b, "", false
	}
	name, ok := validName(b.Name)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_name")
		return b, "", false
	}
	if code, ok := checkDate(b.Month, b.Day, b.Year); !ok {
		writeError(w, http.StatusBadRequest, code)
		return b, "", false
	}
	return b, name, true
}

func (s *Server) handleListBirthdays(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	rows, err := s.Store.ListViewerBirthdays(r.Context(), db.ListViewerBirthdaysParams{ViewerID: v.user.ID, ViewerEmail: v.email})
	if err != nil {
		s.internal(w, r, "list birthdays", err)
		return
	}
	out := make([]birthdayJSON, 0, len(rows))
	for _, b := range rows {
		out = append(out, birthdayJSON{ID: b.ID, Name: b.Name, Month: b.Month, Day: b.Day, Year: yearPtr(b.Year),
			IsMine: b.IsMine, OwnerEmail: b.OwnerEmail, ReminderOffsets: nonNil(b.ReminderOffsets)})
	}
	writeJSON(w, http.StatusOK, map[string]any{"birthdays": out})
}

func (s *Server) handleCreateBirthday(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	b, name, ok := parseBirthdayBody(w, r)
	if !ok {
		return
	}
	remind := v.user.AutoRemind
	if b.Remind != nil {
		remind = *b.Remind
	}
	var out birthdayJSON
	var tooMany bool
	err := s.Tx.InTx(r.Context(), func(q db.Querier) error {
		if _, err := q.LockUser(r.Context(), v.user.ID); err != nil { // serializes this person's cap check
			return err
		}
		n, err := q.CountOwnedBirthdays(r.Context(), v.user.ID)
		if err != nil {
			return err
		}
		if n >= maxOwnedBirthdays {
			tooMany = true
			return nil
		}
		row, err := q.InsertBirthday(r.Context(), db.InsertBirthdayParams{OwnerID: v.user.ID, Name: name,
			Month: int16(b.Month), Day: int16(b.Day), Year: int2(b.Year)})
		if err != nil {
			return err
		}
		offsets := []int16{}
		if remind {
			offsets = slices.Clone(v.user.DefaultOffsets)
			if _, err := q.UpsertViewerReminder(r.Context(), db.UpsertViewerReminderParams{
				ViewerID: v.user.ID, Offsets: offsets, BirthdayID: row.ID, ViewerEmail: v.email}); err != nil {
				return err
			}
		}
		out = birthdayJSON{ID: row.ID, Name: row.Name, Month: row.Month, Day: row.Day, Year: yearPtr(row.Year),
			IsMine: true, OwnerEmail: v.email, ReminderOffsets: offsets}
		return nil
	})
	if err != nil {
		s.internal(w, r, "create birthday", err)
		return
	}
	if tooMany {
		writeError(w, http.StatusConflict, "too_many_birthdays")
		return
	}
	writeJSON(w, http.StatusCreated, out)
}

// viewerBirthday loads birthday id as the viewer. It answers 404 itself (no access and no such birthday look the same)
// and 500 on a database error, returning ok=false.
func (s *Server) viewerBirthday(w http.ResponseWriter, r *http.Request, v viewer, id int64) (birthdayJSON, bool) {
	row, err := s.Store.GetViewerBirthday(r.Context(), db.GetViewerBirthdayParams{
		ViewerID: v.user.ID, BirthdayID: id, ViewerEmail: v.email})
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "not_found")
		return birthdayJSON{}, false
	}
	if err != nil {
		s.internal(w, r, "get birthday", err)
		return birthdayJSON{}, false
	}
	return birthdayJSON{ID: row.ID, Name: row.Name, Month: row.Month, Day: row.Day, Year: yearPtr(row.Year),
		IsMine: row.IsMine, OwnerEmail: row.OwnerEmail, ReminderOffsets: nonNil(row.ReminderOffsets)}, true
}

// ownedBirthday is viewerBirthday plus the owner-only rule: a recipient gets 403 not_owner.
func (s *Server) ownedBirthday(w http.ResponseWriter, r *http.Request, v viewer, id int64) (birthdayJSON, bool) {
	b, ok := s.viewerBirthday(w, r, v, id)
	if !ok {
		return b, false
	}
	if !b.IsMine {
		writeError(w, http.StatusForbidden, "not_owner")
		return b, false
	}
	return b, true
}

func (s *Server) giftsFor(ctx context.Context, v viewer, birthdayID int64) ([]giftJSON, error) {
	rows, err := s.Store.ListViewerGifts(ctx, db.ListViewerGiftsParams{ViewerID: v.user.ID, BirthdayID: birthdayID, ViewerEmail: v.email})
	if err != nil {
		return nil, err
	}
	out := make([]giftJSON, 0, len(rows))
	for _, g := range rows {
		out = append(out, giftJSON{ID: g.ID, Text: g.Text, Shared: g.Shared, AuthorEmail: g.AuthorEmail, Mine: g.Mine})
	}
	return out, nil
}

func (s *Server) handleGetBirthday(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	b, ok := s.viewerBirthday(w, r, v, id)
	if !ok {
		return
	}
	resp := map[string]any{"birthday": b}
	if b.IsMine {
		shares, err := s.Store.ListOwnedShares(r.Context(), db.ListOwnedSharesParams{BirthdayID: id, OwnerID: v.user.ID})
		if err != nil {
			s.internal(w, r, "list shares", err)
			return
		}
		if shares == nil {
			shares = []string{}
		}
		resp["shares"] = shares
	}
	gifts, err := s.giftsFor(r.Context(), v, id)
	if err != nil {
		s.internal(w, r, "list gifts", err)
		return
	}
	resp["gifts"] = gifts
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handlePutBirthday(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	cur, ok := s.ownedBirthday(w, r, v, id)
	if !ok {
		return
	}
	b, name, ok := parseBirthdayBody(w, r)
	if !ok {
		return
	}
	row, err := s.Store.UpdateOwnedBirthday(r.Context(), db.UpdateOwnedBirthdayParams{Name: name, Month: int16(b.Month),
		Day: int16(b.Day), Year: int2(b.Year), BirthdayID: id, OwnerID: v.user.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		s.internal(w, r, "update birthday", err)
		return
	}
	cur.Name, cur.Month, cur.Day, cur.Year = row.Name, row.Month, row.Day, yearPtr(row.Year)
	writeJSON(w, http.StatusOK, cur)
}

func (s *Server) handleDeleteBirthday(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	b, ok := s.viewerBirthday(w, r, v, id)
	if !ok {
		return
	}
	err := s.Tx.InTx(r.Context(), func(q db.Querier) error {
		ctx := r.Context()
		if b.IsMine {
			_, err := q.DeleteOwnedBirthday(ctx, db.DeleteOwnedBirthdayParams{BirthdayID: id, OwnerID: v.user.ID})
			return err
		}
		// A recipient removes only their own share, reminders and gift ideas, in one transaction.
		if _, err := q.DeleteOwnShare(ctx, db.DeleteOwnShareParams{BirthdayID: id, ViewerEmail: v.email}); err != nil {
			return err
		}
		if err := q.DeleteOwnReminders(ctx, db.DeleteOwnRemindersParams{BirthdayID: id, ViewerID: v.user.ID}); err != nil {
			return err
		}
		return q.DeleteOwnGifts(ctx, db.DeleteOwnGiftsParams{BirthdayID: id, ViewerID: v.user.ID})
	})
	if err != nil {
		s.internal(w, r, "delete birthday", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handlePutReminders(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if _, ok := s.viewerBirthday(w, r, v, id); !ok {
		return
	}
	var body struct {
		Offsets *[]int `json:"offsets"`
	}
	if ok, handled := decodeBody(w, r, &body); !ok || body.Offsets == nil {
		if !handled {
			writeError(w, http.StatusBadRequest, "invalid_offsets")
		}
		return
	}
	offs, ok := validOffsets(*body.Offsets)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_offsets")
		return
	}
	if len(offs) == 0 {
		if _, err := s.Store.DeleteViewerReminder(r.Context(), db.DeleteViewerReminderParams{
			BirthdayID: id, ViewerID: v.user.ID, ViewerEmail: v.email}); err != nil {
			s.internal(w, r, "delete reminder", err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"offsets": offs})
		return
	}
	n, err := s.Store.UpsertViewerReminder(r.Context(), db.UpsertViewerReminderParams{
		ViewerID: v.user.ID, Offsets: offs, BirthdayID: id, ViewerEmail: v.email})
	if err != nil {
		s.internal(w, r, "upsert reminder", err)
		return
	}
	if n == 0 {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"offsets": offs})
}

// shareEmail trims, lowercases and validates an email from a share body.
func shareEmail(raw string) (string, bool) {
	e := strings.ToLower(strings.TrimSpace(raw))
	if len(e) > maxEmailLen || !emailPattern.MatchString(e) {
		return "", false
	}
	for _, c := range e {
		if c < 0x21 || c > 0x7e { // printable ASCII only: no NUL (Postgres rejects it) and no lower() mismatches
			return "", false
		}
	}
	return e, true
}

func (s *Server) handlePostShare(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if _, ok := s.ownedBirthday(w, r, v, id); !ok {
		return
	}
	var body struct {
		Email string `json:"email"`
	}
	if ok, handled := decodeBody(w, r, &body); !ok {
		if !handled {
			writeError(w, http.StatusBadRequest, "invalid_email")
		}
		return
	}
	email, ok := shareEmail(body.Email)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_email")
		return
	}
	if email == v.email {
		writeError(w, http.StatusBadRequest, "self_share")
		return
	}
	status := http.StatusCreated
	tooMany, gone := false, false
	err := s.Tx.InTx(r.Context(), func(q db.Querier) error {
		if _, err := q.LockOwnedBirthday(r.Context(), db.LockOwnedBirthdayParams{BirthdayID: id, OwnerID: v.user.ID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				gone = true
				return nil
			}
			return err
		}
		existing, err := q.ListOwnedShares(r.Context(), db.ListOwnedSharesParams{BirthdayID: id, OwnerID: v.user.ID})
		if err != nil {
			return err
		}
		if slices.Contains(existing, email) {
			status = http.StatusOK
			return nil
		}
		if len(existing) >= maxSharesPerB {
			tooMany = true
			return nil
		}
		n, err := q.InsertOwnedShare(r.Context(), db.InsertOwnedShareParams{Email: email, BirthdayID: id, OwnerID: v.user.ID})
		if err == nil && n == 0 {
			gone = true
		}
		return err
	})
	if err != nil {
		s.internal(w, r, "share birthday", err)
		return
	}
	if gone {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if tooMany {
		writeError(w, http.StatusConflict, "too_many_shares")
		return
	}
	writeJSON(w, status, map[string]string{"email": email})
}

func (s *Server) handleDeleteShare(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if _, ok := s.ownedBirthday(w, r, v, id); !ok {
		return
	}
	var body struct {
		Email string `json:"email"`
	}
	if ok, handled := decodeBody(w, r, &body); !ok {
		if !handled {
			writeError(w, http.StatusBadRequest, "invalid_email")
		}
		return
	}
	email, ok := shareEmail(body.Email)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_email")
		return
	}
	err := s.Tx.InTx(r.Context(), func(q db.Querier) error {
		ctx := r.Context()
		if _, err := q.LockOwnedBirthday(ctx, db.LockOwnedBirthdayParams{BirthdayID: id, OwnerID: v.user.ID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil // deleted meanwhile: nothing left to unshare
			}
			return err
		}
		n, err := q.DeleteOwnedShare(ctx, db.DeleteOwnedShareParams{BirthdayID: id, OwnerID: v.user.ID, Email: email})
		if err != nil || n == 0 {
			return err // an absent share changes nothing (so the owner's own email, never a share, deletes nothing)
		}
		if err := q.DeleteSharedPersonReminders(ctx, db.DeleteSharedPersonRemindersParams{BirthdayID: id, OwnerID: v.user.ID, Email: email}); err != nil {
			return err
		}
		return q.DeleteSharedPersonGifts(ctx, db.DeleteSharedPersonGiftsParams{BirthdayID: id, OwnerID: v.user.ID, Email: email})
	})
	if err != nil {
		s.internal(w, r, "unshare birthday", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handlePostGift(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if _, ok := s.viewerBirthday(w, r, v, id); !ok {
		return
	}
	var body struct {
		Text   string `json:"text"`
		Shared *bool  `json:"shared"`
	}
	if ok, handled := decodeBody(w, r, &body); !ok {
		if !handled {
			writeError(w, http.StatusBadRequest, "invalid_text")
		}
		return
	}
	text := strings.TrimSpace(body.Text)
	if n := utf8.RuneCountInString(text); n < 1 || n > 200 || strings.ContainsRune(text, 0) {
		writeError(w, http.StatusBadRequest, "invalid_text")
		return
	}
	shared := body.Shared != nil && *body.Shared
	var out giftJSON
	tooMany, gone := false, false
	err := s.Tx.InTx(r.Context(), func(q db.Querier) error {
		// Lock order birthday -> user. The birthday lock waits for a concurrent unshare; the user lock serializes the cap.
		if _, err := q.LockBirthdayShared(r.Context(), id); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				gone = true
				return nil
			}
			return err
		}
		if _, err := q.LockUser(r.Context(), v.user.ID); err != nil {
			return err
		}
		n, err := q.CountViewerGifts(r.Context(), db.CountViewerGiftsParams{BirthdayID: id, ViewerID: v.user.ID})
		if err != nil {
			return err
		}
		if n >= maxGiftsPerAuthor {
			tooMany = true
			return nil
		}
		row, err := q.InsertViewerGift(r.Context(), db.InsertViewerGiftParams{ViewerID: v.user.ID, Text: text,
			Shared: shared, BirthdayID: id, ViewerEmail: v.email})
		if errors.Is(err, pgx.ErrNoRows) {
			gone = true
			return nil
		}
		if err != nil {
			return err
		}
		out = giftJSON{ID: row.ID, Text: row.Text, Shared: row.Shared, AuthorEmail: v.email, Mine: true}
		return nil
	})
	switch {
	case err != nil:
		s.internal(w, r, "create gift", err)
	case gone:
		writeError(w, http.StatusNotFound, "not_found")
	case tooMany:
		writeError(w, http.StatusConflict, "too_many_gifts")
	default:
		writeJSON(w, http.StatusCreated, out)
	}
}

// authorGift resolves a gift id for its author, then re-checks the author can still see the birthday it hangs off
// (GetViewerBirthday first, so every miss is the same 404). It answers 404 / 500 itself.
func (s *Server) authorGift(w http.ResponseWriter, r *http.Request, v viewer) (int64, bool) {
	id, ok := pathID(r)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found")
		return 0, false
	}
	bid, err := s.Store.GetOwnGiftBirthday(r.Context(), db.GetOwnGiftBirthdayParams{GiftID: id, AuthorID: v.user.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "not_found")
		return 0, false
	}
	if err != nil {
		s.internal(w, r, "get gift", err)
		return 0, false
	}
	if _, ok := s.viewerBirthday(w, r, v, bid); !ok {
		return 0, false
	}
	return id, true
}

func (s *Server) handlePatchGift(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	id, ok := s.authorGift(w, r, v)
	if !ok {
		return
	}
	var body struct {
		Shared *bool `json:"shared"`
	}
	if ok, handled := decodeBody(w, r, &body); !ok || body.Shared == nil {
		if !handled {
			writeError(w, http.StatusBadRequest, "invalid_shared")
		}
		return
	}
	row, err := s.Store.UpdateOwnGiftShared(r.Context(), db.UpdateOwnGiftSharedParams{Shared: *body.Shared, GiftID: id, AuthorID: v.user.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, "not_found")
		return
	}
	if err != nil {
		s.internal(w, r, "update gift", err)
		return
	}
	writeJSON(w, http.StatusOK, giftJSON{ID: row.ID, Text: row.Text, Shared: row.Shared, AuthorEmail: v.email, Mine: true})
}

func (s *Server) handleDeleteGift(w http.ResponseWriter, r *http.Request) {
	v, ok := s.ensureUser(w, r)
	if !ok {
		return
	}
	id, ok := s.authorGift(w, r, v)
	if !ok {
		return
	}
	if _, err := s.Store.DeleteOwnGift(r.Context(), db.DeleteOwnGiftParams{GiftID: id, AuthorID: v.user.ID}); err != nil {
		s.internal(w, r, "delete gift", err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
