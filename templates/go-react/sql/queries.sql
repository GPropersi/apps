-- name: ListItems :many
SELECT id, text, created_by, source, created_at
FROM items
ORDER BY id DESC
LIMIT 50;

-- name: CreateItem :one
INSERT INTO items (text, created_by, source)
VALUES ($1, $2, $3)
RETURNING id, text, created_by, source, created_at;

-- ---------------------------------------------------------------- phone notifications (per person, keyed by email)

-- name: LockNotifsEmail :exec
-- Per-person transaction-scoped advisory lock taken first in every read-then-write of a person's notify rows, so two
-- concurrent first calls provision once and the destination cap holds.
SELECT pg_advisory_xact_lock(hashtext(sqlc.arg(email)::text));

-- name: GetNtfyUserID :one
SELECT ntfy_user_id FROM notifs_users WHERE email = sqlc.arg(email);

-- name: SetNtfyUserID :exec
INSERT INTO notifs_users (email, ntfy_user_id)
VALUES (sqlc.arg(email), sqlc.arg(ntfy_user_id))
ON CONFLICT DO NOTHING;

-- name: ListDestinations :many
SELECT id, notifs_id, kind, label, hint, stale
FROM destinations
WHERE email = sqlc.arg(email)
ORDER BY id;

-- name: CountDestinations :one
SELECT count(*)::bigint FROM destinations WHERE email = sqlc.arg(email);

-- name: GetDestinationCounts :one
SELECT count(*)::bigint AS total, (count(*) FILTER (WHERE stale))::bigint AS stale
FROM destinations
WHERE email = sqlc.arg(email);

-- name: InsertDestination :one
INSERT INTO destinations (email, notifs_id, kind, label, hint)
VALUES (sqlc.arg(email), sqlc.arg(notifs_id), sqlc.arg(kind), sqlc.arg(label), sqlc.arg(hint))
RETURNING id, notifs_id, kind, label, hint, stale;

-- name: GetOwnDestination :one
SELECT id, notifs_id, kind, label, hint, stale
FROM destinations
WHERE id = sqlc.arg(destination_id) AND email = sqlc.arg(email);

-- name: SetOwnDestinationStale :execrows
UPDATE destinations SET stale = sqlc.arg(stale)
WHERE id = sqlc.arg(destination_id) AND email = sqlc.arg(email);

-- name: DeleteOwnDestination :execrows
DELETE FROM destinations WHERE id = sqlc.arg(destination_id) AND email = sqlc.arg(email);

-- name: InsertJobRun :execrows
INSERT INTO job_runs (idempotency_key, job)
VALUES ($1, $2)
ON CONFLICT DO NOTHING;
