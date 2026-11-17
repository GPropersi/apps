package app

import (
	"context"
	"slices"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/gpropersi/apps/apps/birthdays/internal/app/db"
)

// In-memory rows and the birthday / share / reminder / gift queries of fakeStore. Each method mirrors the SQL in
// sql/queries.sql (access rule included) closely enough for handler tests; test_image.sh runs the real SQL.

type fBirthday struct {
	ID, OwnerID int64
	Name        string
	Month, Day  int16
	Year        pgtype.Int2
}

type fShare struct {
	BirthdayID int64
	Email      string
}

type fReminder struct {
	BirthdayID, UserID int64
	Offsets            []int16
}

type fGift struct {
	ID, BirthdayID, AuthorID int64
	Text                     string
	Shared                   bool
}

func (s *fakeStore) userByID(id int64) (db.User, bool) {
	for _, u := range s.users {
		if u.ID == id {
			return u, true
		}
	}
	return db.User{}, false
}

func (s *fakeStore) birthdayByID(id int64) (fBirthday, bool) {
	for _, b := range s.birthdays {
		if b.ID == id {
			return b, true
		}
	}
	return fBirthday{}, false
}

func (s *fakeStore) shared(birthdayID int64, email string) bool {
	return slices.Contains(s.shares, fShare{BirthdayID: birthdayID, Email: email})
}

// canSee is the access rule: owner, or a share row for the viewer's email.
func (s *fakeStore) canSee(b fBirthday, viewerID int64, viewerEmail string) bool {
	return b.OwnerID == viewerID || s.shared(b.ID, viewerEmail)
}

func (s *fakeStore) offsetsOf(birthdayID, userID int64) []int16 {
	for _, r := range s.reminders {
		if r.BirthdayID == birthdayID && r.UserID == userID {
			return r.Offsets
		}
	}
	return []int16{}
}

func (s *fakeStore) viewerRow(b fBirthday, viewerID int64) db.GetViewerBirthdayRow {
	owner, _ := s.userByID(b.OwnerID)
	return db.GetViewerBirthdayRow{ID: b.ID, Name: b.Name, Month: b.Month, Day: b.Day, Year: b.Year,
		IsMine: b.OwnerID == viewerID, OwnerEmail: owner.Email, ReminderOffsets: s.offsetsOf(b.ID, viewerID)}
}

func (s *fakeStore) UpdateSettings(_ context.Context, a db.UpdateSettingsParams) (db.User, error) {
	for email, u := range s.users {
		if u.ID != a.UserID {
			continue
		}
		if a.AutoRemind.Valid {
			u.AutoRemind = a.AutoRemind.Bool
		}
		if a.DefaultOffsets != nil {
			u.DefaultOffsets = a.DefaultOffsets
		}
		if a.StartTab.Valid {
			u.StartTab = a.StartTab.String
		}
		if a.ListView.Valid {
			u.ListView = a.ListView.String
		}
		if a.CalendarZoom.Valid {
			u.CalendarZoom = a.CalendarZoom.String
		}
		if a.ColorScheme.Valid {
			u.ColorScheme = a.ColorScheme.String
		}
		s.users[email] = u
		return u, nil
	}
	return db.User{}, pgx.ErrNoRows
}

func (s *fakeStore) GetDestinationCounts(_ context.Context, userID int64) (db.GetDestinationCountsRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out db.GetDestinationCountsRow
	for _, d := range s.dests {
		if d.UserID == userID {
			out.Total++
			if d.Stale {
				out.Stale++
			}
		}
	}
	return out, nil
}

// fDest is a destinations row; the fake keeps exactly the columns the table has (never a URL or secret).
type fDest struct {
	ID, UserID, NotifsID int64
	Kind, Label, Hint    string
	Stale                bool
}

func (s *fakeStore) logCall(name string) {
	if s.calls != nil {
		*s.calls = append(*s.calls, name)
	}
}

