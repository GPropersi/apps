# birthdays

A family birthday list with reminders: each person keeps their own birthdays, can share them with other family
members, track gift ideas, and choose how many days ahead to be reminded. Built from the `go-react` template (Go server
with chi, pgx + sqlc and goose, embedding a Vite + React page); template details are in
[`../../templates/go-react/README.md`](../../templates/go-react/README.md).

## Notifications

The app sets `notifs: true` in `app.yaml`, so reminders go out through 4irl-notifs (phone, Discord or webhook). After
the first deploy, run the manual `notifs-exchange` workflow for this app to fetch its key; until then the host refuses
the app's notifs key and reminders are not sent. See "Notifications" in [`../README.md`](../README.md) for the one-time
operator steps and how the exchange works.

## Jobs

Jobs follow [`platform/jobs/CONTRACT.md`](../../platform/jobs/CONTRACT.md).

- `reminder-scan` runs daily at 07:00 in the schedule zone (with catch-up) and enqueues one `send-reminder` per
  reminder that is due today; duplicates are ignored.
- `send-reminder` sends one reminder through 4irl-notifs and records the outcome (`sent`, `skipped` or `failed`). It
  re-checks access and the birthday date first, so a stale reminder is skipped, not sent.

## Shared platform package

`internal/platform/` is the shared helper package; never edit it inside this app. It is a copy of the template's, and
a lint compares the two, so change the template and copy it over.

## Development

Run tests with `make test-app APP=birthdays`; regenerate sqlc with `make app-sqlc APP=birthdays` after changing
`sql/queries.sql` or the migrations. Every migration must stay compatible with the previous app version, because a
rollback never reverts the schema.
