package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"github.com/gpropersi/apps/apps/birthdays/internal/app/db"
	"github.com/gpropersi/apps/apps/birthdays/internal/platform"
)

const (
	scanWindowDays   = 2               // a reminder missed this many days ago is still sent
	maxScanEnqueues  = 900             // one scan queues at most this many sends
	scanDedupeTTL    = 20 * time.Hour  // shorter than the daily scan period, so the next scan can re-enqueue an unsent reminder
	jobSendReminder  = "send-reminder" // the queued job's name in app.yaml
	msgNoPublisher   = "app has no ntfy publisher"
	msgNoPersonalDst = "personal destination not available for recipient"
)

// Transactor runs fn inside one database transaction: commit when fn returns nil, roll back otherwise.
type Transactor interface {
	InTx(ctx context.Context, fn func(db.Querier) error) error
}

// ReminderNotifier is the part of the 4irl-notifs client the reminder jobs use; *platform.NotifsClient satisfies it and
// tests fake it.
type ReminderNotifier interface {
	Configured() error
	Send(ctx context.Context, m platform.Message) (platform.Result, error)
	EnsurePublisher(ctx context.Context) error
	LookupPersonalDestinations(ctx context.Context, email string, ids []int64) (map[int64]bool, error)
}

// Jobs holds the handlers for the jobs declared in app.yaml. Store, Tx, Queue and Notifs are set by Run before the
// listener opens, so the scheduled scan can hand work to the queued sender through Queue.
type Jobs struct {
	Store  db.Querier
	Tx     Transactor
	Queue  Enqueuer
	Notifs ReminderNotifier
	Logger *slog.Logger
	Now    func() time.Time // the clock behind every "today"; time.Now when nil
}

// Funcs maps each job name to its handler; platform.VerifyJobs checks the keys against app.yaml `jobs[]`.
func (j *Jobs) Funcs() map[string]platform.JobFunc {
	return map[string]platform.JobFunc{
		"reminder-scan": j.ReminderScan,
		"send-reminder": j.SendReminder,
	}
}

func (j *Jobs) today() (Date, error) {
	zone, err := platform.ScheduleZone()
	if err != nil {
		return Date{}, err
	}
	now := time.Now
	if j.Now != nil {
		now = j.Now
	}
	return DateOf(now().In(zone)), nil
}

func (j *Jobs) log() *slog.Logger {
	if j.Logger != nil {
		return j.Logger
	}
	return slog.Default()
}

// reminderPayload is what the scan queues: ids and the occurrence only, no personal data in Redis.
type reminderPayload struct {
	BirthdayID int64  `json:"birthday_id"`
	UserID     int64  `json:"user_id"`
	Occurrence string `json:"occurrence"`
	OffsetDays int16  `json:"offset_days"`
}

// reminderKey is both the queue dedupe key and the delivery idempotency key.
func reminderKey(birthdayID, userID int64, occurrence string, offset int16) string {
	return fmt.Sprintf("rem-%d-%d-%s-%d", birthdayID, userID, occurrence, offset)
}

func pgDate(d Date) pgtype.Date {
	return pgtype.Date{Time: time.Date(d.Year, time.Month(d.Month), d.Day, 0, 0, 0, 0, time.UTC), Valid: true}
}

func fromPgDate(d pgtype.Date) Date { return DateOf(d.Time) }

type sentKey struct {
	birthday, user int64
	occurrence     Date
	offset         int16
}

