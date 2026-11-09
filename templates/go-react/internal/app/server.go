// Package app is the template's server: the JSON API, the jobs wiring, the embedded SPA and the startup sequence.
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
	"unicode/utf8"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"github.com/gpropersi/apps/apps/tmplgoreact/internal/app/db"
	"github.com/gpropersi/apps/apps/tmplgoreact/internal/platform"
)

const (
	maxBody      = 4 << 10
	maxTextRunes = 200
	cspValue     = "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'"
)

// Enqueuer queues a background job (platform.Enqueuer satisfies it).
type Enqueuer interface {
	Enqueue(ctx context.Context, job string, payload any) (string, error)
}

// Server holds what the HTTP handlers need.
//
// Edge note: Cloudflare's Traefik errors middleware replaces 502-504 bodies with the platform down page, so this
// server answers its own failures with 4xx or 500 and never with 502, 503 or 504.
type Server struct {
	Store   db.Querier
	Queue   Enqueuer
	Jobs    http.Handler
	Static  fs.FS
	Logger  *slog.Logger
	Auth    func(http.Handler) http.Handler // answers 401 unless the request carries a valid identity
	EmailOf func(*http.Request) (string, bool)
}

type itemJSON struct {
	ID        int64  `json:"id"`
	Text      string `json:"text"`
	CreatedBy string `json:"created_by"`
	Source    string `json:"source"`
	CreatedAt string `json:"created_at"`
}

func toItemJSON(i db.Item) itemJSON {
	return itemJSON{ID: i.ID, Text: i.Text, CreatedBy: i.CreatedBy, Source: i.Source, CreatedAt: i.CreatedAt.Time.UTC().Format(time.RFC3339)}
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
		api.Use(s.Auth)
		api.NotFound(func(w http.ResponseWriter, _ *http.Request) { writeError(w, http.StatusNotFound, "not_found") })
		api.MethodNotAllowed(func(w http.ResponseWriter, _ *http.Request) {
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed")
		})
		api.Get("/me", s.handleMe)
		api.Get("/items", s.handleListItems)
		api.With(s.stateChanging).Post("/items", s.handleCreateItem)
		api.With(s.stateChanging).Post("/tasks", s.handleEnqueueTask)
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

// stateChanging guards POST routes: a foreign Origin or a cross-site fetch is 403, a body that is not JSON is 415 and a
// body over 4 KiB is 413 (checked up front by Content-Length, and by the capped reader when the length is unknown).
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

func (s *Server) email(w http.ResponseWriter, r *http.Request) (string, bool) {
	email, ok := s.EmailOf(r)
	if !ok || email == "" {
		// Unreachable behind Auth; fail closed anyway.
		writeError(w, http.StatusUnauthorized, "unauthenticated")
		return "", false
	}
	return email, true
}

func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	email, ok := s.email(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"email": email})
}

func (s *Server) handleListItems(w http.ResponseWriter, r *http.Request) {
	rows, err := s.Store.ListItems(r.Context())
	if err != nil {
		s.Logger.Error("list items failed", "error", err)
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	items := make([]itemJSON, 0, len(rows))
	for _, row := range rows {
		items = append(items, toItemJSON(row))
	}
	writeJSON(w, http.StatusOK, map[string][]itemJSON{"items": items})
}

func (s *Server) handleCreateItem(w http.ResponseWriter, r *http.Request) {
	email, ok := s.email(w, r)
	if !ok {
		return
	}
	body, tooLarge := readBody(r)
	if tooLarge {
		writeError(w, http.StatusRequestEntityTooLarge, "too_large")
		return
	}
	var in struct {
		Text *string `json:"text"`
	}
	if err := json.Unmarshal(body, &in); err != nil || in.Text == nil {
		writeError(w, http.StatusBadRequest, "invalid_text")
		return
	}
	text := strings.TrimSpace(*in.Text)
	if n := utf8.RuneCountInString(text); n < 1 || n > maxTextRunes || strings.ContainsRune(text, 0) { // Postgres text cannot hold NUL
		writeError(w, http.StatusBadRequest, "invalid_text")
		return
	}
	item, err := s.Store.CreateItem(r.Context(), db.CreateItemParams{Text: text, CreatedBy: email, Source: "user"})
	if err != nil {
		s.Logger.Error("create item failed", "error", err)
		writeError(w, http.StatusInternalServerError, "internal")
		return
	}
	writeJSON(w, http.StatusCreated, toItemJSON(item))
}

func (s *Server) handleEnqueueTask(w http.ResponseWriter, r *http.Request) {
	email, ok := s.email(w, r)
	if !ok {
		return
	}
	// The body is ignored entirely, but it is still read so the 4 KiB cap applies.
	if _, tooLarge := readBody(r); tooLarge {
		writeError(w, http.StatusRequestEntityTooLarge, "too_large")
		return
	}
	id, err := s.Queue.Enqueue(r.Context(), "add-note", map[string]string{"by": email})
	switch {
	case err == nil:
		writeJSON(w, http.StatusAccepted, map[string]string{"id": id})
	case errors.Is(err, platform.ErrQueueFull):
		writeError(w, http.StatusTooManyRequests, "queue_full")
	default:
		s.Logger.Error("enqueue failed", "job", "add-note", "error", err)
		writeError(w, http.StatusInternalServerError, "queue_error")
	}
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
