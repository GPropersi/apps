#!/usr/bin/env bash
# install-jobs.sh: install and check the jobs runner on the app host (run yourself, not Claude).
#
# The runner is one small Go daemon that fires every app's scheduled jobs and drains the Redis queue. It runs as the
# Compose project platform-jobs from /opt/platform/jobs on the existing `platform` Docker network, from an image built
# on the host (platform-jobs-runner:<source hash>). No port is published and no firewall rule is touched. The runner
# carries no platform.app label (it is platform infrastructure, so `platform ls` does not list it).
#
# Host-side inputs (you create them; the installer never writes a secret):
#   /etc/platform/jobs.env                 root:64324 0640, exactly one key: DISCORD_WEBHOOK=https://...
#   /etc/platform/jobs-redis.password      root:64324 0640, the runner's Redis password: one line (one trailing newline is
#                                          fine and exactly one is stripped everywhere), made of letters, digits and
#                                          . _ ~ + = / @ % ^ : , - only (it is handed to redis-cli on stdin)
#   the deploy user, the `platform` network, the healthy data stack (make host-data), the backup window directory
#   /opt/platform/backup with a valid window.env (make host-backup) and the job-secrets root (make host-data)
# The installer itself creates (as root, explicit owners and modes, never relying on umask):
#   /opt/platform/jobs                     root:root 0755: compose.yaml 0644, inputs.sha256 0600 (written after health)
#   /var/lib/platform/registry             deploy:deploy 0755 (the per-app registry the runner reads)
#   /var/lib/platform/jobs-status          65532:65532 0755 (the runner's status files)
#   /var/lib/platform/jobs-state           65532:65532 0700 (the runner's state)
#
# Two groups of payload files are embedded below (BEGIN-PAYLOAD/END-PAYLOAD) because the host has no checkout:
# `platform/lint/embed-payloads.sh` regenerates them from the tracked sources (`make embed`), and `make lint` fails if
# they differ. Group 1 is the runner (Go sources, go.mod, go.sum, Dockerfile, compose.yaml); group 2 is the test app
# (platform/jobs/testapp/*.go and Dockerfile.testapp). The runner image tag is a hash of group 1's build inputs (Go
# sources, go.mod, go.sum, Dockerfile; not compose.yaml, which `compose up` applies, and never the test app).
#
# Usage: install-jobs.sh [install|status|verify|testapp-up|testapp-down] [--host ALIAS]
#   install      checks every precondition first and reports all problems together; nothing is installed and no mutating
#                docker command runs until they all pass. The build network (builder image pull and `go mod download`) is
#                checked only when the runner image for the current source hash is absent. Then it builds the image when
#                absent (20 minute bound), applies the runner's Redis user when sha256(password) differs from the live
#                #<hash> token (rule on stdin, never argv; then ACL SAVE), creates the host dirs, places compose.yaml,
#                runs `compose up -d` (with --force-recreate when inputs.sha256 is absent or either input hash differs
#                from it), waits up to 90s for health and only then writes inputs.sha256 atomically. Idempotent: a second
#                run with unchanged inputs prints only "already:" lines.
#   status       report every check (PASS/FAIL/WARN), exit 0
#   verify       the same checks, exit 1 on any FAIL (a WARN never changes the status)
#   testapp-up   build the test app image, write /var/lib/platform/registry/jobstest/app.yaml and start the test app
#                container (label platform.app=jobstest, alias jobstest). Needs `platform new-db jobstest` done first.
#                Never run implicitly: install, status and verify never touch the test app.
#   testapp-down remove the test app container, its registry file and its image (the job secret and the Redis user are
#                left to the hand-run removal commands it prints)
#   --host       stream this script over one `ssh <alias> bash -s` call (BatchMode, no tty; passwordless sudo needed).
#
# Exit: 0 ok | 1 failed check, wrong state or unusable input | 2 usage error. ssh failures pass through ssh's status.
#
# Test overrides (env, test-only): INSTALL_JOBS_ROOT (path prefix for every default host path), INSTALL_JOBS_SUDO (the
# privilege prefix; "sudo -n" by default, none when already root), INSTALL_JOBS_HEALTH_TIMEOUT / INSTALL_JOBS_POLL /
# INSTALL_JOBS_BUILD_TIMEOUT / INSTALL_JOBS_NET_TIMEOUT (seconds), INSTALL_JOBS_NOW (epoch seconds), INSTALL_JOBS_NETWORK,
# INSTALL_JOBS_DISK_PATH, INSTALL_JOBS_MIN_FREE_KB, INSTALL_JOBS_PG_CONTAINER / INSTALL_JOBS_REDIS_CONTAINER /
# INSTALL_JOBS_RUNNER_CONTAINER / INSTALL_JOBS_TESTAPP_CONTAINER, INSTALL_JOBS_REDIS_CTR_ADMIN_FILE, and per-path
# overrides (absolute, not prefixed by the root): INSTALL_JOBS_DIR, INSTALL_JOBS_VAR_DIR, INSTALL_JOBS_REGISTRY_DIR,
# INSTALL_JOBS_JOB_SECRETS_ROOT, INSTALL_JOBS_STATUS_DIR, INSTALL_JOBS_STATE_DIR, INSTALL_JOBS_BACKUP_DIR,
# INSTALL_JOBS_ENV_FILE, INSTALL_JOBS_PW_FILE. INSTALL_JOBS_SOURCE_ONLY=1 makes the script define its functions and
# return (the tests source it). The docker, stat, getent, install, chown, df and chmod commands are the ones on PATH.
set -euo pipefail

export LC_ALL=C
# getent and friends live in /usr/sbin, which a non-root ssh user's PATH lacks
export PATH="$PATH:/usr/sbin:/sbin"

