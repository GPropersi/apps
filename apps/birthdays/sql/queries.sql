-- Access rule, used by every viewer-scoped query: a viewer sees birthday B iff B.owner_id = viewer id, or a
-- birthday_shares row (B.id, viewer email) exists. No query takes a birthday id without the viewer. The viewer email is
-- already trimmed and lowercased (ensureUser / EmailOf), so no query lowercases it.

-- ---------------------------------------------------------------- users and settings

-- name: UpsertUser :one
-- The no-op DO UPDATE makes RETURNING work for an existing row.
INSERT INTO users (email)
VALUES (sqlc.arg(email))
ON CONFLICT (email) DO UPDATE SET email = EXCLUDED.email
RETURNING *;

-- name: UpdateSettings :one
UPDATE users
SET auto_remind     = COALESCE(sqlc.narg(auto_remind), auto_remind),
    default_offsets = COALESCE(sqlc.narg(default_offsets)::smallint[], default_offsets),
    start_tab       = COALESCE(sqlc.narg(start_tab), start_tab),
    list_view       = COALESCE(sqlc.narg(list_view), list_view),
    calendar_zoom   = COALESCE(sqlc.narg(calendar_zoom), calendar_zoom),
    color_scheme    = COALESCE(sqlc.narg(color_scheme), color_scheme)
WHERE id = sqlc.arg(user_id)
RETURNING *;

-- name: SetNtfyUser :exec
UPDATE users SET ntfy_user_id = sqlc.arg(ntfy_user_id) WHERE id = sqlc.arg(user_id);

-- name: LockUserNtfy :exec
-- Per-user transaction-scoped advisory lock taken first in the ntfy provisioning transaction, so two concurrent first
-- calls provision once (the second waits, then sees the stored id).
SELECT pg_advisory_xact_lock(sqlc.arg(user_id)::bigint);

-- name: GetNtfyUser :one
SELECT ntfy_user_id FROM users WHERE id = sqlc.arg(user_id);

-- name: GetDestinationCounts :one
SELECT count(*)::bigint AS total, (count(*) FILTER (WHERE stale))::bigint AS stale
FROM destinations
WHERE user_id = sqlc.arg(user_id);

-- ---------------------------------------------------------------- birthdays (viewer-scoped)

-- name: ListViewerBirthdays :many
SELECT b.id, b.name, b.month, b.day, b.year,
       (b.owner_id = sqlc.arg(viewer_id))::boolean AS is_mine,
       o.email AS owner_email,
       COALESCE(rs.offsets, ARRAY[]::smallint[])::smallint[] AS reminder_offsets
FROM birthdays b
JOIN users o ON o.id = b.owner_id
LEFT JOIN reminder_settings rs ON rs.birthday_id = b.id AND rs.user_id = sqlc.arg(viewer_id)
WHERE b.owner_id = sqlc.arg(viewer_id)
   OR EXISTS (SELECT 1 FROM birthday_shares s WHERE s.birthday_id = b.id AND s.email = sqlc.arg(viewer_email))
ORDER BY b.id;

-- name: GetViewerBirthday :one
SELECT b.id, b.name, b.month, b.day, b.year,
       (b.owner_id = sqlc.arg(viewer_id))::boolean AS is_mine,
       o.email AS owner_email,
       COALESCE(rs.offsets, ARRAY[]::smallint[])::smallint[] AS reminder_offsets
FROM birthdays b
JOIN users o ON o.id = b.owner_id
LEFT JOIN reminder_settings rs ON rs.birthday_id = b.id AND rs.user_id = sqlc.arg(viewer_id)
WHERE b.id = sqlc.arg(birthday_id)
  AND (b.owner_id = sqlc.arg(viewer_id)
       OR EXISTS (SELECT 1 FROM birthday_shares s WHERE s.birthday_id = b.id AND s.email = sqlc.arg(viewer_email)));

-- name: CountOwnedBirthdays :one
SELECT count(*)::bigint FROM birthdays WHERE owner_id = sqlc.arg(owner_id);

-- name: InsertBirthday :one
INSERT INTO birthdays (owner_id, name, month, day, year)
VALUES (sqlc.arg(owner_id), sqlc.arg(name), sqlc.arg(month), sqlc.arg(day), sqlc.narg(year))
RETURNING id, name, month, day, year;

-- name: UpdateOwnedBirthday :one
UPDATE birthdays
SET name = sqlc.arg(name), month = sqlc.arg(month), day = sqlc.arg(day), year = sqlc.narg(year), updated_at = now()
WHERE id = sqlc.arg(birthday_id) AND owner_id = sqlc.arg(owner_id)
RETURNING id, name, month, day, year;

-- name: DeleteOwnedBirthday :execrows
DELETE FROM birthdays WHERE id = sqlc.arg(birthday_id) AND owner_id = sqlc.arg(owner_id);

