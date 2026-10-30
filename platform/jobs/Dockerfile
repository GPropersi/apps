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