readonly JOBS_GID=64324
readonly RUNNER_UID=65532
readonly PROJECT="platform-jobs"
readonly RUNNER_IMAGE_REPO="platform-jobs-runner"
readonly TESTAPP_IMAGE_REPO="platform-jobs-testapp"
readonly TESTAPP_APP="jobstest"
# The declared jobs of the test app: the one list behind both the app.yaml it writes and the JOBS_DECLARED env var of
# its container (the registry directory is not mounted into the test app, so the env var carries them).
readonly TESTAPP_JOBS="ok-job always-fail"
NETWORK="${INSTALL_JOBS_NETWORK:-platform}"
[[ "$NETWORK" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { printf '%s\n' "INSTALL_JOBS_NETWORK must be a Docker network name (letters, digits, _ . -)" >&2; exit 2; }
readonly NETWORK
ROOT="${INSTALL_JOBS_ROOT:-}"
INSTALL_DIR="${INSTALL_JOBS_DIR:-$ROOT/opt/platform/jobs}"
VAR_DIR="${INSTALL_JOBS_VAR_DIR:-$ROOT/var/lib/platform}"
REGISTRY_DIR="${INSTALL_JOBS_REGISTRY_DIR:-$VAR_DIR/registry}"
JOB_SECRETS_DIR="${INSTALL_JOBS_JOB_SECRETS_ROOT:-$VAR_DIR/job-secrets}"
STATUS_DIR="${INSTALL_JOBS_STATUS_DIR:-$VAR_DIR/jobs-status}"
STATE_DIR="${INSTALL_JOBS_STATE_DIR:-$VAR_DIR/jobs-state}"
BACKUP_DIR="${INSTALL_JOBS_BACKUP_DIR:-$ROOT/opt/platform/backup}"
ENV_FILE="${INSTALL_JOBS_ENV_FILE:-$ROOT/etc/platform/jobs.env}"
PW_FILE="${INSTALL_JOBS_PW_FILE:-$ROOT/etc/platform/jobs-redis.password}"
REDIS_CTR_ADMIN_FILE="${INSTALL_JOBS_REDIS_CTR_ADMIN_FILE:-/etc/platform/redis-admin.password}"
PG="${INSTALL_JOBS_PG_CONTAINER:-platform-data-postgres}"
REDIS="${INSTALL_JOBS_REDIS_CONTAINER:-platform-data-redis}"
RUNNER="${INSTALL_JOBS_RUNNER_CONTAINER:-platform-jobs-runner}"
TESTAPP="${INSTALL_JOBS_TESTAPP_CONTAINER:-platform-jobs-testapp}"
HEALTH_TIMEOUT="${INSTALL_JOBS_HEALTH_TIMEOUT:-90}"
POLL="${INSTALL_JOBS_POLL:-2}"
BUILD_TIMEOUT="${INSTALL_JOBS_BUILD_TIMEOUT:-1200}"
NET_TIMEOUT="${INSTALL_JOBS_NET_TIMEOUT:-300}"
MIN_FREE_KB="${INSTALL_JOBS_MIN_FREE_KB:-1048576}"
RECORD="$INSTALL_DIR/inputs.sha256"
HEARTBEAT_MAX_AGE=120

if [ -n "${INSTALL_JOBS_SUDO+set}" ]; then
  read -r -a SUDO <<<"$INSTALL_JOBS_SUDO"
elif [ "$EUID" -eq 0 ]; then
  SUDO=()
else
  SUDO=(sudo -n)
fi

FAILURES=0
CHANGED=0
TMP=""
SECRET=""
RUNNER_TAG=""
TESTAPP_TAG=""
PW_HASH=""
ENV_HASH=""

info() { printf '%s\n' "$1"; }
err() { printf '%s\n' "$1" >&2; }
pass() { printf 'PASS: %s\n' "$1"; }
warn() { printf 'WARN: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
die() { err "install-jobs: $1"; exit "${2:-1}"; }

# shellcheck disable=SC2329,SC2317 # invoked through the EXIT trap
cleanup() {
  [ -z "$TMP" ] || rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

# priv <cmd...>: run with privilege; stdin is never forwarded (this script may itself be read from stdin).
priv() { "${SUDO[@]}" "$@" </dev/null; }
dk() { priv docker "$@"; }

require_privilege() {
  priv true || die "no usable privilege (sudo -n failed). Over --host the account needs passwordless sudo; otherwise copy this script to the host and run it there directly"
}

# ---- embedded payloads (regenerated by platform/lint/embed-payloads.sh; do not edit between the markers) ----
# Group 1: the runner. Group 2: the test app. Go file basenames are unique across both groups (function names come
# from basenames).

# BEGIN-PAYLOAD platform/jobs/go.mod
payload_go_mod() {
  cat <<'PLATFORM_PAYLOAD_EOF'
module github.com/gpropersi/apps/platform/jobs

go 1.26

toolchain go1.26.0

require (
	github.com/redis/go-redis/v9 v9.7.3
	gopkg.in/yaml.v3 v3.0.1
)

require (
	github.com/cespare/xxhash/v2 v2.2.0 // indirect
	github.com/dgryski/go-rendezvous v0.0.0-20200823014737-9f7001d12a5f // indirect
)
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/go.mod

# BEGIN-PAYLOAD platform/jobs/go.sum
payload_go_sum() {
  cat <<'PLATFORM_PAYLOAD_EOF'
github.com/cespare/xxhash/v2 v2.2.0 h1:DC2CZ1Ep5Y4k3ZQ899DldepgrayRUGE6BBZ/cd9Cj44=
github.com/cespare/xxhash/v2 v2.2.0/go.mod h1:VGX0DQ3Q6kWi7AoAeZDth3/j3BFtOZR5XLFGgcrjCOs=
github.com/dgryski/go-rendezvous v0.0.0-20200823014737-9f7001d12a5f h1:lO4WD4F/rVNCu3HqELle0jiPLLBs70cWOduZpkS1E78=
github.com/dgryski/go-rendezvous v0.0.0-20200823014737-9f7001d12a5f/go.mod h1:cuUVRXasLTGF7a8hSLbxyZXjz+1KgoB3wDUb6vlszIc=
github.com/redis/go-redis/v9 v9.7.3 h1:YpPyAayJV+XErNsatSElgRZZVCwXX9QzkKYNvO7x0wM=
github.com/redis/go-redis/v9 v9.7.3/go.mod h1:bGUrSggJ9X9GUmZpZNEOQKaANxSGgOEBRltRTZHSvrA=
gopkg.in/check.v1 v0.0.0-20161208181325-20d25e280405 h1:yhCVgyC4o1eVCa2tZl7eS0r+SDo693bJlVdllGtEeKM=
gopkg.in/check.v1 v0.0.0-20161208181325-20d25e280405/go.mod h1:Co6ibVJAznAaIkqp8huTwlJQCZ016jof/cbN4VW5Yz0=
gopkg.in/yaml.v3 v3.0.1 h1:fxVm/GzAzEWqLHuvctI91KS9hhNmmWOoWu0XTYJS7CA=
gopkg.in/yaml.v3 v3.0.1/go.mod h1:K4uyk7z7BCEPqu6E+C64Yfv1cQ7kz7rIZviUmN+EgEM=
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/go.sum

# BEGIN-PAYLOAD platform/jobs/Dockerfile
payload_Dockerfile() {
  cat <<'PLATFORM_PAYLOAD_EOF'
# Jobs runner image, built on the host by install-jobs.sh (tag: platform-jobs-runner:<source hash>).
# Both base images are pinned by multi-arch index digest, so the same pin resolves on amd64 CI and the arm64 Pi.
# The builder tag must equal platform/jobs/GO_VERSION (platform/jobs/test_jobs_stack.sh enforces it).
# The COPY list below is hand-kept and names every runner file; it never copies a directory, so nothing outside the
# runner can enter the build context or change the image hash. platform/host/test_jobs_image.sh builds from the
# embedded installer payload alone, which fails when a file is missing from this list or from the payload.
FROM golang:1.26.0@sha256:fb612b7831d53a89cbc0aaa7855b69ad7b0caf603715860cf538df854d047b84 AS build
ARG VERSION=dev
ENV GOTOOLCHAIN=local
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/runner/runner_healthcheck.go cmd/runner/runner_main.go ./cmd/runner/
COPY internal/clock/clock.go internal/clock/fake.go internal/clock/real.go ./internal/clock/
COPY internal/cron/cron.go ./internal/cron/
COPY internal/dispatch/dispatch.go ./internal/dispatch/
COPY internal/health/health.go ./internal/health/
COPY internal/history/atomic.go internal/history/history.go internal/history/status.go ./internal/history/
COPY internal/logx/logx.go ./internal/logx/
COPY internal/mask/mask.go ./internal/mask/
COPY internal/notify/discord.go internal/notify/env.go ./internal/notify/
COPY internal/queue/consumer.go internal/queue/envelope.go internal/queue/recover.go internal/queue/redisstate.go internal/queue/redisstore.go internal/queue/store.go internal/queue/take.go internal/queue/writes.go ./internal/queue/
COPY internal/registry/registry.go internal/registry/reserved-names.txt ./internal/registry/
COPY internal/sched/queue.go internal/sched/sched.go ./internal/sched/
COPY internal/window/window.go ./internal/window/
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /runner ./cmd/runner

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /runner /runner
USER 65532:65532
ENTRYPOINT ["/runner"]
CMD ["runner"]
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/Dockerfile

# BEGIN-PAYLOAD platform/jobs/compose.yaml
payload_compose_yaml() {
  cat <<'PLATFORM_PAYLOAD_EOF'
# Jobs runner: one small Go daemon that fires every app's scheduled jobs and drains the Redis queue, on the
# `platform` network only. It publishes nothing and carries no `platform.app` label (it is platform infrastructure,
# not an app, so `platform ls` does not list it).
#
# Host-side inputs (never written here, validated by install-jobs.sh): /etc/platform/jobs.env and
# /etc/platform/jobs-redis.password (root:64324 0640, read through group_add 64324), the registry and job-secrets
# roots, and the backup window directory. The image platform-jobs-runner:<source hash> is built on the host by
# install-jobs.sh; RUNNER_TAG carries that hash and pull_policy never keeps compose from looking for a registry copy.
#
# Rules this file keeps (platform/jobs/test_jobs_stack.sh enforces them):
# - It stays inside the small YAML subset (block style only) so the tests can read it without a YAML library.
# - Nothing in `environment:` is secret; every secret is a mounted file. GOMEMLIMIT is about 75% of mem_limit so the Go
#   GC works inside the container limit.
# - The window directory /opt/platform/backup is mounted as a directory, never the single file window.env:
#   install-backup.sh replaces window.env by temp file + rename, and a single-file bind mount would keep the old inode.
# - stop_grace_period 65m is above the longest job timeout (1h, the registry maximum): on SIGTERM the runner waits for
#   in-flight runs, and docker must not SIGKILL it after its default 10s. A stop can therefore take up to 65 minutes.
# - Registry, job secrets and the backup directory are read-only; only jobs-status and jobs-state are writable.
name: platform-jobs

services:
  runner:
    image: platform-jobs-runner:${RUNNER_TAG:?RUNNER_TAG must be set}
    pull_policy: never
    container_name: platform-jobs-runner
    environment:
      GOMEMLIMIT: 36MiB
    volumes:
      - /var/lib/platform/registry:/var/lib/platform/registry:ro
      - /var/lib/platform/job-secrets:/var/lib/platform/job-secrets:ro
      - /opt/platform/backup:/opt/platform/backup:ro
      - /etc/platform/jobs.env:/etc/platform/jobs.env:ro
      - /etc/platform/jobs-redis.password:/etc/platform/jobs-redis.password:ro
      - /var/lib/platform/jobs-status:/var/lib/platform/jobs-status
      - /var/lib/platform/jobs-state:/var/lib/platform/jobs-state
    tmpfs:
      - /tmp
    user: "65532:65532"
    group_add:
      - "64324"
    networks:
      - platform
    restart: unless-stopped
    stop_grace_period: 65m
    mem_limit: 48m
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    read_only: true
    healthcheck:
      test:
        - CMD
        - /runner
        - healthcheck
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

networks:
  platform:
    external: true
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/compose.yaml

# BEGIN-PAYLOAD platform/jobs/cmd/runner/runner_main.go
payload_runner_main_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
// Command runner is the platform jobs runner. Mode "runner" (the default) schedules the declared jobs and consumes
// the per-app Redis queues; mode "healthcheck" exits 0 only when runner.tsv has a fresh heartbeat.
package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/dispatch"
	"github.com/gpropersi/apps/platform/jobs/internal/history"
	"github.com/gpropersi/apps/platform/jobs/internal/logx"
	"github.com/gpropersi/apps/platform/jobs/internal/notify"
	"github.com/gpropersi/apps/platform/jobs/internal/queue"
	"github.com/gpropersi/apps/platform/jobs/internal/sched"
)

// The queue consumer collapses run alerts only when its Notifier is an Alerter (a runtime type assertion), so pin it.
var _ queue.Alerter = (*notify.Discord)(nil)

// version is set with -ldflags "-X main.version=...".
var version = "dev"

// Environment variable names that override a path or address (none holds a secret).
const (
	envJobsEnv      = "JOBS_ENV_FILE"
	envPasswordFile = "JOBS_REDIS_PASSWORD_FILE"
	envRegistry     = "JOBS_REGISTRY_DIR"
	envSecrets      = "JOBS_SECRETS_DIR"
	envWindowDir    = "JOBS_WINDOW_DIR"
	envStatusDir    = "JOBS_STATUS_DIR"
	envStateDir     = "JOBS_STATE_DIR"
	envRedisAddr    = "JOBS_REDIS_ADDR"
)

// config holds every path and address the runner uses.
type config struct {
	JobsEnv      string
	PasswordFile string
	Registry     string
	Secrets      string
	WindowDir    string
	StatusDir    string
	StateDir     string
	RedisAddr    string
}

// loadConfig returns the production defaults, each overridable by its environment variable.
func loadConfig(getenv func(string) string) config {
	pick := func(name, def string) string {
		if v := getenv(name); v != "" {
			return v
		}
		return def
	}
	return config{
		JobsEnv:      pick(envJobsEnv, "/etc/platform/jobs.env"),
		PasswordFile: pick(envPasswordFile, "/etc/platform/jobs-redis.password"),
		Registry:     pick(envRegistry, "/var/lib/platform/registry"),
		Secrets:      pick(envSecrets, "/var/lib/platform/job-secrets"),
		WindowDir:    pick(envWindowDir, "/opt/platform/backup"),
		StatusDir:    pick(envStatusDir, "/var/lib/platform/jobs-status"),
		StateDir:     pick(envStateDir, "/var/lib/platform/jobs-state"),
		RedisAddr:    pick(envRedisAddr, queue.RedisAddr),
	}
}

func (c config) windowPath() string { return filepath.Join(c.WindowDir, "window.env") }
func (c config) runnerTSV() string  { return filepath.Join(c.StatusDir, "runner.tsv") }

// inputs are the two start-time secrets; their values are never logged.
type inputs struct {
	webhook  string
	password string
}

// loadInputs reads jobs.env and the Redis password. Errors never include a value.
func loadInputs(c config) (inputs, error) {
	hook, err := notify.LoadEnv(c.JobsEnv)
	if err != nil {
		return inputs{}, err
	}
	pw, err := queue.ReadPassword(c.PasswordFile)
	if err != nil {
		return inputs{}, err
	}
	return inputs{webhook: hook, password: pw}, nil
}

// dispatchMode maps the arguments to a mode: no argument is the runner; an unknown one is "" (exit 2).
func dispatchMode(args []string) string {
	if len(args) == 0 {
		return "runner"
	}
	switch args[0] {
	case "runner", "healthcheck":
		return args[0]
	}
	return ""
}

func main() {
	os.Exit(run(os.Args[1:], os.Getenv, os.Stdout, os.Stderr))
}

// run is main without the process exit, so the argument dispatch is testable.
func run(args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	mode := dispatchMode(args)
	cfg := loadConfig(getenv)
	switch mode {
	case "healthcheck":
		return runHealthcheck(cfg, clock.Real{}, stderr)
	case "runner":
		ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
		defer stop()
		return runRunner(ctx, cfg, stdout)
	}
	fmt.Fprintf(stderr, "usage: runner [runner|healthcheck]\n")
	return 2
}

// runRunner wires the runner and blocks until ctx ends. It returns the process exit code.
func runRunner(ctx context.Context, cfg config, stdout io.Writer) int {
	clk := clock.Real{}
	log := logx.New(stdout, clk)
	log.Printf("runner starting version=%s", version)

	in, err := loadInputs(cfg)
	if err != nil {
		log.Printf("runner refusing to start: %s", err.Error())
		return 1
	}
	hist, err := history.NewWriter(cfg.StatusDir)
	if err != nil {
		log.Printf("runner refusing to start: status dir: %s", err.Error())
		return 1
	}
	status := history.NewStatus(clk, cfg.runnerTSV(), version, log)
	discord := notify.New(clk, log, in.webhook, nil)
	disp := dispatch.New(clk, cfg.Secrets, version)

	scheduler := sched.New(sched.Config{
		Clock: clk, RegistryRoot: cfg.Registry, WindowPath: cfg.windowPath(), StateDir: cfg.StateDir,
		Caller: disp, History: hist, Status: status, Notifier: discord, Log: log,
	})
	store := queue.NewRedisStore(cfg.RedisAddr, queue.RedisUser, in.password, queue.CommandTimeout)
	consumer := queue.New(queue.Config{
		Clock: clk, Store: store, Caller: disp, Registry: scheduler.QueueRegistry(),
		SecretsDir: cfg.Secrets, Status: status, Notifier: discord, Log: log,
	})

	return supervise(ctx, log, []component{
		{name: "notify", run: discord.Run, last: true},
		{name: "status", run: status.Run},
		{name: "scheduler", run: scheduler.Run},
		{name: "queue", run: consumer.Run},
	}, fmt.Sprintf("runner started redis=%s", cfg.RedisAddr))
}

// component is one long-running part of the runner. A last component stops after all the others have stopped.
type component struct {
	name string
	run  func(context.Context)
	last bool
}

// supervise runs the components until ctx ends and returns the process exit code. Any component returning before
// shutdown was asked for is a fault: cancel everything and exit non-zero, so the restart policy brings the runner
// back instead of leaving it up half-dead. The table is a parameter so the fault path is testable.
func supervise(ctx context.Context, log *logx.Logger, comps []component, startedMsg string) int {
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	var early atomic.Bool
	// The alert sink stops last (its own context), so alerts raised by runs that finish during shutdown are sent.
	notifyCtx, stopNotify := context.WithCancel(context.Background())
	defer stopNotify()

	var wg, notifyWG sync.WaitGroup
	for _, comp := range comps {
		group, c := &wg, runCtx
		if comp.last {
			group, c = &notifyWG, notifyCtx
		}
		group.Add(1)
		go func() {
			defer group.Done()
			comp.run(c)
			if c.Err() == nil {
				early.Store(true)
				log.Printf("runner %s exited before shutdown: stopping the runner", comp.name)
				cancel()
				return
			}
			log.Printf("runner %s stopped", comp.name)
		}()
	}
	log.Printf("%s", startedMsg)
	<-runCtx.Done()
	log.Printf("runner stopping: waiting for in-flight runs")
	wg.Wait()
	stopNotify()
	notifyWG.Wait()
	if early.Load() {
		log.Printf("runner stopped with a component fault")
		return 1
	}
	log.Printf("runner stopped")
	return 0
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/cmd/runner/runner_main.go

# BEGIN-PAYLOAD platform/jobs/cmd/runner/runner_healthcheck.go
payload_runner_healthcheck_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
package main

import (
	"fmt"
	"io"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/health"
)

// runHealthcheck returns 0 only when runner.tsv has a fresh heartbeat; the reason goes to stderr.
func runHealthcheck(cfg config, clk clock.Clock, stderr io.Writer) int {
	if err := health.Check(clk, cfg.runnerTSV()); err != nil {
		fmt.Fprintf(stderr, "unhealthy: %s\n", err.Error())
		return 1
	}
	return 0
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/cmd/runner/runner_healthcheck.go

# BEGIN-PAYLOAD platform/jobs/internal/health/health.go
payload_health_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
// Package health is the runner's container healthcheck: runner.tsv must hold one well-formed line whose
// heartbeat_at is fresh.
package health

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
)

// MaxAge is the oldest heartbeat that still counts as healthy.
const MaxAge = 60 * time.Second

// maxFileBytes bounds the read; a runner.tsv line is far below this.
const maxFileBytes = 4096

// Check returns nil only when the file at path holds exactly one line of exactly six tab-separated fields and its
// heartbeat_at (field 2, RFC3339 UTC with Z) is less than MaxAge old by clk and not in the future. Fail closed: every
// other case is an error naming the reason.
func Check(clk clock.Clock, path string) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read runner.tsv: %w", err)
	}
	if len(b) == 0 || len(b) > maxFileBytes {
		return errors.New("runner.tsv is empty or too large")
	}
	line := strings.TrimSuffix(string(b), "\n")
	if strings.Contains(line, "\n") {
		return errors.New("runner.tsv has more than one line")
	}
	fields := strings.Split(line, "\t")
	if len(fields) != 6 {
		return fmt.Errorf("runner.tsv has %d fields, want 6", len(fields))
	}
	if !strings.HasSuffix(fields[1], "Z") {
		return errors.New("heartbeat_at is not UTC (Z)")
	}
	hb, err := time.Parse(time.RFC3339, fields[1])
	if err != nil {
		return errors.New("heartbeat_at is not RFC3339")
	}
	age := clk.Now().Sub(hb)
	if age < 0 {
		return fmt.Errorf("heartbeat_at is in the future by %s", -age)
	}
	if age >= MaxAge {
		return fmt.Errorf("heartbeat_at is %s old, limit %s", age.Truncate(time.Second), MaxAge)
	}
	return nil
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/health/health.go

# BEGIN-PAYLOAD platform/jobs/internal/clock/clock.go
payload_clock_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
// Package clock is the one place the runner touches wall-clock time, timers and randomness.
//
// Every other package takes a Clock (and a Jitter) so tests advance time deterministically and never sleep.
// TestNoDirectTimeUse fails when a non-test file outside real.go calls time.Now, time.After, time.NewTicker,
// time.Sleep, time.Tick, time.NewTimer, time.AfterFunc or a random source directly.
package clock

import "time"

// Clock covers reads and timers.
type Clock interface {
	// Now returns the current time.
	Now() time.Time
	// After returns a channel that receives once, after d.
	After(d time.Duration) <-chan time.Time
	// NewTicker returns a repeating ticker with period d (d must be > 0).
	NewTicker(d time.Duration) Ticker
}

// Ticker is a stoppable repeating channel. After Stop returns, the ticker never fires again.
type Ticker interface {
	C() <-chan time.Time
	Stop()
}

// Jitter returns a factor in [-0.2, +0.2] to scale a delay by (delay * (1 + factor)).
type Jitter func() float64

// MaxJitter is the largest magnitude a Jitter may return.
const MaxJitter = 0.2

// FixedJitter returns a Jitter that always returns f (tests).
func FixedJitter(f float64) Jitter {
	return func() float64 { return f }
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/clock/clock.go

# BEGIN-PAYLOAD platform/jobs/internal/clock/fake.go
payload_fake_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
package clock

import (
	"sort"
	"sync"
	"time"
)

// tickerBuffer is the fake ticker's channel capacity, so a test that advances several periods at once can
// read every tick (a real ticker would drop them for a slow reader).
const tickerBuffer = 1024

// Fake is a deterministic Clock for tests. Time moves only on Advance; timers fire in deadline order (ties by
// creation order), never early, and a stopped ticker never fires again.
type Fake struct {
	mu     sync.Mutex
	now    time.Time
	seq    int
	timers []*fakeTimer
	// onFire, when set, is called (under no lock) for every fire, in order. Tests of this package use it.
	onFire func(seq int, deadline time.Time)
}

type fakeTimer struct {
	seq      int
	deadline time.Time
	period   time.Duration // 0 for a one-shot
	ch       chan time.Time
	stopped  bool
}

// NewFake returns a Fake whose Now() is start.
func NewFake(start time.Time) *Fake {
	return &Fake{now: start}
}

// Now returns the fake time.
func (f *Fake) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now
}

// After returns a channel that receives once the fake time reaches now+d. d <= 0 fires immediately.
func (f *Fake) After(d time.Duration) <-chan time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	ch := make(chan time.Time, 1)
	if d <= 0 {
		ch <- f.now
		return ch
	}
	f.seq++
	f.timers = append(f.timers, &fakeTimer{seq: f.seq, deadline: f.now.Add(d), ch: ch})
	return ch
}

// NewTicker returns a ticker that fires once per elapsed period of fake time. It panics when d <= 0, like
// time.NewTicker.
func (f *Fake) NewTicker(d time.Duration) Ticker {
	if d <= 0 {
		panic("clock: non-positive interval for NewTicker")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.seq++
	t := &fakeTimer{seq: f.seq, deadline: f.now.Add(d), period: d, ch: make(chan time.Time, tickerBuffer)}
	f.timers = append(f.timers, t)
	return &fakeTicker{f: f, t: t}
}

// Jump moves the fake wall clock by d without firing any timer, like an NTP step or a resume from suspend: real
// timers run on the monotonic clock and do not notice. The next Advance fires the timers that are now overdue.
func (f *Fake) Jump(d time.Duration) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.now = f.now.Add(d)
}

// Pending returns the number of armed timers and tickers (tests use it to wait for a goroutine to arm one).
func (f *Fake) Pending() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, t := range f.timers {
		if !t.stopped {
			n++
		}
	}
	return n
}

// Advance moves the fake time forward by d, firing every timer whose deadline falls in (now, now+d] in
// deadline order. Now() reads the timer's deadline while it fires and now+d afterwards.
func (f *Fake) Advance(d time.Duration) {
	if d < 0 {
		panic("clock: negative Advance")
	}
	f.mu.Lock()
	target := f.now.Add(d)
	f.mu.Unlock()
	for {
		f.mu.Lock()
		t := f.nextDue(target)
		if t == nil {
			if target.After(f.now) { // never move time backwards under a concurrent Advance
				f.now = target
			}
			f.mu.Unlock()
			return
		}
		if t.deadline.After(f.now) {
			f.now = t.deadline
		}
		fired := t.deadline
		seq := t.seq
		select {
		case t.ch <- fired:
		default: // a full ticker buffer drops the tick, like a real ticker
		}
		if t.period > 0 {
			t.deadline = t.deadline.Add(t.period)
		} else {
			t.stopped = true
		}
		f.prune()
		hook := f.onFire
		f.mu.Unlock()
		if hook != nil {
			hook(seq, fired)
		}
	}
}

// nextDue returns the live timer with the earliest deadline <= target (lowest seq on a tie), or nil.
// The caller holds f.mu.
func (f *Fake) nextDue(target time.Time) *fakeTimer {
	live := make([]*fakeTimer, 0, len(f.timers))
	for _, t := range f.timers {
		if !t.stopped && !t.deadline.After(target) {
			live = append(live, t)
		}
	}
	if len(live) == 0 {
		return nil
	}
	sort.Slice(live, func(i, j int) bool {
		if live[i].deadline.Equal(live[j].deadline) {
			return live[i].seq < live[j].seq
		}
		return live[i].deadline.Before(live[j].deadline)
	})
	return live[0]
}

// prune drops stopped timers. The caller holds f.mu.
func (f *Fake) prune() {
	kept := f.timers[:0]
	for _, t := range f.timers {
		if !t.stopped {
			kept = append(kept, t)
		}
	}
	f.timers = kept
}

type fakeTicker struct {
	f *Fake
	t *fakeTimer
}

func (k *fakeTicker) C() <-chan time.Time { return k.t.ch }

func (k *fakeTicker) Stop() {
	k.f.mu.Lock()
	defer k.f.mu.Unlock()
	k.t.stopped = true
	for drained := false; !drained; { // like Go 1.23 tickers: no stale tick is readable after Stop
		select {
		case <-k.t.ch:
		default:
			drained = true
		}
	}
	k.f.prune()
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/clock/fake.go

# BEGIN-PAYLOAD platform/jobs/internal/clock/real.go
payload_real_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
package clock

import (
	crand "crypto/rand"
	"math/rand/v2"
	"time"
)

const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// NewULID returns a 26-character ULID: a 48-bit millisecond timestamp followed by 80 random bits, in Crockford
// base32. It lives here because only this file may touch a random source.
func NewULID(now time.Time) string {
	var b [16]byte
	ms := uint64(now.UnixMilli())
	for i := 0; i < 6; i++ {
		b[i] = byte(ms >> (8 * uint(5-i)))
	}
	_, _ = crand.Read(b[6:])
	var out [26]byte
	for i := range out {
		var v byte
		for k := 0; k < 5; k++ {
			bit := i*5 + k - 2 // 130 bits: two zero bits in front of the 128
			v <<= 1
			if bit >= 0 {
				v |= (b[bit/8] >> (7 - uint(bit%8))) & 1
			}
		}
		out[i] = crockford[v]
	}
	return string(out[:])
}

// Real is the production Clock, backed by the time package.
type Real struct{}

// Now returns the current wall-clock time. Round(0) strips the monotonic reading, so the difference of two Now
// values is a wall-clock difference and an NTP step or a resume from suspend is visible to the scheduler.
func (Real) Now() time.Time { return time.Now().Round(0) }

// After wraps time.After.
func (Real) After(d time.Duration) <-chan time.Time { return time.After(d) }

// NewTicker wraps time.NewTicker.
func (Real) NewTicker(d time.Duration) Ticker { return realTicker{t: time.NewTicker(d)} }

type realTicker struct{ t *time.Ticker }

func (r realTicker) C() <-chan time.Time { return r.t.C }
func (r realTicker) Stop()               { r.t.Stop() }

// RandomJitter is the production Jitter: uniform in [-MaxJitter, +MaxJitter).
func RandomJitter() float64 {
	return (rand.Float64()*2 - 1) * MaxJitter
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/clock/real.go

# BEGIN-PAYLOAD platform/jobs/internal/cron/cron.go
payload_cron_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
// Package cron parses and matches the platform's 5-field cron schedules.
//
// The grammar is the one platform/registry/validate-app-yaml.sh accepts (shared fixture
// platform/registry/cron-cases.table): a comma list of items, each "*", N or N-M with an optional /step;
// numbers without leading zeros; N <= M; a step (>= 1, at most the field's max minus min) only after "*" or a
// range. Matching follows Vixie cron: day-of-week 0-7 (0 and 7 are Sunday) and, when both day-of-month and
// day-of-week are restricted (neither field starts with "*"), a day matches if either matches.
package cron

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type fieldSpec struct {
	name   string
	lo, hi int
}

var fieldSpecs = [5]fieldSpec{
	{"minute", 0, 59},
	{"hour", 0, 23},
	{"day-of-month", 1, 31},
	{"month", 1, 12},
	{"day-of-week", 0, 7},
}

const (
	cronNum = `(0|[1-9][0-9]{0,5})`
	// item = ("*" | N | N-M) with an optional /step, exactly validate-app-yaml.sh's CRON_ITEM.
	cronItem = `(\*|` + cronNum + `(-` + cronNum + `)?)(/` + cronNum + `)?`
)

var itemRE = regexp.MustCompile(`^` + cronItem + `$`)

// maxSearchDays bounds Next: 8 years covers a "0 0 29 2 *" schedule across a non-leap century gap.
const maxSearchDays = 366 * 8

// Schedule is a parsed cron expression.
type Schedule struct {
	expr    string
	minutes [60]bool
	hours   [24]bool
	doms    [32]bool // index 1-31
	months  [13]bool // index 1-12
	dows    [7]bool  // 0 = Sunday (7 folded in)
	domStar bool
	dowStar bool
}

// String returns the expression the schedule was parsed from.
func (s *Schedule) String() string { return s.expr }

// Parse parses a 5-field expression. Fields are separated by whitespace. Any defect is an error.
func Parse(expr string) (*Schedule, error) {
	// ASCII blanks only, like bash `read -a` (strings.Fields would also split on Unicode spaces).
	fields := strings.FieldsFunc(expr, func(r rune) bool { return r == ' ' || r == '\t' || r == '\n' })
	if len(fields) != 5 {
		// Report a bad field shape first, like the bash validator, then the count.
		for i, f := range fields {
			if i < 5 {
				if _, err := parseField(i, f); err != nil {
					return nil, err
				}
			}
		}
		return nil, fmt.Errorf("schedule must have exactly 5 fields, got %d", len(fields))
	}
	s := &Schedule{expr: expr}
	for i, f := range fields {
		vals, err := parseField(i, f)
		if err != nil {
			return nil, err
		}
		for _, v := range vals {
			switch i {
			case 0:
				s.minutes[v] = true
			case 1:
				s.hours[v] = true
			case 2:
				s.doms[v] = true
			case 3:
				s.months[v] = true
			case 4:
				s.dows[v%7] = true
			}
		}
	}
	s.domStar = strings.HasPrefix(fields[2], "*")
	s.dowStar = strings.HasPrefix(fields[4], "*")
	return s, nil
}

// parseField returns the values (not yet folded: day-of-week may contain 7) a field selects.
func parseField(idx int, field string) ([]int, error) {
	spec := fieldSpecs[idx]
	bad := func(format string, a ...any) ([]int, error) {
		return nil, fmt.Errorf("%s field %q %s", spec.name, field, fmt.Sprintf(format, a...))
	}
	var out []int
	for _, item := range strings.Split(field, ",") {
		if !itemRE.MatchString(item) {
			return bad("is not a cron field")
		}
		base, stepStr, hasStep := strings.Cut(item, "/")
		lo, hi := spec.lo, spec.hi
		switch {
		case base == "*":
			// whole field
		case strings.Contains(base, "-"):
			as, bs, _ := strings.Cut(base, "-")
			a, _ := strconv.Atoi(as)
			b, _ := strconv.Atoi(bs)
			if a < spec.lo || a > spec.hi || b < spec.lo || b > spec.hi {
				return bad("is out of range (must be %d-%d)", spec.lo, spec.hi)
			}
			if a > b {
				return bad("has a reversed range %q", base)
			}
			lo, hi = a, b
		default:
			if hasStep {
				return bad("has a step %q on a single number", "/"+stepStr)
			}
			n, _ := strconv.Atoi(base)
			if n < spec.lo || n > spec.hi {
				return bad("is out of range (must be %d-%d)", spec.lo, spec.hi)
			}
			lo, hi = n, n
		}
		step := 1
		if hasStep {
			n, _ := strconv.Atoi(stepStr)
			if n < 1 {
				return bad("has a step of zero")
			}
			if n > spec.hi-spec.lo {
				return bad("has a step %q larger than the range %d-%d", "/"+stepStr, spec.lo, spec.hi)
			}
			step = n
		}
		for v := lo; v <= hi; v += step {
			out = append(out, v)
		}
	}
	return out, nil
}

// dayMatches applies the Vixie day rule to a civil date.
func (s *Schedule) dayMatches(month time.Month, day int, wd time.Weekday) bool {
	if !s.months[int(month)] {
		return false
	}
	domOK := s.doms[day]
	dowOK := s.dows[int(wd)]
	if s.domStar || s.dowStar {
		return domOK && dowOK
	}
	return domOK || dowOK
}

// instants returns the earliest real instant whose wall clock in loc reads the given civil time, and false
// when the wall time does not exist (spring-forward gap). A repeated wall time (autumn fall-back) resolves
// to the first occurrence.
func instants(year int, month time.Month, day, hour, minute int, loc *time.Location) (time.Time, bool) {
	civil := time.Date(year, month, day, hour, minute, 0, 0, time.UTC)
	var best time.Time
	found := false
	seen := map[int]bool{}
	for _, probe := range []time.Duration{-36 * time.Hour, 36 * time.Hour} {
		_, off := civil.Add(probe).In(loc).Zone()
		if seen[off] {
			continue
		}
		seen[off] = true
		cand := civil.Add(-time.Duration(off) * time.Second)
		l := cand.In(loc)
		if l.Year() != year || l.Month() != month || l.Day() != day || l.Hour() != hour || l.Minute() != minute {
			continue
		}
		if !found || cand.Before(best) {
			best, found = cand, true
		}
	}
	return best, found
}

// Next returns the first fire instant strictly after `after`, evaluated in loc, at second 0 of the cron
// minute (the runner adds its per-job offset itself). It returns the zero Time when no fire exists within
// eight years. A time in a spring-forward gap does not fire that day; a repeated autumn time fires once, at
// the first occurrence.
func (s *Schedule) Next(after time.Time, loc *time.Location) time.Time {
	local := after.In(loc)
	day := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, time.UTC)
	for i := 0; i <= maxSearchDays; i, day = i+1, day.AddDate(0, 0, 1) {
		y, m, d := day.Date()
		if !s.dayMatches(m, d, day.Weekday()) {
			continue
		}
		for h := 0; h < 24; h++ {
			if !s.hours[h] {
				continue
			}
			for mi := 0; mi < 60; mi++ {
				if !s.minutes[mi] {
					continue
				}
				t, ok := instants(y, m, d, h, mi, loc)
				if ok && t.After(after) {
					return t.In(loc)
				}
			}
		}
	}
	return time.Time{}
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/cron/cron.go

# BEGIN-PAYLOAD platform/jobs/internal/dispatch/dispatch.go
payload_dispatch_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
// Package dispatch makes the one HTTP call that runs a job: POST http://<app>:<port>/_jobs/<name> with the app's
// bearer secret, a deadline equal to the job's timeout and no redirect following. It classifies the response into
// the outcome classes of the jobs-runner contract.
//
// The secret is read from <secrets>/<app>/jobs-secret on every call and never logged; the error text it returns
// is the masked first 300 characters of the response body or of the transport error.
package dispatch

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/mask"
)

const (
	// maxBodyBytes is how much of a response body is read for the error text.
	maxBodyBytes = 4096
	// maxSecretBytes bounds the secret file; a real secret is 40 characters.
	maxSecretBytes = 256
)

// Class is the outcome class of one call.
type Class int

const (
	// ClassPermanent is the zero value on purpose: anything not proven ok or retryable fails closed.
	ClassPermanent Class = iota
	// ClassOK is a 2xx response.
	ClassOK
	// ClassRetryable is 408, 425, 429, 5xx, a refused connection, a DNS failure or a timeout.
	ClassRetryable
)

// String returns the contract name of the class.
func (c Class) String() string {
	switch c {
	case ClassOK:
		return "ok"
	case ClassRetryable:
		return "retryable"
	default:
		return "permanent"
	}
}

// Request is one call to an app.
type Request struct {
	App          string
	Port         int
	Job          string
	Timeout      time.Duration
	RunID        string
	Trigger      string // schedule | catch_up | queue
	Attempt      int
	ScheduledFor time.Time       // zero for a queued run
	QueueID      string          // "" for a scheduled run
	EnqueuedAt   time.Time       // zero for a scheduled run
	Payload      json.RawMessage // nil or empty means null
}

// Result is the outcome of one call.
type Result struct {
	Class      Class
	Timeout    bool   // the per-job deadline expired and the request was cancelled
	NoSecret   bool   // the secret file is missing or unusable; no request was made
	HTTPStatus int    // 0 when there was no response
	Err        string // masked, at most 300 characters; "" for ok
}

// Dispatcher calls apps.
type Dispatcher struct {
	Clock      clock.Clock
	SecretsDir string
	Version    string
	// Client is used for every call. New sets CheckRedirect so a 3xx is returned as is.
	Client *http.Client
	// URL builds the target; the default is http://<app>:<port>/_jobs/<job>. Tests point it at an httptest server.
	URL func(app string, port int, job string) string
}

// New returns a Dispatcher with the production URL scheme and a client that never follows redirects.
func New(clk clock.Clock, secretsDir, version string) *Dispatcher {
	return &Dispatcher{
		Clock:      clk,
		SecretsDir: secretsDir,
		Version:    version,
		Client: &http.Client{
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
		URL: func(app string, port int, job string) string {
			return "http://" + app + ":" + strconv.Itoa(port) + "/_jobs/" + job
		},
	}
}

type body struct {
	V            int             `json:"v"`
	RunID        string          `json:"run_id"`
	Job          string          `json:"job"`
	Trigger      string          `json:"trigger"`
	Attempt      int             `json:"attempt"`
	ScheduledFor *string         `json:"scheduled_for"`
	QueueID      *string         `json:"queue_id"`
	EnqueuedAt   *string         `json:"enqueued_at"`
	Payload      json.RawMessage `json:"payload"`
}

func optTime(t time.Time) *string {
	if t.IsZero() {
		return nil
	}
	s := t.UTC().Format(time.RFC3339)
	return &s
}

// ReadSecret reads <dir>/<app>/jobs-secret, stripping one trailing newline. It reports false when the file is
// missing, unreadable, empty, too long or holds anything but visible ASCII (which could not be a header value).
func ReadSecret(dir, app string) (string, bool) {
	if app == "" || strings.ContainsAny(app, `/\`) || app == "." || app == ".." {
		return "", false
	}
	path := filepath.Join(dir, app, "jobs-secret")
	// Lstat first: a symlink, FIFO, device or directory is refused without being opened, so a hostile entry can
	// neither block the read nor redirect it.
	if fi, err := os.Lstat(path); err != nil || !fi.Mode().IsRegular() {
		return "", false
	}
	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxSecretBytes+1))
	if err != nil || len(b) > maxSecretBytes {
		return "", false
	}
	s := strings.TrimSuffix(string(b), "\n")
	if s == "" {
		return "", false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x21 || s[i] > 0x7e {
			return "", false
		}
	}
	return s, true
}

// Call runs one request. The timeout is enforced with Clock.After, so a test with a fake clock cancels the
// request by advancing time.
func (d *Dispatcher) Call(parent context.Context, r Request) Result {
	secret, ok := ReadSecret(d.SecretsDir, r.App)
	if !ok {
		return Result{NoSecret: true, Err: "jobs-secret is missing or unusable"}
	}
	payload := r.Payload
	if len(payload) == 0 {
		payload = json.RawMessage("null")
	}
	buf, err := json.Marshal(body{
		V: 1, RunID: r.RunID, Job: r.Job, Trigger: r.Trigger, Attempt: r.Attempt,
		ScheduledFor: optTime(r.ScheduledFor), QueueID: strPtr(r.QueueID), EnqueuedAt: optTime(r.EnqueuedAt),
		Payload: payload,
	})
	if err != nil { // an invalid payload cannot be fixed by retrying
		return Result{Class: ClassPermanent, Err: mask.Text("request body: " + err.Error())}
	}

	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	var timedOut atomic.Bool
	done := make(chan struct{})
	defer close(done)
	deadline := d.Clock.After(r.Timeout) // armed before the call so the deadline counts from its start
	go func() {
		select {
		case <-deadline:
			timedOut.Store(true)
			cancel()
		case <-done:
		}
	}()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, d.URL(r.App, r.Port, r.Job), bytes.NewReader(buf))
	if err != nil {
		return Result{Class: ClassPermanent, Err: mask.Text("build request: "+err.Error(), secret)}
	}
	req.Header.Set("Authorization", "Bearer "+secret)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Platform-Run-Id", r.RunID)
	req.Header.Set("User-Agent", "platform-jobs-runner/"+d.Version)

	resp, err := d.Client.Do(req)
	if err != nil {
		if timedOut.Load() {
			return Result{Class: ClassRetryable, Timeout: true, Err: fmt.Sprintf("timeout after %s", r.Timeout)}
		}
		// Connection refused, DNS failure, reset: the app may simply be restarting.
		return Result{Class: ClassRetryable, Err: mask.Text(err.Error(), secret)}
	}
	defer resp.Body.Close()
	raw, rerr := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
	if rerr != nil && timedOut.Load() {
		return Result{Class: ClassRetryable, Timeout: true, HTTPStatus: resp.StatusCode, Err: fmt.Sprintf("timeout after %s", r.Timeout)}
	}
	res := Result{HTTPStatus: resp.StatusCode, Class: classify(resp.StatusCode)}
	if res.Class == ClassOK {
		return res
	}
	text := string(raw)
	if len(raw) >= maxBodyBytes && len(secret) < len(raw) { // a secret cut in half by the read limit
		text = text[:len(text)-len(secret)]
	}
	text = mask.Text(text, secret)
	if text == "" {
		text = "http " + strconv.Itoa(resp.StatusCode)
	}
	res.Err = text
	return res
}

func strPtr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// classify maps an HTTP status to its outcome class. Anything outside the table is permanent.
func classify(status int) Class {
	switch {
	case status >= 200 && status <= 299:
		return ClassOK
	case status == 408 || status == 425 || status == 429:
		return ClassRetryable
	case status >= 500 && status <= 599:
		return ClassRetryable
	default:
		return ClassPermanent
	}
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/dispatch/dispatch.go

# BEGIN-PAYLOAD platform/jobs/internal/history/atomic.go
payload_atomic_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
package history

import (
	"fmt"
	"os"
	"path/filepath"
)

// WriteAtomic replaces path with data: write a temp file in the same directory, fsync, chmod, rename. A reader
// sees the old file or the new one, never a partial one. Callers serialise writers of the same path.
func WriteAtomic(path string, data []byte, mode os.FileMode) error {
	tmp := filepath.Join(filepath.Dir(path), "."+filepath.Base(path)+".tmp")
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
	if err != nil {
		return fmt.Errorf("create %s: %w", filepath.Base(tmp), err)
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		os.Remove(tmp)
		return fmt.Errorf("write %s: %w", filepath.Base(tmp), err)
	}
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tmp)
		return fmt.Errorf("sync %s: %w", filepath.Base(tmp), err)
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("close %s: %w", filepath.Base(tmp), err)
	}
	if err := os.Chmod(tmp, mode); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("chmod %s: %w", filepath.Base(tmp), err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("rename to %s: %w", filepath.Base(path), err)
	}
	return nil
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/history/atomic.go

# BEGIN-PAYLOAD platform/jobs/internal/history/history.go
payload_history_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
// Package history writes what the Step 13 status page reads: the run history (runs-YYYY-MM-DD.tsv, one line per
// finished or skipped run), the job table (jobs.tsv) and the runner heartbeat (runner.tsv). The column order of
// each file is part of the platform contract.
package history

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	// KeepRunFiles is how many runs-*.tsv files survive pruning (the newest by date).
	KeepRunFiles = 30
	// maxErrChars is the longest error column.
	maxErrChars = 300
	// maxNameChars caps the app, job and other identifier cells (the registry name limit).
	maxNameChars = 63
	// maxLineBytes keeps one run line inside a single atomic write(2).
	maxLineBytes = 4096
)

var runsFileRE = regexp.MustCompile(`^runs-[0-9]{4}-[0-9]{2}-[0-9]{2}\.tsv$`)

// Run is one run record.
type Run struct {
	RunID        string
	App          string
	Job          string
	Trigger      string
	ScheduledFor time.Time // zero prints -
	Started      time.Time
	Ended        time.Time
	HTTPStatus   int // 0 prints -
	Result       string
	Attempt      int
	Err          string // sanitised and capped here; callers mask secrets first
}

// JobRow is one row of jobs.tsv.
type JobRow struct {
	App         string
	Job         string
	Schedule    string // "" prints -
	CatchUp     bool
	LastResult  string
	LastStarted time.Time
	LastEnded   time.Time
	NextDue     time.Time
	State       string
}

// Writer writes the run history and the job table under one directory.
type Writer struct {
	dir string

	runMu    sync.Mutex
	lastDate string // the date last pruned for

	// appendWrite writes one run line to the open file; the default is a single f.WriteString (one write(2)).
	// Tests replace it to count the calls.
	appendWrite func(f *os.File, line string) (int, error)

	jobsMu sync.Mutex
}

// NewWriter returns a Writer for dir (created when missing, mode 0755).
func NewWriter(dir string) (*Writer, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("history dir: %w", err)
	}
	return &Writer{dir: dir, appendWrite: func(f *os.File, line string) (int, error) { return f.WriteString(line) }}, nil
}

// cell makes a value safe for a TSV cell: tabs, newlines and other control characters become spaces, empty
// becomes -.
func cell(s string) string {
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, strings.ToValidUTF8(s, "?"))
	if s == "" {
		return "-"
	}
	return s
}

func ts(t time.Time) string {
	if t.IsZero() {
		return "-"
	}
	return t.UTC().Format(time.RFC3339)
}

func capErr(s string, n int) string {
	if utf8.RuneCountInString(s) > n {
		return string([]rune(s)[:n])
	}
	return s
}

// FormatRun renders the run line (with its newline). The line is always under 4 KiB: the error column shrinks
// until it fits.
func FormatRun(r Run) string {
	// The free-text cells are capped first (63 runes is the registry name limit), so even with the error column
	// reduced to "-" the line stays under maxLineBytes (5 cells x 63 runes x 4 bytes plus the fixed columns).
	idCell, appCell, jobCell := capErr(cell(r.RunID), maxNameChars), capErr(cell(r.App), maxNameChars), capErr(cell(r.Job), maxNameChars)
	trigCell, resCell := capErr(cell(r.Trigger), maxNameChars), capErr(cell(r.Result), maxNameChars)
	errText := capErr(cell(r.Err), maxErrChars)
	for {
		cols := []string{
			idCell, appCell, jobCell, trigCell, ts(r.ScheduledFor), ts(r.Started), ts(r.Ended),
			strconv.FormatInt(r.Ended.Sub(r.Started).Milliseconds(), 10), resCell, httpCell(r.HTTPStatus),
			strconv.Itoa(r.Attempt), errText,
		}
		line := strings.Join(cols, "\t") + "\n"
		if len(line) < maxLineBytes || errText == "-" {
			return line
		}
		if utf8.RuneCountInString(errText) <= 1 {
			errText = "-"
			continue
		}
		errText = capErr(errText, utf8.RuneCountInString(errText)/2)
	}
}

func httpCell(s int) string {
	if s == 0 {
		return "-"
	}
	return strconv.Itoa(s)
}

// AppendRun appends one line to runs-<UTC date of Ended>.tsv with a single write(2) (O_APPEND), then prunes old
// files when the date changed since the last prune (and on the first write).
func (w *Writer) AppendRun(r Run) error {
	date := r.Ended.UTC().Format("2006-01-02")
	line := FormatRun(r)
	w.runMu.Lock()
	defer w.runMu.Unlock()
	f, err := os.OpenFile(filepath.Join(w.dir, "runs-"+date+".tsv"), os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("open run file: %w", err)
	}
	n, werr := w.appendWrite(f, line)
	cerr := f.Close()
	if werr != nil {
		return fmt.Errorf("append run line: %w", werr)
	}
	if n != len(line) {
		return fmt.Errorf("append run line: short write (%d of %d bytes)", n, len(line))
	}
	if cerr != nil {
		return fmt.Errorf("close run file: %w", cerr)
	}
	if w.lastDate != date {
		if err := w.prune(); err != nil {
			return fmt.Errorf("prune (the run line was appended): %w", err)
		}
		w.lastDate = date
	}
	return nil
}

// prune removes all but the newest KeepRunFiles runs-*.tsv files. The caller holds runMu.
func (w *Writer) prune() error {
	des, err := os.ReadDir(w.dir)
	if err != nil {
		return fmt.Errorf("list history dir: %w", err)
	}
	var names []string
	for _, de := range des {
		if !de.IsDir() && runsFileRE.MatchString(de.Name()) {
			names = append(names, de.Name())
		}
	}
	sort.Strings(names) // the date in the name sorts chronologically
	for len(names) > KeepRunFiles {
		if err := os.Remove(filepath.Join(w.dir, names[0])); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("prune %s: %w", names[0], err)
		}
		names = names[1:]
	}
	return nil
}

// WriteJobs rewrites jobs.tsv atomically, rows sorted by app then job.
func (w *Writer) WriteJobs(rows []JobRow) error {
	sorted := append([]JobRow(nil), rows...)
	sort.SliceStable(sorted, func(i, j int) bool {
		if sorted[i].App != sorted[j].App {
			return sorted[i].App < sorted[j].App
		}
		return sorted[i].Job < sorted[j].Job
	})
	var b strings.Builder
	for _, r := range sorted {
		cu := "false"
		if r.CatchUp {
			cu = "true"
		}
		b.WriteString(strings.Join([]string{
			cell(r.App), cell(r.Job), cell(r.Schedule), cu, cell(r.LastResult),
			ts(r.LastStarted), ts(r.LastEnded), ts(r.NextDue), cell(r.State),
		}, "\t"))
		b.WriteByte('\n')
	}
	w.jobsMu.Lock()
	defer w.jobsMu.Unlock()
	return WriteAtomic(filepath.Join(w.dir, "jobs.tsv"), []byte(b.String()), 0o644)
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/history/history.go

# BEGIN-PAYLOAD platform/jobs/internal/history/status.go
payload_status_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
package history

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/logx"
)

// HeartbeatEvery is the runner.tsv heartbeat period.
const HeartbeatEvery = 15 * time.Second

// Snapshot is the content of runner.tsv.
type Snapshot struct {
	StartedAt   time.Time
	HeartbeatAt time.Time
	Window      string // ok | invalid
	Config      string // ok | invalid
	Redis       string // ok | down | invalid
	Version     string
}

// Status owns runner.tsv. Setters update one field under a mutex and wake the single status goroutine (Run),
// which is the only writer of the file; a 15s ticker rewrites it regardless of any other activity, so the
// heartbeat advances while Redis is down, the window file is invalid and nothing runs.
type Status struct {
	clk  clock.Clock
	path string
	log  *logx.Logger

	mu   sync.Mutex
	snap Snapshot

	kick  chan struct{}
	ready chan struct{}
	once  sync.Once
}

// NewStatus returns a Status that writes path. Window, config and redis start as ok; the Step 7 manager moves
// redis_state.
func NewStatus(clk clock.Clock, path, version string, log *logx.Logger) *Status {
	now := clk.Now()
	return &Status{
		clk: clk, path: path, log: log,
		snap:  Snapshot{StartedAt: now, HeartbeatAt: now, Window: "ok", Config: "ok", Redis: "ok", Version: version},
		kick:  make(chan struct{}, 1),
		ready: make(chan struct{}),
	}
}

// Ready is closed once Run has written the first line and armed its ticker.
func (s *Status) Ready() <-chan struct{} { return s.ready }

// Snapshot returns a copy of the current state.
func (s *Status) Snapshot() Snapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snap
}

// SetWindow records window_state; anything but ok is stored as invalid (fail closed).
func (s *Status) SetWindow(v string) {
	s.set(func(sn *Snapshot) { sn.Window = pick(v, "ok", "invalid") })
}

// SetConfig records config_state; anything but ok is stored as invalid.
func (s *Status) SetConfig(v string) {
	s.set(func(sn *Snapshot) { sn.Config = pick(v, "ok", "invalid") })
}

// SetRedis records redis_state; anything but ok or down is stored as invalid.
func (s *Status) SetRedis(v string) {
	s.set(func(sn *Snapshot) { sn.Redis = pick(v, "ok", "down", "invalid") })
}

func pick(v string, allowed ...string) string {
	for _, a := range allowed {
		if v == a {
			return v
		}
	}
	return "invalid"
}

func (s *Status) set(f func(*Snapshot)) {
	s.mu.Lock()
	f(&s.snap)
	s.mu.Unlock()
	select {
	case s.kick <- struct{}{}:
	default: // a write is already pending and will read the newest state
	}
}

// Line renders a snapshot as the runner.tsv line (with its newline).
func Line(sn Snapshot) string {
	ver := strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return ' '
		}
		return r
	}, sn.Version)
	if ver == "" {
		ver = "-"
	}
	return strings.Join([]string{ts(sn.StartedAt), ts(sn.HeartbeatAt), sn.Window, sn.Config, sn.Redis, ver}, "\t") + "\n"
}

func (s *Status) write() {
	s.mu.Lock()
	s.snap.HeartbeatAt = s.clk.Now()
	line := Line(s.snap)
	s.mu.Unlock()
	if err := WriteAtomic(s.path, []byte(line), 0o644); err != nil {
		s.log.Printf("status write_failed file=runner.tsv err=%q", err.Error())
	}
}

// Run writes runner.tsv now, on every state change and on every heartbeat tick until ctx ends.
func (s *Status) Run(ctx context.Context) {
	tick := s.clk.NewTicker(HeartbeatEvery)
	defer tick.Stop()
	s.write()
	s.once.Do(func() { close(s.ready) })
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C():
		case <-s.kick:
		}
		s.write()
	}
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/history/status.go

# BEGIN-PAYLOAD platform/jobs/internal/logx/logx.go
payload_logx_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
// Package logx is the runner's stdout logger: one line per event, prefixed with a UTC RFC3339 timestamp from the
// injected Clock (journald adds its own, but the line must stand alone when copied out).
package logx

import (
	"fmt"
	"io"
	"strings"
	"sync"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
)

// Logger writes whole lines with a single Write each. A nil *Logger discards everything.
type Logger struct {
	mu  sync.Mutex
	w   io.Writer
	clk clock.Clock
}

// New returns a Logger writing to w.
func New(w io.Writer, clk clock.Clock) *Logger {
	return &Logger{w: w, clk: clk}
}

// Printf formats one event. Newlines inside the message are replaced with spaces so a line is always one line.
func (l *Logger) Printf(format string, a ...any) {
	if l == nil {
		return
	}
	msg := strings.NewReplacer("\r", " ", "\n", " ").Replace(fmt.Sprintf(format, a...))
	line := l.clk.Now().UTC().Format(time.RFC3339) + " " + msg + "\n"
	l.mu.Lock()
	defer l.mu.Unlock()
	_, _ = io.WriteString(l.w, line)
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/logx/logx.go

# BEGIN-PAYLOAD platform/jobs/internal/mask/mask.go
payload_mask_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
// Package mask turns arbitrary text (a response body, a transport error) into a short single-line string that is
// safe to log and to write into the run history: secrets and bearer tokens are replaced, control characters
// become spaces and the length is capped.
package mask

import (
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// MaxLen is the longest masked text, in characters.
const MaxLen = 300

var bearerRE = regexp.MustCompile(`(?i)bearer\s+[A-Za-z0-9._~+/=-]+`)

// Text masks s. Every occurrence of a non-empty secret is replaced by ***, any "Bearer <token>" is replaced by
// "Bearer ***", control characters (tabs and newlines included) become spaces, surrounding whitespace is
// trimmed and the result is cut to MaxLen characters. Masking happens before the cut, so a secret that
// straddles the cut point is already gone.
func Text(s string, secrets ...string) string { return TextN(MaxLen, s, secrets...) }

// TextN is Text with a caller-chosen length cap (the consumer's log lines keep up to 4096 characters of a raw item).
func TextN(max int, s string, secrets ...string) string {
	s = strings.ToValidUTF8(s, "?")
	for _, sec := range secrets {
		if sec != "" {
			s = strings.ReplaceAll(s, sec, "***")
		}
	}
	s = bearerRE.ReplaceAllString(s, "Bearer ***")
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, s)
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) > max {
		r := []rune(s)
		s = string(r[:max])
	}
	return s
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/mask/mask.go

# BEGIN-PAYLOAD platform/jobs/internal/notify/discord.go
payload_discord_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
// Package notify delivers the runner's Discord alerts, mirroring backup.sh notify(): the webhook comes from
// jobs.env, mentions are disabled, the text is prefixed, masked and cut, a post has a 30s timeout and a failed post
// only logs. Run-failure alerts for the same (app, job, result) collapse to one per 15 minutes with a "N more since"
// count; state-change alerts (Notify) are not collapsed.
package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/logx"
)

const (
	// CollapseWindow is the shortest gap between two alerts for the same (app, job, result).
	CollapseWindow = 15 * time.Minute
	// PostTimeout bounds one webhook post.
	PostTimeout = 30 * time.Second
	// MaxText is the longest message sent, in characters.
	MaxText = 1900
	// Prefix starts every message.
	Prefix = "platform-jobs"

	queueLen   = 64
	maxEntries = 1024
)

// PostFunc sends one JSON body to the webhook.
type PostFunc func(ctx context.Context, body []byte) error

type key struct{ app, job, result string }

type entry struct {
	sentAt     time.Time
	suppressed int
}

// Discord is the alert sink. Notify and Alert never block: a message is queued and a goroutine (Run) posts it.
type Discord struct {
	clk     clock.Clock
	log     *logx.Logger
	webhook string
	post    PostFunc

	mu   sync.Mutex
	seen map[key]*entry
	out  chan string
}

// New returns a Discord notifier that posts to webhook over client (nil gets a client with the 30s timeout).
func New(clk clock.Clock, log *logx.Logger, webhook string, client *http.Client) *Discord {
	if client == nil {
		client = &http.Client{Timeout: PostTimeout}
	}
	d := NewWithPost(clk, log, webhook, nil)
	d.post = func(ctx context.Context, body []byte) error {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, webhook, bytes.NewReader(body))
		if err != nil {
			return fmt.Errorf("build request: %s", d.mask(err.Error()))
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			return fmt.Errorf("post: %s", d.mask(err.Error())) // a transport error carries the URL
		}
		defer resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode > 299 {
			return fmt.Errorf("webhook answered http %d", resp.StatusCode)
		}
		return nil
	}
	return d
}

// NewWithPost returns a Discord notifier that delivers through post (tests).
func NewWithPost(clk clock.Clock, log *logx.Logger, webhook string, post PostFunc) *Discord {
	return &Discord{
		clk: clk, log: log, webhook: webhook, post: post,
		seen: map[key]*entry{}, out: make(chan string, queueLen),
	}
}

// mask removes the webhook URL and control characters, and cuts the text to MaxText characters.
func (d *Discord) mask(s string) string {
	s = strings.ToValidUTF8(s, "?")
	if d.webhook != "" {
		s = strings.ReplaceAll(s, d.webhook, "***")
	}
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) && r != '\n' {
			return ' '
		}
		return r
	}, s)
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) > MaxText {
		s = string([]rune(s)[:MaxText])
	}
	return s
}

// decide applies the collapse rule: it returns the text to send, or false when the alert is suppressed.
func (d *Discord) decide(k key, msg string) (string, bool) {
	now := d.clk.Now()
	d.mu.Lock()
	defer d.mu.Unlock()
	e := d.seen[k]
	if e != nil && now.Sub(e.sentAt) < CollapseWindow {
		e.suppressed++
		return "", false
	}
	text := msg
	if e != nil && e.suppressed > 0 {
		text = fmt.Sprintf("%s (%d more since %s)", msg, e.suppressed, e.sentAt.UTC().Format("15:04Z"))
	}
	if len(d.seen) >= maxEntries { // bound the table: forget what is past its window
		for kk, ee := range d.seen {
			if now.Sub(ee.sentAt) >= CollapseWindow {
				delete(d.seen, kk)
			}
		}
	}
	d.seen[k] = &entry{sentAt: now}
	return text, true
}

// Notify sends a state-change alert. State alerts are never collapsed: each is sent once per change by the caller, and
// a repeated "down" or "parked" after a recovery must reach the operator. Only the bounded queue limits them.
func (d *Discord) Notify(msg string) { d.enqueue(msg) }

// Alert sends a run alert, collapsed per (app, job, result).
func (d *Discord) Alert(app, job, result, msg string) {
	text, ok := d.decide(key{app, job, result}, msg)
	if !ok {
		return
	}
	d.enqueue(text)
}

func (d *Discord) enqueue(text string) {
	text = d.mask(Prefix + ": " + text)
	select {
	case d.out <- text:
	default:
		d.log.Printf("notify dropped queue_full=%d", queueLen)
	}
}

// Run delivers queued messages until ctx ends.
func (d *Discord) Run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case text := <-d.out:
			d.deliver(ctx, text)
		}
	}
}

func (d *Discord) deliver(ctx context.Context, text string) {
	body, err := json.Marshal(map[string]any{
		"content":          text,
		"allowed_mentions": map[string]any{"parse": []string{}},
	})
	if err != nil {
		d.log.Printf("notify marshal_failed err=%q", err.Error())
		return
	}
	pctx, cancel := context.WithCancel(ctx)
	defer cancel()
	deadline := d.clk.After(PostTimeout) // the 30s bound goes through the injected clock
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-deadline:
			cancel()
		case <-done:
		}
	}()
	if err := d.post(pctx, body); err != nil {
		d.log.Printf("notify post_failed err=%q", d.mask(err.Error())) // a failed post never affects a run
	}
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/notify/discord.go

# BEGIN-PAYLOAD platform/jobs/internal/notify/env.go
payload_env_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
package notify

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// WebhookKey is the one key jobs.env may hold.
const WebhookKey = "DISCORD_WEBHOOK"

const maxEnvBytes = 8192

// LoadEnv reads jobs.env as literal KEY=VALUE lines (no quoting, no expansion). It allows exactly one key,
// DISCORD_WEBHOOK, with an https:// value; blank lines and # comments are skipped. Any other key, a duplicate, a
// malformed line or a missing key is an error, so the runner refuses to start. Errors never include the value.
func LoadEnv(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("jobs.env: %w", err)
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxEnvBytes+1))
	if err != nil {
		return "", fmt.Errorf("jobs.env: %w", err)
	}
	if len(b) > maxEnvBytes {
		return "", errors.New("jobs.env: file is too large")
	}
	var hook string
	seen := false
	for i, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSuffix(line, "\r")
		if strings.TrimSpace(line) == "" || strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			return "", fmt.Errorf("jobs.env: line %d is not KEY=VALUE", i+1)
		}
		if k != WebhookKey {
			return "", fmt.Errorf("jobs.env: line %d has an unexpected key (only %s is allowed)", i+1, WebhookKey)
		}
		if seen {
			return "", fmt.Errorf("jobs.env: line %d repeats %s", i+1, WebhookKey)
		}
		seen = true
		if !strings.HasPrefix(v, "https://") || strings.ContainsAny(v, " \t\"'") || len(v) <= len("https://") {
			return "", fmt.Errorf("jobs.env: %s must be an https:// URL without spaces or quotes", WebhookKey)
		}
		hook = v
	}
	if !seen {
		return "", fmt.Errorf("jobs.env: %s is missing", WebhookKey)
	}
	return hook, nil
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/notify/env.go

# BEGIN-PAYLOAD platform/jobs/internal/queue/consumer.go
payload_consumer_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
package queue

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/dispatch"
	"github.com/gpropersi/apps/platform/jobs/internal/history"
	"github.com/gpropersi/apps/platform/jobs/internal/logx"
	"github.com/gpropersi/apps/platform/jobs/internal/mask"
)

const (
	// ResultsCap is the results channel capacity and the platform-wide cap on runs in flight.
	ResultsCap = 3
	// IdleWait is how long a pass that took nothing waits before the next one.
	IdleWait = 250 * time.Millisecond
	// PromoteEvery is the delayed-set promotion period.
	PromoteEvery = time.Second
	// ProbeEvery is how often a parked app is probed.
	ProbeEvery = 60 * time.Second
	// BackoffInitial and BackoffCap bound the retry delay of Redis work (completion writes, reconnects).
	BackoffInitial = time.Second
	BackoffCap     = 30 * time.Second
	// promoteBatch is how many due items one promotion tick moves per app.
	promoteBatch = 100
	// probeKey is the key the connection probe reads (TYPE of a missing key is a harmless reply that still
	// exercises the runner's key scope).
	probeKey = "runner:jobs:probe"
)

// JobSpec is what the queue needs to know about a declared job.
type JobSpec struct {
	Port    int
	Timeout time.Duration
}

// WindowVerdict is the backup-window decision for one job timeout.
type WindowVerdict int

const (
	// WindowInvalid is the zero value on purpose: an unreadable window.env refuses everything.
	WindowInvalid WindowVerdict = iota
	// WindowHold means the window rule refuses a run now.
	WindowHold
	// WindowAllow means a run may start.
	WindowAllow
)

// Registry is the scheduler's view the consumer shares: the declared apps and jobs, the backup window, and the
// platform-wide cap slot with the (app, job) in-flight mark.
type Registry interface {
	// Apps returns the apps with a valid app.yaml and at least one declared job, sorted.
	Apps() []string
	// Job returns a declared job.
	Job(app, job string) (JobSpec, bool)
	// WindowGate re-reads window.env and applies the backup-window rule for a job timeout.
	WindowGate(timeout time.Duration) WindowVerdict
	// TryAcquire takes a cap slot and the (app, job) in-flight mark without blocking. release frees both.
	TryAcquire(app, job string) (release func(), ok bool)
	// Record appends a run record and updates the job table.
	Record(r history.Run)
}

// Caller makes the HTTP call for one run; *dispatch.Dispatcher is the production implementation.
type Caller interface {
	Call(ctx context.Context, r dispatch.Request) dispatch.Result
}

// Notifier delivers a state-change alert; it must not block.
type Notifier interface {
	Notify(msg string)
}

// Alerter is the optional extension of a Notifier that collapses run alerts per (app, job, result).
type Alerter interface {
	Alert(app, job, result, msg string)
}

// StatusSink receives redis_state for runner.tsv.
type StatusSink interface {
	SetRedis(v string)
}

// Config wires a Consumer.
type Config struct {
	Clock      clock.Clock
	Store      Store
	Caller     Caller
	Registry   Registry
	SecretsDir string
	Status     StatusSink
	Notifier   Notifier
	Log        *logx.Logger
	// Jitter scales every backoff and retry delay (production: clock.RandomJitter).
	Jitter clock.Jitter
	// NewRunID returns a fresh run id (default: a ULID stamped with the clock).
	NewRunID func() string
	// IdleWait overrides the idle interval (tests); zero means IdleWait.
	IdleWait time.Duration
}

type appState struct {
	name       string
	recovered  bool
	recovering int // recovery writes not landed yet
	busy       int // queued items in flight (worker running) or with a pending completion write
	pending    []*write
	parked     *parkInfo
	nextTake   time.Time
	takeFails  int
}

// Consumer is the queue state machine. Everything it does to Redis happens on the goroutine that runs Run (or, in
// tests, calls pass).
type Consumer struct {
	cfg  Config
	clk  clock.Clock
	s    Store
	root context.Context

	results chan result
	wg      sync.WaitGroup

	apps map[string]*appState
	rr   int

	promoteDue bool
	tick       clock.Ticker

	redisState string // ok | down | invalid
	redisFails int
	redisNext  time.Time
	oomActive  bool

	// Test-only hooks. They are nil in production (New leaves them nil; TestHookNilInProduction asserts it).
	afterPeek  func(app string) // between the peek and the LMOVE
	beforeExec func(app string) // between the TYPE pre-check and the EXEC
	trace      func(phase string)
}

// New returns a Consumer. It does nothing until Run.
func New(cfg Config) *Consumer {
	if cfg.Jitter == nil {
		cfg.Jitter = clock.RandomJitter
	}
	if cfg.NewRunID == nil {
		clk := cfg.Clock
		cfg.NewRunID = func() string { return clock.NewULID(clk.Now()) }
	}
	if cfg.IdleWait <= 0 {
		cfg.IdleWait = IdleWait
	}
	return &Consumer{
		cfg: cfg, clk: cfg.Clock, s: cfg.Store, root: context.Background(),
		results: make(chan result, ResultsCap), apps: map[string]*appState{}, redisState: "ok",
	}
}

func (c *Consumer) logf(format string, a ...any) { c.cfg.Log.Printf(format, a...) }

func (c *Consumer) now() time.Time { return c.clk.Now() }

func (c *Consumer) tr(phase string) {
	if c.trace != nil {
		c.trace(phase)
	}
}

func (c *Consumer) st(app string) *appState {
	s := c.apps[app]
	if s == nil {
		s = &appState{name: app}
		c.apps[app] = s
	}
	return s
}

// Run blocks until ctx ends, then waits for the runs still in flight (their requests are cancelled with ctx).
func (c *Consumer) Run(ctx context.Context) {
	c.root = ctx
	c.tick = c.clk.NewTicker(PromoteEvery)
	defer c.tick.Stop()
	for ctx.Err() == nil {
		if c.pass() {
			continue
		}
		select {
		case <-ctx.Done():
		case r := <-c.results:
			c.handleResult(r)
		case <-c.tick.C():
			c.promoteDue = true
		case <-c.clk.After(c.idleWait()):
		}
	}
	c.wg.Wait()
}

// idleWait is the short interval, or less when a write backoff or a Redis probe is due sooner.
func (c *Consumer) idleWait() time.Duration {
	wait := c.cfg.IdleWait
	now := c.now()
	consider := func(t time.Time) {
		if t.IsZero() {
			return
		}
		if d := t.Sub(now); d < wait {
			wait = d
		}
	}
	if c.redisState != "ok" {
		consider(c.redisNext)
	}
	for _, st := range c.apps {
		if st.parked == nil && len(st.pending) > 0 {
			consider(st.pending[0].notBefore)
		}
	}
	if wait < time.Millisecond {
		wait = time.Millisecond
	}
	return wait
}

// pass runs the phases in order and reports whether it made progress (so Run does not idle).
func (c *Consumer) pass() bool {
	progress := false
	if c.tick != nil {
		select {
		case <-c.tick.C():
			c.promoteDue = true
		default:
		}
	}
	c.tr("drain")
	for drained := false; !drained; {
		select {
		case r := <-c.results:
			c.handleResult(r)
			progress = true
		default:
			drained = true
		}
	}
	if !c.redisGate() {
		return progress
	}
	if c.runWrites() {
		progress = true
	}
	c.probeParked()
	c.tr("promote")
	if c.promoteDue {
		c.promoteDue = false
		c.promote()
	}
	c.tr("recover")
	c.recoverApps()
	c.tr("take")
	if c.takeAll() {
		progress = true
	}
	return progress
}

// secretReadable reports whether the app's jobs-secret can be read now.
func (c *Consumer) secretReadable(app string) bool {
	_, ok := dispatch.ReadSecret(c.cfg.SecretsDir, app)
	return ok
}

// enabledApps returns the apps the consumer may serve: a valid app.yaml with a declared job, a readable
// jobs-secret and not parked. It also clears the recovered flag of every app that is not in that state.
func (c *Consumer) enabledApps() []string {
	reg := c.cfg.Registry.Apps()
	in := map[string]bool{}
	var out []string
	for _, a := range reg {
		in[a] = true
		st := c.st(a)
		if st.parked == nil && c.secretReadable(a) {
			out = append(out, a)
		}
	}
	for name, st := range c.apps {
		if st.parked != nil || !in[name] || !c.secretReadable(name) {
			st.recovered = false
		}
	}
	sort.Strings(out)
	return out
}

// declaredFor returns the declared-job predicate of one app.
func (c *Consumer) declaredFor(app string) func(string) bool {
	return func(job string) bool {
		_, ok := c.cfg.Registry.Job(app, job)
		return ok
	}
}

func (c *Consumer) newID() string { return c.cfg.NewRunID() }

// text masks and caps an error for a record or an alert.
func text(s string) string { return mask.Text(s) }

// notify logs and sends a state-change alert.
func (c *Consumer) notify(msg string) {
	c.logf("alert %s", msg)
	if c.cfg.Notifier != nil {
		c.cfg.Notifier.Notify(msg)
	}
}

// alertRun sends a run alert, collapsed per (app, job, result) when the notifier supports it.
func (c *Consumer) alertRun(app, job, result, msg string) {
	c.logf("alert %s", msg)
	if c.cfg.Notifier == nil {
		return
	}
	if a, ok := c.cfg.Notifier.(Alerter); ok {
		a.Alert(app, job, result, msg)
		return
	}
	c.cfg.Notifier.Notify(msg)
}

func qkey(app, kind string) string { return app + ":jobs:" + kind }
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/queue/consumer.go

# BEGIN-PAYLOAD platform/jobs/internal/queue/envelope.go
payload_envelope_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
// Package queue is the runner's queue consumer: it takes the envelopes apps LPUSH onto <app>:jobs:queue, runs them
// through the same guardrails as scheduled jobs, retries failures with growing delays through <app>:jobs:delayed,
// sets aside the jobs that keep failing in <app>:jobs:dead and recovers what a crash left in <app>:jobs:processing.
//
// One consumer goroutine owns every Redis queue operation. Workers only call the app and hand the outcome back.
package queue

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gpropersi/apps/platform/jobs/internal/mask"
)

// logIDBytes bounds the id and job name a log line keeps from an item that may not be valid.
const logIDBytes = 64

// rawSummary describes a raw queue item for a log line without its payload: the envelope id, the job name and the
// byte length. The payload may hold user data, so it never reaches the journal; the item itself stays recoverable
// from <app>:jobs:processing or :dead. The id and job are best effort (an unparseable or oversize item has none).
func rawSummary(raw string) string {
	id, job := "-", "-"
	if len(raw) <= MaxEnvelopeBytes {
		var fields map[string]json.RawMessage
		if json.Unmarshal([]byte(raw), &fields) == nil {
			var s string
			if json.Unmarshal(fields["id"], &s) == nil && s != "" {
				id = mask.TextN(logIDBytes, s)
			}
			if json.Unmarshal(fields["job"], &s) == nil && s != "" {
				job = mask.TextN(logIDBytes, s)
			}
		}
	}
	return fmt.Sprintf("id=%q job=%q bytes=%d", id, job, len(raw))
}

const (
	// MaxEnvelopeBytes is the largest envelope that is parsed; a bigger one is dead-lettered unread.
	MaxEnvelopeBytes = 65536
	// MaxAttempts is the number of HTTP attempts a queued job gets.
	MaxAttempts = 5
	// DeadKeep is how many dead records <app>:jobs:dead keeps.
	DeadKeep = 100
	// DeadEnvelopeBytes is how much of the raw item a dead record holds.
	DeadEnvelopeBytes = 4096
	// DelayedMax is the most entries <app>:jobs:delayed may hold before a retry dead-letters as overflow.
	DelayedMax = 1000
	// MaxLastError is the longest last_error kept on an envelope or dead record.
	MaxLastError = 300
)

// Dead-record reasons (the one enum of the contract).
const (
	ReasonInvalid   = "invalid_envelope"
	ReasonUndeclare = "undeclared_job"
	ReasonOverflow  = "overflow"
	ReasonPermanent = "permanent"
	ReasonExhausted = "retries_exhausted"
)

var (
	jobNameRE = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,62}$`)
	ulidRE    = regexp.MustCompile(`^[0-9A-Za-z]{26}$`)
)

// Envelope is one queued job as apps write it, plus the fields the runner adds when it re-queues.
type Envelope struct {
	V          int             `json:"v"`
	ID         string          `json:"id"`
	Job        string          `json:"job"`
	Payload    json.RawMessage `json:"payload"`
	EnqueuedAt string          `json:"enqueued_at"`
	Attempt    int             `json:"attempt,omitempty"`
	LastError  string          `json:"last_error,omitempty"`
}

// Verdict is the result of Validate.
type Verdict struct {
	Env    *Envelope // set only when valid
	Reason string    // "" when valid, else one of the dead-record reasons
	Detail string    // why, for last_error
	ID     string    // the envelope id when it could be read
	Job    string    // the job name when it could be read
}

// Valid reports whether the envelope may be run.
func (v Verdict) Valid() bool { return v.Reason == "" && v.Env != nil }

// Validate validates one raw item. The size check comes first and nothing above MaxEnvelopeBytes is parsed. The
// same function serves the take path and recovery. declared reports whether a job name is declared by the app.
func Validate(raw string, declared func(job string) bool) Verdict {
	if len(raw) > MaxEnvelopeBytes {
		return Verdict{Reason: ReasonInvalid, Detail: fmt.Sprintf("oversize envelope (%d bytes, max %d)", len(raw), MaxEnvelopeBytes)}
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &fields); err != nil || fields == nil {
		return Verdict{Reason: ReasonInvalid, Detail: "not a JSON object"}
	}
	v := Verdict{Reason: ReasonInvalid}
	// Best-effort id and job for the record, even when something else is wrong.
	var id, job string
	if json.Unmarshal(fields["id"], &id) == nil {
		v.ID = id
	}
	if json.Unmarshal(fields["job"], &job) == nil {
		v.Job = job
	}
	for _, k := range []string{"v", "id", "job", "payload", "enqueued_at"} {
		if _, ok := fields[k]; !ok {
			v.Detail = "missing field " + k
			return v
		}
	}
	var e Envelope
	if err := json.Unmarshal(fields["v"], &e.V); err != nil || e.V != 1 {
		v.Detail = "unknown v"
		return v
	}
	if err := json.Unmarshal(fields["id"], &e.ID); err != nil || !ulidRE.MatchString(e.ID) {
		v.Detail = "id is not a 26-character ULID"
		return v
	}
	if err := json.Unmarshal(fields["job"], &e.Job); err != nil || !jobNameRE.MatchString(e.Job) {
		v.Detail = "job is not a valid job name"
		return v
	}
	e.Payload = fields["payload"]
	if err := json.Unmarshal(fields["enqueued_at"], &e.EnqueuedAt); err != nil {
		v.Detail = "enqueued_at is not a string"
		return v
	}
	if _, err := time.Parse(time.RFC3339, e.EnqueuedAt); err != nil {
		v.Detail = "enqueued_at is not RFC3339"
		return v
	}
	e.Attempt = 1
	if raw, ok := fields["attempt"]; ok {
		if err := json.Unmarshal(raw, &e.Attempt); err != nil || e.Attempt < 1 {
			v.Detail = "attempt is not an integer >= 1"
			return v
		}
	}
	if raw, ok := fields["last_error"]; ok {
		if err := json.Unmarshal(raw, &e.LastError); err != nil {
			v.Detail = "last_error is not a string"
			return v
		}
	}
	if declared == nil || !declared(e.Job) {
		v.Reason, v.Detail = ReasonUndeclare, "job "+e.Job+" is not declared in app.yaml"
		return v
	}
	return Verdict{Env: &e, ID: e.ID, Job: e.Job}
}

// Encode renders the envelope for re-queueing with the given attempt and masked last_error. The payload bytes are
// kept as they are. When the result would be too large to be taken again, last_error is dropped.
func (e Envelope) Encode(attempt int, lastError string) string {
	e.Attempt, e.LastError = attempt, lastError
	if len(e.Payload) == 0 {
		e.Payload = json.RawMessage("null")
	}
	b, err := marshalPlain(e)
	if err != nil || len(b) > MaxEnvelopeBytes {
		e.LastError = ""
		b, _ = marshalPlain(e)
	}
	return string(b)
}

// marshalPlain is json.Marshal without HTML escaping, so a payload near the size bound is not inflated (< > & would
// grow six-fold). The output is still valid JSON.
func marshalPlain(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

// DeadRecord is one entry of <app>:jobs:dead. Envelope is always a JSON string holding the raw bytes, so an invalid
// or oversize original still gives a valid record.
type DeadRecord struct {
	V             int    `json:"v"`
	Envelope      string `json:"envelope"`
	Truncated     bool   `json:"truncated"`
	EnvelopeBytes int    `json:"envelope_bytes"`
	ID            string `json:"id,omitempty"`
	Reason        string `json:"reason"`
	Attempts      int    `json:"attempts"`
	LastError     string `json:"last_error"`
	DeadAt        string `json:"dead_at"`
}

// NewDeadRecord builds the record for raw. The envelope string is cut to DeadEnvelopeBytes on a character
// boundary and invalid UTF-8 becomes U+FFFD first, so the stored string is at most DeadEnvelopeBytes after decoding.
func NewDeadRecord(raw, id, reason string, attempts int, lastError string, at time.Time) DeadRecord {
	head := raw
	if len(head) > DeadEnvelopeBytes+utf8.UTFMax {
		head = head[:DeadEnvelopeBytes+utf8.UTFMax]
	}
	clean := strings.ToValidUTF8(head, "�")
	for len(clean) > DeadEnvelopeBytes {
		_, size := utf8.DecodeLastRuneInString(clean)
		clean = clean[:len(clean)-size]
	}
	return DeadRecord{
		V: 1, Envelope: clean, Truncated: clean != raw, EnvelopeBytes: len(raw), ID: id,
		Reason: reason, Attempts: attempts, LastError: lastError, DeadAt: at.UTC().Format(time.RFC3339),
	}
}

// JSON renders the record.
func (d DeadRecord) JSON() string {
	var sb strings.Builder
	enc := json.NewEncoder(&sb)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(d) // a struct of strings and ints cannot fail
	return strings.TrimSuffix(sb.String(), "\n")
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/queue/envelope.go

# BEGIN-PAYLOAD platform/jobs/internal/queue/recover.go
payload_recover_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
package queue

import (
	"fmt"
)

// recoverApps runs recovery for each enabled, unparked app that is due for it, before that app's next peek.
//
// Trigger, per app: on runner start, and on each transition of the app to enabled (a disabled app whose file or
// secret was fixed, an app added after start, an app un-parked after a deterministic write error). The flag is
// cleared whenever the app leaves enabled or is parked (enabledApps does that) and set when recovery has run.
// Recovery waits while the runner holds an in-flight queued item or a pending completion write for the app, so an
// item whose result write is still pending is never re-delivered.
func (c *Consumer) recoverApps() {
	for _, app := range c.enabledApps() {
		if c.down() {
			return
		}
		st := c.st(app)
		if st.parked != nil || st.recovered || st.busy > 0 || len(st.pending) > 0 || c.now().Before(st.nextTake) {
			continue
		}
		c.recoverApp(st)
	}
}

// recoverApp reads the app's processing list and queues one completion write per leftover item. Items go through
// the same Validate as the take path: an invalid, oversize (never parsed) or undeclared item is dead-lettered with
// its normal reason and never given attempt + 1; a valid one goes back to the head of the queue with attempt + 1,
// or is dead-lettered with retries_exhausted when that would exceed MaxAttempts. The list is read leftmost (newest)
// first and pushed in that order, so the oldest ends at the head of the queue.
func (c *Consumer) recoverApp(st *appState) {
	app := st.name
	items, err := c.s.LRangeAll(c.root, qkey(app, "processing"))
	c.observe(err)
	if err != nil {
		c.takeErr(st, "LRANGE", err)
		return
	}
	st.recovered = true
	if len(items) > 0 {
		c.logf("recovery app=%s items=%d", app, len(items))
	}
	declared := c.declaredFor(app)
	for _, raw := range items {
		v := Validate(raw, declared)
		if !v.Valid() {
			c.addWrite(st, c.newDeadWrite(app, raw, v, v.Reason, 0, v.Detail, true))
			continue
		}
		n := v.Env.Attempt
		if n+1 > MaxAttempts {
			c.addWrite(st, c.newDeadWrite(app, raw, v, ReasonExhausted, n, fmt.Sprintf("runner crashed during attempt %d", n), true))
			continue
		}
		w := &write{
			app: app, job: v.Env.Job, raw: raw, kind: wRequeue, envID: v.ID, recovery: true, newBusy: true,
			newRaw: v.Env.Encode(n+1, fmt.Sprintf("runner crashed during attempt %d", n)),
		}
		c.addWrite(st, w)
	}
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/queue/recover.go

# BEGIN-PAYLOAD platform/jobs/internal/queue/redisstate.go
payload_redisstate_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
package queue

import (
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
)

// Backoff returns the delay before retry number n (0-based): 1s, 2s, 4s, ... capped at 30s, scaled by (1 + jitter).
// The completion writes, the take-phase errors and the Redis reconnect all use it. The jitter is clamped to the
// contract's +-20%.
func Backoff(n int, j clock.Jitter) time.Duration {
	d := BackoffCap
	if n < 6 { // 1s << 5 is already 32s
		d = BackoffInitial << uint(n)
		if d > BackoffCap {
			d = BackoffCap
		}
	}
	return scale(d, j)
}

func scale(d time.Duration, j clock.Jitter) time.Duration {
	f := 0.0
	if j != nil {
		f = j()
	}
	if f > clock.MaxJitter {
		f = clock.MaxJitter
	}
	if f < -clock.MaxJitter {
		f = -clock.MaxJitter
	}
	return time.Duration(float64(d) * (1 + f))
}

// RetryDelay is the delay before the retry that follows failed attempt n (1-4): 30s x 4^(n-1), +-20% jitter, at
// most one hour.
func RetryDelay(attempt int, j clock.Jitter) time.Duration {
	d := 30 * time.Second
	for i := 1; i < attempt; i++ {
		d *= 4
		if d > time.Hour {
			break
		}
	}
	d = scale(d, j)
	if d > time.Hour {
		d = time.Hour
	}
	return d
}

func (c *Consumer) backoff(n int) time.Duration { return Backoff(n, c.cfg.Jitter) }

// setRedis moves redis_state and alerts once per change.
func (c *Consumer) setRedis(state, why string) {
	if state == c.redisState {
		return
	}
	prev := c.redisState
	c.redisState = state
	if c.cfg.Status != nil {
		c.cfg.Status.SetRedis(state)
	}
	c.logf("redis state=%s prev=%s why=%q", state, prev, why)
	switch state {
	case "down":
		c.notify("Redis is unreachable, queued jobs are paused (scheduled jobs keep running): " + text(why))
	case "invalid":
		c.notify("Redis rejected the runner user (NOPERM or WRONGPASS), queued jobs are paused (scheduled jobs keep running): " + text(why))
	case "ok":
		c.notify("Redis is reachable again, queued jobs resume")
	}
}

// observe feeds the outcome of every store call into the connection state: a connection error moves redis_state
// to down, NOPERM/WRONGPASS to invalid, and any success back to ok. OOM is alert-only: redis_state stays ok.
func (c *Consumer) observe(err error) {
	if err == nil {
		c.markOK()
		return
	}
	cl := Classify(err)
	switch {
	case cl.Conn:
		c.enterBad("down", err)
	case cl.Kind == KindAuth:
		c.enterBad("invalid", err)
	default: // the server answered with an error: it is reachable and accepted the credentials
		c.redisFails = 0
		if c.redisState != "ok" {
			c.setRedis("ok", "")
		}
	}
}

func (c *Consumer) enterBad(state string, err error) {
	if c.redisState == "ok" {
		c.redisFails = 0
		c.redisNext = c.now().Add(c.backoff(0))
	}
	c.setRedis(state, err.Error())
}

func (c *Consumer) markOK() {
	c.redisFails = 0
	if c.redisState != "ok" {
		c.setRedis("ok", "")
	}
}

// wroteOK clears an OOM condition. Only a write command that Redis accepted proves it again takes writes; reads
// succeed under OOM and must not end it.
func (c *Consumer) wroteOK() {
	if c.oomActive {
		c.oomActive = false
		c.notify("Redis accepts writes again after an OOM rejection")
	}
}

// noteOOM alerts once per state change and logs every backoff cycle.
func (c *Consumer) noteOOM(app, cmd string, attempt int, next time.Duration) {
	c.logf("OOM app=%s command=%s attempt=%d next_delay=%s", app, cmd, attempt, next)
	if !c.oomActive {
		c.oomActive = true
		c.notify("Redis is out of memory (OOM): queue writes for " + app + " are being retried, nothing is lost")
	}
}

// down reports whether Redis work should stop for now.
func (c *Consumer) down() bool { return c.redisState != "ok" }

// redisGate lets a pass use Redis. While the state is down or invalid it probes once per backoff period.
func (c *Consumer) redisGate() bool {
	if c.redisState == "ok" {
		return true
	}
	now := c.now()
	if now.Before(c.redisNext) {
		return false
	}
	_, err := c.s.Type(c.root, probeKey)
	c.observe(err)
	if err != nil {
		c.redisFails++
		c.redisNext = now.Add(c.backoff(c.redisFails))
		c.logf("redis probe failed state=%s attempt=%d next=%s err=%q", c.redisState, c.redisFails, c.redisNext.UTC().Format(time.RFC3339), text(err.Error()))
		return false
	}
	return true
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/queue/redisstate.go

# BEGIN-PAYLOAD platform/jobs/internal/queue/redisstore.go
payload_redisstore_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
package queue

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

// RedisAddr is the shared Redis on the platform network.
const RedisAddr = "redis:6379"

// RedisUser is the runner's ACL user.
const RedisUser = "runner"

// CommandTimeout bounds every Redis command (dial, write and read).
const CommandTimeout = 5 * time.Second

// ReadPassword reads the runner password file and strips exactly one trailing newline (the Password normalisation
// rule), so a file written with echo and one written with printf give the same value.
func ReadPassword(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("jobs-redis.password: %w", err)
	}
	pw := strings.TrimSuffix(string(b), "\n")
	if pw == "" {
		return "", errors.New("jobs-redis.password is empty")
	}
	return pw, nil
}

// RedisStore is the go-redis Store. The client's own retries are off (MaxRetries -1), so the consumer's loop is the
// only retry and its LPOS check sees every ambiguous write.
type RedisStore struct {
	c *redis.Client
}

// NewRedisStore returns a Store for addr. bound is the per-command timeout (CommandTimeout in production).
func NewRedisStore(addr, user, password string, bound time.Duration) *RedisStore {
	return &RedisStore{c: redis.NewClient(&redis.Options{
		Addr: addr, Username: user, Password: password,
		DialTimeout: bound, ReadTimeout: bound, WriteTimeout: bound, PoolTimeout: bound,
		MaxRetries: -1, Protocol: 2, DisableIdentity: true,
		PoolSize: 2, MinIdleConns: 0,
	})}
}

func args(name string, a ...any) []any { return append([]any{name}, a...) }

// LIndexLast implements Store.
func (r *RedisStore) LIndexLast(ctx context.Context, key string) (string, bool, error) {
	s, err := r.c.Do(ctx, args("LINDEX", key, -1)...).Text()
	return nilAware(s, err)
}

// LMove implements Store.
func (r *RedisStore) LMove(ctx context.Context, src, dst, from, to string) (string, bool, error) {
	s, err := r.c.Do(ctx, args("LMOVE", src, dst, from, to)...).Text()
	return nilAware(s, err)
}

func nilAware(s string, err error) (string, bool, error) {
	if errors.Is(err, redis.Nil) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return s, true, nil
}

// LPos implements Store.
func (r *RedisStore) LPos(ctx context.Context, key, val string) (bool, error) {
	_, err := r.c.Do(ctx, args("LPOS", key, val)...).Int64()
	if errors.Is(err, redis.Nil) {
		return false, nil
	}
	return err == nil, err
}

// LRem implements Store.
func (r *RedisStore) LRem(ctx context.Context, key, val string) (int64, error) {
	return r.c.Do(ctx, args("LREM", key, 1, val)...).Int64()
}

// LRangeAll implements Store.
func (r *RedisStore) LRangeAll(ctx context.Context, key string) ([]string, error) {
	return r.c.Do(ctx, args("LRANGE", key, 0, -1)...).StringSlice()
}

// ZCard implements Store.
func (r *RedisStore) ZCard(ctx context.Context, key string) (int64, error) {
	return r.c.Do(ctx, args("ZCARD", key)...).Int64()
}

// ZRangeDue implements Store.
func (r *RedisStore) ZRangeDue(ctx context.Context, key string, max int64, limit int) ([]string, error) {
	return r.c.Do(ctx, args("ZRANGEBYSCORE", key, "-inf", max, "LIMIT", 0, limit)...).StringSlice()
}

// Type implements Store.
func (r *RedisStore) Type(ctx context.Context, key string) (string, error) {
	return r.c.Do(ctx, args("TYPE", key)...).Text()
}

// Exec implements Store.
func (r *RedisStore) Exec(ctx context.Context, cmds []Cmd) ([]error, error) {
	pipe := r.c.TxPipeline()
	out := make([]*redis.Cmd, len(cmds))
	for i, c := range cmds {
		a := make([]any, 0, len(c.Args)+1)
		a = append(a, c.Name)
		for _, s := range c.Args {
			a = append(a, s)
		}
		out[i] = pipe.Do(ctx, a...)
	}
	_, err := pipe.Exec(ctx)
	if err != nil && wholeFailure(err) {
		return nil, err
	}
	errs := make([]error, len(cmds))
	found := false
	for i, c := range out {
		if e := c.Err(); e != nil && !errors.Is(e, redis.Nil) {
			errs[i] = e
			found = true
		}
	}
	if err != nil && !found {
		return nil, err // fail closed: an EXEC error that no command explains must not read as success
	}
	return errs, nil
}

// wholeFailure reports whether an Exec error means the block as a whole did not run (or its outcome is unknown),
// as opposed to a runtime error of one command inside a block that did run.
func wholeFailure(err error) bool {
	var re redis.Error
	if !errors.As(err, &re) {
		return true // a connection error, a timeout, a closed client
	}
	c := Classify(err)
	return c.Kind != KindDeterministic
}

// Close implements Store.
func (r *RedisStore) Close() error { return r.c.Close() }
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/queue/redisstore.go

# BEGIN-PAYLOAD platform/jobs/internal/queue/store.go
payload_store_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
package queue

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"strings"

	"github.com/redis/go-redis/v9"
)

// Cmd is one Redis command inside a MULTI/EXEC block. Arguments are plain strings: keys, values, and numbers in
// decimal.
type Cmd struct {
	Name string
	Args []string
}

// Store is exactly the set of Redis commands the consumer uses. The production implementation wraps go-redis; the
// unit tests use an in-memory fake with error injection.
//
// Every method returns the server's error unchanged so Classify can sort it. A nil reply is (zero, false, nil).
type Store interface {
	// LIndexLast peeks the rightmost list item (LINDEX key -1).
	LIndexLast(ctx context.Context, key string) (string, bool, error)
	// LMove is LMOVE src dst from to, with from/to "LEFT" or "RIGHT".
	LMove(ctx context.Context, src, dst, from, to string) (string, bool, error)
	// LPos reports whether val is in the list (LPOS key val).
	LPos(ctx context.Context, key, val string) (bool, error)
	// LRem removes one occurrence of val (LREM key 1 val).
	LRem(ctx context.Context, key, val string) (int64, error)
	// LRangeAll returns the whole list, leftmost first.
	LRangeAll(ctx context.Context, key string) ([]string, error)
	// ZCard is the size of a sorted set.
	ZCard(ctx context.Context, key string) (int64, error)
	// ZRangeDue returns up to limit members whose score is <= max, lowest score first.
	ZRangeDue(ctx context.Context, key string, max int64, limit int) ([]string, error)
	// Type is TYPE key ("none" for a missing key).
	Type(ctx context.Context, key string) (string, error)
	// Exec runs the commands in one MULTI/EXEC. The returned slice has one entry per command (nil when it
	// applied). A non-nil error means the block as a whole failed: EXECABORT or a queue-time error applies
	// nothing, and a connection error leaves the outcome unknown.
	Exec(ctx context.Context, cmds []Cmd) ([]error, error)
	// Close releases the connection.
	Close() error
}

// Kind is how a Redis error is handled.
type Kind int

const (
	// KindDeterministic is the zero value on purpose: an error nobody classified fails closed (the app is
	// parked) instead of being retried in a loop.
	KindDeterministic Kind = iota
	// KindTransient is retried with backoff: connection loss, timeout, OOM, EXECABORT, LOADING, BUSY.
	KindTransient
	// KindAuth is NOPERM, WRONGPASS or NOAUTH: redis_state=invalid, retried slowly.
	KindAuth
)

// Class is the classification of one error.
type Class struct {
	Kind Kind
	Conn bool // connection loss or timeout: the server may or may not have applied the command
	OOM  bool
}

var transientPrefixes = []string{"OOM", "EXECABORT", "LOADING", "BUSY", "TRYAGAIN", "MASTERDOWN", "MISCONF"}
var authPrefixes = []string{"NOPERM", "WRONGPASS", "NOAUTH"}

// Classify sorts an error from the Store.
func Classify(err error) Class {
	if err == nil {
		return Class{}
	}
	s := err.Error()
	for _, p := range authPrefixes {
		if strings.HasPrefix(s, p) {
			return Class{Kind: KindAuth}
		}
	}
	for _, p := range transientPrefixes {
		if strings.HasPrefix(s, p) {
			return Class{Kind: KindTransient, OOM: p == "OOM" || (p == "EXECABORT" && strings.Contains(s, "OOM"))}
		}
	}
	if isConn(err) {
		return Class{Kind: KindTransient, Conn: true}
	}
	return Class{Kind: KindDeterministic}
}

func isConn(err error) bool {
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, redis.ErrClosed) ||
		errors.Is(err, context.DeadlineExceeded) || errors.Is(err, os.ErrDeadlineExceeded) || errors.Is(err, net.ErrClosed) {
		return true
	}
	var ne net.Error
	if errors.As(err, &ne) {
		return true
	}
	s := err.Error()
	for _, frag := range []string{"connection refused", "connection reset", "broken pipe", "i/o timeout", "no such host", "use of closed network connection", "EOF"} {
		if strings.Contains(s, frag) {
			return true
		}
	}
	return false
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/queue/store.go

# BEGIN-PAYLOAD platform/jobs/internal/queue/take.go
payload_take_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
package queue

import (
	"github.com/gpropersi/apps/platform/jobs/internal/mask"
)

// takeAll gives every enabled, unparked app one turn, round-robin, and reports whether anything was taken.
func (c *Consumer) takeAll() bool {
	apps := c.enabledApps()
	if len(apps) == 0 {
		return false
	}
	start := c.rr % len(apps)
	c.rr++
	took := false
	for i := range apps {
		if c.down() {
			break
		}
		if c.takeApp(apps[(start+i)%len(apps)]) {
			took = true
		}
	}
	return took
}

// hasMoveBack reports a pending move-back: until it lands the item is not in the queue, so a later item must not
// jump ahead of it.
func (st *appState) hasMoveBack() bool {
	for _, w := range st.pending {
		if w.kind == wBack {
			return true
		}
	}
	return false
}

// gateOK applies the take-time conditions to a valid head: its jobs-secret is readable now and the window.env read
// is valid and allows the job for its timeout. (The app is enabled and unparked, and the job is not in flight,
// which TryAcquire checks.) A head that fails is not taken: no cap slot, no LMOVE, no attempt, nothing recorded.
func (c *Consumer) gateOK(app string, env *Envelope) (JobSpec, bool) {
	spec, ok := c.cfg.Registry.Job(app, env.Job)
	if !ok || !c.secretReadable(app) {
		return spec, false
	}
	return spec, c.cfg.Registry.WindowGate(spec.Timeout) == WindowAllow
}

// takeApp takes at most one item of one app. It reports whether an item was moved to processing.
func (c *Consumer) takeApp(app string) bool {
	st := c.st(app)
	if st.parked != nil || !st.recovered || st.recovering > 0 || st.hasMoveBack() || c.now().Before(st.nextTake) {
		return false
	}
	queue, proc := qkey(app, "queue"), qkey(app, "processing")
	raw, found, err := c.s.LIndexLast(c.root, queue)
	c.observe(err)
	if err != nil {
		c.takeErr(st, "LINDEX", err)
		return false
	}
	if !found {
		st.takeFails = 0
		return false
	}
	v := Validate(raw, c.declaredFor(app))
	var release func()
	var spec JobSpec
	if v.Valid() {
		var ok bool
		if spec, ok = c.gateOK(app, v.Env); !ok {
			return false // waits at the head; head-of-line waiting is intentional
		}
		if release, ok = c.cfg.Registry.TryAcquire(app, v.Env.Job); !ok {
			return false
		}
	}
	// An invalid, oversize or undeclared head skips the gate: it has no usable job timeout or in-flight state.
	if c.afterPeek != nil {
		c.afterPeek(app)
	}
	moved, found, err := c.s.LMove(c.root, queue, proc, "RIGHT", "LEFT")
	c.observe(err)
	if err != nil || !found {
		if release != nil { // a nil reply or an error must not pin a cap slot while it backs off
			release()
		}
		if err != nil {
			if Classify(err).Conn {
				// The LMOVE may have been applied: an item could sit in processing with nothing tracking it, so
				// recovery must run again.
				st.recovered = false
			}
			c.takeErr(st, "LMOVE", err)
		}
		return false
	}
	st.takeFails = 0
	c.wroteOK()
	if moved == raw {
		if !v.Valid() {
			c.deadFromTake(st, moved, v)
			return true
		}
		c.dispatchRun(task{app: app, raw: moved, env: v.Env, spec: spec, release: release})
		return true
	}
	// The right end changed between the peek and the LMOVE: what moved is a new head. Nothing may run on a gate
	// evaluated for a different job.
	if release != nil {
		release()
	}
	c.logf("lmove mismatch app=%s: the moved item differs from the peeked one, re-gating it", app)
	v2 := Validate(moved, c.declaredFor(app))
	if !v2.Valid() {
		c.deadFromTake(st, moved, v2)
		return true
	}
	if spec2, ok := c.gateOK(app, v2.Env); ok {
		if rel2, ok := c.cfg.Registry.TryAcquire(app, v2.Env.Job); ok {
			c.dispatchRun(task{app: app, raw: moved, env: v2.Env, spec: spec2, release: rel2})
			return true
		}
	}
	c.moveBack(st, moved, v2)
	return true
}

// deadFromTake dead-lettering of an item the take path just moved to processing.
func (c *Consumer) deadFromTake(st *appState, raw string, v Verdict) {
	attempts := 0
	if v.Env != nil {
		attempts = v.Env.Attempt
	}
	c.addWrite(st, c.newDeadWrite(st.name, raw, v, v.Reason, attempts, v.Detail, false))
}

// moveBack returns a moved-but-not-runnable item to the head of the queue, unchanged.
func (c *Consumer) moveBack(st *appState, raw string, v Verdict) {
	w := &write{app: st.name, job: orDash(v.Job), raw: raw, kind: wBack, newBusy: true, envID: v.ID}
	c.addWrite(st, w)
}

// takeErr handles an error of a take-phase command: transient errors back the app off, deterministic ones park it.
func (c *Consumer) takeErr(st *appState, cmd string, err error) {
	if c.root.Err() != nil { // shutting down: a cancelled call is not a Redis fault
		return
	}
	cl := Classify(err)
	if cl.Kind == KindDeterministic {
		c.park(st, &write{app: st.name}, cmd, err)
		return
	}
	delay := c.backoff(st.takeFails)
	st.takeFails++
	st.nextTake = c.now().Add(delay)
	if cl.OOM {
		c.noteOOM(st.name, cmd, st.takeFails, delay)
		return
	}
	c.logf("take retry app=%s command=%s attempt=%d next_delay=%s err=%q", st.name, cmd, st.takeFails, delay, mask.Text(err.Error()))
}

// ---- promotion ----

// promote moves the due items of every enabled, unparked app's delayed set to the head of its queue, one MULTI/EXEC
// per item (ZREM + RPUSH), so a promoted retry runs next.
func (c *Consumer) promote() {
	for _, app := range c.enabledApps() {
		if c.down() {
			return
		}
		st := c.st(app)
		if st.parked != nil {
			continue
		}
		due, err := c.s.ZRangeDue(c.root, qkey(app, "delayed"), c.now().Unix(), promoteBatch)
		c.observe(err)
		if err != nil {
			c.promoteErr(st, "ZRANGEBYSCORE", err, "")
			continue
		}
		for _, raw := range due {
			if c.down() || st.parked != nil {
				break
			}
			if err := c.typeCheck(app, "queue"); err != nil {
				c.promoteErr(st, "TYPE", err, raw)
				break
			}
			if c.beforeExec != nil {
				c.beforeExec(app)
			}
			replies, err := c.s.Exec(c.root, []Cmd{
				{Name: "ZREM", Args: []string{qkey(app, "delayed"), raw}},
				{Name: "RPUSH", Args: []string{qkey(app, "queue"), raw}},
			})
			c.observe(err)
			if err != nil {
				c.promoteErr(st, "EXEC", err, raw)
				break
			}
			var first error
			applied := 0
			for _, e := range replies {
				if e == nil {
					applied++
				} else if first == nil {
					first = e
				}
			}
			if first != nil {
				if applied > 0 {
					c.logf("partial EXEC applied app=%s command=promote applied=%d failed=%q item: %s", app, applied, mask.Text(first.Error()), rawSummary(raw))
				}
				c.promoteErr(st, "EXEC", first, raw)
				break
			}
		}
	}
}

// promoteErr sorts an error of a promotion: transient ones wait for the next tick (the item stays in delayed),
// deterministic ones park the app.
func (c *Consumer) promoteErr(st *appState, cmd string, err error, raw string) {
	if c.root.Err() != nil { // shutting down: a cancelled call is not a Redis fault
		return
	}
	cl := Classify(err)
	if cl.Kind == KindDeterministic {
		c.park(st, &write{app: st.name, raw: raw}, cmd, err)
		return
	}
	if cl.OOM {
		c.noteOOM(st.name, "promote "+cmd, 1, PromoteEvery)
		return
	}
	c.logf("promote retry app=%s command=%s next=%s err=%q", st.name, cmd, PromoteEvery, mask.Text(err.Error()))
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/queue/take.go

# BEGIN-PAYLOAD platform/jobs/internal/queue/writes.go
payload_writes_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
package queue

import (
	"fmt"
	"sort"
	"strconv"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/dispatch"
	"github.com/gpropersi/apps/platform/jobs/internal/history"
)

type writeKind int

const (
	// wDone removes a finished item from processing.
	wDone writeKind = iota
	// wRetry removes the item from processing and schedules it in <app>:jobs:delayed.
	wRetry
	// wDead removes the item from processing and records it in <app>:jobs:dead.
	wDead
	// wBack returns an item from processing to the head of the queue without changing it (gate-fail).
	wBack
	// wRequeue returns a recovered item to the head of the queue with attempt + 1.
	wRequeue
)

type outcome int

const (
	outLanded outcome = iota
	outRetry
	outPark
)

// write is one completion write: the Redis change that follows a run, a dead-letter decision or a recovery step.
type write struct {
	app  string
	job  string // "-" when unknown
	raw  string // the exact bytes in processing; every LREM uses them
	kind writeKind

	// retry / requeue
	newRaw string
	due    time.Time

	// dead
	reason    string
	attempts  int
	lastError string
	envID     string
	deadAt    time.Time

	rec         history.Run // written once, when the write lands (zero Result: nothing to record)
	alertResult string      // non-empty: send a run alert when the write lands
	alertMsg    string

	release   func() // frees the cap slot and the in-flight mark; nil when none is held
	recovery  bool   // counts in appState.recovering
	newBusy   bool   // no worker was dispatched for it, so addWrite counts it in appState.busy
	attempted bool   // a first attempt was made: every later one checks LPOS first
	partial   bool   // an EXEC applied some commands but not all: the LPOS shortcut is unsound, the whole block is rerun
	fails     int    // consecutive failed attempts, for the backoff
	notBefore time.Time
}

// task is one queued run handed to a worker.
type task struct {
	app     string
	raw     string
	env     *Envelope
	spec    JobSpec
	release func()
}

// result is what a worker hands back.
type result struct {
	task     task
	runID    string
	res      dispatch.Result
	started  time.Time
	ended    time.Time
	gateFail bool
	rec      history.Run // the skip record of a gate-fail
}

type parkInfo struct {
	cmd       string
	err       string
	since     time.Time
	nextProbe time.Time
	lastLog   time.Time
}

// ---- workers ----

// dispatchRun starts a worker for a valid item that holds a cap slot and the in-flight mark.
func (c *Consumer) dispatchRun(t task) {
	c.st(t.app).busy++
	c.wg.Add(1)
	go c.work(t)
}

func (c *Consumer) work(t task) {
	defer c.wg.Done()
	r := result{task: t}
	switch c.cfg.Registry.WindowGate(t.spec.Timeout) {
	case WindowAllow:
		runID := c.newID()
		r.runID, r.started = runID, c.now()
		enq, _ := time.Parse(time.RFC3339, t.env.EnqueuedAt)
		r.res = c.cfg.Caller.Call(c.root, dispatch.Request{
			App: t.app, Port: t.spec.Port, Job: t.env.Job, Timeout: t.spec.Timeout, RunID: runID,
			Trigger: "queue", Attempt: t.env.Attempt, QueueID: t.env.ID, EnqueuedAt: enq, Payload: t.env.Payload,
		})
		r.ended = c.now()
		if r.res.NoSecret {
			r.gateFail = true
			r.rec = c.skipRec(t, "skipped_no_secret", r.res.Err)
		}
	case WindowInvalid:
		r.gateFail = true
		r.rec = c.skipRec(t, "refused_config", "window.env invalid")
	default: // the window now refuses this job: it waits at the head, nothing is recorded
		r.gateFail = true
	}
	select {
	case c.results <- r:
	case <-c.root.Done():
		if t.release != nil {
			t.release()
		}
	}
}

func (c *Consumer) skipRec(t task, result, why string) history.Run {
	now := c.now()
	return history.Run{
		RunID: c.newID(), App: t.app, Job: t.env.Job, Trigger: "queue", Started: now, Ended: now,
		Result: result, Attempt: 0, Err: text(why),
	}
}

// handleResult turns a worker's outcome into a completion write.
func (c *Consumer) handleResult(r result) {
	t := r.task
	st := c.st(t.app)
	w := &write{app: t.app, job: t.env.Job, raw: t.raw, release: t.release, envID: t.env.ID}
	if r.gateFail {
		// The item goes back to the queue head without incrementing attempt, and the slot and mark are freed at
		// once: the move-back is a completion write with no slot held.
		if w.release != nil {
			w.release()
			w.release = nil
		}
		w.kind = wBack
		w.rec = r.rec
		if r.rec.Result == "" {
			c.logf("gate-fail app=%s job=%s id=%s: the window refuses the job now, returning it to the queue head", t.app, t.env.Job, t.env.ID)
		} else {
			// A gate-fail that leaves a record must not loop hot if the gate keeps disagreeing with the take-time check.
			st.nextTake = c.now().Add(c.backoff(st.takeFails))
			st.takeFails++
		}
		c.addWrite(st, w)
		return
	}
	env := t.env
	attempt := env.Attempt
	cause := r.res.Err
	if r.res.HTTPStatus > 0 && !r.res.Timeout {
		cause = fmt.Sprintf("http %d: %s", r.res.HTTPStatus, r.res.Err)
	}
	cause = text(cause)
	rec := history.Run{
		RunID: r.runID, App: t.app, Job: env.Job, Trigger: "queue", Started: r.started, Ended: r.ended,
		HTTPStatus: r.res.HTTPStatus, Attempt: attempt,
	}
	switch r.res.Class {
	case dispatch.ClassOK:
		w.kind = wDone
		rec.Result = "ok"
	case dispatch.ClassRetryable:
		if attempt >= MaxAttempts {
			c.makeDead(w, ReasonExhausted, attempt, cause, &rec)
			break
		}
		w.kind, w.attempts = wRetry, attempt
		w.due = c.now().Add(RetryDelay(attempt, c.cfg.Jitter))
		w.newRaw = env.Encode(attempt+1, cause)
		rec.Result, rec.Err = "retry_scheduled", cause
	default: // permanent, and anything unclassified
		c.makeDead(w, ReasonPermanent, attempt, cause, &rec)
	}
	w.rec = rec
	c.addWrite(st, w)
}

// makeDead turns w into a dead-letter write and fills the record and the alert.
func (c *Consumer) makeDead(w *write, reason string, attempts int, lastError string, rec *history.Run) {
	w.kind, w.reason, w.attempts, w.lastError = wDead, reason, attempts, text(lastError)
	w.deadAt = c.now()
	rec.Result, rec.Err = "dead_lettered", reason+": "+w.lastError
	w.alertResult = "dead_lettered"
	w.alertMsg = fmt.Sprintf("queued job %s/%s dead-lettered (%s) after attempt %d: %s [id %s]", w.app, w.job, reason, attempts, w.lastError, orDash(w.envID))
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func (c *Consumer) addWrite(st *appState, w *write) {
	if w.recovery {
		st.recovering++
	}
	if w.newBusy {
		st.busy++
	}
	if st.parked != nil && w.release != nil { // a parked app holds no slot or mark
		w.release()
		w.release = nil
	}
	st.pending = append(st.pending, w)
}

// newDeadWrite builds the dead-letter of an item that is already in processing and has no run (an invalid head, a
// recovered item). busy is counted here because no worker was dispatched for it.
func (c *Consumer) newDeadWrite(app, raw string, v Verdict, reason string, attempts int, lastError string, recovery bool) *write {
	now := c.now()
	w := &write{app: app, job: orDash(v.Job), raw: raw, envID: v.ID, recovery: recovery, newBusy: true}
	rec := history.Run{
		RunID: c.newID(), App: app, Job: w.job, Trigger: "queue", Started: now, Ended: now, Attempt: attempts,
	}
	c.makeDead(w, reason, attempts, lastError, &rec)
	w.rec = rec
	return w
}

// ---- running the writes ----

// runWrites performs the pending completion writes, one app at a time, strictly in order within an app. It reports
// whether a write landed.
func (c *Consumer) runWrites() bool {
	progress := false
	names := make([]string, 0, len(c.apps))
	for name, st := range c.apps {
		if len(st.pending) > 0 {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	for _, name := range names {
		st := c.apps[name]
		for len(st.pending) > 0 && st.parked == nil && !c.down() {
			w := st.pending[0]
			if c.now().Before(w.notBefore) {
				break
			}
			if c.attempt(st, w) != outLanded {
				break
			}
			c.land(st, w)
			progress = true
		}
	}
	return progress
}

// land finishes a write that took effect: it records the run once, sends the alert, frees the slot and mark and
// forgets the write.
func (c *Consumer) land(st *appState, w *write) {
	for i, p := range st.pending {
		if p == w {
			st.pending = append(st.pending[:i], st.pending[i+1:]...)
			break
		}
	}
	if w.release != nil {
		w.release()
		w.release = nil
	}
	if w.recovery && st.recovering > 0 {
		st.recovering--
	}
	if st.busy > 0 {
		st.busy--
	}
	if w.rec.Result != "" {
		c.cfg.Registry.Record(w.rec)
		c.logf("run end app=%s job=%s trigger=queue run_id=%s result=%s http=%d attempt=%d", w.app, w.job, w.rec.RunID, w.rec.Result, w.rec.HTTPStatus, w.rec.Attempt)
	}
	if w.alertResult != "" {
		c.alertRun(w.app, w.job, w.alertResult, w.alertMsg)
	}
}

// expectedType returns the Redis type a destination key must have (or be missing).
func expectedType(kind string) string {
	if kind == "delayed" {
		return "zset"
	}
	return "list"
}

// typeCheck refuses a destination key of the wrong type before an EXEC, so the common case applies nothing.
func (c *Consumer) typeCheck(app, kind string) error {
	key := qkey(app, kind)
	t, err := c.s.Type(c.root, key)
	c.observe(err)
	if err != nil {
		return err
	}
	if t != "none" && t != expectedType(kind) {
		return fmt.Errorf("WRONGTYPE key %s holds %s, want %s", key, t, expectedType(kind))
	}
	return nil
}

// attempt performs one try of a completion write.
func (c *Consumer) attempt(st *appState, w *write) outcome {
	app := w.app
	ctx := c.root
	if w.attempted && !w.partial {
		// Ambiguous-write check before every retry: a lost reply may hide a write the server applied. The consumer is
		// the only writer of processing, so an item that is gone means the write took effect.
		found, err := c.s.LPos(ctx, qkey(app, "processing"), w.raw)
		c.observe(err)
		if err != nil {
			return c.writeErr(st, w, "LPOS", err)
		}
		if !found {
			c.logf("write landed app=%s kind=%d: the item is no longer in processing", app, w.kind)
			return outLanded
		}
	}
	w.attempted = true
	proc := qkey(app, "processing")
	switch w.kind {
	case wDone:
		// Note: LPOS and LREM work by value, so the ambiguity check assumes the raw values in processing are unique;
		// two identical items would let LPOS see the second copy of a write whose reply was lost.
		_, err := c.s.LRem(ctx, proc, w.raw)
		c.observe(err)
		if err != nil {
			return c.writeErr(st, w, "LREM", err)
		}
		c.wroteOK()
		return outLanded
	case wRetry:
		if err := c.typeCheck(app, "delayed"); err != nil {
			return c.writeErr(st, w, "TYPE", err)
		}
		n, err := c.s.ZCard(ctx, qkey(app, "delayed"))
		c.observe(err)
		if err != nil {
			return c.writeErr(st, w, "ZCARD", err)
		}
		if n >= DelayedMax {
			// Dead-letter instead; the record replaces the retry_scheduled one that has not been written yet.
			rec := w.rec
			c.makeDead(w, ReasonOverflow, w.attempts, fmt.Sprintf("delayed set holds %d entries (limit %d)", n, DelayedMax), &rec)
			w.rec = rec
			return c.attempt(st, w)
		}
		cmds := []Cmd{
			{Name: "LREM", Args: []string{proc, "1", w.raw}},
			{Name: "ZADD", Args: []string{qkey(app, "delayed"), strconv.FormatInt(w.due.Unix(), 10), w.newRaw}},
		}
		return c.execBlock(st, w, cmds)
	case wDead:
		if err := c.typeCheck(app, "dead"); err != nil {
			return c.writeErr(st, w, "TYPE", err)
		}
		dead := qkey(app, "dead")
		rec := NewDeadRecord(w.raw, w.envID, w.reason, w.attempts, w.lastError, w.deadAt)
		cmds := []Cmd{
			{Name: "LREM", Args: []string{proc, "1", w.raw}},
			{Name: "LPUSH", Args: []string{dead, rec.JSON()}},
			{Name: "LTRIM", Args: []string{dead, "0", strconv.Itoa(DeadKeep - 1)}},
		}
		return c.execBlock(st, w, cmds)
	default: // wBack, wRequeue
		if err := c.typeCheck(app, "queue"); err != nil {
			return c.writeErr(st, w, "TYPE", err)
		}
		item := w.raw
		if w.kind == wRequeue {
			item = w.newRaw
		}
		cmds := []Cmd{
			{Name: "LREM", Args: []string{proc, "1", w.raw}},
			{Name: "RPUSH", Args: []string{qkey(app, "queue"), item}},
		}
		return c.execBlock(st, w, cmds)
	}
}

// execBlock runs one MULTI/EXEC and inspects the reply of every command: a command that fails at run time fails
// alone while the others apply, so the overall error is not enough.
func (c *Consumer) execBlock(st *appState, w *write, cmds []Cmd) outcome {
	if c.beforeExec != nil {
		c.beforeExec(w.app)
	}
	replies, err := c.s.Exec(c.root, cmds)
	c.observe(err)
	if err != nil {
		return c.writeErr(st, w, "EXEC", err)
	}
	var applied, failed []string
	var first error
	for i, e := range replies {
		if e == nil {
			applied = append(applied, cmds[i].Name)
			continue
		}
		failed = append(failed, cmds[i].Name+": "+text(e.Error()))
		if first == nil {
			first = e
		}
	}
	if first == nil {
		c.wroteOK()
		return outLanded
	}
	if len(applied) > 0 {
		w.partial = true
		c.logf("partial EXEC applied app=%s applied=%v failed=%v item: %s", w.app, applied, failed, rawSummary(w.raw))
	}
	// A reply was received, so the write is not ambiguous: it is not retried through the LPOS shortcut. After a
	// partial apply the item may already be gone from processing although the write did not land, so the whole block
	// is rerun instead (LREM then returns 0 and the missing commands apply).
	return c.park(st, w, "EXEC", first)
}

// writeErr sorts an error of a completion write: transient and auth errors back off, anything else parks the app.
func (c *Consumer) writeErr(st *appState, w *write, cmd string, err error) outcome {
	if c.root.Err() != nil { // shutting down: a cancelled call is not a Redis fault, so no park and no alert
		return outRetry
	}
	cl := Classify(err)
	if cl.Kind == KindDeterministic {
		return c.park(st, w, cmd, err)
	}
	delay := c.backoff(w.fails)
	w.fails++
	w.notBefore = c.now().Add(delay)
	if cl.OOM {
		c.noteOOM(w.app, cmd, w.fails, delay)
	} else {
		c.logf("write retry app=%s command=%s attempt=%d next_delay=%s err=%q", w.app, cmd, w.fails, delay, text(err.Error()))
	}
	return outRetry
}

// ---- parking ----

// park stops serving an app after a deterministic error: the consumer stops taking, promoting and recovering for
// it, holds no slot or mark for it, sends one alert and leaves the item in processing. Others keep being served.
func (c *Consumer) park(st *appState, w *write, cmd string, err error) outcome {
	now := c.now()
	raw := rawSummary(w.raw)
	if st.parked != nil {
		if now.Sub(st.parked.lastLog) >= ProbeEvery || st.parked.lastLog.IsZero() {
			st.parked.lastLog = now
			c.logf("still parked app=%s command=%s err=%q item: %s", st.name, cmd, text(err.Error()), raw)
		}
		return outPark
	}
	st.parked = &parkInfo{cmd: cmd, err: text(err.Error()), since: now, nextProbe: now.Add(ProbeEvery), lastLog: now}
	st.recovered = false
	for _, p := range st.pending {
		if p.release != nil {
			p.release()
			p.release = nil
		}
	}
	c.logf("parked app=%s command=%s err=%q item: %s", st.name, cmd, text(err.Error()), raw)
	c.notify(fmt.Sprintf("app %s is parked: %s failed with %s. Its queue is not served until the key is repaired (inspect it as admin and restore a list or sorted set); other apps are unaffected", st.name, cmd, text(err.Error())))
	return outPark
}

func (c *Consumer) unpark(st *appState, why string) {
	if st.parked == nil {
		return
	}
	st.parked = nil
	st.recovered = false
	st.nextTake = time.Time{}
	c.logf("unparked app=%s why=%s", st.name, why)
	c.notify(fmt.Sprintf("app %s is served again (%s)", st.name, why))
}

// probeParked retries each parked app once per ProbeEvery: the oldest pending write, or a type check of its keys.
func (c *Consumer) probeParked() {
	if c.down() {
		return
	}
	names := make([]string, 0)
	for name, st := range c.apps {
		if st.parked != nil && !c.now().Before(st.parked.nextProbe) {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	for _, name := range names {
		st := c.apps[name]
		st.parked.nextProbe = c.now().Add(ProbeEvery)
		if len(st.pending) > 0 {
			w := st.pending[0]
			w.notBefore = time.Time{}
			// The park left the item in processing; if an operator cleared it, LPOS finds it gone and the write is
			// treated as landed, which un-parks the app.
			if !w.partial { // after a partial EXEC the LPOS shortcut would lose the item
				w.attempted = true
			}
			if c.attempt(st, w) == outLanded {
				st.parked.lastLog = c.now()
				c.unpark(st, "the pending write succeeded")
				c.land(st, w)
			}
			continue
		}
		if c.keysHealthy(st.name) {
			c.unpark(st, "its keys have the expected types")
		}
	}
}

func (c *Consumer) keysHealthy(app string) bool {
	for _, kind := range []string{"queue", "processing", "delayed", "dead"} {
		t, err := c.s.Type(c.root, qkey(app, kind))
		c.observe(err)
		if err != nil {
			return false
		}
		if t != "none" && t != expectedType(kind) {
			c.logf("still parked app=%s key=%s type=%s", app, qkey(app, kind), t)
			return false
		}
	}
	return true
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/queue/writes.go

# BEGIN-PAYLOAD platform/jobs/internal/registry/registry.go
payload_registry_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
// Package registry reads the per-app registry files <root>/<app>/app.yaml with the same rules as
// platform/registry/validate-app-yaml.sh: unknown keys, wrong types, bad values and a name that differs from the
// directory are all errors. An invalid file disables that app only; the other apps keep running.
//
// The reserved-names list is enforced here too, as defense in depth behind the deploy-time validator: the runner
// embeds reserved-names.txt (a copy of platform/registry/reserved-names.txt, kept equal by TestReservedNamesLockstep)
// and marks a registry directory with a reserved name disabled. The Postgres-identifier check is deliberately not
// repeated: it is a provisioning concern the validator enforces when the file is deployed.
package registry

import (
	"bytes"
	_ "embed"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"gopkg.in/yaml.v3"

	"github.com/gpropersi/apps/platform/jobs/internal/cron"
)

// maxFileBytes bounds an app.yaml read; a real file is a few hundred bytes.
const maxFileBytes = 64 * 1024

var (
	appRE      = regexp.MustCompile(`^[a-z][a-z0-9-]{1,30}$`)
	jobRE      = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,62}$`)
	timeoutRE  = regexp.MustCompile(`^[0-9]{1,6}(s|m|h)$`)
	memCapRE   = regexp.MustCompile(`^[1-9][0-9]{0,2}m$`)
	portRE     = regexp.MustCompile(`^[1-9][0-9]{0,4}$`)
	healthRE   = regexp.MustCompile(`^/[A-Za-z0-9._~/%-]*$`)
	topKeys    = []string{"schema_version", "name", "owner", "purpose", "template", "memory_cap", "port", "health_path", "access", "jobs"}
	topReqd    = []string{"schema_version", "name", "owner", "purpose", "template", "memory_cap", "port"}
	jobKeys    = []string{"name", "schedule", "timeout", "catch_up"}
	templates  = []string{"go-react", "go-htmx", "fastapi-react", "flask", "node-hono"}
	accessVals = []string{"family", "public", "restricted"}
)

//go:embed reserved-names.txt
var reservedRaw string

// reservedNames returns the names in the embedded list (comments and blank lines dropped).
func reservedNames() map[string]bool {
	out := map[string]bool{}
	for _, line := range strings.Split(reservedRaw, "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") {
			out[line] = true
		}
	}
	return out
}

// Job is one declared job.
type Job struct {
	Name     string
	Schedule string         // the raw quoted cron, "" for an enqueue-only job
	Cron     *cron.Schedule // nil for an enqueue-only job
	Timeout  time.Duration
	CatchUp  bool
}

// Scheduled reports whether the job has a cron schedule.
func (j Job) Scheduled() bool { return j.Cron != nil }

// App is a valid app registry file.
type App struct {
	Name       string
	Port       int
	HealthPath string
	Jobs       []Job
}

// Entry is the outcome for one registry directory: exactly one of App and Err is set. A non-nil Err means the
// app is disabled (state disabled_invalid_config) and Err.Error() is the one-line reason to log.
type Entry struct {
	Dir string
	App *App
	Err error
}

// Load reads every <root>/<app>/app.yaml. Directories whose names start with "." and plain files are ignored.
// It returns an error only when root itself cannot be read; per-app problems are Entry.Err. Entries are sorted
// by directory name.
func Load(root string) ([]Entry, error) {
	des, err := os.ReadDir(root)
	if err != nil {
		return nil, fmt.Errorf("registry root unreadable: %w", err)
	}
	reserved := reservedNames()
	if len(reserved) == 0 { // fail closed: an empty list would silently allow every reserved name
		return nil, errors.New("embedded reserved-names list has no entries")
	}
	var out []Entry
	for _, de := range des {
		name := de.Name()
		if strings.HasPrefix(name, ".") {
			continue
		}
		switch {
		case de.IsDir() && reserved[name]:
			out = append(out, Entry{Dir: name, Err: fmt.Errorf("name '%s' is reserved", name)})
		case de.IsDir():
			app, err := loadOne(filepath.Join(root, name), name)
			out = append(out, Entry{Dir: name, App: app, Err: err})
		case de.Type()&os.ModeSymlink != 0:
			out = append(out, Entry{Dir: name, Err: errors.New("app directory must be a real directory, not a symlink")})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Dir < out[j].Dir })
	return out, nil
}

func loadOne(dir, name string) (*App, error) {
	path := filepath.Join(dir, "app.yaml")
	fi, err := os.Lstat(path)
	if err != nil {
		return nil, errors.New("app.yaml is missing or unreadable")
	}
	if !fi.Mode().IsRegular() {
		return nil, errors.New("app.yaml must be a regular file, not a symlink")
	}
	if fi.Size() > maxFileBytes {
		return nil, fmt.Errorf("app.yaml is over %d bytes", maxFileBytes)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("app.yaml is unreadable")
	}
	return ParseApp(name, b)
}

type validator struct {
	problems []string
}

func (v *validator) errf(format string, a ...any) {
	v.problems = append(v.problems, fmt.Sprintf(format, a...))
}

// ParseApp validates app.yaml content for the app directory `dir`. The error lists every problem found.
func ParseApp(dir string, b []byte) (*App, error) {
	if !utf8.Valid(b) {
		return nil, errors.New("not valid app.yaml syntax: invalid UTF-8")
	}
	dec := yaml.NewDecoder(bytes.NewReader(b))
	var doc yaml.Node
	if err := dec.Decode(&doc); err != nil {
		if errors.Is(err, io.EOF) {
			return nil, errors.New("not valid app.yaml syntax: empty file")
		}
		return nil, fmt.Errorf("not valid app.yaml syntax: %s", firstLine(err.Error()))
	}
	var extra yaml.Node
	if err := dec.Decode(&extra); !errors.Is(err, io.EOF) {
		return nil, errors.New("not valid app.yaml syntax: more than one YAML document")
	}
	if doc.Kind != yaml.DocumentNode || len(doc.Content) != 1 {
		return nil, errors.New("not valid app.yaml syntax: no document")
	}
	root := doc.Content[0]
	v := &validator{}
	if !v.plainTree(root, "") {
		return nil, v.error()
	}
	if root.Kind != yaml.MappingNode {
		return nil, errors.New("app.yaml must be a map of keys")
	}
	top := v.mapping(root, "", topKeys)
	for _, k := range topReqd {
		if _, ok := top[k]; !ok {
			v.errf("missing required key '%s'", k)
		}
	}
	app := &App{}
	for _, k := range topKeys {
		n, ok := top[k]
		if !ok || k == "jobs" {
			continue
		}
		v.scalarKey(dir, k, n, app)
	}
	if n, ok := top["jobs"]; ok {
		app.Jobs = v.jobs(n)
	}
	if len(v.problems) > 0 {
		return nil, v.error()
	}
	return app, nil
}

func (v *validator) error() error {
	return errors.New(strings.Join(v.problems, "; "))
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// plainTree rejects the YAML features the repo's subset forbids (anchors, aliases, tags, flow collections,
// merge keys) anywhere in the tree. It reports false when it found any.
func (v *validator) plainTree(n *yaml.Node, path string) bool {
	ok := true
	if n.Kind == yaml.AliasNode || n.Anchor != "" {
		v.errf("anchors and aliases are not allowed%s", at(path))
		ok = false
	}
	if n.Style&yaml.TaggedStyle != 0 {
		v.errf("explicit tags are not allowed%s", at(path))
		ok = false
	}
	if n.Style&yaml.FlowStyle != 0 {
		v.errf("flow collections are not allowed%s", at(path))
		ok = false
	}
	if n.Kind == yaml.ScalarNode && n.Style&(yaml.LiteralStyle|yaml.FoldedStyle) != 0 {
		v.errf("block scalars are not allowed%s", at(path))
		ok = false
	}
	for _, c := range n.Content {
		if !v.plainTree(c, path) {
			ok = false
		}
	}
	return ok
}

func at(path string) string {
	if path == "" {
		return ""
	}
	return " at " + path
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// mapping returns the key -> value nodes of a mapping node. It reports unknown keys (against allowed),
// non-scalar keys and duplicate keys. where prefixes messages ("" for the top level, "jobs[0]" for a job).
func (v *validator) mapping(n *yaml.Node, where string, allowed []string) map[string]*yaml.Node {
	out := map[string]*yaml.Node{}
	prefix := ""
	if where != "" {
		prefix = where + " "
	}
	for i := 0; i+1 < len(n.Content); i += 2 {
		kn, vn := n.Content[i], n.Content[i+1]
		if kn.Kind != yaml.ScalarNode {
			v.errf("%shas a non-scalar key", prefix)
			continue
		}
		k := kn.Value
		if _, dup := out[k]; dup {
			v.errf("%shas a duplicate key '%s'", prefix, k)
			continue
		}
		if !contains(allowed, k) {
			if where == "" {
				v.errf("unknown key '%s'", k)
			} else {
				v.errf("%s has unknown key '%s'", where, k)
			}
			continue
		}
		out[k] = vn
	}
	return out
}

func quoted(n *yaml.Node) bool {
	return n.Style&(yaml.DoubleQuotedStyle|yaml.SingleQuotedStyle) != 0
}

func (v *validator) scalarKey(dir, k string, n *yaml.Node, app *App) {
	if n.Kind != yaml.ScalarNode {
		v.errf("%s must be a scalar value", k)
		return
	}
	val := n.Value
	switch k {
	case "schema_version", "port":
		if quoted(n) {
			v.errf("%s must be an unquoted value, not a string", k)
			return
		}
	}
	if val == "" {
		v.errf("%s must not be empty", k)
		return
	}
	switch k {
	case "schema_version":
		if val != "1" {
			v.errf("schema_version '%s' must be 1", val)
		}
	case "name":
		switch {
		case !appRE.MatchString(val):
			v.errf("name '%s' must match %s", val, appRE)
		case val != dir:
			v.errf("name '%s' must equal the parent directory name '%s'", val, dir)
		default:
			app.Name = val
		}
	case "owner":
		if strings.Contains(val, "@") {
			v.errf("owner must be a short handle, not an email address")
		} else if !appRE.MatchString(val) {
			v.errf("owner '%s' must match %s", val, appRE)
		}
	case "purpose":
		if strings.TrimSpace(val) == "" {
			v.errf("purpose must not be only whitespace")
		} else if n := utf8.RuneCountInString(val); n > 120 {
			v.errf("purpose is %d characters, the maximum is 120", n)
		}
	case "template":
		if !contains(templates, val) {
			v.errf("template '%s' is not one of: %s", val, strings.Join(templates, " "))
		}
	case "memory_cap":
		if !memCapRE.MatchString(val) {
			v.errf("memory_cap '%s' must be a number of MiB with the unit m, like 64m", val)
		} else if mib, _ := strconv.Atoi(strings.TrimSuffix(val, "m")); mib < 16 || mib > 512 {
			v.errf("memory_cap '%s' must be between 16m and 512m", val)
		}
	case "port":
		p, _ := strconv.Atoi(val)
		if !portRE.MatchString(val) || p > 65535 {
			v.errf("port '%s' must be an integer from 1 to 65535", val)
		} else {
			app.Port = p
		}
	case "health_path":
		if !strings.HasPrefix(val, "/") {
			v.errf("health_path '%s' must start with /", val)
		} else if !healthRE.MatchString(val) {
			v.errf("health_path '%s' may only contain letters, digits and . _ ~ / %% -", val)
		} else {
			app.HealthPath = val
		}
	case "access":
		if !contains(accessVals, val) {
			v.errf("access '%s' must be family, public or restricted", val)
		}
	}
}

func (v *validator) jobs(n *yaml.Node) []Job {
	if n.Kind == yaml.ScalarNode && n.Value == "" && !quoted(n) || (n.Kind == yaml.SequenceNode && len(n.Content) == 0) {
		v.errf("jobs is present but has no entries (omit the key instead)")
		return nil
	}
	if n.Kind != yaml.SequenceNode {
		v.errf("jobs must be a list of maps, not a scalar")
		return nil
	}
	var out []Job
	seen := map[string]bool{}
	for i, jn := range n.Content {
		where := fmt.Sprintf("jobs[%d]", i)
		if jn.Kind != yaml.MappingNode {
			v.errf("jobs items must be maps (name, schedule, timeout, catch_up), not plain values")
			continue
		}
		j, ok := v.job(where, jn)
		if !ok {
			continue
		}
		if seen[j.Name] {
			v.errf("duplicate job name '%s'", j.Name)
			continue
		}
		seen[j.Name] = true
		out = append(out, j)
	}
	return out
}

func (v *validator) job(where string, n *yaml.Node) (Job, bool) {
	before := len(v.problems)
	m := v.mapping(n, where, jobKeys)
	for k, vn := range m {
		if vn.Kind != yaml.ScalarNode {
			v.errf("%s/%s must be a scalar", where, k)
			delete(m, k)
		}
	}
	var j Job
	if nn, ok := m["name"]; !ok {
		v.errf("%s is missing required key 'name'", where)
	} else if !jobRE.MatchString(nn.Value) {
		v.errf("%s name '%s' must match %s", where, nn.Value, jobRE)
	} else {
		j.Name = nn.Value
	}
	if tn, ok := m["timeout"]; !ok {
		v.errf("%s is missing required key 'timeout'", where)
	} else if d, err := parseTimeout(tn.Value); err != nil {
		v.errf("%s %s", where, err)
	} else {
		j.Timeout = d
	}
	if sn, ok := m["schedule"]; ok {
		switch {
		case !quoted(sn):
			v.errf("%s schedule must be a quoted cron string", where)
		case sn.Value == "":
			v.errf("%s schedule must not be empty", where)
		default:
			c, err := cron.Parse(sn.Value)
			if err != nil {
				v.errf("%s schedule: %s", where, err)
			} else {
				j.Schedule, j.Cron = sn.Value, c
			}
		}
	}
	if cn, ok := m["catch_up"]; ok {
		switch {
		case quoted(cn) || (cn.Value != "true" && cn.Value != "false"):
			v.errf("%s catch_up '%s' must be true or false (unquoted)", where, cn.Value)
		default:
			j.CatchUp = cn.Value == "true"
		}
	}
	return j, len(v.problems) == before
}

// parseTimeout accepts Ns|Nm|Nh, 1 second to 1 hour, with the same digits rule as the validator.
func parseTimeout(s string) (time.Duration, error) {
	if !timeoutRE.MatchString(s) {
		return 0, fmt.Errorf("timeout '%s' must look like 30s, 2m or 1h", s)
	}
	n, _ := strconv.Atoi(s[:len(s)-1])
	if n < 1 {
		return 0, errors.New("timeout must be greater than zero")
	}
	var unit time.Duration
	switch s[len(s)-1] {
	case 's':
		unit = time.Second
	case 'm':
		unit = time.Minute
	case 'h':
		unit = time.Hour
	default:
		return 0, fmt.Errorf("timeout '%s' has an unknown unit", s)
	}
	d := time.Duration(n) * unit
	if d > time.Hour {
		return 0, fmt.Errorf("timeout '%s' is over the 1h maximum", s)
	}
	return d, nil
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/registry/registry.go

# BEGIN-PAYLOAD platform/jobs/internal/registry/reserved-names.txt
payload_reserved_names_txt() {
  cat <<'PLATFORM_PAYLOAD_EOF'
# App names the platform refuses (one per line; blank lines and # comments are ignored).
# Read by validate-app-yaml.sh in the repo, and on the host by `platform new-db` through the copy that
# install-data.sh installs.
#
# Rule beyond this list: an app's Postgres identifier is its name with "-" replaced by "_"; that identifier
# must not start with pg_ or equal postgres, template0, template1 or public. Both the validator and new-db
# apply it, so the two cannot diverge.
postgres
redis
valkey
pgbouncer
traefik
cloudflared
socket-proxy
down-page
status
platform
runner
jobs
backup
admin
health
default
www
ingress-livetest
ingress-livetest-sibling
ingress-livetest-curl
ingress-livetest-hostile
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/registry/reserved-names.txt

# BEGIN-PAYLOAD platform/jobs/internal/sched/queue.go
payload_queue_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
package sched

import (
	"sort"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/history"
	"github.com/gpropersi/apps/platform/jobs/internal/queue"
)

// RunAlerter is the optional extension of Notifier that collapses run alerts per (app, job, result)
// (notify.Discord implements it). A Notifier without it only gets state-change alerts.
type RunAlerter interface {
	Alert(app, job, result, msg string)
}

// alertRun sends the alert for a failed scheduled run.
func (s *Scheduler) alertRun(app, job, result, msg string) {
	s.logf("alert %s", msg)
	if a, ok := s.cfg.Notifier.(RunAlerter); ok {
		a.Alert(app, job, result, msg)
	}
}

// QueueRegistry returns the scheduler's view for the queue consumer: the declared apps and jobs, the backup
// window, the platform-wide cap slot with the (app, job) in-flight mark (shared with scheduled runs) and the run
// record.
func (s *Scheduler) QueueRegistry() queue.Registry { return queueView{s} }

type queueView struct{ s *Scheduler }

func (q queueView) Apps() []string {
	q.s.mu.Lock()
	defer q.s.mu.Unlock()
	seen := map[string]bool{}
	var out []string
	for k := range q.s.jobs {
		if !seen[k.app] {
			seen[k.app] = true
			out = append(out, k.app)
		}
	}
	sort.Strings(out)
	return out
}

func (q queueView) Job(app, job string) (queue.JobSpec, bool) {
	q.s.mu.Lock()
	defer q.s.mu.Unlock()
	js := q.s.jobs[jobKey{app, job}]
	if js == nil {
		return queue.JobSpec{}, false
	}
	return queue.JobSpec{Port: js.port, Timeout: js.job.Timeout}, true
}

// WindowGate re-reads window.env by name (like every scheduled decision) and applies the rule for the job's
// timeout. Nothing is recorded: a queued head that is held simply waits.
func (q queueView) WindowGate(timeout time.Duration) queue.WindowVerdict {
	w, err := q.s.windowDecision()
	if err != nil {
		return queue.WindowInvalid
	}
	if w.Refuses(q.s.now(), timeout) {
		return queue.WindowHold
	}
	return queue.WindowAllow
}

// TryAcquire takes a cap slot and the in-flight mark without waiting; the consumer never queues behind the
// scheduler.
func (q queueView) TryAcquire(app, job string) (func(), bool) {
	k := jobKey{app, job}
	if !q.s.tryStart(k) {
		return nil, false
	}
	select {
	case q.s.sem <- struct{}{}:
	default:
		q.s.finish(k)
		return nil, false
	}
	return func() {
		q.s.releaseSlot()
		q.s.finish(k)
	}, true
}

func (q queueView) Record(r history.Run) { q.s.record(r) }
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/sched/queue.go

# BEGIN-PAYLOAD platform/jobs/internal/sched/sched.go
payload_sched_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
// Package sched is the runner's scheduler: it fires each declared job at its cron time plus a fixed per-job
// offset, applies the single-flight, global-cap and backup-window rules, calls the app through a Caller, and
// records every run, skip and state change for the status page.
//
// All timing goes through clock.Clock, so the tests advance a fake clock instead of sleeping.
package sched

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"hash/fnv"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/dispatch"
	"github.com/gpropersi/apps/platform/jobs/internal/history"
	"github.com/gpropersi/apps/platform/jobs/internal/logx"
	"github.com/gpropersi/apps/platform/jobs/internal/registry"
	"github.com/gpropersi/apps/platform/jobs/internal/window"
)

const (
	// MaxConcurrent is the platform-wide cap on runs in flight.
	MaxConcurrent = 3
	// CapWait is how long a scheduled fire waits for a free slot before it is skipped_cap.
	CapWait = 60 * time.Second
	// ReloadEvery is the registry and window.env re-read period.
	ReloadEvery = 30 * time.Second
	// JumpThreshold is the clock jump (and the lateness) beyond which due jobs are treated as missed.
	JumpThreshold = 2 * time.Minute

	// maxCatchUpScan bounds the walk from the first missed fire to the latest one.
	maxCatchUpScan = 5000
)

// Notifier delivers a state-change alert. Step 7 supplies the Discord implementation.
//
// Notify must not block: the scheduler calls it from its main loop and from run goroutines, so a slow delivery
// would stall every tick. An implementation queues the message internally and delivers it from its own goroutine.
type Notifier interface {
	Notify(msg string)
}

// Caller makes the HTTP call for one run; *dispatch.Dispatcher is the production implementation.
type Caller interface {
	Call(ctx context.Context, r dispatch.Request) dispatch.Result
}

// Config wires a Scheduler.
type Config struct {
	Clock        clock.Clock
	RegistryRoot string // <root>/<app>/app.yaml
	WindowPath   string // backup window.env
	StateDir     string // jobs-state: schedule.tsv
	Caller       Caller
	History      *history.Writer
	Status       *history.Status
	Notifier     Notifier
	Log          *logx.Logger
	// NewRunID returns a fresh run id; the default is a ULID stamped with the clock.
	NewRunID func() string
}

type jobKey struct{ app, job string }

// persistedRow is one schedule.tsv row: last_fired, and the pending deferral of a catch_up run when there is one.
type persistedRow struct {
	lastFired   time.Time
	deferred    time.Time
	deferredFor time.Time
}

type jobState struct {
	app    string
	port   int
	job    registry.Job
	offset time.Duration

	lastFired time.Time
	nextDue   time.Time
	// deferred is the instant a catch_up job refused by the window runs once, at the window END plus its offset.
	deferred    time.Time
	deferredFor time.Time

	lastResult  string
	lastStarted time.Time
	lastEnded   time.Time
	noSecret    bool
}

// runJob is the immutable view of a job a run goroutine works from, so a registry reload cannot change it
// mid-run.
type runJob struct {
	key     jobKey
	port    int
	timeout time.Duration
	catchUp bool
	offset  time.Duration
}

// Scheduler fires jobs. Create it with New and call Run.
type Scheduler struct {
	cfg Config

	mu        sync.Mutex
	jobs      map[jobKey]*jobState
	invalid   map[string]string // app directory -> reason it is disabled_invalid_config
	hash      string
	loaded    bool
	persisted map[jobKey]persistedRow // rows read from schedule.tsv at start; nil after the first reload
	winState  string                  // "", ok, invalid
	zone      *time.Location
	zoneName  string
	inflight  map[jobKey]bool

	sem   chan struct{}
	wake  chan struct{}
	ready chan struct{}

	flushMu sync.Mutex
	stateMu sync.Mutex
	wg      sync.WaitGroup
	root    context.Context

	// test hooks
	ticksDone  atomic.Int64
	capWaiting atomic.Int32
}

// New returns a Scheduler. It does nothing until Run.
func New(cfg Config) *Scheduler {
	if cfg.NewRunID == nil {
		clk := cfg.Clock
		cfg.NewRunID = func() string { return clock.NewULID(clk.Now()) }
	}
	return &Scheduler{
		cfg:      cfg,
		jobs:     map[jobKey]*jobState{},
		invalid:  map[string]string{},
		inflight: map[jobKey]bool{},
		sem:      make(chan struct{}, MaxConcurrent),
		wake:     make(chan struct{}, 1),
		ready:    make(chan struct{}),
		root:     context.Background(),
	}
}

// Ready is closed once the first scan is done and the scheduling timers are armed.
func (s *Scheduler) Ready() <-chan struct{} { return s.ready }

func (s *Scheduler) now() time.Time { return s.cfg.Clock.Now() }

func (s *Scheduler) logf(format string, a ...any) { s.cfg.Log.Printf(format, a...) }

func (s *Scheduler) notify(msg string) {
	s.logf("alert %s", msg)
	if s.cfg.Notifier != nil {
		s.cfg.Notifier.Notify(msg)
	}
}

func offsetFor(app, job string) time.Duration {
	h := fnv.New32a()
	_, _ = h.Write([]byte(app + "/" + job))
	return time.Duration(h.Sum32()%60) * time.Second
}

// Run blocks until ctx ends, then waits for the runs still in flight (their requests are cancelled with ctx).
func (s *Scheduler) Run(ctx context.Context) {
	s.root = ctx
	if err := os.MkdirAll(s.cfg.StateDir, 0o700); err != nil {
		s.logf("state mkdir_failed dir=%s err=%q", s.cfg.StateDir, err.Error())
	}
	s.loadStateFile()
	_, _ = s.windowDecision() // sets the zone and window_state before any next_due is computed
	s.reload()
	tick := s.cfg.Clock.NewTicker(ReloadEvery)
	defer tick.Stop()
	lastWall := s.now()
	s.processDue(true) // the start-up missed-run scan
	armed := false
	for {
		s.processDue(false)
		var timer <-chan time.Time
		if due, ok := s.earliest(); ok {
			timer = s.cfg.Clock.After(due.Sub(s.now()))
		}
		if !armed {
			armed = true
			close(s.ready)
		}
		select {
		case <-ctx.Done():
			s.wg.Wait()
			return
		case <-s.wake:
		case <-timer:
		case <-tick.C():
			now := s.now()
			jumped := now.Sub(lastWall)-ReloadEvery > JumpThreshold
			lastWall = now
			_, _ = s.windowDecision()
			s.reload()
			if jumped {
				s.logf("clock jump detected: scanning for missed runs")
				s.processDue(false) // a fire that is on time keeps its schedule trigger
				s.processDue(true)
			}
			s.ticksDone.Add(1)
		}
	}
}

func (s *Scheduler) kick() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

// earliest returns the soonest next_due or deferred instant.
func (s *Scheduler) earliest() (time.Time, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var best time.Time
	for _, js := range s.jobs {
		for _, t := range []time.Time{js.nextDue, js.deferred} {
			if !t.IsZero() && (best.IsZero() || t.Before(best)) {
				best = t
			}
		}
	}
	return best, !best.IsZero()
}

// location returns the zone cron schedules are evaluated in; the caller holds s.mu.
func (s *Scheduler) location() *time.Location {
	if s.zone != nil {
		return s.zone
	}
	return time.UTC
}

// nextFire returns the first fire instant strictly after `after` (cron minute plus the job offset), or the zero
// Time for an enqueue-only job. The caller holds s.mu.
func (s *Scheduler) nextFire(js *jobState, after time.Time) time.Time {
	if js.job.Cron == nil {
		return time.Time{}
	}
	m := js.job.Cron.Next(after.Add(-js.offset), s.location())
	if m.IsZero() {
		return time.Time{}
	}
	return m.Add(js.offset)
}

// windowDecision re-reads window.env by name. It updates runner.tsv window_state, the schedule zone and, on a
// change of state, alerts once and rewrites jobs.tsv.
func (s *Scheduler) windowDecision() (window.Window, error) {
	w, err := window.Load(s.cfg.WindowPath)
	state := "ok"
	if err != nil {
		state = "invalid"
	}
	var alert string
	changed := false
	s.mu.Lock()
	prev := s.winState
	if prev != state {
		changed = true
		s.winState = state
		switch {
		case state == "invalid":
			alert = "backup window file is invalid, all runs are refused: " + err.Error()
		case prev == "invalid":
			alert = "backup window file is valid again, runs resume"
		}
	}
	if err == nil && s.zoneName != w.TZ {
		changed = true // next_due moves with the zone, so jobs.tsv and the timers need a refresh
		first := s.zoneName == ""
		s.zone, s.zoneName = w.Loc, w.TZ
		now := s.now()
		for _, js := range s.jobs {
			// The first zone read only fixes the zone next_due was computed in (UTC until then): lastFired is an
			// instant and stays, so the runs missed meanwhile are still caught up or recorded. A later zone
			// change restarts the schedule from now.
			if !first {
				js.lastFired = now
			}
			js.nextDue = s.nextFire(js, js.lastFired)
		}
	}
	s.mu.Unlock()
	s.cfg.Status.SetWindow(state)
	if changed {
		s.logf("state window_state=%s", state)
		if alert != "" {
			s.notify(alert)
		}
		s.flushJobs()
		s.kick()
	}
	return w, err
}

// registryHash fingerprints what the scheduler reads from the registry.
func registryHash(entries []registry.Entry) string {
	h := sha256.New()
	for _, e := range entries {
		fmt.Fprintf(h, "dir=%s\n", e.Dir)
		if e.Err != nil {
			fmt.Fprintf(h, "err=%s\n", e.Err.Error())
			continue
		}
		fmt.Fprintf(h, "port=%d\n", e.App.Port)
		for _, j := range e.App.Jobs {
			fmt.Fprintf(h, "job=%s|%s|%d|%t\n", j.Name, j.Schedule, j.Timeout, j.CatchUp)
		}
	}
	return hex.EncodeToString(h.Sum(nil))
}

// reload re-reads the registry; unchanged content (by hash) changes nothing.
func (s *Scheduler) reload() {
	entries, err := registry.Load(s.cfg.RegistryRoot)
	if err != nil {
		s.logf("registry load_failed err=%q", err.Error())
		s.cfg.Status.SetConfig("invalid")
		return
	}
	h := registryHash(entries)
	s.mu.Lock()
	if s.loaded && h == s.hash {
		s.mu.Unlock()
		return
	}
	now := s.now()
	seen := map[jobKey]bool{}
	invalid := map[string]string{}
	var added, removed, changed int
	for _, e := range entries {
		if e.Err != nil {
			invalid[e.Dir] = e.Err.Error()
			continue
		}
		for _, j := range e.App.Jobs {
			k := jobKey{e.App.Name, j.Name}
			seen[k] = true
			js, ok := s.jobs[k]
			if !ok {
				js = &jobState{app: k.app, job: j, port: e.App.Port, offset: offsetFor(k.app, k.job)}
				js.lastFired = now
				if p, found := s.persisted[k]; found {
					js.lastFired = p.lastFired
					if j.CatchUp {
						js.deferred, js.deferredFor = p.deferred, p.deferredFor
					}
				}
				js.nextDue = s.nextFire(js, js.lastFired)
				s.jobs[k] = js
				added++
				continue
			}
			js.port = e.App.Port
			if js.job.Schedule != j.Schedule || js.job.Timeout != j.Timeout || js.job.CatchUp != j.CatchUp {
				scheduleChanged := js.job.Schedule != j.Schedule
				js.job = j
				if scheduleChanged {
					js.lastFired = now
					js.nextDue = s.nextFire(js, now)
					js.deferred, js.deferredFor = time.Time{}, time.Time{}
				}
				if !j.CatchUp {
					js.deferred, js.deferredFor = time.Time{}, time.Time{}
				}
				changed++
			}
		}
	}
	for k := range s.jobs {
		if !seen[k] { // a removed app or job, or an app now disabled: stop scheduling; in-flight runs finish
			delete(s.jobs, k)
			removed++
		}
	}
	var alerts []string
	for dir, reason := range invalid {
		if s.invalid[dir] != reason {
			alerts = append(alerts, fmt.Sprintf("app %s is disabled, invalid config: %s", dir, reason))
		}
	}
	for dir := range s.invalid {
		if _, still := invalid[dir]; !still {
			alerts = append(alerts, fmt.Sprintf("app %s config is valid again or the app was removed", dir))
		}
	}
	sort.Strings(alerts)
	s.invalid, s.hash, s.loaded, s.persisted = invalid, h, true, nil
	s.mu.Unlock()

	s.logf("registry reload apps=%d jobs_added=%d jobs_removed=%d jobs_changed=%d invalid_apps=%d", len(entries), added, removed, changed, len(invalid))
	if len(invalid) > 0 {
		s.cfg.Status.SetConfig("invalid")
	} else {
		s.cfg.Status.SetConfig("ok")
	}
	for _, a := range alerts {
		s.notify(a)
	}
	s.saveState()
	s.flushJobs()
	s.kick()
}

type launch struct {
	j            runJob
	trigger      string
	scheduledFor time.Time
	skipMissed   bool
}

// processDue starts every job that is due. With force (start-up, or a clock jump) and for a job later than
// JumpThreshold, the due time counts as missed: a catch_up job runs once, any other job is recorded as
// skipped_missed. One record per job, however many fires were missed.
func (s *Scheduler) processDue(force bool) {
	now := s.now()
	var todo []launch
	s.mu.Lock()
	keys := make([]jobKey, 0, len(s.jobs))
	for k := range s.jobs {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		if keys[i].app != keys[j].app {
			return keys[i].app < keys[j].app
		}
		return keys[i].job < keys[j].job
	})
	dirty := false
	for _, k := range keys {
		js := s.jobs[k]
		rj := runJob{key: k, port: js.port, timeout: js.job.Timeout, catchUp: js.job.CatchUp, offset: js.offset}
		if !js.deferred.IsZero() && !js.deferred.After(now) {
			todo = append(todo, launch{j: rj, trigger: "catch_up", scheduledFor: js.deferredFor})
			js.deferred, js.deferredFor = time.Time{}, time.Time{}
			dirty = true // the deferral is persisted, so clearing it is too
		}
		if js.nextDue.IsZero() || js.nextDue.After(now) {
			continue
		}
		dirty = true
		if force || now.Sub(js.nextDue) > JumpThreshold {
			latest := js.nextDue
			capped := true
			for i := 0; i < maxCatchUpScan; i++ {
				n := s.nextFire(js, latest)
				if n.IsZero() || n.After(now) {
					capped = false
					break
				}
				latest = n
			}
			js.lastFired = latest
			if capped {
				// A dense schedule after a long outage has more missed fires than one scan covers. Move the
				// marker past the scanned range (to now) so the next scan does not start again from the same
				// fires and regenerate the same skipped_missed record; the one record per job still stands.
				js.lastFired = now
				s.logf("missed app=%s job=%s scan_capped=%d marker=%s", k.app, k.job, maxCatchUpScan, now.UTC().Format(time.RFC3339))
			}
			js.nextDue = s.nextFire(js, js.lastFired)
			if js.job.CatchUp {
				todo = append(todo, launch{j: rj, trigger: "catch_up", scheduledFor: latest})
			} else {
				todo = append(todo, launch{j: rj, trigger: "schedule", scheduledFor: latest, skipMissed: true})
			}
			continue
		}
		due := js.nextDue
		js.lastFired, js.nextDue = due, s.nextFire(js, due)
		todo = append(todo, launch{j: rj, trigger: "schedule", scheduledFor: due})
	}
	s.mu.Unlock()
	if dirty {
		s.saveState()
	}
	for _, l := range todo {
		if l.skipMissed {
			s.logf("missed app=%s job=%s scheduled_for=%s catch_up=false", l.j.key.app, l.j.key.job, l.scheduledFor.UTC().Format(time.RFC3339))
			s.skip(l.j, l.trigger, l.scheduledFor, "skipped_missed", "missed while the runner was not running")
			continue
		}
		l := l
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			s.execute(l.j, l.trigger, l.scheduledFor)
		}()
	}
	if len(todo) > 0 || dirty {
		s.flushJobs()
	}
}

// tryStart takes the (app, job) single-flight; the second caller gets false. Queued runs (Step 7) share it.
func (s *Scheduler) tryStart(k jobKey) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.inflight[k] {
		return false
	}
	s.inflight[k] = true
	return true
}

func (s *Scheduler) finish(k jobKey) {
	s.mu.Lock()
	delete(s.inflight, k)
	s.mu.Unlock()
}

// acquireSlot takes one of the MaxConcurrent slots, waiting up to CapWait.
func (s *Scheduler) acquireSlot() bool {
	select {
	case s.sem <- struct{}{}:
		return true
	default:
	}
	s.capWaiting.Add(1)
	defer s.capWaiting.Add(-1)
	select {
	case s.sem <- struct{}{}:
		return true
	case <-s.cfg.Clock.After(CapWait):
		return false
	case <-s.root.Done():
		return false
	}
}

func (s *Scheduler) releaseSlot() { <-s.sem }

// windowAllows applies the backup-window rule at the moment a run would start. It records the skip itself.
func (s *Scheduler) windowAllows(j runJob, trigger string, scheduledFor time.Time) bool {
	now := s.now()
	w, err := s.windowDecision()
	if err != nil {
		// Fail closed and no deferral, even for a catch_up job: a catch_up run refused because window.env is
		// invalid is lost, and the next fire is the retry (documented in the README).
		s.skip(j, trigger, scheduledFor, "refused_config", "window.env invalid: "+err.Error())
		return false
	}
	if !w.Refuses(now, j.timeout) {
		return true
	}
	reason := fmt.Sprintf("backup window %s-%s %s, timeout %s", w.Start, w.End, w.TZ, j.timeout)
	s.skip(j, trigger, scheduledFor, "skipped_window", reason)
	if j.catchUp {
		at := w.EndOn(now).Add(j.offset)
		set := false
		s.mu.Lock()
		if js := s.jobs[j.key]; js != nil && js.deferred.IsZero() {
			js.deferred, js.deferredFor = at, scheduledFor
			set = true
			s.logf("defer app=%s job=%s until=%s reason=window", j.key.app, j.key.job, at.UTC().Format(time.RFC3339))
		}
		s.mu.Unlock()
		if set {
			s.saveState() // a restart before the window ends must still run it
		}
		s.kick()
	}
	return false
}

// execute runs one scheduled or catch-up run to its record.
func (s *Scheduler) execute(j runJob, trigger string, scheduledFor time.Time) {
	if !s.windowAllows(j, trigger, scheduledFor) {
		return
	}
	if !s.tryStart(j.key) {
		s.skip(j, trigger, scheduledFor, "skipped_overlap", "the previous run of this job is still in flight")
		return
	}
	defer s.finish(j.key)
	if !s.acquireSlot() {
		s.skip(j, trigger, scheduledFor, "skipped_cap", fmt.Sprintf("no free slot of %d within %s", MaxConcurrent, CapWait))
		return
	}
	defer s.releaseSlot()
	if !s.windowAllows(j, trigger, scheduledFor) { // the wait for a slot may have reached the window
		return
	}

	runID := s.cfg.NewRunID()
	started := s.now()
	s.logf("run start app=%s job=%s trigger=%s run_id=%s", j.key.app, j.key.job, trigger, runID)
	res := s.cfg.Caller.Call(s.root, dispatch.Request{
		App: j.key.app, Port: j.port, Job: j.key.job, Timeout: j.timeout, RunID: runID,
		Trigger: trigger, Attempt: 1, ScheduledFor: scheduledFor,
	})
	ended := s.now()

	result, errText := "ok", ""
	switch {
	case res.NoSecret:
		result, errText = "skipped_no_secret", res.Err
	case res.Class != dispatch.ClassOK && !res.Timeout && s.root.Err() != nil:
		// The runner is stopping (SIGTERM), so the cancelled call is a planned stop, not an app failure: record it
		// apart from `failed` and send no alert, as the queue path does.
		result, errText = "interrupted", "the runner stopped while the run was in flight"
	case res.Timeout:
		result, errText = "timeout", res.Err
	case res.Class != dispatch.ClassOK:
		result, errText = "failed", res.Err
	}
	s.setNoSecret(j.key, res.NoSecret)
	rec := history.Run{
		RunID: runID, App: j.key.app, Job: j.key.job, Trigger: trigger, ScheduledFor: scheduledFor,
		Started: started, Ended: ended, HTTPStatus: res.HTTPStatus, Result: result, Attempt: 1, Err: errText,
	}
	if res.NoSecret {
		rec.Attempt = 0
	}
	s.record(rec)
	s.logf("run end app=%s job=%s trigger=%s run_id=%s result=%s http=%d dur_ms=%d", j.key.app, j.key.job, trigger, runID, result, res.HTTPStatus, ended.Sub(started).Milliseconds())
	if result == "failed" || result == "timeout" { // collapsed per (app, job, result) by the notifier
		s.alertRun(j.key.app, j.key.job, result, fmt.Sprintf("scheduled job %s/%s %s (attempt %d, http %d): %s", j.key.app, j.key.job, result, rec.Attempt, res.HTTPStatus, errText))
	}
}

// setNoSecret tracks state=disabled_no_secret and alerts once per change.
func (s *Scheduler) setNoSecret(k jobKey, now bool) {
	var alert string
	s.mu.Lock()
	if js := s.jobs[k]; js != nil && js.noSecret != now {
		js.noSecret = now
		if now {
			alert = fmt.Sprintf("job %s/%s is disabled: its jobs-secret is missing or unusable", k.app, k.job)
		} else {
			alert = fmt.Sprintf("job %s/%s has a usable jobs-secret again", k.app, k.job)
		}
	}
	s.mu.Unlock()
	if alert != "" {
		s.notify(alert)
	}
}

// skip records a run that did not start.
func (s *Scheduler) skip(j runJob, trigger string, scheduledFor time.Time, result, why string) {
	now := s.now()
	id := s.cfg.NewRunID()
	s.logf("run skip app=%s job=%s trigger=%s run_id=%s result=%s why=%q", j.key.app, j.key.job, trigger, id, result, why)
	s.record(history.Run{
		RunID: id, App: j.key.app, Job: j.key.job, Trigger: trigger, ScheduledFor: scheduledFor,
		Started: now, Ended: now, Result: result, Err: why,
	})
}

// record appends the run line, updates the job's last_* fields and rewrites jobs.tsv.
func (s *Scheduler) record(r history.Run) {
	if err := s.cfg.History.AppendRun(r); err != nil {
		s.logf("history append_failed run_id=%s err=%q", r.RunID, err.Error())
	}
	s.mu.Lock()
	if js := s.jobs[jobKey{r.App, r.Job}]; js != nil {
		js.lastResult, js.lastStarted, js.lastEnded = r.Result, r.Started, r.Ended
	}
	s.mu.Unlock()
	s.flushJobs()
}

// flushJobs rewrites jobs.tsv from the current state, serialised so an older snapshot never overwrites a newer.
func (s *Scheduler) flushJobs() {
	s.flushMu.Lock()
	defer s.flushMu.Unlock()
	s.mu.Lock()
	winInvalid := s.winState == "invalid"
	rows := make([]history.JobRow, 0, len(s.jobs)+len(s.invalid))
	for _, js := range s.jobs {
		state := "ok"
		switch {
		case winInvalid:
			state = "window_refused"
		case js.noSecret:
			state = "disabled_no_secret"
		}
		rows = append(rows, history.JobRow{
			App: js.app, Job: js.job.Name, Schedule: js.job.Schedule, CatchUp: js.job.CatchUp,
			LastResult: js.lastResult, LastStarted: js.lastStarted, LastEnded: js.lastEnded,
			NextDue: js.nextDue, State: state,
		})
	}
	for dir := range s.invalid { // the declared jobs of an invalid file are unknown: one placeholder row
		rows = append(rows, history.JobRow{App: dir, Job: "-", State: "disabled_invalid_config"})
	}
	s.mu.Unlock()
	if err := s.cfg.History.WriteJobs(rows); err != nil {
		s.logf("history write_failed file=jobs.tsv err=%q", err.Error())
	}
}

func (s *Scheduler) stateFile() string { return filepath.Join(s.cfg.StateDir, "schedule.tsv") }

// saveState persists last_fired per (app, job) (temp + rename).
func (s *Scheduler) saveState() {
	s.stateMu.Lock()
	defer s.stateMu.Unlock()
	s.mu.Lock()
	lines := make([]string, 0, len(s.jobs))
	for k, js := range s.jobs {
		line := k.app + "\t" + k.job + "\t" + js.lastFired.UTC().Format(time.RFC3339)
		if !js.deferred.IsZero() {
			line += "\t" + js.deferred.UTC().Format(time.RFC3339) + "\t" + js.deferredFor.UTC().Format(time.RFC3339)
		}
		lines = append(lines, line)
	}
	s.mu.Unlock()
	sort.Strings(lines)
	data := strings.Join(lines, "\n")
	if data != "" {
		data += "\n"
	}
	if err := history.WriteAtomic(s.stateFile(), []byte(data), 0o600); err != nil {
		s.logf("state write_failed file=schedule.tsv err=%q", err.Error())
	}
}

// loadStateFile reads schedule.tsv. A missing file means first start: no catch-up.
func (s *Scheduler) loadStateFile() {
	b, err := os.ReadFile(s.stateFile())
	if err != nil {
		if os.IsNotExist(err) {
			s.logf("state schedule_state=absent")
		} else {
			s.logf("state schedule_state=unreadable err=%q", err.Error())
		}
		return
	}
	rows := map[jobKey]persistedRow{}
	for _, line := range strings.Split(strings.TrimSuffix(string(b), "\n"), "\n") {
		if line == "" {
			continue
		}
		cols := strings.Split(line, "\t")
		if len(cols) != 3 && len(cols) != 5 { // app, job, last_fired[, deferred_until, deferred_for]
			s.logf("state schedule_state=bad_row")
			continue
		}
		var row persistedRow
		var err error
		if row.lastFired, err = time.Parse(time.RFC3339, cols[2]); err != nil {
			s.logf("state schedule_state=bad_row")
			continue
		}
		if len(cols) == 5 {
			var errA, errB error
			row.deferred, errA = time.Parse(time.RFC3339, cols[3])
			row.deferredFor, errB = time.Parse(time.RFC3339, cols[4])
			if errA != nil || errB != nil {
				s.logf("state schedule_state=bad_row")
				continue
			}
		}
		rows[jobKey{cols[0], cols[1]}] = row
	}
	s.mu.Lock()
	s.persisted = rows
	s.mu.Unlock()
	s.logf("state schedule_state=present rows=%d", len(rows))
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/sched/sched.go

# BEGIN-PAYLOAD platform/jobs/internal/window/window.go
payload_window_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
// Package window reads the backup window (platform/backup/window.env) with the exact rules of backup.sh
// load_window, but fails closed: any defect is an error, never "disabled".
//
// Load is a function of the path and caches nothing; callers invoke it by name on every window decision.
package window

import (
	"fmt"
	"os"
	"regexp"
	"strings"
	"time"
	_ "time/tzdata" // the runner image has no zoneinfo; the zone database is embedded
)

const (
	keyStart = "BACKUP_WINDOW_START"
	keyEnd   = "BACKUP_WINDOW_END"
	keyTZ    = "BACKUP_WINDOW_TZ"
)

var (
	hhmmRE = regexp.MustCompile(`^([01][0-9]|2[0-3]):[0-5][0-9]$`)
	tzRE   = regexp.MustCompile(`^[A-Za-z0-9_/+-]+$`)
)

// Window is a parsed, valid backup window: the half-open range [Start, End) of wall-clock minutes of the day
// in Loc. It never wraps midnight (Start < End).
type Window struct {
	Start string // "HH:MM"
	End   string // "HH:MM"
	TZ    string
	Loc   *time.Location

	startMin, endMin int
}

// Load reads and validates the window file at path.
func Load(path string) (Window, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return Window{}, fmt.Errorf("window file unreadable: %w", err)
	}
	return Parse(b)
}

// Parse validates window.env content. Rules, as in backup.sh load_window: lines are read literally (no
// trimming); empty lines and lines starting with # are skipped; every other line must be KEY=VALUE with a key
// that is one of the three known ones, each at most once; START and END are HH:MM; START < END; TZ matches
// [A-Za-z0-9_/+-]+ and names a known zone.
func Parse(b []byte) (Window, error) {
	if strings.IndexByte(string(b), 0) >= 0 {
		return Window{}, fmt.Errorf("window file contains a NUL byte")
	}
	var s, e, z string
	seen := map[string]bool{}
	lines := strings.Split(string(b), "\n")
	if lines[len(lines)-1] == "" { // the final LF; an unterminated last line is still read
		lines = lines[:len(lines)-1]
	}
	for _, line := range lines {
		if line == "" || line[0] == '#' {
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if !ok {
			return Window{}, fmt.Errorf("window file has a malformed line")
		}
		if seen[key] {
			return Window{}, fmt.Errorf("window file repeats %s", key)
		}
		seen[key] = true
		switch key {
		case keyStart:
			s = val
		case keyEnd:
			e = val
		case keyTZ:
			z = val
		default:
			return Window{}, fmt.Errorf("window file has an unknown key")
		}
	}
	for _, k := range []string{keyStart, keyEnd, keyTZ} {
		if !seen[k] {
			return Window{}, fmt.Errorf("window file is missing %s", k)
		}
	}
	if !hhmmRE.MatchString(s) {
		return Window{}, fmt.Errorf("%s %q is not HH:MM", keyStart, s)
	}
	if !hhmmRE.MatchString(e) {
		return Window{}, fmt.Errorf("%s %q is not HH:MM", keyEnd, e)
	}
	if !tzRE.MatchString(z) {
		return Window{}, fmt.Errorf("%s %q has characters outside [A-Za-z0-9_/+-]", keyTZ, z)
	}
	if !(s < e) {
		return Window{}, fmt.Errorf("window START %s must be before END %s (no midnight wrap)", s, e)
	}
	if z == "Local" {
		return Window{}, fmt.Errorf("%s %q is not an explicit zone", keyTZ, z)
	}
	loc, err := time.LoadLocation(z)
	if err != nil {
		return Window{}, fmt.Errorf("%s %q is not a known zone: %w", keyTZ, z, err)
	}
	return Window{Start: s, End: e, TZ: z, Loc: loc, startMin: minutes(s), endMin: minutes(e)}, nil
}

// StartOn returns the instant the window starts on t's civil date in the window zone.
func (w Window) StartOn(t time.Time) time.Time { return w.at(t, w.startMin) }

// EndOn returns the instant the window ends on t's civil date in the window zone.
func (w Window) EndOn(t time.Time) time.Time { return w.at(t, w.endMin) }

func (w Window) at(t time.Time, min int) time.Time {
	l := t.In(w.Loc)
	return time.Date(l.Year(), l.Month(), l.Day(), min/60, min%60, 0, 0, w.Loc)
}

// Refuses reports whether a run that begins at fire and may last timeout must not start: fire is inside
// [Start, End), or fire is before Start on the same day and fire+timeout is after Start (a run that ends exactly
// as the window opens is allowed).
func (w Window) Refuses(fire time.Time, timeout time.Duration) bool {
	if w.Contains(fire) {
		return true
	}
	start := w.StartOn(fire)
	return fire.Before(start) && fire.Add(timeout).After(start)
}

func minutes(hhmm string) int {
	return int(hhmm[0]-'0')*600 + int(hhmm[1]-'0')*60 + int(hhmm[3]-'0')*10 + int(hhmm[4]-'0')
}

// Contains reports whether t's wall-clock time in the window zone is in [Start, End): 04:59:59 is inside a
// window ending 05:00, 05:00:00 is not.
func (w Window) Contains(t time.Time) bool {
	l := t.In(w.Loc)
	m := l.Hour()*60 + l.Minute()
	return m >= w.startMin && m < w.endMin
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/internal/window/window.go

# BEGIN-PAYLOAD platform/jobs/Dockerfile.testapp
payload_Dockerfile_testapp() {
  cat <<'PLATFORM_PAYLOAD_EOF'
# Jobs test app image (testapp-up only; never part of the runner image). A package in the same module as the runner, but
# it imports only the standard library, so only go.mod and go.sum are needed beside it. Same digest pins as the
# runner Dockerfile; the builder tag must equal platform/jobs/GO_VERSION.
FROM golang:1.26.0@sha256:fb612b7831d53a89cbc0aaa7855b69ad7b0caf603715860cf538df854d047b84 AS build
ARG VERSION=dev
ENV GOTOOLCHAIN=local
WORKDIR /src
COPY go.mod go.sum ./
COPY testapp/testapp_handler.go testapp/testapp_main.go ./testapp/
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /testapp ./testapp

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /testapp /testapp
USER 65532:65532
ENTRYPOINT ["/testapp"]
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/Dockerfile.testapp

# BEGIN-PAYLOAD platform/jobs/testapp/testapp_main.go
payload_testapp_main_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
package main

import (
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	h, err := newHandlerFromEnv(os.Getenv)
	if err != nil {
		log.Fatalf("testapp: cannot start: %v", err)
	}
	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	srv := &http.Server{Addr: addr, Handler: h, ReadHeaderTimeout: 10 * time.Second}
	log.Printf("testapp: listening on %s", addr)
	log.Fatal(srv.ListenAndServe())
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/testapp/testapp_main.go

# BEGIN-PAYLOAD platform/jobs/testapp/testapp_handler.go
payload_testapp_handler_go() {
  cat <<'PLATFORM_PAYLOAD_EOF'
// Command testapp is a minimal app that implements the full jobs CONTRACT for the runner's tests. It uses only the
// standard library and never imports runner packages, so it stays an independent check of the contract.
package main

import (
	"crypto/subtle"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
)

// DefaultDeclared is the job list used when JOBS_DECLARED is unset: ok-job always succeeds and always-fail always
// answers 503 (a retryable failure). testapp-up writes the same list into the app.yaml it registers.
const DefaultDeclared = "ok-job,always-fail"

const (
	jobPrefix   = "/_jobs/"
	maxBodySize = 1 << 20
	failingJob  = "always-fail"
)

// jobRequest is the POST body (CONTRACT v1). Nullable fields are kept as raw values: the testapp only validates
// the ones it needs.
type jobRequest struct {
	V        int             `json:"v"`
	RunID    string          `json:"run_id"`
	Job      string          `json:"job"`
	Trigger  string          `json:"trigger"`
	Attempt  int             `json:"attempt"`
	QueueID  *string         `json:"queue_id"`
	Payload  json.RawMessage `json:"payload"`
	Enqueued *string         `json:"enqueued_at"`
}

// handler serves POST /_jobs/<name>.
type handler struct {
	secret   string
	declared map[string]bool
	logf     func(format string, a ...any)

	mu   sync.Mutex
	done map[string]bool // idempotency keys of calls that succeeded
}

// newHandler returns the CONTRACT handler for a secret and a comma-separated declared job list.
func newHandler(secret, declared string, logf func(string, ...any)) *handler {
	d := map[string]bool{}
	for _, n := range strings.Split(declared, ",") {
		if n = strings.TrimSpace(n); n != "" {
			d[n] = true
		}
	}
	return &handler{secret: secret, declared: d, logf: logf, done: map[string]bool{}}
}

// newHandlerFromEnv reads JOBS_SECRET_FILE and JOBS_DECLARED. A missing or empty secret is an error (fail closed).
func newHandlerFromEnv(getenv func(string) string) (*handler, error) {
	path := getenv("JOBS_SECRET_FILE")
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	secret := strings.TrimSpace(string(b))
	if secret == "" {
		return nil, io.ErrUnexpectedEOF
	}
	declared := getenv("JOBS_DECLARED")
	if declared == "" {
		declared = DefaultDeclared
	}
	return newHandler(secret, declared, log.Printf), nil
}

func (h *handler) authorized(r *http.Request) bool {
	got := r.Header.Get("Authorization")
	want := "Bearer " + h.secret
	return subtle.ConstantTimeCompare([]byte(got), []byte(want)) == 1
}

func (h *handler) reply(w http.ResponseWriter, r *http.Request, job string, status int, why string) {
	h.logf("call job=%q status=%d run_id=%q why=%q", clip(job), status, clip(r.Header.Get("X-Platform-Run-Id")), why)
	// The body is a fixed plain-text reason and never echoes a request value; the headers keep a browser from
	// sniffing it as HTML.
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, why+"\n")
}

// ServeHTTP checks in this order: method (405), bearer (401), declared job (404), body (400), idempotency (200),
// always-fail (503), then success (200).
func (h *handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	job := strings.TrimPrefix(r.URL.Path, jobPrefix)
	if !strings.HasPrefix(r.URL.Path, jobPrefix) || job == "" || strings.Contains(job, "/") {
		h.reply(w, r, job, http.StatusNotFound, "not found")
		return
	}
	if r.Method != http.MethodPost {
		h.reply(w, r, job, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if !h.authorized(r) {
		h.reply(w, r, job, http.StatusUnauthorized, "unauthorized")
		return
	}
	if !h.declared[job] {
		h.reply(w, r, job, http.StatusNotFound, "job not declared")
		return
	}
	var req jobRequest
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBodySize))
	if err != nil || json.Unmarshal(body, &req) != nil || req.V != 1 || req.RunID == "" || req.Job != job || req.Attempt < 1 {
		h.reply(w, r, job, http.StatusBadRequest, "bad request body")
		return
	}
	key := req.RunID
	if req.QueueID != nil && *req.QueueID != "" {
		key = *req.QueueID
	}
	if job == failingJob {
		h.reply(w, r, job, http.StatusServiceUnavailable, "always-fail")
		return
	}
	h.mu.Lock()
	repeat := h.done[key]
	h.done[key] = true
	h.mu.Unlock()
	if repeat {
		h.reply(w, r, job, http.StatusOK, "already done")
		return
	}
	h.reply(w, r, job, http.StatusOK, "ok")
}

// clip bounds an untrusted value before it is logged (callers print it with %q, which escapes newlines).
func clip(s string) string {
	const max = 80
	if len(s) > max {
		return s[:max]
	}
	return s
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/jobs/testapp/testapp_handler.go

# runner_inputs: "<path under platform/jobs> <payload function>" for every group 1 BUILD INPUT (compose.yaml is applied by
# `compose up`, not built into the image, so it is not here). The image tag is a hash of exactly these files.
runner_inputs() {
  cat <<'LIST'
go.mod payload_go_mod
go.sum payload_go_sum
Dockerfile payload_Dockerfile
cmd/runner/runner_main.go payload_runner_main_go
cmd/runner/runner_healthcheck.go payload_runner_healthcheck_go
internal/health/health.go payload_health_go
internal/clock/clock.go payload_clock_go
internal/clock/fake.go payload_fake_go
internal/clock/real.go payload_real_go
internal/cron/cron.go payload_cron_go
internal/dispatch/dispatch.go payload_dispatch_go
internal/history/atomic.go payload_atomic_go
internal/history/history.go payload_history_go
internal/history/status.go payload_status_go
internal/logx/logx.go payload_logx_go
internal/mask/mask.go payload_mask_go
internal/notify/discord.go payload_discord_go
internal/notify/env.go payload_env_go
internal/queue/consumer.go payload_consumer_go
internal/queue/envelope.go payload_envelope_go
internal/queue/recover.go payload_recover_go
internal/queue/redisstate.go payload_redisstate_go
internal/queue/redisstore.go payload_redisstore_go
internal/queue/store.go payload_store_go
internal/queue/take.go payload_take_go
internal/queue/writes.go payload_writes_go
internal/registry/registry.go payload_registry_go
internal/registry/reserved-names.txt payload_reserved_names_txt
internal/sched/queue.go payload_queue_go
internal/sched/sched.go payload_sched_go
internal/window/window.go payload_window_go
LIST
}

# testapp_inputs: group 2 (the test app's own files). Its build also needs group 1's go.mod and go.sum.
testapp_inputs() {
  cat <<'LIST'
Dockerfile.testapp payload_Dockerfile_testapp
testapp/testapp_main.go payload_testapp_main_go
testapp/testapp_handler.go payload_testapp_handler_go
LIST
}

# write_inputs <dir> <list function> [<list function>...]: write each listed payload under <dir>/<path>.
write_inputs() {
  local dir="$1" lister path fn
  shift
  for lister in "$@"; do
    while read -r path fn; do
      mkdir -p -- "$dir/$(dirname "$path")"
      "$fn" > "$dir/$path"
    done < <("$lister")
  done
}

# source_hash <dir>: a short hash of every file below <dir> (names and contents, sorted).
source_hash() {
  ( cd -- "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) | sha256sum | cut -c1-16
}

# testapp_hash <dir>: the hash of group 2 plus group 1's go.mod and go.sum (the files the test app image build uses).
testapp_hash() {
  local d="$1/hash-testapp"
  rm -rf -- "$d"
  mkdir -p -- "$d"
  write_inputs "$d" testapp_inputs
  payload_go_mod > "$d/go.mod"
  payload_go_sum > "$d/go.sum"
  source_hash "$d"
}

# builder_ref: the pinned builder image reference (golang:<tag>@sha256:...) read from the embedded Dockerfile.
builder_ref() { payload_Dockerfile | sed -n 's/^FROM \(golang:[^ ]*\) AS build$/\1/p' | head -n 1; }

# ---- the runner's Redis user (kept equal to install-data.sh's RUNNER_ACL_RULE by a test) ----

# The password token is a placeholder: the live rule carries a #<hash> instead, so both sides drop their password token.
readonly RUNNER_ACL_RULE='runner on resetpass ><password> resetkeys ~*:jobs:* resetchannels -@all +@list +@sortedset +@string +@keyspace +@transaction +@connection -@dangerous -@scripting -@pubsub -scan -randomkey -dbsize'

# Runs redis-cli as the admin user inside the Redis container. The password is read from the mounted file inside the
# container, with exactly one trailing newline stripped (as the entrypoint's hash does), and handed over through
# REDISCLI_AUTH: it is never in an argv on the host or in the container.
# shellcheck disable=SC2016 # expanded by the shell inside the container
readonly REDIS_ADMIN_SNIPPET='f="$1"; shift; pw="$(cat "$f"; printf x)"; pw="${pw%x}"; nl="$(printf "\nx")"; nl="${nl%x}"; case "$pw" in *"$nl") pw="${pw%"$nl"}" ;; esac; REDISCLI_AUTH="$pw" exec redis-cli --user admin --no-auth-warning "$@"'
redis_admin() { dk exec "$REDIS" sh -c "$REDIS_ADMIN_SNIPPET" sh "$REDIS_CTR_ADMIN_FILE" "$@"; }

# redis_admin_stdin <line>: the same, with one command line on stdin (redis-cli runs the commands it reads). The line
# (which may carry the runner password) is printed by a shell builtin, so it never appears in any argv.
redis_admin_stdin() {
  printf '%s\n' "$1" | "${SUDO[@]}" docker exec -i "$REDIS" sh -c "$REDIS_ADMIN_SNIPPET" sh "$REDIS_CTR_ADMIN_FILE"
}

# runner_rule <password>: RUNNER_ACL_RULE with the password placeholder filled in.
runner_rule() {
  local pre="${RUNNER_ACL_RULE%%><password>*}" post="${RUNNER_ACL_RULE#*><password>}"
  printf '%s>%s%s' "$pre" "$1" "$post"
}

# acl_tok <token>: a token made safe to print. Anything that could be credential material (a hash, a password token)
# is redacted; otherwise only a conservative character class survives (no '#').
# shellcheck disable=SC2329 # reached through runner_problems
acl_tok() {
  case "$1" in
    "#"* | ">"* | "<"*) printf '<redacted>' ;;
    *) printf '%s' "${1//[^A-Za-z0-9_@:*~&%+-]/?}" ;;
  esac
}

# runner_member_diff <live set> <want set>: non-empty when the two sets have different members.
# shellcheck disable=SC2329 # reached through runner_problems
runner_member_diff() {
  local t
  set -f
  for t in $1; do [[ "$2" == *" $t "* ]] || { printf x; return 0; }; done
  for t in $2; do [[ "$1" == *" $t "* ]] || { printf x; return 0; }; done
}

# runner_problems <the runner line after "user runner">: one line per difference between the live rule and
# RUNNER_ACL_RULE. Compares token sequences after dropping the tokens Redis rewrites (on, sanitize-payload, resetpass,
# the #<hash> or ><password> token, resetkeys); never a literal string compare, and no password token is ever printed.
runner_problems() {
  local t hashes=0 want_seq="" live_seq="" want_set=" " live_set=" "
  local -a live want
  read -r -a live <<<"$1"
  read -r -a want <<<"${RUNNER_ACL_RULE#runner }"
  [[ " $1 " == *" on "* ]] || echo "the Redis runner user is not enabled"
  for t in "${live[@]}"; do
    case "$t" in
      on | sanitize-payload | resetpass | resetkeys) ;;
      "#"*) hashes=$((hashes + 1)) ;;
      *) live_seq+="$t "; live_set+="$t " ;;
    esac
  done
  [ "$hashes" -eq 1 ] || echo "the Redis runner user has $hashes password hashes, want exactly 1"
  for t in "${want[@]}"; do
    case "$t" in
      on | sanitize-payload | resetpass | resetkeys | ">"*) ;;
      *) want_seq+="$t "; want_set+="$t " ;;
    esac
  done
  set -f # the rule tokens hold '*': no globbing while they are word-split below
  for t in $live_seq; do
    [[ "$want_set" == *" $t "* ]] && continue
    case "$t" in
      "~"* | "%"* | allkeys | "&"* | allchannels) echo "the Redis runner user has an extra key or channel scope '$(acl_tok "$t")'" ;;
      *) echo "the Redis runner user has an unexpected rule '$(acl_tok "$t")'" ;;
    esac
  done
  for t in $want_seq; do
    [[ "$live_set" == *" $t "* ]] || echo "the Redis runner user lacks '$(acl_tok "$t")'"
  done
  if [ "$live_seq" != "$want_seq" ] && [ -z "$(runner_member_diff "$live_set" "$want_set")" ]; then
    echo "the Redis runner user rule differs from RUNNER_ACL_RULE in order or repetition"
  fi
  set +f
}

# runner_acl_line: the live "user runner ..." line of ACL LIST (empty when the user is absent); returns 1 when ACL LIST
# cannot be read.
runner_acl_line() {
  local text
  text="$(redis_admin acl list | tr -d '\r')" || return 1
  grep '^user runner ' <<<"$text" | head -n 1 || true
}

# acl_hash_token <runner acl line>: the single #<hash> token's hash (empty when none or more than one).
acl_hash_token() {
  local t n=0 h=""
  for t in $1; do
    case "$t" in "#"*) n=$((n + 1)); h="${t#\#}" ;; esac
  done
  [ "$n" -eq 1 ] && printf '%s' "$h"
  return 0
}

# ---- host inputs: each chk_* prints one line per problem (never a file's content) and always returns 0 ----

# file_meta <path>: "<uid>:<gid> <octal mode>".
file_meta() { priv stat -c '%u:%g %a' -- "$1"; }

deploy_uid() { getent passwd deploy | cut -d: -f3; }
deploy_gid() { getent passwd deploy | cut -d: -f4; }

# read_secret <path>: sets SECRET to the file's content with exactly one trailing newline stripped. Never printed.
read_secret() {
  local raw
  raw="$(priv cat -- "$1" 2>/dev/null && printf x)" || return 1
  raw="${raw%x}"
  if [[ "$raw" == *$'\n' ]]; then raw="${raw%$'\n'}"; fi
  SECRET="$raw"
}

# sha_of <string-from-stdin>: hex sha256.
sha_stdin() { sha256sum | cut -d ' ' -f 1; }

# compute_hashes: ENV_HASH (raw bytes of jobs.env) and PW_HASH (password bytes with exactly one trailing newline stripped).
compute_hashes() {
  ENV_HASH="$(priv sha256sum -- "$ENV_FILE" | cut -d ' ' -f 1)"
  read_secret "$PW_FILE" || die "cannot read $PW_FILE"
  PW_HASH="$(printf '%s' "$SECRET" | sha_stdin)"
  SECRET=""
  [ -n "$ENV_HASH" ] && [ -n "$PW_HASH" ] || die "cannot hash the host inputs"
}

# wanted_record: the content inputs.sha256 must have.
wanted_record() { printf 'jobs.env=%s\njobs-redis.password=%s\n' "$ENV_HASH" "$PW_HASH"; }

chk_deploy_user() {
  local uid
  if ! getent passwd deploy >/dev/null 2>&1; then
    echo "the deploy user does not exist: run \`make host-deploy-user HOST=<alias> ARGS=\"install --pubkey-file <path>\"\` first"
    return 0
  fi
  uid="$(deploy_uid)"
  [[ "$uid" =~ ^[0-9]+$ ]] || echo "cannot read the deploy user's numeric uid"
}

chk_network() {
  local desc
  desc="$(dk network inspect --format '{{.Driver}} {{.EnableIPv6}}' "$NETWORK" 2>/dev/null)" || { echo "network $NETWORK is missing: run \`make host-ingress HOST=<alias> ARGS=install\` first"; return 0; }
  [ "$desc" = "bridge false" ] || echo "network $NETWORK is '$desc', want 'bridge false' (a bridge with IPv6 off)"
}

# ctr_problems [run] <name>...: one line per container that is absent, not running or (without "run") not healthy.
ctr_problems() {
  local only_run="" name st state health
  if [ "${1:-}" = "run" ]; then only_run=1; shift; fi
  for name in "$@"; do
    if ! st="$(dk inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null)"; then
      echo "container $name does not exist"
      continue
    fi
    state="${st%%|*}"
    health="${st#*|}"
    if [ "$state" != "running" ]; then
      echo "$name is $state"
    elif [ -z "$only_run" ] && [ "$health" != "healthy" ]; then
      echo "$name is ${health:-without a health status}"
    fi
  done
}

chk_data_stack() {
  local p
  p="$(ctr_problems "$PG" "$REDIS")"
  [ -z "$p" ] || { echo "the data stack is not healthy (run \`make host-data HOST=<alias> ARGS=install\`):"; printf '  %s\n' "${p//$'\n'/$'\n'  }"; }
}

# chk_input_file <label> <path>: regular, not a symlink, root:JOBS_GID 0640, non-empty.
chk_input_file() {
  local label="$1" p="$2" meta
  if ! priv test -e "$p"; then echo "$label missing: $p"; return 1; fi
  if priv test -L "$p"; then echo "$label is a symlink: $p"; return 1; fi
  if ! priv test -f "$p"; then echo "$label is not a regular file: $p"; return 1; fi
  meta="$(file_meta "$p")" || { echo "cannot stat $label"; return 1; }
  [ "$meta" = "0:$JOBS_GID 640" ] || echo "$label uid:gid/mode is '$meta', want '0:$JOBS_GID 640' (owner root, group $JOBS_GID, mode 0640)"
  if ! priv test -s "$p"; then echo "$label is empty"; return 1; fi
}

chk_jobs_env() {
  local raw line n=0 bad=0
  chk_input_file "jobs.env" "$ENV_FILE" || return 0
  raw="$(priv cat -- "$ENV_FILE" 2>/dev/null)" || { echo "cannot read jobs.env"; return 0; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [[ "$line" != \#* ]] || continue
    n=$((n + 1))
    if [[ "$line" =~ ^DISCORD_WEBHOOK=https://[^[:space:]\"\']+$ ]]; then :; else bad=1; fi
  done <<<"$raw"
  [ "$n" -eq 1 ] && [ "$bad" -eq 0 ] || echo "jobs.env must hold exactly one line DISCORD_WEBHOOK=https://<url> (no spaces or quotes, no other key, no repeat)"
}

chk_redis_admin() {
  # Only when the data stack container is up (chk_data_stack reports a missing one); a broken admin login would
  # otherwise surface only after the image build.
  if [ -n "$(ctr_problems "$REDIS")" ]; then return 0; fi
  runner_acl_line >/dev/null 2>&1 || echo "cannot read ACL LIST as the Redis admin user (admin auth failed or Redis is down)"
}

chk_pw_file() {
  chk_input_file "jobs-redis.password" "$PW_FILE" || return 0
  read_secret "$PW_FILE" || { echo "cannot read jobs-redis.password"; SECRET=""; return 0; }
  if [[ "$SECRET" == *$'\n'* ]]; then
    echo "jobs-redis.password has more than one line (one trailing newline is fine)"
  elif [ -z "$SECRET" ]; then
    echo "jobs-redis.password has no content"
  elif ! [[ "$SECRET" =~ ^[A-Za-z0-9._~+=/@%^:,-]+$ ]]; then
    echo "jobs-redis.password must use only letters, digits and . _ ~ + = / @ % ^ : , - (it is handed to redis-cli on stdin)"
  fi
  SECRET=""
}

# chk_window_env: the backup directory and a valid window.env (the runner reads it by name from the directory mount).
chk_window_env() {
  local f="$BACKUP_DIR/window.env" raw line k v s="" e="" z="" n=0 dup=0 bad=0
  if priv test -L "$BACKUP_DIR" || ! priv test -d "$BACKUP_DIR"; then echo "the backup directory $BACKUP_DIR is missing or not a directory (run \`make host-backup HOST=<alias> ARGS=install\`)"; return 0; fi
  if ! priv test -f "$f" || priv test -L "$f"; then echo "window.env missing or not a regular file: $f"; return 0; fi
  raw="$(priv cat -- "$f" 2>/dev/null)" || { echo "cannot read window.env"; return 0; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [[ "$line" != \#* ]] || continue
    n=$((n + 1))
    k="${line%%=*}"
    v="${line#*=}"
    case "$k" in
      BACKUP_WINDOW_START) [ -z "$s" ] || dup=1; s="$v" ;;
      BACKUP_WINDOW_END) [ -z "$e" ] || dup=1; e="$v" ;;
      BACKUP_WINDOW_TZ) [ -z "$z" ] || dup=1; z="$v" ;;
      *) bad=1 ;;
    esac
  done <<<"$raw"
  if [ "$bad" -eq 1 ] || [ "$dup" -eq 1 ] || [ "$n" -ne 3 ] || ! [[ "$s" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || ! [[ "$e" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || ! [[ "$z" =~ ^[A-Za-z][A-Za-z0-9_+/-]*$ ]] || [ "$s" \> "$e" ] || [ "$s" = "$e" ]; then
    echo "window.env is not valid (want BACKUP_WINDOW_START and BACKUP_WINDOW_END as HH:MM with START before END, and BACKUP_WINDOW_TZ, each once, no other key)"
  fi
}

# chk_path_kind <label> <path>: a symlink or a non-directory at a directory path fails closed.
chk_path_kind() {
  if priv test -L "$2"; then
    echo "$1 is a symlink: $2 (refusing to follow it)"
  elif priv test -e "$2" && ! priv test -d "$2"; then
    echo "$1 is not a directory: $2"
  fi
}

chk_paths() {
  chk_path_kind "install directory" "$INSTALL_DIR"
  chk_path_kind "platform state directory" "$VAR_DIR"
  chk_path_kind "registry root" "$REGISTRY_DIR"
  chk_path_kind "jobs-status directory" "$STATUS_DIR"
  chk_path_kind "jobs-state directory" "$STATE_DIR"
}

# chk_job_secrets_root: created by install-data.sh as deploy:JOBS_GID 2710.
chk_job_secrets_root() {
  local uid meta
  if [ ! -d "$JOB_SECRETS_DIR" ] || [ -L "$JOB_SECRETS_DIR" ]; then
    echo "the job-secrets root $JOB_SECRETS_DIR is missing or not a directory (run \`make host-data HOST=<alias> ARGS=install\`)"
    return 0
  fi
  uid="$(deploy_uid 2>/dev/null || true)"
  [[ "$uid" =~ ^[0-9]+$ ]] || return 0
  meta="$(file_meta "$JOB_SECRETS_DIR")" || meta="unreadable"
  [ "$meta" = "$uid:$JOBS_GID 2710" ] || echo "$JOB_SECRETS_DIR uid:gid/mode is '$meta', want '$uid:$JOBS_GID 2710' (owner deploy, group $JOBS_GID, setgid, mode 2710)"
}

# chk_disk: free space for a build.
chk_disk() {
  local path="${INSTALL_JOBS_DISK_PATH:-}" avail
  if [ -z "$path" ]; then
    if [ -d "$ROOT/var/lib/docker" ]; then path="$ROOT/var/lib/docker"; else path="$ROOT/var/lib"; fi
  fi
  avail="$(priv df -Pk -- "$path" 2>/dev/null | awk 'NR == 2 { print $4 }')" || avail=""
  if ! [[ "$avail" =~ ^[0-9]+$ ]]; then echo "cannot read the free disk space of $path"; return 0; fi
  [ "$avail" -ge "$MIN_FREE_KB" ] || echo "free disk space at $path is $((avail / 1024)) MiB, need at least $((MIN_FREE_KB / 1024)) MiB for the image build"
}

# chk_build_network <build-dir>: the builder image pulls and `go mod download` reaches the module proxy. Called only when
# an image will be built.
chk_build_network() {
  local ref="$1" dir="$2"
  [ -n "$ref" ] || { echo "cannot read the pinned builder image from the embedded Dockerfile"; return 0; }
  if ! priv timeout "$NET_TIMEOUT" docker pull "$ref" >"$TMP/pull.log" 2>&1; then
    echo "cannot pull the pinned builder image $ref (registry unreachable?): the image build needs the network"
    echo "  last lines of the pull output:"
    tail -n 5 "$TMP/pull.log" 2>/dev/null | sed 's/^/    /' || true
    return 0
  fi
  if ! priv timeout "$NET_TIMEOUT" docker run --rm -e GOTOOLCHAIN=local -v "$dir:/src:ro" -w /src "$ref" go mod download >"$TMP/modproxy.log" 2>&1; then
    echo "\`go mod download\` failed (module proxy unreachable?): the image build needs the network"
    echo "  last lines of the go output:"
    tail -n 5 "$TMP/modproxy.log" 2>/dev/null | sed 's/^/    /' || true
  fi
}

print_instructions() {
  err ""
  err "Create the two host-side inputs yourself (nothing here writes a secret). Every create command is guarded with"
  err "\`test -e ||\`, so pasting it never overwrites a file that already exists. A change to either file needs"
  err "\`make host-jobs HOST=<alias> ARGS=install\` afterwards, which recreates the runner container:"
  err "  sudo install -d -m 0755 -o root -g root /etc/platform"
  err "  sudo test -e $ENV_FILE || sudo install -m 0640 -o root -g $JOBS_GID /dev/null $ENV_FILE"
  err "  sudoedit $ENV_FILE     # one line: DISCORD_WEBHOOK=https://..."
  err "  sudo test -e $PW_FILE || { sudo install -m 0640 -o root -g $JOBS_GID /dev/null $PW_FILE && openssl rand -hex 24 | sudo tee $PW_FILE >/dev/null; }"
  err "A file that exists with the wrong owner or mode is fixed in place (never recreated):"
  err "  sudo chown root:$JOBS_GID $ENV_FILE $PW_FILE && sudo chmod 0640 $ENV_FILE $PW_FILE"
}

# ---- file helpers ----

# place_file <src> <dest> <mode>: copy, own as root, chmod, then atomic rename. Reports already/changed.
place_file() {
  local src="$1" dest="$2" mode="$3"
  if priv test -f "$dest" && ! priv test -L "$dest" && priv cmp -s "$src" "$dest" && [ "$(file_meta "$dest")" = "0:0 $mode" ]; then
    info "already: $dest"
    return 0
  fi
  # install replaces a pre-planted $dest.new instead of following it, and sets owner and mode in one step.
  priv install -m "$mode" -o root -g root -- "$src" "$dest.new"
  priv mv -f -- "$dest.new" "$dest"
  info "changed: $dest"
  CHANGED=1
}

# ensure_dir <dir> <uid> <gid> <mode>: create when absent, then correct owner and mode of the directory itself only
# (never recursive, never touching what is inside). A symlink or non-directory was rejected earlier.
ensure_dir() {
  local dir="$1" uid="$2" gid="$3" mode="$4" meta created=0 parent
  if ! priv test -d "$dir"; then
    parent="$(dirname "$dir")"
    priv test -d "$parent" || priv install -d -m 0755 -o root -g root "$parent"
    priv install -d -m 0755 -o root -g root "$dir"
    created=1
  fi
  meta="$(file_meta "$dir")" || meta="unreadable"
  if [ "$meta" = "$uid:$gid $mode" ]; then
    if [ "$created" -eq 1 ]; then info "changed: $dir/"; CHANGED=1; else info "already: $dir/"; fi
    return 0
  fi
  priv chown "$uid:$gid" "$dir"
  priv chmod "$mode" "$dir"
  [ "${#mode}" -ge 4 ] || priv chmod ug-s "$dir"
  if [ "$created" -eq 1 ]; then info "changed: $dir/ (created as $uid:$gid $mode)"; else info "changed: $dir/ (was '$meta', now '$uid:$gid $mode')"; fi
  CHANGED=1
}

# ---- compose helpers ----

compose() { priv env "RUNNER_TAG=$RUNNER_TAG" docker compose -p "$PROJECT" -f "$INSTALL_DIR/compose.yaml" "$@"; }

wait_healthy() {
  local deadline problems
  deadline=$((SECONDS + HEALTH_TIMEOUT))
  while :; do
    problems="$(ctr_problems "$RUNNER")"
    [ -n "$problems" ] || return 0
    if [ "$SECONDS" -ge "$deadline" ]; then
      err "$problems"
      die "the runner is not healthy after ${HEALTH_TIMEOUT}s (unhealthy: $(tr '\n' ';' <<<"$problems")); the old inputs.sha256 is kept, so the next install recreates the container"
    fi
    sleep "$POLL"
  done
}

# image_present <ref>
image_present() { dk image inspect "$1" >/dev/null 2>&1; }

# build_image <ref> <context dir> <dockerfile name>: bounded build with the log kept out of the output unless it fails.
build_image() {
  local ref="$1" dir="$2" dockerfile="$3" log="$TMP/build-${3}.log"
  info "building: $ref (up to $((BUILD_TIMEOUT / 60)) minutes)"
  if ! priv timeout "$BUILD_TIMEOUT" docker build -f "$dir/$dockerfile" --build-arg "VERSION=${ref##*:}" -t "$ref" "$dir" >"$log" 2>&1; then
    tail -n 25 "$log" >&2 || true
    die "the build of $ref failed or timed out after $((BUILD_TIMEOUT / 60)) minutes (see the last lines above; a pull or module download error is a network problem, not a payload bug)"
  fi
  info "changed: image $ref"
  CHANGED=1
}

# prepare_sources: extract the payloads into $TMP and compute both image tags.
prepare_sources() {
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/build"
  write_inputs "$TMP/build" runner_inputs
  RUNNER_TAG="$(source_hash "$TMP/build")"
  TESTAPP_TAG="$(testapp_hash "$TMP")"
}

# ---- install ----

# acl_error_class <redis-cli output>: " (redis answered: ERR)" for a known error class, else nothing. The reply text is
# never printed (a Redis error can echo the rule, and the rule carries the password); only the class word survives.
acl_error_class() {
  local first
  first="$(tr -d '\r' <<<"$1" | head -n 1 | sed 's/^(error) //' | awk '{ print $1 }')"
  case "$first" in
    ERR | NOAUTH | WRONGPASS | NOPERM | LOADING | BUSY | OOM | READONLY | MISCONF) printf ' (redis answered: %s)' "$first" ;;
    *) ;;
  esac
}

apply_acl() {
  local live_line live_hash rule out drift=""
  live_line="$(runner_acl_line)" || die "cannot read ACL LIST (admin auth failed or Redis is down)"
  live_hash="$(acl_hash_token "$live_line")"
  # The password hash alone is not enough: a rule that drifted (user turned off, scope changed) is re-applied too.
  if [ -n "$live_line" ]; then drift="$(runner_problems "${live_line#user runner }")"; fi
  if [ -n "$live_line" ] && [ "$live_hash" = "$PW_HASH" ] && [ -z "$drift" ]; then
    info "already: Redis runner user"
    return 0
  fi
  read_secret "$PW_FILE" || die "cannot read $PW_FILE"
  rule="ACL SETUSER $(runner_rule "$SECRET")"
  SECRET=""
  out="$(redis_admin_stdin "$rule" 2>&1)" || { rule=""; die "ACL SETUSER for the runner failed$(acl_error_class "$out")"; }
  rule=""
  grep -qx 'OK' <<<"${out//$'\r'/}" || die "ACL SETUSER for the runner did not answer OK$(acl_error_class "$out")"
  out="$(redis_admin_stdin "ACL SAVE" 2>&1)" || die "ACL SAVE failed$(acl_error_class "$out")"
  grep -qx 'OK' <<<"${out//$'\r'/}" || die "ACL SAVE did not answer OK$(acl_error_class "$out")"
  if [ -n "$live_line" ]; then info "changed: Redis runner user (password or rule changed)"; else info "changed: Redis runner user created"; fi
  CHANGED=1
}

make_host_dirs() {
  local uid gid
  uid="$(deploy_uid)"
  gid="$(deploy_gid)"
  ensure_dir "$INSTALL_DIR" 0 0 755
  ensure_dir "$VAR_DIR" 0 0 755
  ensure_dir "$REGISTRY_DIR" "$uid" "$gid" 755
  ensure_dir "$STATUS_DIR" "$RUNNER_UID" "$RUNNER_UID" 755
  ensure_dir "$STATE_DIR" "$RUNNER_UID" "$RUNNER_UID" 700
}

do_install() {
  local problems line have_image=0 force=0 want cur stopped cur_image
  require_privilege
  prepare_sources
  image_present "$RUNNER_IMAGE_REPO:$RUNNER_TAG" && have_image=1

  problems="$(chk_deploy_user; chk_network; chk_data_stack; chk_redis_admin; chk_window_env; chk_jobs_env; chk_pw_file; chk_job_secrets_root; chk_paths)"
  # Disk space and the build network matter only when a build will run; with the image present neither is checked, so a
  # full disk or an offline host does not block an otherwise no-op install.
  if [ "$have_image" -eq 0 ]; then
    problems+=$'\n'"$(chk_disk)"
    problems+=$'\n'"$(chk_build_network "$(builder_ref)" "$TMP/build")"
  fi
  problems="$(grep -v '^$' <<<"$problems" || true)"
  if [ -n "$problems" ]; then
    while IFS= read -r line; do err "install-jobs: $line"; done <<<"$problems"
    print_instructions
    die "preconditions failed; nothing was installed (only the read-only checks, the builder image pull and the module check ran)"
  fi

  compute_hashes
  want="$(wanted_record)"

  if [ "$have_image" -eq 1 ]; then info "already: image $RUNNER_IMAGE_REPO:$RUNNER_TAG"; else build_image "$RUNNER_IMAGE_REPO:$RUNNER_TAG" "$TMP/build" Dockerfile; fi
  apply_acl
  make_host_dirs
  payload_compose_yaml > "$TMP/compose.yaml"
  place_file "$TMP/compose.yaml" "$INSTALL_DIR/compose.yaml" 644

  # The record is the proof the running container was created from the current jobs.env and password; without it, or
  # with a different one, the single-file mounts may be stale, so the container is recreated.
  cur="$(priv cat -- "$RECORD" 2>/dev/null || true)"
  if [ -z "$cur" ] || [ "$cur" != "$want" ]; then force=1; fi

  cur_image="$(dk inspect --format '{{.Config.Image}}' "$RUNNER" 2>/dev/null || true)"
  stopped="$(ctr_problems run "$RUNNER")"
  if [ "$force" -eq 1 ]; then
    compose up -d --remove-orphans --force-recreate || die "docker compose up failed"
    info "changed: runner (re)created"
    CHANGED=1
  else
    compose up -d --remove-orphans || die "docker compose up failed"
    if [ -n "$stopped" ] || [ "$cur_image" != "$RUNNER_IMAGE_REPO:$RUNNER_TAG" ]; then
      info "changed: runner started"
      CHANGED=1
    else
      info "already: runner running"
    fi
  fi
  wait_healthy
  printf '%s\n' "$want" > "$TMP/inputs.sha256"
  place_file "$TMP/inputs.sha256" "$RECORD" 600
  if [ "$CHANGED" -eq 1 ]; then info "install-jobs: done (runner healthy)"; fi
}

# ---- status / verify ----

check_meta() {
  local label="$1" path="$2" want="$3" meta
  if ! priv test -e "$path"; then fail "$label missing: $path"; return 1; fi
  if priv test -L "$path"; then fail "$label is a symlink: $path"; return 1; fi
  meta="$(file_meta "$path")" || meta="unreadable"
  if [ "$meta" = "$want" ]; then pass "$label owner/mode ($meta)"; else fail "$label uid:gid/mode is '$meta', want '$want'"; return 1; fi
}

check_payload() {
  local label="$1" path="$2" fn="$3"
  "$fn" > "$TMP/check.payload"
  if priv test -f "$path" && priv cmp -s "$TMP/check.payload" "$path"; then pass "$label bytes equal the embedded payload"; else fail "$label bytes differ from the embedded payload"; fi
}

# run_check <label> <fn> [args...]: PASS when the chk function prints nothing, one FAIL per printed problem otherwise.
run_check() {
  local label="$1" probs line
  shift
  probs="$("$@")"
  if [ -z "$probs" ]; then
    pass "$label"
  else
    while IFS= read -r line; do fail "$label: $line"; done <<<"$probs"
  fi
}

# shellcheck disable=SC2329 # invoked by name through run_check
chk_redis_runner() {
  local line hash
  line="$(runner_acl_line)" || { echo "cannot read ACL LIST (admin auth failed or Redis is down)"; return 0; }
  if [ -z "$line" ]; then echo "the Redis runner user is missing (run install)"; return 0; fi
  runner_problems "${line#user runner }" | sed 's/$/ (run install: it re-applies the rule)/'
  hash="$(acl_hash_token "$line")"
  if [ -n "$hash" ] && [ -n "$PW_HASH" ] && [ "$hash" != "$PW_HASH" ]; then
    echo "the Redis runner password hash differs from jobs-redis.password (run install)"
  fi
}

# shellcheck disable=SC2329 # invoked by name through run_check
chk_record() {
  local cur
  if ! cur="$(priv cat -- "$RECORD" 2>/dev/null)"; then echo "$RECORD is missing (run install)"; return 0; fi
  if [ -z "$PW_HASH" ] || [ -z "$ENV_HASH" ]; then echo "cannot hash jobs.env and jobs-redis.password to compare with the record"; return 0; fi
  [ "$cur" = "$(wanted_record)" ] || echo "jobs.env or jobs-redis.password changed since the container was created (stale single-file mount); run install, which recreates the container"
}

# shellcheck disable=SC2016 # the {{ }} docker templates are literal on purpose
runner_container_checks() {
  local out
  out="$(dk inspect --format '{{.Config.Image}}' "$RUNNER" 2>/dev/null || echo "inspect-failed")"
  if [ "$out" = "inspect-failed" ]; then fail "cannot inspect the image of $RUNNER"
  elif [ "$out" = "$RUNNER_IMAGE_REPO:$RUNNER_TAG" ]; then pass "$RUNNER runs the image for the current source hash ($RUNNER_TAG)"
  else fail "$RUNNER runs image '${out//[^A-Za-z0-9_.:-]/?}', want $RUNNER_IMAGE_REPO:$RUNNER_TAG (image hash drift; run install)"; fi

  out="$(dk port "$RUNNER" 2>/dev/null || true)"
  if [ -z "$out" ]; then pass "$RUNNER publishes no port"; else fail "$RUNNER publishes a port"; fi

  out="$(dk inspect --format '{{range $k, $v := .Config.Labels}}{{$k}}{{"\n"}}{{end}}' "$RUNNER" 2>/dev/null || echo "inspect-failed")"
  if [ "$out" = "inspect-failed" ]; then fail "cannot inspect the labels of $RUNNER"
  elif grep -qxF "platform.app" <<<"$out"; then fail "$RUNNER carries the platform.app label (the runner is infrastructure, not an app)"
  else pass "$RUNNER carries no platform.app label"; fi

  out="$(dk inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$RUNNER" 2>/dev/null || echo "inspect-failed")"
  if [ "$out" = "inspect-failed" ]; then fail "cannot inspect the networks of $RUNNER"
  elif [ "$out" = "$NETWORK" ]; then pass "$RUNNER is only on the $NETWORK network"
  else fail "$RUNNER is not exactly on the $NETWORK network (networks: $(tr '\n' ' ' <<<"$out"))"; fi

  out="$(dk inspect --format '{{range .Mounts}}{{.Source}}|{{.Destination}}|{{.RW}}{{"\n"}}{{end}}' "$RUNNER" 2>/dev/null || echo "inspect-failed")"
  if [ "$out" = "inspect-failed" ]; then fail "cannot inspect the mounts of $RUNNER"
  elif grep -qxF "$BACKUP_DIR|/opt/platform/backup|false" <<<"$out"; then pass "$RUNNER mounts the backup directory read-only"
  else fail "the backup directory $BACKUP_DIR is not mounted read-only at /opt/platform/backup in $RUNNER (a single-file window.env mount goes stale; run install)"; fi
}

# runner_tsv_checks: the runner's own status file. A fresh heartbeat does not mean the queue or the window works, so the
# states are read too.
runner_tsv_checks() {
  local f="$STATUS_DIR/runner.tsv" content lines nf hb hbe now age ws cs rs
  if ! priv test -f "$f"; then fail "runner.tsv missing: $f"; return 0; fi
  content="$(priv cat -- "$f" 2>/dev/null)" || { fail "cannot read runner.tsv"; return 0; }
  if [ -z "$content" ]; then fail "runner.tsv is empty"; return 0; fi
  lines="$(printf '%s\n' "$content" | wc -l | tr -d ' ')"
  if [ "$lines" -ne 1 ]; then fail "runner.tsv has $lines lines, want exactly one"; return 0; fi
  nf="$(printf '%s\n' "$content" | awk -F '\t' '{ print NF }')"
  if [ "$nf" -ne 6 ]; then fail "runner.tsv has $nf tab-separated fields, want exactly six"; return 0; fi
  hb="$(printf '%s\n' "$content" | awk -F '\t' '{ print $2 }')"
  ws="$(printf '%s\n' "$content" | awk -F '\t' '{ print $3 }')"
  cs="$(printf '%s\n' "$content" | awk -F '\t' '{ print $4 }')"
  rs="$(printf '%s\n' "$content" | awk -F '\t' '{ print $5 }')"
  now="${INSTALL_JOBS_NOW:-$(date +%s)}"
  if [[ "$hb" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && hbe="$(date -u -d "$hb" +%s 2>/dev/null)"; then
    age=$((now - hbe))
    if [ "$age" -gt "$HEARTBEAT_MAX_AGE" ]; then fail "runner heartbeat is ${age}s old (limit ${HEARTBEAT_MAX_AGE}s)"
    elif [ "$age" -lt -60 ]; then fail "runner heartbeat is ${age#-}s in the future"
    else pass "runner heartbeat is ${age}s old"; fi
  else
    fail "runner.tsv heartbeat_at is not an RFC3339 UTC time"
  fi
  case "$ws" in
    ok) pass "runner window_state is ok" ;;
    invalid) fail "runner window_state is invalid (the runner refuses all runs; fix window.env)" ;;
    *) fail "runner window_state is '${ws//[^A-Za-z0-9_-]/?}', want ok or invalid" ;;
  esac
  case "$cs" in
    ok) pass "runner config_state is ok" ;;
    invalid) warn "runner config_state is invalid (an app's registry file is invalid; that app's jobs are disabled)" ;;
    *) fail "runner config_state is '${cs//[^A-Za-z0-9_-]/?}', want ok or invalid" ;;
  esac
  case "$rs" in
    ok) pass "runner redis_state is ok" ;;
    down) warn "runner redis_state is down (the queue is paused until Redis answers)" ;;
    invalid) fail "runner redis_state is invalid (NOPERM or WRONGPASS: the queue is refused; run install)" ;;
    *) fail "runner redis_state is '${rs//[^A-Za-z0-9_-]/?}', want ok, down or invalid" ;;
  esac
}

do_checks() {
  local problems line uid gid
  PW_HASH=""
  ENV_HASH=""
  if priv test -f "$ENV_FILE" && priv test -f "$PW_FILE"; then
    ENV_HASH="$(priv sha256sum -- "$ENV_FILE" 2>/dev/null | cut -d ' ' -f 1 || true)"
    if read_secret "$PW_FILE"; then PW_HASH="$(printf '%s' "$SECRET" | sha_stdin)"; fi
    SECRET=""
  fi
  check_meta "install directory" "$INSTALL_DIR" "0:0 755" || true
  check_meta "compose.yaml" "$INSTALL_DIR/compose.yaml" "0:0 644" || true
  check_payload "compose.yaml" "$INSTALL_DIR/compose.yaml" payload_compose_yaml
  check_meta "inputs.sha256" "$RECORD" "0:0 600" || true
  run_check "inputs.sha256 matches jobs.env and jobs-redis.password" chk_record

  uid="$(deploy_uid 2>/dev/null || true)"
  gid="$(deploy_gid 2>/dev/null || true)"
  if [[ "$uid" =~ ^[0-9]+$ ]] && [[ "$gid" =~ ^[0-9]+$ ]]; then
    check_meta "registry root" "$REGISTRY_DIR" "$uid:$gid 755" || true
    check_meta "job-secrets root" "$JOB_SECRETS_DIR" "$uid:$JOBS_GID 2710" || true
  else
    fail "cannot read the deploy user's uid and gid to judge the registry and job-secrets roots"
  fi
  check_meta "jobs-status directory" "$STATUS_DIR" "$RUNNER_UID:$RUNNER_UID 755" || true
  check_meta "jobs-state directory" "$STATE_DIR" "$RUNNER_UID:$RUNNER_UID 700" || true
  check_meta "jobs.env" "$ENV_FILE" "0:$JOBS_GID 640" || true
  check_meta "jobs-redis.password" "$PW_FILE" "0:$JOBS_GID 640" || true
  run_check "network $NETWORK" chk_network
  run_check "backup window" chk_window_env

  problems="$(ctr_problems "$RUNNER")"
  if [ -z "$problems" ]; then
    pass "$RUNNER is running and healthy"
  else
    while IFS= read -r line; do fail "$line"; done <<<"$problems"
  fi
  if image_present "$RUNNER_IMAGE_REPO:$RUNNER_TAG"; then pass "image $RUNNER_IMAGE_REPO:$RUNNER_TAG exists"; else fail "image $RUNNER_IMAGE_REPO:$RUNNER_TAG is missing (source hash drift; run install)"; fi
  runner_container_checks
  run_check "Redis runner user" chk_redis_runner
  runner_tsv_checks
}

do_report() {
  require_privilege
  prepare_sources
  do_checks
  if [ "$FAILURES" -gt 0 ]; then
    printf 'install-jobs: %d check(s) failed\n' "$FAILURES"
    [ "$1" = "status" ] || exit 1
  else
    printf 'install-jobs: all checks passed\n'
  fi
}

# ---- testapp-up / testapp-down (explicit only: install, status and verify never touch the test app) ----

# testapp_yaml: the registry file of the test app. Its jobs are generated from TESTAPP_JOBS, the same list as the
# JOBS_DECLARED env var of its container, so the two cannot drift.
testapp_yaml() {
  local j
  printf 'schema_version: 1\nname: %s\nowner: platform\npurpose: Jobs runner test app (testapp-up only, removed by testapp-down)\n' "$TESTAPP_APP"
  printf 'template: go-htmx\nmemory_cap: 32m\nport: 8080\njobs:\n'
  for j in $TESTAPP_JOBS; do printf '  - name: %s\n    timeout: 30s\n' "$j"; done
}

# testapp_declared: the comma-separated job list for JOBS_DECLARED.
testapp_declared() {
  local j out=""
  for j in $TESTAPP_JOBS; do out+="${out:+,}$j"; done
  printf '%s' "$out"
}

chk_testapp_secret() {
  local f="$JOB_SECRETS_DIR/$TESTAPP_APP/jobs-secret"
  priv test -f "$f" || echo "the $TESTAPP_APP job secret is missing: $f (run \`platform new-db $TESTAPP_APP\` as the deploy user first)"
}

# testapp_label: the platform.app label value of the container named $TESTAPP (empty when none or absent).
testapp_label() { dk inspect --format '{{index .Config.Labels "platform.app"}}' "$TESTAPP" 2>/dev/null || true; }

# chk_testapp_owner: a container that holds our name but not our label is somebody else's; never replace or remove it.
chk_testapp_owner() {
  if dk inspect --format '{{.State.Status}}' "$TESTAPP" >/dev/null 2>&1 && [ "$(testapp_label)" != "$TESTAPP_APP" ]; then
    echo "a container named $TESTAPP exists without the platform.app=$TESTAPP_APP label: it is not the test app, so it is left alone (remove it by hand if it is stale)"
  fi
}

chk_registry_root() {
  priv test -d "$REGISTRY_DIR" || echo "the registry root $REGISTRY_DIR is missing (run \`make host-jobs HOST=<alias> ARGS=install\` first)"
}

# shellcheck disable=SC2016 # the {{ }} docker templates are literal on purpose
do_testapp_up() {
  local problems line have_image=0 uid gid cur_img cur_state cur_env cur_nets state reg_dir="$REGISTRY_DIR/$TESTAPP_APP" declared secret
  require_privilege
  prepare_sources
  image_present "$TESTAPP_IMAGE_REPO:$TESTAPP_TAG" && have_image=1
  problems="$(chk_deploy_user; chk_network; chk_registry_root; chk_testapp_secret; chk_path_kind "registry root" "$REGISTRY_DIR"; chk_testapp_owner)"
  if [ "$have_image" -eq 0 ]; then
    problems+=$'\n'"$(chk_disk)"
    mkdir -p "$TMP/tbuild"
    write_inputs "$TMP/tbuild" testapp_inputs
    payload_go_mod > "$TMP/tbuild/go.mod"
    payload_go_sum > "$TMP/tbuild/go.sum"
    problems+=$'\n'"$(chk_build_network "$(builder_ref)" "$TMP/tbuild")"
  fi
  problems="$(grep -v '^$' <<<"$problems" || true)"
  if [ -n "$problems" ]; then
    while IFS= read -r line; do err "install-jobs: $line"; done <<<"$problems"
    die "testapp-up preconditions failed; nothing was installed (only the read-only checks, the builder image pull and the module check ran)"
  fi
  uid="$(deploy_uid)"
  gid="$(deploy_gid)"
  declared="$(testapp_declared)"
  secret="$JOB_SECRETS_DIR/$TESTAPP_APP/jobs-secret"

  if [ "$have_image" -eq 1 ]; then
    info "already: image $TESTAPP_IMAGE_REPO:$TESTAPP_TAG"
  else
    build_image "$TESTAPP_IMAGE_REPO:$TESTAPP_TAG" "$TMP/tbuild" Dockerfile.testapp
  fi
  ensure_dir "$reg_dir" "$uid" "$gid" 755
  testapp_yaml > "$TMP/app.yaml"
  place_file "$TMP/app.yaml" "$reg_dir/app.yaml" 644

  cur_img="$(dk inspect --format '{{.Config.Image}}' "$TESTAPP" 2>/dev/null || true)"
  cur_state="$(dk inspect --format '{{.State.Status}}' "$TESTAPP" 2>/dev/null || true)"
  cur_env="$(dk inspect --format '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' "$TESTAPP" 2>/dev/null || true)"
  cur_nets="$(dk inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$TESTAPP" 2>/dev/null || true)"
  state=new
  if [ -n "$cur_img" ]; then
    if [ "$cur_state" = "running" ] && [ "$cur_img" = "$TESTAPP_IMAGE_REPO:$TESTAPP_TAG" ] && grep -qxF "JOBS_DECLARED=$declared" <<<"$cur_env" \
      && [ "$(testapp_label)" = "$TESTAPP_APP" ] && [ "$cur_nets" = "$NETWORK" ]; then
      state=current
    else
      state=stale
    fi
  fi
  case "$state" in
    current) info "already: $TESTAPP running" ;;
    *)
      [ "$state" != stale ] || dk rm -f "$TESTAPP" >/dev/null
      dk run -d --name "$TESTAPP" --label "platform.app=$TESTAPP_APP" --network "$NETWORK" --network-alias "$TESTAPP_APP" \
        --user "$RUNNER_UID:$RUNNER_UID" --group-add "$JOBS_GID" --cap-drop ALL --security-opt no-new-privileges:true \
        --read-only --tmpfs /tmp --memory 32m --restart unless-stopped \
        -e JOBS_SECRET_FILE=/run/jobs-secret -e "JOBS_DECLARED=$declared" -e LISTEN_ADDR=:8080 \
        -v "$secret:/run/jobs-secret:ro" "$TESTAPP_IMAGE_REPO:$TESTAPP_TAG" >/dev/null || die "docker run of $TESTAPP failed"
      if [ "$state" = stale ]; then info "changed: $TESTAPP recreated"; else info "changed: $TESTAPP started"; fi
      CHANGED=1
      ;;
  esac
  if [ "$CHANGED" -eq 1 ]; then info "install-jobs: testapp-up done (alias $TESTAPP_APP, jobs: $declared)"; fi
}

do_testapp_down() {
  local reg_dir="$REGISTRY_DIR/$TESTAPP_APP" img found=0
  require_privilege
  if dk inspect --format '{{.State.Status}}' "$TESTAPP" >/dev/null 2>&1; then
    [ "$(testapp_label)" = "$TESTAPP_APP" ] || die "a container named $TESTAPP exists without the platform.app=$TESTAPP_APP label: it is not the test app, so it is not removed (nothing was changed)"
    dk rm -f "$TESTAPP" >/dev/null || die "cannot remove $TESTAPP"
    info "changed: removed container $TESTAPP"
    CHANGED=1
  else
    info "already: no container $TESTAPP"
  fi
  if priv test -e "$reg_dir/app.yaml" || priv test -L "$reg_dir/app.yaml"; then
    priv rm -f -- "$reg_dir/app.yaml"
    priv rmdir -- "$reg_dir" 2>/dev/null || true
    info "changed: removed $reg_dir/app.yaml"
    CHANGED=1
  else
    info "already: no $reg_dir/app.yaml"
  fi
  while IFS= read -r img; do
    [ -n "$img" ] || continue
    found=1
    dk rmi "$img" >/dev/null || die "cannot remove image $img"
    info "changed: removed image $img"
    CHANGED=1
  done < <(dk images --format '{{.Repository}}:{{.Tag}}' "$TESTAPP_IMAGE_REPO" 2>/dev/null || true)
  if [ "$found" -eq 0 ]; then info "already: no $TESTAPP_IMAGE_REPO image"; fi
  if [ "$CHANGED" -eq 1 ]; then
    info "install-jobs: testapp-down done. The $TESTAPP_APP job secret and Redis user are left in place; remove them by hand if wanted:"
    info "  sudo rm -rf $JOB_SECRETS_DIR/$TESTAPP_APP"
    info "  (Redis) ACL DELUSER $TESTAPP_APP, then ACL SAVE, as admin"
  fi
}

# ---- main ----

main() {
  local cmd="install" host=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      install | status | verify | testapp-up | testapp-down) cmd="$1"; shift ;;
      --host) { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "missing value for --host" 2; host="$2"; shift 2 ;;
      -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  case "$host" in -*) die "refusing option-looking --host: $host" 2 ;; esac
  [[ "$HEALTH_TIMEOUT" =~ ^[0-9]+$ ]] || die "INSTALL_JOBS_HEALTH_TIMEOUT must be a whole number of seconds" 2
  [[ "$BUILD_TIMEOUT" =~ ^[0-9]+$ ]] || die "INSTALL_JOBS_BUILD_TIMEOUT must be a whole number of seconds" 2
  [[ "$NET_TIMEOUT" =~ ^[0-9]+$ ]] || die "INSTALL_JOBS_NET_TIMEOUT must be a whole number of seconds" 2
  [[ "$POLL" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "INSTALL_JOBS_POLL must be a number of seconds" 2

  if [ -n "$host" ]; then
    exec ssh -o BatchMode=yes -- "$host" "bash -s -- $cmd" < "${BASH_SOURCE[0]}"
  fi

  case "$cmd" in
    install) do_install ;;
    status | verify) do_report "$cmd" ;;
    testapp-up) do_testapp_up ;;
    testapp-down) do_testapp_down ;;
  esac
}

# The tests source this file for its functions (INSTALL_JOBS_SOURCE_ONLY=1).
# shellcheck disable=SC2317 # the exit is the fallback when the file is executed, not sourced
if [ -n "${INSTALL_JOBS_SOURCE_ONLY:-}" ]; then return 0 2>/dev/null || exit 0; fi
main "$@"
exit 0