func (s *fakeStore) LockUserNtfy(_ context.Context, _ int64) error {
	s.logCall("lock")
	return nil
}

func (s *fakeStore) GetNtfyUser(_ context.Context, userID int64) (pgtype.Text, error) {
	s.logCall("get")
	u, ok := s.userByID(userID)
	if !ok {
		return pgtype.Text{}, pgx.ErrNoRows
	}
	return u.NtfyUserID, nil
}

func (s *fakeStore) SetNtfyUser(_ context.Context, a db.SetNtfyUserParams) error {
	if s.failSetNtfy != nil {
		return s.failSetNtfy
	}
	for email, u := range s.users {
		if u.ID == a.UserID {
			u.NtfyUserID = a.NtfyUserID
			s.users[email] = u
			return nil
		}
	}
	return pgx.ErrNoRows
}

func (s *fakeStore) ListDestinations(_ context.Context, userID int64) ([]db.ListDestinationsRow, error) {
	var out []db.ListDestinationsRow
	for _, d := range s.dests {
		if d.UserID == userID {
			out = append(out, db.ListDestinationsRow{ID: d.ID, NotifsID: d.NotifsID, Kind: d.Kind, Label: d.Label, Hint: d.Hint, Stale: d.Stale})
		}
	}
	return out, nil
}

func (s *fakeStore) CountDestinations(_ context.Context, userID int64) (int64, error) {
	var n int64
	for _, d := range s.dests {
		if d.UserID == userID {
			n++
		}
	}
	return n, nil
}

func (s *fakeStore) InsertDestination(_ context.Context, a db.InsertDestinationParams) (db.InsertDestinationRow, error) {
	if s.failInsertDest != nil {
		return db.InsertDestinationRow{}, s.failInsertDest
	}
	s.nextID++
	s.dests = append(s.dests, fDest{ID: s.nextID, UserID: a.UserID, NotifsID: a.NotifsID, Kind: a.Kind, Label: a.Label, Hint: a.Hint})
	return db.InsertDestinationRow{ID: s.nextID, NotifsID: a.NotifsID, Kind: a.Kind, Label: a.Label, Hint: a.Hint}, nil
}

func (s *fakeStore) GetOwnDestination(_ context.Context, a db.GetOwnDestinationParams) (db.GetOwnDestinationRow, error) {
	for _, d := range s.dests {
		if d.ID == a.DestinationID && d.UserID == a.UserID {
			return db.GetOwnDestinationRow{ID: d.ID, NotifsID: d.NotifsID, Kind: d.Kind, Label: d.Label, Hint: d.Hint, Stale: d.Stale}, nil
		}
	}
	return db.GetOwnDestinationRow{}, pgx.ErrNoRows
}

func (s *fakeStore) SetOwnDestinationStale(_ context.Context, a db.SetOwnDestinationStaleParams) (int64, error) {
	for i, d := range s.dests {
		if d.ID == a.DestinationID && d.UserID == a.UserID {
			s.dests[i].Stale = a.Stale
			return 1, nil
		}
	}
	return 0, nil
}

func (s *fakeStore) DeleteOwnDestination(_ context.Context, a db.DeleteOwnDestinationParams) (int64, error) {
	before := len(s.dests)
	s.dests = slices.DeleteFunc(s.dests, func(d fDest) bool { return d.ID == a.DestinationID && d.UserID == a.UserID })
	return int64(before - len(s.dests)), nil
}

func (s *fakeStore) ListViewerBirthdays(_ context.Context, a db.ListViewerBirthdaysParams) ([]db.ListViewerBirthdaysRow, error) {
	var out []db.ListViewerBirthdaysRow
	for _, b := range s.birthdays {
		if s.canSee(b, a.ViewerID, a.ViewerEmail) {
			r := s.viewerRow(b, a.ViewerID)
			out = append(out, db.ListViewerBirthdaysRow(r))
		}
	}
	return out, nil
}

