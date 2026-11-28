package app

import (
	"context"
	"sort"

	"github.com/jackc/pgx/v5"

	"github.com/gpropersi/apps/apps/tmplgoreact/internal/app/db"
)

// undo reverses one write; it runs under fakeStore.mu.
type undo func()

// ---- notify queries on the live store (each call takes mu for itself) -----------------------------------------------

// LockNotifsEmail outside a transaction has nothing to hold; the transaction view takes the real per-email lock.
func (s *fakeStore) LockNotifsEmail(context.Context, string) error { return nil }

func (s *fakeStore) GetNtfyUserID(_ context.Context, email string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failPhone != nil {
		return "", s.failPhone
	}
	id, ok := s.ntfyUsers[email]
	if !ok {
		return "", pgx.ErrNoRows // what the real :one query returns for a missing row
	}
	return id, nil
}

func (s *fakeStore) SetNtfyUserID(_ context.Context, arg db.SetNtfyUserIDParams) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.setNtfyLocked(arg)
	return nil
}

func (s *fakeStore) setNtfyLocked(arg db.SetNtfyUserIDParams) undo {
	if _, ok := s.ntfyUsers[arg.Email]; ok {
		return nil // ON CONFLICT DO NOTHING
	}
	s.ntfyUsers[arg.Email] = arg.NtfyUserID
	return func() { delete(s.ntfyUsers, arg.Email) }
}

func (s *fakeStore) ListDestinations(_ context.Context, email string) ([]db.ListDestinationsRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []db.ListDestinationsRow{}
	for _, d := range s.dests {
		if d.email == email {
			out = append(out, db.ListDestinationsRow{ID: d.id, NotifsID: d.notifsID, Kind: d.kind, Label: d.label, Hint: d.hint, Stale: d.stale})
		}
	}
	return out, nil
}

func (s *fakeStore) CountDestinations(_ context.Context, email string) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var n int64
	for _, d := range s.dests {
		if d.email == email {
			n++
		}
	}
	return n, nil
}

func (s *fakeStore) GetDestinationCounts(_ context.Context, email string) (db.GetDestinationCountsRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failPhone != nil {
		return db.GetDestinationCountsRow{}, s.failPhone
	}
	if s.failCounts != nil {
		return db.GetDestinationCountsRow{}, s.failCounts
	}
	var row db.GetDestinationCountsRow
	for _, d := range s.dests {
		if d.email == email {
			row.Total++
			if d.stale {
				row.Stale++
			}
		}
	}
	return row, nil
}

func (s *fakeStore) InsertDestination(_ context.Context, arg db.InsertDestinationParams) (db.InsertDestinationRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	row, _ := s.insertDestLocked(arg)
	return row, nil
}

func (s *fakeStore) insertDestLocked(arg db.InsertDestinationParams) (db.InsertDestinationRow, undo) {
	s.nextDestID++
	d := destRow{id: s.nextDestID, notifsID: arg.NotifsID, email: arg.Email, kind: arg.Kind, label: arg.Label, hint: arg.Hint}
	s.dests = append(s.dests, d)
	return db.InsertDestinationRow{ID: d.id, NotifsID: d.notifsID, Kind: d.kind, Label: d.label, Hint: d.hint}, func() {
		s.removeDestLocked(d.id)
	}
}

func (s *fakeStore) removeDestLocked(id int64) {
	for i, d := range s.dests {
		if d.id == id {
			s.dests = append(s.dests[:i], s.dests[i+1:]...)
			return
		}
	}
}

func (s *fakeStore) GetOwnDestination(_ context.Context, arg db.GetOwnDestinationParams) (db.GetOwnDestinationRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, d := range s.dests {
		if d.id == arg.DestinationID && d.email == arg.Email {
			return db.GetOwnDestinationRow{ID: d.id, NotifsID: d.notifsID, Kind: d.kind, Label: d.label, Hint: d.hint, Stale: d.stale}, nil
		}
	}
	return db.GetOwnDestinationRow{}, pgx.ErrNoRows
}

func (s *fakeStore) SetOwnDestinationStale(_ context.Context, arg db.SetOwnDestinationStaleParams) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	n, _ := s.setStaleLocked(arg)
	return n, nil
}

func (s *fakeStore) setStaleLocked(arg db.SetOwnDestinationStaleParams) (int64, undo) {
	for i, d := range s.dests {
		if d.id == arg.DestinationID && d.email == arg.Email {
			prev := d.stale
			s.dests[i].stale = arg.Stale
			return 1, func() {
				for j := range s.dests {
					if s.dests[j].id == arg.DestinationID {
						s.dests[j].stale = prev
					}
				}
			}
		}
	}
	return 0, nil
}

