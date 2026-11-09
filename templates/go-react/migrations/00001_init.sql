-- +goose Up
CREATE TABLE items (
    id         bigserial PRIMARY KEY,
    text       varchar(200) NOT NULL,
    created_by text NOT NULL,
    source     text NOT NULL CHECK (source IN ('user', 'task')),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE job_runs (
    idempotency_key text PRIMARY KEY,
    job             text NOT NULL,
    done_at         timestamptz NOT NULL DEFAULT now()
);

-- +goose Down
DROP TABLE job_runs;
DROP TABLE items;