func (s *fakeStore) GetViewerBirthday(_ context.Context, a db.GetViewerBirthdayParams) (db.GetViewerBirthdayRow, error) {
	b, ok := s.birthdayByID(a.BirthdayID)
	if !ok || !s.canSee(b, a.ViewerID, a.ViewerEmail) {
		return db.GetViewerBirthdayRow{}, pgx.ErrNoRows
	}
	return s.viewerRow(b, a.ViewerID), nil
}

func (s *fakeStore) CountOwnedBirthdays(_ context.Context, ownerID int64) (int64, error) {
	var n int64
	for _, b := range s.birthdays {
		if b.OwnerID == ownerID {
			n++
		}
	}
	return n, nil
}

func (s *fakeStore) InsertBirthday(_ context.Context, a db.InsertBirthdayParams) (db.InsertBirthdayRow, error) {
	s.nextID++
	s.birthdays = append(s.birthdays, fBirthday{ID: s.nextID, OwnerID: a.OwnerID, Name: a.Name, Month: a.Month, Day: a.Day, Year: a.Year})
	return db.InsertBirthdayRow{ID: s.nextID, Name: a.Name, Month: a.Month, Day: a.Day, Year: a.Year}, nil
}

func (s *fakeStore) UpdateOwnedBirthday(_ context.Context, a db.UpdateOwnedBirthdayParams) (db.UpdateOwnedBirthdayRow, error) {
	for i, b := range s.birthdays {
		if b.ID == a.BirthdayID && b.OwnerID == a.OwnerID {
			s.birthdays[i].Name, s.birthdays[i].Month, s.birthdays[i].Day, s.birthdays[i].Year = a.Name, a.Month, a.Day, a.Year
			return db.UpdateOwnedBirthdayRow{ID: b.ID, Name: a.Name, Month: a.Month, Day: a.Day, Year: a.Year}, nil
		}
	}
	return db.UpdateOwnedBirthdayRow{}, pgx.ErrNoRows
}

func (s *fakeStore) DeleteOwnedBirthday(_ context.Context, a db.DeleteOwnedBirthdayParams) (int64, error) {
	b, ok := s.birthdayByID(a.BirthdayID)
	if !ok || b.OwnerID != a.OwnerID {
		return 0, nil
	}
	s.birthdays = slices.DeleteFunc(s.birthdays, func(x fBirthday) bool { return x.ID == b.ID })
	s.shares = slices.DeleteFunc(s.shares, func(x fShare) bool { return x.BirthdayID == b.ID })
	s.reminders = slices.DeleteFunc(s.reminders, func(x fReminder) bool { return x.BirthdayID == b.ID })
	s.gifts = slices.DeleteFunc(s.gifts, func(x fGift) bool { return x.BirthdayID == b.ID })
	return 1, nil
}

func (s *fakeStore) ListOwnedShares(_ context.Context, a db.ListOwnedSharesParams) ([]string, error) {
	b, ok := s.birthdayByID(a.BirthdayID)
	if !ok || b.OwnerID != a.OwnerID {
		return nil, nil
	}
	var out []string
	for _, sh := range s.shares {
		if sh.BirthdayID == b.ID {
			out = append(out, sh.Email)
		}
	}
	return out, nil
}

func (s *fakeStore) InsertOwnedShare(_ context.Context, a db.InsertOwnedShareParams) (int64, error) {
	b, ok := s.birthdayByID(a.BirthdayID)
	if !ok || b.OwnerID != a.OwnerID || s.shared(b.ID, a.Email) {
		return 0, nil
	}
	s.shares = append(s.shares, fShare{BirthdayID: b.ID, Email: a.Email})
	return 1, nil
}

