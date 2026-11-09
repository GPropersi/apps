# Image for an app built from the go-react template. Every base image is pinned by multi-arch index digest, so the same
# pin resolves on the amd64 CI runner and the arm64 host. The builder tag and digest equal platform/jobs/Dockerfile
# (platform/jobs/GO_VERSION); bump them together. The final stage must stay last (CI builds the default target).
#
# Stages: web (Vite build), web-test (the web unit tests: `docker build --target web-test`), sqlc (only names the pinned
# sqlc image that test_sqlc.sh and platform/test/prewarm.sh read), build (Go binary, no -tags: the dev identity code is
# never compiled in), final (distroless, non-root).
FROM node:24.21.0-bookworm-slim@sha256:d6aa754f16b3197301076f047b5def2f02ea1dbbc2ca920407d46d7ec7f87b20 AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci
COPY web/ ./
# vite.config.ts writes the build to ../internal/app/static, that is /src/internal/app/static here.
RUN npm run build

FROM web AS web-test
RUN npm test

FROM sqlc/sqlc:1.30.0@sha256:b8d1092c720438e093a231e75eba5d55b7696122f390292acabd5b6d3e986a12 AS sqlc

FROM golang:1.26.0@sha256:fb612b7831d53a89cbc0aaa7855b69ad7b0caf603715860cf538df854d047b84 AS build
ARG VERSION=dev
ENV GOTOOLCHAIN=local
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY appmeta.go app.yaml ./
COPY cmd/ ./cmd/
COPY internal/ ./internal/
COPY migrations/ ./migrations/
COPY --from=web /src/internal/app/static/ ./internal/app/static/
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /server ./cmd/server

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /server /server
USER 65532:65532
EXPOSE 8080
# About 80% of app.yaml memory_cap (64m).
ENV GOMEMLIMIT=51MiB
ENTRYPOINT ["/server"]
