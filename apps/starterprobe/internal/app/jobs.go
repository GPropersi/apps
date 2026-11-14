package app

import (
	"context"
	"errors"
	"log/slog"

	"github.com/gpropersi/apps/apps/starterprobe/internal/app/db"
	"github.com/gpropersi/apps/apps/starterprobe/internal/platform"
)

// Transactor runs fn inside one database transaction: commit when fn returns nil, roll back otherwise.
type Transactor interface {
	InTx(ctx context.Context, fn func(db.Querier) error) error
}

// Jobs holds the handlers for the jobs declared in app.yaml. Tx is set once the database is up, before the listener
// opens.
type Jobs struct {
	Tx     Transactor
	Logger *slog.Logger
}

// Funcs maps each job name to its handler; platform.VerifyJobs checks the keys against app.yaml `jobs[]`.
func (j *Jobs) Funcs() map[string]platform.JobFunc {
	return map[string]platform.JobFunc{"add-note": j.AddNote}
}

// AddNote is idempotent on the delivery key (the queue id, else the run id): the key row and the note are written in
// one transaction, so a redelivery finds the key and does nothing. It returns nil only after the commit.
func (j *Jobs) AddNote(ctx context.Context, req platform.JobRequest) error {
	if j.Tx == nil {
		return errors.New("jobs: database is not ready")
	}
	outcome := "duplicate"
	err := j.Tx.InTx(ctx, func(q db.Querier) error {
		n, err := q.InsertJobRun(ctx, db.InsertJobRunParams{IdempotencyKey: req.IdempotencyKey(), Job: req.Job})
		if err != nil {
			return err
		}
		if n == 0 {
			return nil // already done
		}
		if _, err := q.CreateItem(ctx, db.CreateItemParams{
			Text: "Added by a background task", CreatedBy: "Background task", Source: "task",
		}); err != nil {
			return err
		}
		outcome = "added"
		return nil
	})
	if err != nil {
		j.Logger.Error("job finished", "job", req.Job, "run_id", req.RunID, "outcome", "error", "error", err)
		return err
	}
	j.Logger.Info("job finished", "job", req.Job, "run_id", req.RunID, "outcome", outcome)
	return nil
}