func (s *fakeStore) DeleteOwnedShare(_ context.Context, a db.DeleteOwnedShareParams) (int64, error) {
	b, ok := s.birthdayByID(a.BirthdayID)
	if !ok || b.OwnerID != a.OwnerID || !s.shared(b.ID, a.Email) {
		return 0, nil
	}
	s.shares = slices.DeleteFunc(s.shares, func(x fShare) bool { return x.BirthdayID == b.ID && x.Email == a.Email })
	return 1, nil
}

func (s *fakeStore) DeleteSharedPersonReminders(_ context.Context, a db.DeleteSharedPersonRemindersParams) error {
	b, ok := s.birthdayByID(a.BirthdayID)
	u := s.users[a.Email]
	if ok && b.OwnerID == a.OwnerID {
		s.reminders = slices.DeleteFunc(s.reminders, func(x fReminder) bool { return x.BirthdayID == b.ID && x.UserID == u.ID })
	}
	return nil
}

// Row locks are no-ops in the single-threaded fake; they only report a missing row like the SQL.
func (s *fakeStore) LockUser(_ context.Context, id int64) (int64, error) {
	if _, ok := s.userByID(id); !ok {
		return 0, pgx.ErrNoRows
	}
	return id, nil
}

func (s *fakeStore) LockOwnedBirthday(_ context.Context, a db.LockOwnedBirthdayParams) (int64, error) {
	if b, ok := s.birthdayByID(a.BirthdayID); ok && b.OwnerID == a.OwnerID {
		return b.ID, nil
	}
	return 0, pgx.ErrNoRows
}

func (s *fakeStore) LockBirthdayShared(_ context.Context, id int64) (int64, error) {
	if _, ok := s.birthdayByID(id); !ok {
		return 0, pgx.ErrNoRows
	}
	return id, nil
}

func (s *fakeStore) DeleteSharedPersonGifts(_ context.Context, a db.DeleteSharedPersonGiftsParams) error {
	if s.failSharedGifts != nil {
		return s.failSharedGifts
	}
	b, ok := s.birthdayByID(a.BirthdayID)
	u := s.users[a.Email]
	if ok && b.OwnerID == a.OwnerID {
		s.gifts = slices.DeleteFunc(s.gifts, func(x fGift) bool { return x.BirthdayID == b.ID && x.AuthorID == u.ID })
	}
	return nil
}

func (s *fakeStore) DeleteOwnShare(_ context.Context, a db.DeleteOwnShareParams) (int64, error) {
	if !s.shared(a.BirthdayID, a.ViewerEmail) {
		return 0, nil
	}
	s.shares = slices.DeleteFunc(s.shares, func(x fShare) bool { return x.BirthdayID == a.BirthdayID && x.Email == a.ViewerEmail })
	return 1, nil
}

func (s *fakeStore) DeleteOwnReminders(_ context.Context, a db.DeleteOwnRemindersParams) error {
	s.reminders = slices.DeleteFunc(s.reminders, func(x fReminder) bool { return x.BirthdayID == a.BirthdayID && x.UserID == a.ViewerID })
	return nil
}

func (s *fakeStore) DeleteOwnGifts(_ context.Context, a db.DeleteOwnGiftsParams) error {
	if s.failSharedGifts != nil {
		return s.failSharedGifts
	}
	s.gifts = slices.DeleteFunc(s.gifts, func(x fGift) bool { return x.BirthdayID == a.BirthdayID && x.AuthorID == a.ViewerID })
	return nil
}

func (s *fakeStore) UpsertViewerReminder(_ context.Context, a db.UpsertViewerReminderParams) (int64, error) {
	b, ok := s.birthdayByID(a.BirthdayID)
	if !ok || !s.canSee(b, a.ViewerID, a.ViewerEmail) {
		return 0, nil
	}
	for i, r := range s.reminders {
		if r.BirthdayID == b.ID && r.UserID == a.ViewerID {
			s.reminders[i].Offsets = a.Offsets
			return 1, nil
		}
	}
	s.reminders = append(s.reminders, fReminder{BirthdayID: b.ID, UserID: a.ViewerID, Offsets: a.Offsets})
	return 1, nil
}