func (s *fakeStore) DeleteOwnDestination(_ context.Context, arg db.DeleteOwnDestinationParams) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.failDelete != nil {
		return 0, s.failDelete
	}
	n, _ := s.deleteDestLocked(arg)
	return n, nil
}

func (s *fakeStore) deleteDestLocked(arg db.DeleteOwnDestinationParams) (int64, undo) {
	for _, d := range s.dests {
		if d.id == arg.DestinationID && d.email == arg.Email {
			s.removeDestLocked(d.id)
			return 1, func() {
				s.dests = append(s.dests, d)
				sort.Slice(s.dests, func(i, j int) bool { return s.dests[i].id < s.dests[j].id })
			}
		}
	}
	return 0, nil
}

// ---- transactions -----------------------------------------------------------------------------------------------------

// txStore is the view InTx hands to fn: it reads and writes the parent's live state, and records the inverse of every
// write so a failed or cancelled transaction can be rolled back. The per-email lock taken by LockNotifsEmail is held
// until InTx returns.
type txStore struct {
	*fakeStore
	ctx  context.Context
	undo []undo
	held map[string]chan struct{}
}

func (s *fakeStore) emailLock(email string) chan struct{} {
	s.lockMu.Lock()
	defer s.lockMu.Unlock()
	ch, ok := s.locks[email]
	if !ok {
		ch = make(chan struct{}, 1)
		s.locks[email] = ch
	}
	return ch
}

// InTx runs fn on a transaction view. fn's error, or a context that ended by the time fn returned, rolls back every
// write the view made (in reverse order); success discards the log.
func (s *fakeStore) InTx(ctx context.Context, fn func(db.Querier) error) error {
	tx := &txStore{fakeStore: s, ctx: ctx, held: map[string]chan struct{}{}}
	defer func() {
		for _, ch := range tx.held {
			<-ch
		}
	}()
	done := false
	defer func() {
		if !done { // fn panicked: roll back like a real aborted transaction, then let the panic continue
			tx.rollback()
		}
	}()
	err := fn(tx)
	done = true
	if err == nil {
		err = ctx.Err() // a context that ended fails the commit, as with pgx
	}
	if err != nil {
		tx.rollback()
		return err
	}
	return nil
}

func (t *txStore) rollback() {
	t.mu.Lock()
	defer t.mu.Unlock()
	for i := len(t.undo) - 1; i >= 0; i-- {
		t.undo[i]()
	}
	t.undo = nil
}

func (t *txStore) record(u undo) {
	if u != nil {
		t.undo = append(t.undo, u)
	}
}

// LockNotifsEmail takes the per-email lock (ctx-aware); a second call for the same email in one transaction is a no-op.
func (t *txStore) LockNotifsEmail(ctx context.Context, email string) error {
	if _, ok := t.held[email]; ok {
		return nil
	}
	ch := t.emailLock(email)
	select {
	case ch <- struct{}{}:
		t.held[email] = ch
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (t *txStore) CreateItem(_ context.Context, arg db.CreateItemParams) (db.Item, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	it, err := t.createItemLocked(arg)
	if err != nil {
		return it, err
	}
	t.record(func() {
		for i, x := range t.items {
			if x.ID == it.ID {
				t.items = append(t.items[:i], t.items[i+1:]...)
				return
			}
		}
	})
	return it, nil
}

func (t *txStore) InsertJobRun(_ context.Context, arg db.InsertJobRunParams) (int64, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if _, ok := t.jobRuns[arg.IdempotencyKey]; ok {
		return 0, nil
	}
	t.jobRuns[arg.IdempotencyKey] = arg.Job
	t.record(func() { delete(t.jobRuns, arg.IdempotencyKey) })
	return 1, nil
}

func (t *txStore) SetNtfyUserID(_ context.Context, arg db.SetNtfyUserIDParams) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	if err := t.failSetNtfy; err != nil {
		t.failSetNtfy = nil
		return err
	}
	t.record(t.setNtfyLocked(arg))
	return nil
}

func (t *txStore) InsertDestination(_ context.Context, arg db.InsertDestinationParams) (db.InsertDestinationRow, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.failInsert != nil {
		return db.InsertDestinationRow{}, t.failInsert
	}
	row, u := t.insertDestLocked(arg)
	t.record(u)
	return row, nil
}

func (t *txStore) SetOwnDestinationStale(_ context.Context, arg db.SetOwnDestinationStaleParams) (int64, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	n, u := t.setStaleLocked(arg)
	t.record(u)
	return n, nil
}

func (t *txStore) DeleteOwnDestination(_ context.Context, arg db.DeleteOwnDestinationParams) (int64, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	n, u := t.deleteDestLocked(arg)
	t.record(u)
	return n, nil
}
