# Jobs contract: `enqueue()` and `POST /_jobs/<name>`

The language-neutral, normative spec that the Go, Python and Node helpers in `templates/` implement. The runner
(`platform/jobs`) is the other side of every rule here. `internal/contractdoc/contractdoc_test.go` greps this file for
the runner's constants, so a limit changed in code but not here fails `platform/jobs/test_go.sh`.

An app does two things: it **enqueues** a job (an `LPUSH` of an envelope onto its own Redis list) and it **answers**
the runner's `POST /_jobs/<name>` call. Scheduled jobs (a `schedule:` in `app.yaml`) need only the second.

## Terms

MUST, MUST NOT and SHOULD are used in their usual specification sense. `<app>` is the app name (the directory under
`apps/` and the registry name), `<name>` a job name declared in `app.yaml` `jobs[]`.

## 1. `enqueue(job, payload)`

Adds one job to the app's queue. A helper MUST do these steps in order and MUST surface every failure to the caller,
never dropping a job silently:

1. **Validate `job`** against the app's declared jobs (the `jobs[]` names in `app.yaml`); an undeclared name is an error
   before anything is sent to Redis.
2. **Build the envelope** (JSON, UTF-8):

   ```
   {"v":1,"id":"<26-char ULID>","job":"<job name>","payload":<any JSON value or null>,"enqueued_at":"<RFC3339 UTC Z>"}
   ```

   `id` is a new ULID per call. `payload` is any JSON value; omit nothing (use `null` for no payload).
3. **Refuse an oversize envelope:** if the serialized envelope is more than 65536 bytes, return an error and write
   nothing.
4. **Refuse a full queue:** if `LLEN <app>:jobs:queue` is 1000 or more, return an error and write nothing.
5. **`LPUSH <app>:jobs:queue <envelope>`.** Redis errors (`OOM`, `NOPERM`, connection failures) MUST reach the caller
   unchanged in meaning.

The runner adds `"attempt":<int >= 1>` and `"last_error":"<masked, at most 300 chars>"` when it re-queues an
envelope. Apps never write these fields.

### Redis keys

All keys are inside the app's own prefix, so the app's Redis user can write them:

| Key | Type | Writer | Bound |
|---|---|---|---|
| `<app>:jobs:queue` | LIST of envelopes (`LPUSH` by the app; the runner takes from the right) | app, runner (retry promotion) | `enqueue()` refuses when `LLEN` is 1000 or more |
| `<app>:jobs:processing` | LIST, in-flight envelopes | runner | at most the platform cap of 3 in flight plus items awaiting a dead-letter or move-back write |
| `<app>:jobs:delayed` | ZSET, score = due epoch seconds | runner | at most 1000 entries (overflow dead-letters) |
| `<app>:jobs:dead` | LIST of dead records | runner | trimmed to the newest 100 after every push |

Apps only write `<app>:jobs:queue`. The other three belong to the runner.

### Reserved key namespace

`<app>:jobs:*` is a **reserved key namespace** inside each app prefix. The runner's Redis user reaches `~*:jobs:*`,
and one glob cannot be narrower than that (Redis `*` also spans colons), so an app MUST NOT use any key matching
`<app>:jobs:*` for other data.

### Value size

The shared Redis rejects any single value above 1 MB (`--proto-max-bulk-len 1mb`) for every app. The envelope limit of
65536 bytes is the tighter one and is what `enqueue()` enforces.

## 2. The `/_jobs/<name>` handler

The runner calls `POST http://<app>:<port>/_jobs/<name>`. The app container joins the `platform` network with the
network alias `<app>` and listens on the `port` from `app.yaml` (the deploy step wires this). The call never goes
through Traefik, and the edge `jobs-deny` router returns 503 for any `/_jobs*` request, so the endpoint is private to
the `platform` network.

### Request

- Headers: `Authorization: Bearer <jobs-secret>`, `Content-Type: application/json`, `X-Platform-Run-Id: <run_id>`,
  `User-Agent: platform-jobs-runner/<version>`.