func (s *fakeStore) DeleteViewerReminder(_ context.Context, a db.DeleteViewerReminderParams) (int64, error) {
	b, ok := s.birthdayByID(a.BirthdayID)
	if !ok || !s.canSee(b, a.ViewerID, a.ViewerEmail) {
		return 0, nil
	}
	before := len(s.reminders)
	s.reminders = slices.DeleteFunc(s.reminders, func(x fReminder) bool { return x.BirthdayID == b.ID && x.UserID == a.ViewerID })
	return int64(before - len(s.reminders)), nil
}

func (s *fakeStore) ListViewerGifts(_ context.Context, a db.ListViewerGiftsParams) ([]db.ListViewerGiftsRow, error) {
	b, ok := s.birthdayByID(a.BirthdayID)
	if !ok || !s.canSee(b, a.ViewerID, a.ViewerEmail) {
		return nil, nil
	}
	var out []db.ListViewerGiftsRow
	for _, g := range s.gifts {
		if g.BirthdayID != b.ID || (g.AuthorID != a.ViewerID && !g.Shared) {
			continue
		}
		author, _ := s.userByID(g.AuthorID)
		out = append(out, db.ListViewerGiftsRow{ID: g.ID, Text: g.Text, Shared: g.Shared, AuthorEmail: author.Email, Mine: g.AuthorID == a.ViewerID})
	}
	return out, nil
}

func (s *fakeStore) CountViewerGifts(_ context.Context, a db.CountViewerGiftsParams) (int64, error) {
	var n int64
	for _, g := range s.gifts {
		if g.BirthdayID == a.BirthdayID && g.AuthorID == a.ViewerID {
			n++
		}
	}
	return n, nil
}

func (s *fakeStore) InsertViewerGift(_ context.Context, a db.InsertViewerGiftParams) (db.InsertViewerGiftRow, error) {
	b, ok := s.birthdayByID(a.BirthdayID)
	if !ok || !s.canSee(b, a.ViewerID, a.ViewerEmail) {
		return db.InsertViewerGiftRow{}, pgx.ErrNoRows
	}
	s.nextID++
	s.gifts = append(s.gifts, fGift{ID: s.nextID, BirthdayID: b.ID, AuthorID: a.ViewerID, Text: a.Text, Shared: a.Shared})
	return db.InsertViewerGiftRow{ID: s.nextID, Text: a.Text, Shared: a.Shared}, nil
}

func (s *fakeStore) GetOwnGiftBirthday(_ context.Context, a db.GetOwnGiftBirthdayParams) (int64, error) {
	for _, g := range s.gifts {
		if g.ID == a.GiftID && g.AuthorID == a.AuthorID {
			return g.BirthdayID, nil
		}
	}
	return 0, pgx.ErrNoRows
}

func (s *fakeStore) UpdateOwnGiftShared(_ context.Context, a db.UpdateOwnGiftSharedParams) (db.UpdateOwnGiftSharedRow, error) {
	for i, g := range s.gifts {
		if g.ID == a.GiftID && g.AuthorID == a.AuthorID {
			s.gifts[i].Shared = a.Shared
			return db.UpdateOwnGiftSharedRow{ID: g.ID, Text: g.Text, Shared: a.Shared}, nil
		}
	}
	return db.UpdateOwnGiftSharedRow{}, pgx.ErrNoRows
}

func (s *fakeStore) DeleteOwnGift(_ context.Context, a db.DeleteOwnGiftParams) (int64, error) {
	before := len(s.gifts)
	s.gifts = slices.DeleteFunc(s.gifts, func(x fGift) bool { return x.ID == a.GiftID && x.AuthorID == a.AuthorID })
	return int64(before - len(s.gifts)), nil
}
