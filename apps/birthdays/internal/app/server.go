// Package app is the birthdays server: the JSON API, the jobs wiring, the embedded SPA and the startup sequence.
package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log/slog"
	"mime"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"github.com/gpropersi/apps/apps/birthdays/internal/app/db"
)

const (
	maxBody  = 4 << 10
	cspValue = "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'"
)

// Enqueuer queues a background job (platform.Enqueuer satisfies it).
type Enqueuer interface {
	Enqueue(ctx context.Context, job string, payload any) (string, error)
	// EnqueueUnique queues the job at most once per key within ttl; it returns enqueued=false (and no error) when
	// the key already exists.
	EnqueueUnique(ctx context.Context, job, key string, payload any, ttl time.Duration) (id string, enqueued bool, err error)
}

// Server holds what the HTTP handlers need.
//
// Edge note: Cloudflare's Traefik errors middleware replaces 502-504 bodies with the platform down page, so this
// server answers its own failures with 4xx or 500 and never with 502, 503 or 504.
type Server struct {
	Store   db.Querier
	Tx      Transactor // multi-statement writes run in one transaction
	Queue   Enqueuer
	Notifs  Notifier // 4irl-notifs client for the notification settings routes; nil answers notify_unavailable
	Jobs    http.Handler
	Static  fs.FS
	Logger  *slog.Logger
	Auth    func(http.Handler) http.Handler // answers 401 unless the request carries a valid identity
	EmailOf func(*http.Request) (string, bool)
	// NotifsAppID is this app's 4irl-notifs app_id (apps_birthdays); it goes in the phone setup link.
	NotifsAppID string
}

// Handler builds the router. Security headers and request logging wrap every response, including 401, 404, 405 and 413.
func (s *Server) Handler() http.Handler {
	r := chi.NewRouter()
	r.Use(s.securityHeaders, s.requestLog)

	healthz := func(w http.ResponseWriter, _ *http.Request) { plain(w, http.StatusOK, "ok") }
	r.Get("/healthz", healthz)
	r.Head("/healthz", healthz)
	r.Handle("/_jobs/*", s.Jobs)

	r.Route("/api", func(api chi.Router) {
		// Nothing under /api is cacheable: answers are per viewer and notify answers can carry one-time secrets.
		// noStore runs first so the 401 and the write guard's 415/413 answers carry it too.
		api.Use(noStore, s.Auth)
		api.NotFound(func(w http.ResponseWriter, _ *http.Request) { writeError(w, http.StatusNotFound, "not_found") })
		api.MethodNotAllowed(func(w http.ResponseWriter, _ *http.Request) {
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed")
		})
		write := api.With(s.stateChanging)
		api.Get("/me", s.handleMe)
		write.Patch("/settings", s.handlePatchSettings)
		api.Get("/birthdays", s.handleListBirthdays)
		write.Post("/birthdays", s.handleCreateBirthday)
		api.Get("/birthdays/{id}", s.handleGetBirthday)
		write.Put("/birthdays/{id}", s.handlePutBirthday)
		write.Delete("/birthdays/{id}", s.handleDeleteBirthday)
		write.Put("/birthdays/{id}/reminders", s.handlePutReminders)
		write.Post("/birthdays/{id}/shares", s.handlePostShare)
		write.Delete("/birthdays/{id}/shares", s.handleDeleteShare)
		write.Post("/birthdays/{id}/gifts", s.handlePostGift)
		write.Patch("/gifts/{id}", s.handlePatchGift)
		write.Delete("/gifts/{id}", s.handleDeleteGift)

		// Notification settings: one-time secrets can appear in these answers (no-store comes from the group).
		write.Post("/notify/ntfy", s.handleNtfy)
		write.Post("/notify/ntfy/reset", s.handleNtfyReset)
		api.Get("/notify/destinations", s.handleListDestinations)
		write.Post("/notify/destinations", s.handlePostDestination)
		write.Post("/notify/destinations/{id}/check", s.handleCheckDestination)
		write.Delete("/notify/destinations/{id}", s.handleDeleteDestination)
	})

	r.Handle("/*", spaHandler{files: s.Static})
	return r
}

func (s *Server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", cspValue)
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "same-origin")
		next.ServeHTTP(w, r)
	})
}

// requestLog writes one line per request: method, path without the query, status and duration. No email, no headers.
// A panic is logged and answered 500 (never 502-504).
func (s *Server) requestLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
		defer func() {
			if p := recover(); p != nil {
				if p == http.ErrAbortHandler {
					panic(p) // net/http's silent-abort sentinel keeps its meaning
				}
				s.Logger.Error("request panicked", "method", r.Method, "path", r.URL.Path, "panic", p)
				if ww.Status() == 0 {
					writeError(ww, http.StatusInternalServerError, "internal")
				}
			}
			status := ww.Status()
			if status == 0 {
				status = http.StatusOK
			}
			s.Logger.Info("request", "method", r.Method, "path", r.URL.Path, "status", status,
				"duration_ms", time.Since(start).Milliseconds())
		}()
		next.ServeHTTP(ww, r)
	})
}

// stateChanging guards write routes (any method): a foreign Origin or a cross-site fetch is 403, a body that is not
// JSON is 415 and a body over 4 KiB is 413 (checked up front by Content-Length, and by the capped reader when the
// length is unknown).
func (s *Server) stateChanging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if crossSite(r) {
			writeError(w, http.StatusForbidden, "cross_site")
			return
		}
		if mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mt != "application/json" {
			writeError(w, http.StatusUnsupportedMediaType, "unsupported_media_type")
			return
		}
		if r.ContentLength > maxBody {
			writeError(w, http.StatusRequestEntityTooLarge, "too_large")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxBody)
		next.ServeHTTP(w, r)
	})
}

// crossSite is true unless every Origin header is https://<Host> (or, in the dev build, a dev origin) and the browser
// did not mark the fetch cross-site. A request with no Origin header passes the Origin test.
func crossSite(r *http.Request) bool {
	if r.Header.Get("Sec-Fetch-Site") == "cross-site" {
		return true
	}
	for _, origin := range r.Header.Values("Origin") {
		if origin != "https://"+r.Host && !extraOriginAllowed(origin, r.Host) {
			return true
		}
	}
	return false
}

// email is the caller's identity, trimmed and lowercased once here; nothing downstream normalizes it again.
func (s *Server) email(w http.ResponseWriter, r *http.Request) (string, bool) {
	raw, ok := s.EmailOf(r)
	email := strings.ToLower(strings.TrimSpace(raw))
	if !ok || email == "" {
		// Unreachable behind Auth; fail closed anyway.
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return "", false
	}
	return email, true
}

// readBody reads the capped request body. tooLarge is true when the cap was hit; any other read error yields whatever
// was read (the caller's JSON parse then rejects it).
func readBody(r *http.Request) (body []byte, tooLarge bool) {
	body, err := io.ReadAll(r.Body)
	var mbe *http.MaxBytesError
	if errors.As(err, &mbe) {
		return nil, true
	}
	return body, false
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	var buf bytes.Buffer
	if err := json.NewEncoder(&buf).Encode(v); err != nil {
		status = http.StatusInternalServerError
		buf.Reset()
		buf.WriteString(`{"error":"internal"}` + "\n")
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(buf.Bytes())
}

func writeError(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, map[string]string{"error": code})
}
