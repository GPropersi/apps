-- name: ListItems :many
SELECT id, text, created_by, source, created_at
FROM items
ORDER BY id DESC
LIMIT 50;

-- name: CreateItem :one
INSERT INTO items (text, created_by, source)
VALUES ($1, $2, $3)
RETURNING id, text, created_by, source, created_at;

-- name: InsertJobRun :execrows
INSERT INTO job_runs (idempotency_key, job)
VALUES ($1, $2)
ON CONFLICT DO NOTHING;