-- ---------------------------------------------------------------- shares (owner-scoped, except the recipient's own removal)

-- name: ListOwnedShares :many
SELECT s.email
FROM birthday_shares s
JOIN birthdays b ON b.id = s.birthday_id
WHERE b.id = sqlc.arg(birthday_id) AND b.owner_id = sqlc.arg(owner_id)
ORDER BY s.created_at, s.email;

-- Row locks that serialize a count-then-insert limit check and the unshare cleanup (READ COMMITTED has no other guard).
-- name: LockUser :one
SELECT id FROM users WHERE id = sqlc.arg(user_id) FOR UPDATE;

-- name: LockOwnedBirthday :one
SELECT id FROM birthdays WHERE id = sqlc.arg(birthday_id) AND owner_id = sqlc.arg(owner_id) FOR UPDATE;

-- name: LockBirthdayShared :one
-- A recipient's write takes this lock, so it waits for a concurrent unshare (which holds LockOwnedBirthday) and then
-- fails its own access check instead of leaving an orphan row.
SELECT id FROM birthdays WHERE id = sqlc.arg(birthday_id) FOR SHARE;

-- name: InsertOwnedShare :execrows
INSERT INTO birthday_shares (birthday_id, email)
SELECT b.id, sqlc.arg(email)::text
FROM birthdays b
WHERE b.id = sqlc.arg(birthday_id) AND b.owner_id = sqlc.arg(owner_id)
ON CONFLICT DO NOTHING;

-- name: DeleteOwnedShare :execrows
DELETE FROM birthday_shares s
USING birthdays b
WHERE s.birthday_id = b.id AND b.id = sqlc.arg(birthday_id) AND b.owner_id = sqlc.arg(owner_id)
  AND s.email = sqlc.arg(email);

-- name: DeleteSharedPersonReminders :exec
DELETE FROM reminder_settings rs
USING birthdays b, users u
WHERE rs.birthday_id = b.id AND b.id = sqlc.arg(birthday_id) AND b.owner_id = sqlc.arg(owner_id)
  AND rs.user_id = u.id AND u.email = sqlc.arg(email);

-- name: DeleteSharedPersonGifts :exec
DELETE FROM gift_ideas g
USING birthdays b, users u
WHERE g.birthday_id = b.id AND b.id = sqlc.arg(birthday_id) AND b.owner_id = sqlc.arg(owner_id)
  AND g.author_id = u.id AND u.email = sqlc.arg(email);

-- A recipient removing the birthday from their own list: their share row, then their own reminders and gifts.
-- name: DeleteOwnShare :execrows
DELETE FROM birthday_shares
WHERE birthday_id = sqlc.arg(birthday_id) AND email = sqlc.arg(viewer_email);

-- name: DeleteOwnReminders :exec
DELETE FROM reminder_settings
WHERE birthday_id = sqlc.arg(birthday_id) AND user_id = sqlc.arg(viewer_id);

-- name: DeleteOwnGifts :exec
DELETE FROM gift_ideas
WHERE birthday_id = sqlc.arg(birthday_id) AND author_id = sqlc.arg(viewer_id);

-- ---------------------------------------------------------------- reminder settings (viewer-scoped)

-- name: UpsertViewerReminder :execrows
INSERT INTO reminder_settings (birthday_id, user_id, offsets)
SELECT b.id, sqlc.arg(viewer_id)::bigint, sqlc.arg(offsets)::smallint[]
FROM birthdays b
WHERE b.id = sqlc.arg(birthday_id)
  AND (b.owner_id = sqlc.arg(viewer_id)
       OR EXISTS (SELECT 1 FROM birthday_shares s WHERE s.birthday_id = b.id AND s.email = sqlc.arg(viewer_email)))
ON CONFLICT (birthday_id, user_id) DO UPDATE SET offsets = EXCLUDED.offsets;

-- name: DeleteViewerReminder :execrows
DELETE FROM reminder_settings rs
USING birthdays b
WHERE rs.birthday_id = b.id AND b.id = sqlc.arg(birthday_id) AND rs.user_id = sqlc.arg(viewer_id)
  AND (b.owner_id = sqlc.arg(viewer_id)
       OR EXISTS (SELECT 1 FROM birthday_shares s WHERE s.birthday_id = b.id AND s.email = sqlc.arg(viewer_email)));

-- ---------------------------------------------------------------- gift ideas (viewer-scoped)

-- name: ListViewerGifts :many
-- The viewer's own ideas plus the shared ideas of other people, on a birthday the viewer can see.
SELECT g.id, g.text, g.shared, a.email AS author_email, (g.author_id = sqlc.arg(viewer_id))::boolean AS mine
FROM gift_ideas g
JOIN users a ON a.id = g.author_id
JOIN birthdays b ON b.id = g.birthday_id
WHERE b.id = sqlc.arg(birthday_id)
  AND (b.owner_id = sqlc.arg(viewer_id)
       OR EXISTS (SELECT 1 FROM birthday_shares s WHERE s.birthday_id = b.id AND s.email = sqlc.arg(viewer_email)))
  AND (g.author_id = sqlc.arg(viewer_id) OR g.shared)
ORDER BY g.id;

-- name: CountViewerGifts :one
SELECT count(*)::bigint FROM gift_ideas
WHERE birthday_id = sqlc.arg(birthday_id) AND author_id = sqlc.arg(viewer_id);

-- name: InsertViewerGift :one
INSERT INTO gift_ideas (birthday_id, author_id, text, shared)
SELECT b.id, sqlc.arg(viewer_id)::bigint, sqlc.arg(text)::varchar, sqlc.arg(shared)::boolean
FROM birthdays b
WHERE b.id = sqlc.arg(birthday_id)
  AND (b.owner_id = sqlc.arg(viewer_id)
       OR EXISTS (SELECT 1 FROM birthday_shares s WHERE s.birthday_id = b.id AND s.email = sqlc.arg(viewer_email)))
RETURNING id, text, shared;

-- name: GetOwnGiftBirthday :one
-- The birthday an idea hangs off, for its author only; the handler then re-checks the author can still see that birthday.
SELECT birthday_id FROM gift_ideas
WHERE id = sqlc.arg(gift_id) AND author_id = sqlc.arg(author_id);

-- name: UpdateOwnGiftShared :one
UPDATE gift_ideas
SET shared = sqlc.arg(shared)
WHERE id = sqlc.arg(gift_id) AND author_id = sqlc.arg(author_id)
RETURNING id, text, shared;

-- name: DeleteOwnGift :execrows
DELETE FROM gift_ideas WHERE id = sqlc.arg(gift_id) AND author_id = sqlc.arg(author_id);

-- ---------------------------------------------------------------- notification destinations (owner-scoped)

-- name: ListDestinations :many
SELECT id, notifs_id, kind, label, hint, stale
FROM destinations
WHERE user_id = sqlc.arg(user_id)
ORDER BY id;

-- name: CountDestinations :one
SELECT count(*)::bigint FROM destinations WHERE user_id = sqlc.arg(user_id);

-- name: InsertDestination :one
INSERT INTO destinations (user_id, notifs_id, kind, label, hint)
VALUES (sqlc.arg(user_id), sqlc.arg(notifs_id), sqlc.arg(kind), sqlc.arg(label), sqlc.arg(hint))
RETURNING id, notifs_id, kind, label, hint, stale;

-- name: GetOwnDestination :one
SELECT id, notifs_id, kind, label, hint, stale
FROM destinations
WHERE id = sqlc.arg(destination_id) AND user_id = sqlc.arg(user_id);

-- name: SetOwnDestinationStale :execrows
UPDATE destinations SET stale = sqlc.arg(stale)
WHERE id = sqlc.arg(destination_id) AND user_id = sqlc.arg(user_id);

-- name: DeleteOwnDestination :execrows
DELETE FROM destinations WHERE id = sqlc.arg(destination_id) AND user_id = sqlc.arg(user_id);

-- ---------------------------------------------------------------- jobs

-- name: InsertJobRun :execrows
INSERT INTO job_runs (idempotency_key, job)
VALUES ($1, $2)
ON CONFLICT DO NOTHING;

-- name: ListReminderCandidates :many
-- Every reminder setting with the birthday's date; the scan applies the date rules in Go.
SELECT rs.birthday_id, rs.user_id, rs.offsets, b.month, b.day, b.year
FROM reminder_settings rs
JOIN birthdays b ON b.id = rs.birthday_id
ORDER BY rs.birthday_id, rs.user_id;

-- name: ListRemindersSentSince :many
SELECT birthday_id, user_id, occurrence, offset_days
FROM reminders_sent
WHERE occurrence >= sqlc.arg(since)::date;

-- name: GetReminderContext :one
-- The send job's re-read: the birthday, the person, whether they still have access and their current offsets.
SELECT b.name, b.month, b.day, b.year, u.email, u.ntfy_user_id,
       COALESCE(rs.offsets, ARRAY[]::smallint[])::smallint[] AS offsets,
       (b.owner_id = u.id OR EXISTS (SELECT 1 FROM birthday_shares s WHERE s.birthday_id = b.id AND s.email = u.email))::boolean AS has_access
FROM birthdays b
JOIN users u ON u.id = sqlc.arg(user_id)
LEFT JOIN reminder_settings rs ON rs.birthday_id = b.id AND rs.user_id = u.id
WHERE b.id = sqlc.arg(birthday_id);

-- name: InsertReminderSent :execrows
INSERT INTO reminders_sent (birthday_id, user_id, occurrence, offset_days, outcome, at)
VALUES (sqlc.arg(birthday_id), sqlc.arg(user_id), sqlc.arg(occurrence), sqlc.arg(offset_days), sqlc.arg(outcome)::text,
        CASE WHEN sqlc.arg(outcome)::text = 'sent' THEN now() END)
ON CONFLICT DO NOTHING;
