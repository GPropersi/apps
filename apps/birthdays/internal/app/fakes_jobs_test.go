package app

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/gpropersi/apps/apps/birthdays/internal/app/db"
	"github.com/gpropersi/apps/apps/birthdays/internal/platform"
)

// The reminder-job queries of fakeStore, mirroring sql/queries.sql; test_image.sh runs the real SQL.

type fSent struct {
	BirthdayID, UserID int64
	Occurrence         Date
	OffsetDays         int16
	Outcome            string
}

func (s *fakeStore) ListReminderCandidates(context.Context) ([]db.ListReminderCandidatesRow, error) {
	var out []db.ListReminderCandidatesRow
	for _, r := range s.reminders {
		b, ok := s.birthdayByID(r.BirthdayID)
		if !ok {
			continue
		}
		out = append(out, db.ListReminderCandidatesRow{BirthdayID: r.BirthdayID, UserID: r.UserID, Offsets: r.Offsets,
			Month: b.Month, Day: b.Day, Year: b.Year})
	}
	return out, nil
}

func (s *fakeStore) ListRemindersSentSince(_ context.Context, since pgtype.Date) ([]db.ListRemindersSentSinceRow, error) {
	from := fromPgDate(since)
	var out []db.ListRemindersSentSinceRow
	for _, r := range s.remSent {
		if !r.Occurrence.Before(from) {
			out = append(out, db.ListRemindersSentSinceRow{BirthdayID: r.BirthdayID, UserID: r.UserID,
				Occurrence: pgDate(r.Occurrence), OffsetDays: r.OffsetDays})
		}
	}
	return out, nil
}

func (s *fakeStore) GetReminderContext(_ context.Context, a db.GetReminderContextParams) (db.GetReminderContextRow, error) {
	b, ok := s.birthdayByID(a.BirthdayID)
	u, uok := s.userByID(a.UserID)
	if !ok || !uok {
		return db.GetReminderContextRow{}, pgx.ErrNoRows
	}
	offsets := s.offsetsOf(b.ID, u.ID)
	if offsets == nil {
		offsets = []int16{}
	}
	return db.GetReminderContextRow{Name: b.Name, Month: b.Month, Day: b.Day, Year: b.Year, Email: u.Email,
		NtfyUserID: u.NtfyUserID, Offsets: offsets, HasAccess: s.canSee(b, u.ID, u.Email)}, nil
}

func (s *fakeStore) InsertReminderSent(_ context.Context, a db.InsertReminderSentParams) (int64, error) {
	if s.failRemSent != nil {
		return 0, s.failRemSent
	}
	occ := fromPgDate(a.Occurrence)
	for _, r := range s.remSent {
		if r.BirthdayID == a.BirthdayID && r.UserID == a.UserID && r.Occurrence == occ && r.OffsetDays == a.OffsetDays {
			return 0, nil
		}
	}
	s.remSent = append(s.remSent, fSent{a.BirthdayID, a.UserID, occ, a.OffsetDays, a.Outcome})
	return 1, nil
}

// fakeSender is the ReminderNotifier the job tests drive. sendResults scripts each Send call in order (nil = 202; once
// exhausted, 202); calls records every notifs call by name.
type fakeSender struct {
	configErr   error
	sendResults []error
	publisher   error
	lookupErr   error
	deliverable map[int64]bool
	calls       []string
	sent        []platform.Message
}

func (f *fakeSender) Configured() error { return f.configErr }

func (f *fakeSender) Send(_ context.Context, m platform.Message) (platform.Result, error) {
	f.calls = append(f.calls, "send")
	f.sent = append(f.sent, m)
	if len(f.sendResults) == 0 {
		return platform.Result{Status: 202}, nil
	}
	err := f.sendResults[0]
	f.sendResults = f.sendResults[1:]
	if err != nil {
		return platform.Result{}, err
	}
	return platform.Result{Status: 202}, nil
}

func (f *fakeSender) EnsurePublisher(context.Context) error {
	f.calls = append(f.calls, "mint")
	return f.publisher
}

func (f *fakeSender) LookupPersonalDestinations(_ context.Context, _ string, ids []int64) (map[int64]bool, error) {
	f.calls = append(f.calls, "lookup")
	if f.lookupErr != nil {
		return nil, f.lookupErr
	}
	out := map[int64]bool{}
	for _, id := range ids {
		out[id] = f.deliverable[id]
	}
	return out, nil
}

func fixedClock(t time.Time) func() time.Time { return func() time.Time { return t } }
