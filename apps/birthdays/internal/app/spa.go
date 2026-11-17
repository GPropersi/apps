package app

import (
	"embed"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"path"
	"strings"
	"time"
)

// staticFS is the SPA build. The Docker build overwrites static/ with the Vite output; in git it holds only a
// placeholder index.html so `go build` works without Node.
//
//go:embed all:static
var staticFS embed.FS

// Static returns the embedded SPA files rooted at the static directory.
func Static() (fs.FS, error) {
	return fs.Sub(staticFS, "static")
}

const (
	cacheHashed = "public, max-age=31536000, immutable"
	cacheNone   = "no-cache"
)

// spaHandler serves GET and HEAD from the SPA build. An existing file is served as is (hashed assets/* with a long
// cache, everything else no-cache). A missing path under assets/ or with a file extension (so /favicon.ico too) is a
// plain-text 404; any other missing path is a client-side route and gets index.html with 200. Other methods are 405.
type spaHandler struct {
	files fs.FS
}

func (h spaHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		plain(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	name := strings.TrimPrefix(path.Clean("/"+r.URL.Path), "/")
	if name == "" {
		name = "index.html"
	}
	if h.serve(w, r, name) {
		return
	}
	if name == "assets" || strings.HasPrefix(name, "assets/") || path.Ext(name) != "" {
		plain(w, http.StatusNotFound, "not found")
		return
	}
	if !h.serve(w, r, "index.html") {
		plain(w, http.StatusNotFound, "not found")
	}
}

// serve writes the named regular file and reports whether it exists.
func (h spaHandler) serve(w http.ResponseWriter, r *http.Request, name string) bool {
	f, err := h.files.Open(name)
	if err != nil {
		if !errors.Is(err, fs.ErrNotExist) && !errors.Is(err, fs.ErrInvalid) {
			// Unreadable but present: answer a plain 500 rather than pretending the path is a route.
			plain(w, http.StatusInternalServerError, "internal error")
			return true
		}
		return false
	}
	defer func() { _ = f.Close() }()
	info, err := f.Stat()
	if err != nil || info.IsDir() {
		return false
	}
	rs, ok := f.(io.ReadSeeker)
	if !ok {
		plain(w, http.StatusInternalServerError, "internal error")
		return true
	}
	if strings.HasPrefix(name, "assets/") {
		w.Header().Set("Cache-Control", cacheHashed)
	} else {
		w.Header().Set("Cache-Control", cacheNone)
	}
	http.ServeContent(w, r, name, time.Time{}, rs)
	return true
}

func plain(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(status)
	_, _ = io.WriteString(w, msg+"\n")
}