// ReminderScan is the daily scheduled job: it finds every reminder due today (or missed inside the catch-up window)
// that has no outcome yet and queues one send-reminder job per reminder. It writes nothing to the database.
func (j *Jobs) ReminderScan(ctx context.Context, _ platform.JobRequest) error {
	started := time.Now()
	log := j.log()
	if j.Notifs == nil {
		return platform.ErrNotifsUnconfigured
	}
	if err := j.Notifs.Configured(); err != nil {
		log.Error("reminder scan: notifs not configured, nothing queued", "error", err)
		return err
	}
	today, err := j.today()
	if err != nil {
		return err
	}
	cands, err := j.Store.ListReminderCandidates(ctx)
	if err != nil {
		return fmt.Errorf("list reminder candidates: %w", err)
	}
	sentRows, err := j.Store.ListRemindersSentSince(ctx, pgDate(today))
	if err != nil {
		return fmt.Errorf("list reminders sent: %w", err)
	}
	sent := make(map[sentKey]bool, len(sentRows))
	for _, r := range sentRows {
		sent[sentKey{r.BirthdayID, r.UserID, fromPgDate(r.Occurrence), r.OffsetDays}] = true
	}

	var due []reminderPayload
	for _, c := range cands {
		occ := Occurrence(c.Month, c.Day, today)
		offsets := slices.Clone(c.Offsets)
		slices.Sort(offsets)
		offsets = slices.Compact(offsets)
		for _, off := range offsets {
			remindOn := occ.AddDays(-int(off))
			if remindOn.Before(today.AddDays(-scanWindowDays)) || today.Before(remindOn) {
				continue
			}
			if sent[sentKey{c.BirthdayID, c.UserID, occ, off}] {
				continue
			}
			due = append(due, reminderPayload{BirthdayID: c.BirthdayID, UserID: c.UserID, Occurrence: occ.String(), OffsetDays: off})
		}
	}

	enqueued, dupes := 0, 0
	for i, p := range due {
		if enqueued >= maxScanEnqueues {
			log.Warn("reminder scan: enqueue cap reached", "enqueued", enqueued, "remaining", len(due)-i)
			break
		}
		_, ok, err := j.Queue.EnqueueUnique(ctx, jobSendReminder, reminderKey(p.BirthdayID, p.UserID, p.Occurrence, p.OffsetDays), p, scanDedupeTTL)
		if errors.Is(err, platform.ErrQueueFull) {
			log.Warn("reminder scan: queue full", "enqueued", enqueued, "remaining", len(due)-i)
			break
		}
		if err != nil {
			return fmt.Errorf("enqueue reminder: %w", err)
		}
		if ok {
			enqueued++
		} else {
			dupes++
		}
	}
	log.Info("reminder scan done", "today", today.String(), "due", len(due), "enqueued", enqueued, "duplicates", dupes,
		"duration_ms", time.Since(started).Milliseconds())
	return nil
}

