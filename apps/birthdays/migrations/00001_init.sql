-- +goose Up
CREATE TABLE users (
    id              bigserial PRIMARY KEY,
    email           text NOT NULL UNIQUE CHECK (email = lower(email)),
    auto_remind     boolean NOT NULL DEFAULT false,
    default_offsets smallint[] NOT NULL DEFAULT '{7,1}',
    ntfy_user_id    text NULL,
    start_tab       text NOT NULL DEFAULT 'auto' CHECK (start_tab IN ('auto', 'add', 'view')),
    list_view       text NOT NULL DEFAULT 'upcoming' CHECK (list_view IN ('upcoming', 'month', 'name', 'calendar')),
    calendar_zoom   text NOT NULL DEFAULT 'month' CHECK (calendar_zoom IN ('year', 'month', 'week')),
    color_scheme    text NOT NULL DEFAULT 'confetti' CHECK (color_scheme IN ('confetti', 'frosting', 'candle')),
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- A birthday's date: month 1-12, a day that exists in that month (Feb 29 allowed), an optional year in 1900-2200, and
-- Feb 29 with a year only when that year is a leap year.
CREATE TABLE birthdays (
    id         bigserial PRIMARY KEY,
    owner_id   bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    name       varchar(100) NOT NULL,
    month      smallint NOT NULL CHECK (month BETWEEN 1 AND 12),
    day        smallint NOT NULL,
    year       smallint NULL CHECK (year BETWEEN 1900 AND 2200),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT birthdays_day_valid CHECK (
        day BETWEEN 1 AND CASE WHEN month = 2 THEN 29 WHEN month IN (4, 6, 9, 11) THEN 30 ELSE 31 END
    ),
    CONSTRAINT birthdays_feb29_year_leap CHECK (
        NOT (month = 2 AND day = 29 AND year IS NOT NULL)
        OR (year % 4 = 0 AND (year % 100 <> 0 OR year % 400 = 0))
    )
);
CREATE INDEX birthdays_owner_idx ON birthdays (owner_id);

CREATE TABLE birthday_shares (
    birthday_id bigint NOT NULL REFERENCES birthdays (id) ON DELETE CASCADE,
    email       text NOT NULL CHECK (email = lower(email)),
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (birthday_id, email)
);
CREATE INDEX birthday_shares_email_idx ON birthday_shares (email);

-- No row means reminders are off for that person on that birthday.
CREATE TABLE reminder_settings (
    birthday_id bigint NOT NULL REFERENCES birthdays (id) ON DELETE CASCADE,
    user_id     bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    offsets     smallint[] NOT NULL CHECK (cardinality(offsets) >= 1 AND offsets <@ ARRAY[0, 1, 7]::smallint[]),
    PRIMARY KEY (birthday_id, user_id)
);
CREATE INDEX reminder_settings_user_idx ON reminder_settings (user_id);

CREATE TABLE gift_ideas (
    id          bigserial PRIMARY KEY,
    birthday_id bigint NOT NULL REFERENCES birthdays (id) ON DELETE CASCADE,
    author_id   bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    text        varchar(200) NOT NULL,
    shared      boolean NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX gift_ideas_birthday_idx ON gift_ideas (birthday_id);
CREATE INDEX gift_ideas_author_idx ON gift_ideas (author_id);

CREATE TABLE destinations (
    id         bigserial PRIMARY KEY,
    user_id    bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    notifs_id  bigint NOT NULL,
    kind       text NOT NULL CHECK (kind IN ('discord', 'webhook')),
    label      varchar(50) NOT NULL,
    hint       varchar(8) NOT NULL,
    stale      boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX destinations_user_idx ON destinations (user_id);

CREATE TABLE reminders_sent (
    birthday_id bigint NOT NULL REFERENCES birthdays (id) ON DELETE CASCADE,
    user_id     bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    occurrence  date NOT NULL,
    offset_days smallint NOT NULL,
    outcome     text NOT NULL CHECK (outcome IN ('sent', 'skipped', 'failed')),
    at          timestamptz,
    PRIMARY KEY (birthday_id, user_id, occurrence, offset_days)
);

CREATE TABLE job_runs (
    idempotency_key text PRIMARY KEY,
    job             text NOT NULL,
    done_at         timestamptz NOT NULL DEFAULT now()
);

-- +goose Down
DROP TABLE job_runs;
DROP TABLE reminders_sent;
DROP TABLE destinations;
DROP TABLE gift_ideas;
DROP TABLE reminder_settings;
DROP TABLE birthday_shares;
DROP TABLE birthdays;
DROP TABLE users;