- Body:

  ```
  {"v":1,"run_id":"<ULID>","job":"<name>","trigger":"schedule|catch_up|queue","attempt":<int>,"scheduled_for":"<RFC3339 Z>|null","queue_id":"<id>|null","enqueued_at":"<RFC3339 Z>|null","payload":<JSON|null>}
  ```

  For a queued run `queue_id` is the envelope `id` and `payload` its payload; for a scheduled run both are `null`.
- The client deadline is the job's `timeout` from `app.yaml`. The runner reads at most 4096 bytes of the response
  body, and uses them as the error text on failure (masked, at most 300 characters).

### Handler rules

A handler MUST:

1. **Check the secret in constant time.** Compare `Authorization: Bearer <token>` with the contents of the file named
   by `JOBS_SECRET_FILE` (one trailing newline stripped) using a constant-time comparison. A mismatched or missing
   header returns **401**. The secret is read from the file, never from an argument or a log line.
2. **Return 404 for an undeclared job** (a `<name>` not in the app's declared jobs).
3. **Parse the body and require `v` equal to 1.** An unknown `v` or invalid body is a client error (400).
4. **Return 2xx only after the work is committed.** A 2xx tells the runner the job is done and will not be repeated.
5. **Be idempotent by `queue_id` (queued) or `run_id` (scheduled).** Delivery is at least once: a crash after the work
   but before the response, a timeout, or runner recovery after its own crash redelivers the same `queue_id`, so a
   duplicate MUST have a single effect (for example a unique-key record of the id written in the same transaction as
   the work).
6. **Never be routed through Traefik** and never be exposed on a public port.
7. **Trust no header other than the bearer token.** `X-Platform-Run-Id` and `User-Agent` are for logging only.

### Status-code meanings (outcome classes)

| Result | Meaning | Queued job | Scheduled job |
|---|---|---|---|
| `ok` | 2xx | done (removed from processing) | done |
| `retryable` | 408, 425, 429, 5xx, connect refused, DNS failure, timeout | re-queued with backoff until attempt 5, then dead | `failed` (`timeout` when the deadline passed), no retry (next fire) |
| `permanent` | any other 4xx (including 401, 403, 404), any 3xx, and any other status not listed (1xx, unknown) | dead immediately | `failed` |

Redirects are **never followed** (the 3xx response is taken as is), so the bearer token is never re-sent to a
`Location` target. An app that redirects `/_jobs` is misconfigured and its job is `permanent`. The rule fails closed: a
status outside the table is `permanent`, never `ok` or `retryable`.

Handlers should therefore answer 5xx or 429 for a temporary problem worth retrying, and a 4xx for a request that will
never succeed.

### Result mapping for queued attempts

Queued `ok` -> `ok`. Queued `retryable` -> `retry_scheduled` (the cause is in `error`, the HTTP status in
`http_status` or `-`), and `dead_lettered` on the last attempt (dead reason `retries_exhausted`). Queued `permanent`
-> `dead_lettered` (dead reason `permanent`). `failed`, `timeout` and `interrupted` are scheduled-only results. `interrupted` is a scheduled run cut off because the
runner itself was stopping (SIGTERM): it is recorded apart from `failed` and sends no alert.

### The `error` column is untrusted app text

The runner copies text the app returned into the `error` column of `runs-*.tsv` (masked, capped, tabs and newlines
turned into spaces). It is app-controlled, so any consumer of the history, such as the status page, MUST
HTML-escape it before rendering.

### Retries

`max_attempts` is 5 (the first call plus four retries). After attempt *n* (1-4) the next try waits `30s x 4^(n-1)`
(30s, 2m, 8m, 32m), with plus or minus 20% jitter, capped at 1h. Retries wait in `<app>:jobs:delayed`; when that set
already holds 1000 entries, the retry dead-letters with reason `overflow`.

## 3. Queue semantics

- **Order.** Items are taken in enqueue order per app. Completion order and retries may differ.
- **Head-of-line waiting (intentional).** A head that is in flight, or held by the backup-window rule, makes that
  app's later items wait. This preserves order. Other apps are never blocked by it, and waiting items are never
  dropped.
- **Backup window.** Items are not taken while the job's `timeout` would overlap `[START, END)` of the backup
  window. In-flight runs are never killed.
- **At least once.** Every job is delivered at least once; handlers must be idempotent (rule 5 above).
- **Platform cap.** At most 3 runs are in flight across all apps, and one run per (app, job) at a time.

## 4. Dead records

A job that cannot or will not run any more is pushed onto `<app>:jobs:dead` (the newest 100 are kept). Each record is
a JSON object:

| Field | Meaning |
|---|---|
| `v` | record version (1) |
| `envelope` | the raw item as a **string**, truncated to 4096 bytes; never embedded JSON |
| `truncated` | `true` when `envelope` was cut, or invalid UTF-8 in the original was replaced (the cut is on a character boundary) |
| `envelope_bytes` | the original size in bytes |
| `id` | the envelope id, when it could be read |
| `reason` | one of the values below |
| `attempts` | the attempt number that ended it (0 for `invalid_envelope` and `undeclared_job`, which never ran) |
| `last_error` | masked error text, at most 300 characters |
| `dead_at` | RFC3339 UTC |

`reason` is exactly one of `retries_exhausted`, `invalid_envelope`, `undeclared_job`, `overflow`, `permanent`:

- `permanent`: a queued attempt whose outcome class was `permanent`; the HTTP status is in `last_error` and
  `attempts` is the current attempt number (1 for a first-attempt failure).
- `retries_exhausted`: five failed attempts, and also crash recovery after five attempts (`last_error` tells which).
- `invalid_envelope`: an unknown `v`, a missing field (the `payload` key must be present, use `null`), invalid JSON
  or a non-object, an `id` that is not exactly 26 characters of `[0-9A-Za-z]`, a `job` not matching
  `^[a-z][a-z0-9_-]{0,62}$`, an `enqueued_at` that is not an RFC3339 string, an `attempt` that is present but not an
  integer of 1 or more, a `last_error` that is not a string, or an envelope over 65536 bytes.
- `undeclared_job`: the `job` is not declared in the app's registry entry.
- `overflow`: the delayed set was full.

Invalid, oversize or undeclared items are dead-lettered at once, without retries, including those found in
`<app>:jobs:processing` at runner start. They skip the cap, window and in-flight gate. This happens only for an app the
runner currently serves (a valid `app.yaml` with at least one declared job, a readable `jobs-secret`, and not parked);
otherwise items wait in the queue, consuming no attempt.

Crash recovery re-queues an item left in `processing` with its attempt number plus one, so a runner crash consumes an
attempt. The request body `attempt` is 1 to 5 for queued runs and always 1 for scheduled runs. A retry is promoted to
the head of the queue, so it runs before newer items.

The `jobs-secret` the runner reads is a regular file of 1 to 256 visible ASCII characters with one trailing newline
stripped; compare the file contents after stripping exactly one trailing newline and nothing else.

## 5. Conformance checklist

Every language helper (Go, Python, Node) ships tests for all of these:

- [ ] **Wrong secret** gives 401; a missing `Authorization` header gives 401.
- [ ] **Unknown job** gives 404.
- [ ] **Body with `v` other than 1** is rejected (no work done).
- [ ] **Duplicate `queue_id`** (the same request twice) has a single effect.
- [ ] **2xx only after commit:** a handler failure after partial work does not answer 2xx.
- [ ] **Constant-time comparison** is used for the secret (the helper's tests or review show it).
- [ ] **Oversize enqueue refused:** an envelope over 65536 bytes returns an error and writes nothing.
- [ ] **Full queue refused:** `LLEN` of 1000 or more returns an error and writes nothing.
- [ ] **Undeclared job refused** by `enqueue()` before touching Redis.
- [ ] **Redis errors surface:** `OOM` and `NOPERM` reach the caller.
- [ ] **Envelope shape:** `v`, ULID `id`, `job`, `payload` (or `null`) and RFC3339 UTC `enqueued_at`.
- [ ] **No key outside the app prefix** is written, and no `<app>:jobs:*` key other than `<app>:jobs:queue`.