// SendReminder is the queued job that sends one reminder; see the outcome table in the plan's Contracts -> Jobs.
// reminders_sent is the record of outcome, so a reminder is never sent twice. Every notifs call happens before the
// recording transaction.
func (j *Jobs) SendReminder(ctx context.Context, req platform.JobRequest) error {
	started := time.Now()
	log := j.log()
	var p reminderPayload
	if err := json.Unmarshal(req.Payload, &p); err != nil || p.BirthdayID == 0 || p.UserID == 0 {
		log.Error("send-reminder: unreadable payload, dropped", "run_id", req.RunID)
		return nil
	}
	occ, err := ParseDate(p.Occurrence)
	if err != nil {
		log.Error("send-reminder: bad occurrence, dropped", "run_id", req.RunID)
		return nil
	}
	if j.Notifs == nil {
		return platform.ErrNotifsUnconfigured
	}
	today, err := j.today()
	if err != nil {
		return err
	}
	key := reminderKey(p.BirthdayID, p.UserID, p.Occurrence, p.OffsetDays)
	logf := func(outcome string, attrs ...any) {
		log.Info("send-reminder", append([]any{"key", key, "outcome", outcome, "duration_ms", time.Since(started).Milliseconds()}, attrs...)...)
	}

	rc, err := j.Store.GetReminderContext(ctx, db.GetReminderContextParams{UserID: p.UserID, BirthdayID: p.BirthdayID})
	if errors.Is(err, pgx.ErrNoRows) {
		logf("gone")
		return nil
	}
	if err != nil {
		return fmt.Errorf("read reminder context: %w", err)
	}
	already, err := j.alreadyRecorded(ctx, p, occ)
	if err != nil {
		return err
	}
	if already {
		logf("already_recorded")
		return nil
	}

	switch {
	case !rc.HasAccess:
		return j.record(ctx, req, p, occ, "skipped", "no_access", logf)
	case !slices.Contains(rc.Offsets, p.OffsetDays):
		return j.record(ctx, req, p, occ, "skipped", "offset_off", logf)
	case occ.Before(today):
		return j.record(ctx, req, p, occ, "skipped", "past", logf)
	case occurrenceIn(rc.Month, rc.Day, occ.Year) != occ:
		return j.record(ctx, req, p, occ, "skipped", "date_changed", logf)
	}

	dests, err := j.Store.ListDestinations(ctx, p.UserID)
	if err != nil {
		return fmt.Errorf("list destinations: %w", err)
	}
	var personal []int64
	var localByNotifs = map[int64]int64{}
	for _, d := range dests {
		if !d.Stale {
			personal = append(personal, d.NotifsID)
			localByNotifs[d.NotifsID] = d.ID
		}
	}
	hasNtfy := rc.NtfyUserID.Valid && rc.NtfyUserID.String != ""
	if !hasNtfy && len(personal) == 0 {
		logf("nowhere_to_send")
		return nil
	}

	days := DaysUntil(today, occ)
	title := rc.Name + "'s birthday is " + whenText(days)
	body := time.Date(occ.Year, time.Month(occ.Month), occ.Day, 0, 0, 0, 0, time.UTC).Format("Monday, January 2")
	var birthYear *int16
	if rc.Year.Valid {
		birthYear = &rc.Year.Int16
	}
	if age := Turning(birthYear, occ); age != nil {
		body += " - turns " + strconv.Itoa(*age)
	}
	send := func(ids []int64) error {
		m := platform.Message{Channel: "all", IdempotencyKey: key, Recipient: rc.Email, Title: title, Body: body,
			Via: viaOf(hasNtfy, len(ids) > 0)}
		if len(ids) > 0 {
			m.PersonalDestinationIDs = ids
		}
		_, err := j.Notifs.Send(ctx, m)
		return err
	}
	// failed records a rejection a retry cannot fix.
	failed := func(err error) error {
		return j.record(ctx, req, p, occ, "failed", "status_"+strconv.Itoa(notifsStatus(err)), logf)
	}

	err = send(personal)
	if err == nil {
		return j.record(ctx, req, p, occ, "sent", "", logf)
	}
	switch {
	case isNotifsMsg(err, msgNoPublisher):
		if perr := j.Notifs.EnsurePublisher(ctx); perr != nil {
			logf("error", "step", "ensure_publisher", "status", notifsStatus(perr))
			return perr
		}
		err = send(personal)
		if err == nil {
			return j.record(ctx, req, p, occ, "sent", "", logf)
		}
		if isNotifsMsg(err, msgNoPersonalDst) {
			// Call four is the lookup; no retry after a mint. Settle the staling, then error for the runner's retry.
			if len(personal) > 0 {
				if _, _, lerr := j.staleUndeliverable(ctx, rc.Email, p.UserID, personal, localByNotifs); lerr != nil {
					return lerr
				}
			}
			logf("error", "step", "resend_after_mint", "status", notifsStatus(err))
			return err
		}
		return j.classify(err, failed, logf)
	case isNotifsMsg(err, msgNoPersonalDst):
		if len(personal) == 0 {
			return failed(err) // nothing of ours to stale, the 422 is unexplained
		}
		stale, survivors, lerr := j.staleUndeliverable(ctx, rc.Email, p.UserID, personal, localByNotifs)
		if lerr != nil {
			return lerr
		}
		if stale == 0 {
			return failed(err) // the 422 is unexplained
		}
		if len(survivors) == 0 && !hasNtfy {
			logf("nowhere_to_send", "staled", stale)
			return nil
		}
		err = send(survivors)
		switch {
		case err == nil:
			return j.record(ctx, req, p, occ, "sent", "", logf)
		case isNotifsMsg(err, msgNoPersonalDst):
			return failed(err)
		}
		return j.classify(err, failed, logf)
	}
	return j.classify(err, failed, logf)
}

