-- +goose Up
CREATE TABLE notifs_users (
    email        text PRIMARY KEY CHECK (email = lower(email)),
    ntfy_user_id text NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE destinations (
    id         bigserial PRIMARY KEY,
    email      text NOT NULL CHECK (email = lower(email)),
    notifs_id  bigint NOT NULL,
    kind       text NOT NULL CHECK (kind IN ('discord', 'webhook')),
    label      varchar(50) NOT NULL,
    hint       varchar(8) NOT NULL,
    stale      boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX destinations_email_idx ON destinations (email);

-- +goose Down
DROP TABLE destinations;
DROP TABLE notifs_users;
