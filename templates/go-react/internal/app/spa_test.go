package app

import (
	"errors"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"testing"
	"testing/fstest"
)

// errFS fails every Open with err.
type errFS struct{ err error }

func (e errFS) Open(string) (fs.File, error) { return nil, e.err }

// noSeekFile is a regular file that is not an io.ReadSeeker.
type noSeekFile struct{}

func (noSeekFile) Stat() (fs.FileInfo, error) {
	return fstest.MapFS{"index.html": &fstest.MapFile{Data: []byte("x")}}.Stat("index.html")
}
func (noSeekFile) Read([]byte) (int, error) { return 0, errors.New("unused") }
func (noSeekFile) Close() error             { return nil }

type noSeekFS struct{}

func (noSeekFS) Open(string) (fs.File, error) { return noSeekFile{}, nil }

func TestSPAHandlerDefensive500s(t *testing.T) {
	for name, files := range map[string]fs.FS{
		"open error that is not a missing file": errFS{err: fs.ErrPermission},
		"file that is not a ReadSeeker":         noSeekFS{},
	} {
		rec := httptest.NewRecorder()
		spaHandler{files: files}.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/index.html", nil))
		if rec.Code != http.StatusInternalServerError {
			t.Errorf("%s: status = %d, want 500", name, rec.Code)
		}
		if ct := rec.Header().Get("Content-Type"); ct != "text/plain; charset=utf-8" {
			t.Errorf("%s: content type = %q, want plain text", name, ct)
		}
	}
}