// classify maps a send error that needs no special handling: a rejection a retry cannot fix is recorded failed (nil),
// everything else (network, 5xx, 408, 425, 429, 401, 403, unconfigured, a publisher 422 with no mint left) is an error so the
// runner retries and nothing is recorded.
func (j *Jobs) classify(err error, failed func(error) error, logf func(string, ...any)) error {
	var ne *platform.NotifsError
	if errors.As(err, &ne) && ne.Status >= 400 && ne.Status < 500 &&
		ne.Status != http.StatusUnauthorized && ne.Status != http.StatusForbidden && ne.Status != http.StatusTooManyRequests &&
		ne.Status != http.StatusRequestTimeout && ne.Status != http.StatusTooEarly &&
		!strings.Contains(ne.Message, msgNoPublisher) {
		return failed(err)
	}
	logf("error", "status", notifsStatus(err))
	return err
}

func isNotifsMsg(err error, msg string) bool {
	var ne *platform.NotifsError
	return errors.As(err, &ne) && ne.Status == http.StatusUnprocessableEntity && strings.Contains(ne.Message, msg)
}

func viaOf(ntfy, personal bool) string {
	switch {
	case ntfy && personal:
		return "both"
	case personal:
		return "personal"
	default:
		return "ntfy"
	}
}

// whenText is the actual wording for the days until the occurrence (never the offset).
func whenText(days int) string {
	switch days {
	case 0:
		return "today"
	case 1:
		return "tomorrow"
	default:
		return "in " + strconv.Itoa(days) + " days"
	}
}

// staleUndeliverable looks up the person's destinations and marks stale those among ids that are not deliverable. It
// returns how many it staled and the surviving ids. A failed lookup is an error and stales nothing.
func (j *Jobs) staleUndeliverable(ctx context.Context, email string, userID int64, ids []int64, local map[int64]int64) (int, []int64, error) {
	ok, err := j.Notifs.LookupPersonalDestinations(ctx, email, ids)
	if err != nil {
		j.log().Error("send-reminder: destination lookup failed", "status", notifsStatus(err))
		return 0, nil, err
	}
	var bad, survivors []int64
	for _, id := range ids {
		if ok[id] {
			survivors = append(survivors, id)
		} else {
			bad = append(bad, id)
		}
	}
	if len(bad) == 0 {
		return 0, survivors, nil
	}
	err = j.Tx.InTx(ctx, func(q db.Querier) error {
		for _, id := range bad {
			if _, err := q.SetOwnDestinationStale(ctx, db.SetOwnDestinationStaleParams{DestinationID: local[id], UserID: userID, Stale: true}); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return 0, nil, fmt.Errorf("stale destinations: %w", err)
	}
	j.log().Info("send-reminder: destinations staled", "count", len(bad))
	return len(bad), survivors, nil
}

// alreadyRecorded reports whether reminders_sent already holds an outcome for this reminder.
func (j *Jobs) alreadyRecorded(ctx context.Context, p reminderPayload, occ Date) (bool, error) {
	rows, err := j.Store.ListRemindersSentSince(ctx, pgDate(occ))
	if err != nil {
		return false, fmt.Errorf("read reminders sent: %w", err)
	}
	for _, r := range rows {
		if r.BirthdayID == p.BirthdayID && r.UserID == p.UserID && fromPgDate(r.Occurrence) == occ && r.OffsetDays == p.OffsetDays {
			return true, nil
		}
	}
	return false, nil
}

// record writes the outcome and the job_runs row in one transaction. An error means nothing was recorded and the
// runner retries with the same idempotency key.
func (j *Jobs) record(ctx context.Context, req platform.JobRequest, p reminderPayload, occ Date, outcome, reason string, logf func(string, ...any)) error {
	err := j.Tx.InTx(ctx, func(q db.Querier) error {
		if _, err := q.InsertJobRun(ctx, db.InsertJobRunParams{IdempotencyKey: req.IdempotencyKey(), Job: jobSendReminder}); err != nil {
			return err
		}
		_, err := q.InsertReminderSent(ctx, db.InsertReminderSentParams{BirthdayID: p.BirthdayID, UserID: p.UserID,
			Occurrence: pgDate(occ), OffsetDays: p.OffsetDays, Outcome: outcome})
		return err
	})
	if err != nil {
		logf("record_failed", "wanted", outcome)
		return fmt.Errorf("record %s: %w", outcome, err)
	}
	logf(outcome, "reason", reason)
	return nil
}
