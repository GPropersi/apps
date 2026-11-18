package app

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gpropersi/apps/apps/birthdays/internal/platform"
)

func decode(t *testing.T, body string, into any) {
	t.Helper()
	if err := json.Unmarshal([]byte(body), into); err != nil {
		t.Fatalf("response is not the expected JSON: %q: %v", body, err)
	}
}

func wantError(t *testing.T, status int, body, code string, rec interface {
	Header() http.Header
}) {
	t.Helper()
	var got struct{ Error string }
	decode(t, body, &got)
	if got.Error != code {
		t.Fatalf("status %d error %q, want %q (body %q)", status, got.Error, code, body)
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("Content-Type %q, want application/json", ct)
	}
}

func TestHealthzNeedsNoAuthAndNoDatabase(t *testing.T) {
	hn := newHarness(t)
	rec := hn.do(req{method: "GET", path: "/healthz", noAuth: true})
	if rec.Code != 200 || strings.TrimSpace(rec.Body.String()) != "ok" {
		t.Fatalf("healthz = %d %q", rec.Code, rec.Body.String())
	}
}

func TestEveryAPIRouteIs401WithoutIdentity(t *testing.T) {
	hn := newHarness(t)
	for _, c := range []struct {
		method, path string
		probe        bool
	}{
		{"GET", "/api/me", false}, {"POST", "/api/me", false}, {"GET", "/api/unknown", false},
		{"DELETE", "/api/me", false}, {"GET", "/api", false}, {"POST", "/api/probe", true}, {"PUT", "/api/probe", true},
		{"DELETE", "/api/probe", true},
	} {
		rec := hn.do(req{method: c.method, path: c.path, noAuth: true, json: true, body: `{"x":1}`, probe: c.probe})
		if rec.Code != 401 {
			t.Errorf("%s %s = %d, want 401", c.method, c.path, rec.Code)
		}
	}
	if hn.probeHits.Load() != 0 {
		t.Fatal("an unauthenticated request reached a handler")
	}
}

func TestMe(t *testing.T) {
	rec := newHarness(t).do(req{method: "GET", path: "/api/me"})
	var got struct{ Email string }
	decode(t, rec.Body.String(), &got)
	if rec.Code != 200 || got.Email != testEmail {
		t.Fatalf("me = %d %q", rec.Code, rec.Body.String())
	}
}

func TestTheTemplateSampleRoutesAreGone(t *testing.T) {
	hn := newHarness(t)
	for _, c := range []struct{ method, path string }{
		{"GET", "/api/items"}, {"POST", "/api/items"}, {"POST", "/api/tasks"}, {"GET", "/api/tasks"},
	} {
		rec := hn.do(req{method: c.method, path: c.path, json: true, body: `{"text":"x"}`})
		if rec.Code != 404 {
			t.Errorf("%s %s = %d, want 404", c.method, c.path, rec.Code)
		}
	}
	if len(hn.queue.calls) != 0 {
		t.Fatal("a removed route queued a job")
	}
}

func TestCrossSiteStateChangesAreRefused(t *testing.T) {
	cases := map[string]map[string]string{
		"foreign origin":      {"Origin": "https://evil.example"},
		"null origin":         {"Origin": "null"},
		"origin other port":   {"Origin": "https://" + testHost + ":8443"},
		"fetch cross-site":    {"Sec-Fetch-Site": "cross-site"},
		"origin and fetch":    {"Origin": "https://" + testHost, "Sec-Fetch-Site": "cross-site"},
		"origin as subdomain": {"Origin": "https://x." + testHost},
	}
	for name, header := range cases {
		for _, method := range []string{"POST", "PUT", "PATCH", "DELETE"} {
			hn := newHarness(t)
			rec := hn.do(req{method: method, path: "/api/probe", probe: true, json: true, body: `{"x":1}`, header: header})
			if rec.Code != 403 {
				t.Errorf("%s %s = %d, want 403", name, method, rec.Code)
				continue
			}
			wantError(t, rec.Code, rec.Body.String(), "cross_site", rec)
			if hn.probeHits.Load() != 0 {
				t.Errorf("%s %s had an effect", name, method)
			}
		}
	}
}

func TestSameOriginStateChangesPass(t *testing.T) {
	for name, header := range map[string]map[string]string{
		"origin matches host": {"Origin": "https://" + testHost},
		"same-origin fetch":   {"Origin": "https://" + testHost, "Sec-Fetch-Site": "same-origin"},
		"no origin":           nil,
	} {
		hn := newHarness(t)
		if rec := hn.do(req{method: "PUT", path: "/api/probe", probe: true, json: true, body: `{"x":1}`, header: header}); rec.Code != 204 {
			t.Errorf("%s = %d, want 204", name, rec.Code)
		}
	}
}

func TestStateChangesNeedJSONContentType(t *testing.T) {
	for _, ct := range []string{"", "text/plain", "application/x-www-form-urlencoded", "application/jsonx", "multipart/form-data; boundary=x"} {
		for _, method := range []string{"POST", "DELETE"} {
			hn := newHarness(t)
			header := map[string]string{}
			if ct != "" {
				header["Content-Type"] = ct
			}
			rec := hn.do(req{method: method, path: "/api/probe", probe: true, body: `{"x":1}`, header: header})
			if rec.Code != 415 {
				t.Errorf("%s with %q = %d, want 415", method, ct, rec.Code)
				continue
			}
			wantError(t, rec.Code, rec.Body.String(), "unsupported_media_type", rec)
			if hn.probeHits.Load() != 0 {
				t.Errorf("%s with %q had an effect", method, ct)
			}
		}
	}
	hn := newHarness(t)
	if rec := hn.do(req{method: "POST", path: "/api/probe", probe: true, body: `{"x":1}`,
		header: map[string]string{"Content-Type": "application/json; charset=utf-8"}}); rec.Code != 204 {
		t.Errorf("json with a charset = %d, want 204", rec.Code)
	}
}

func TestBodiesOver4KiBAre413(t *testing.T) {
	big := `{"x":"` + strings.Repeat("p", 4096) + `"}`
	// Known length: refused before the body is read.
	hn := newHarness(t)
	rec := hn.do(req{method: "POST", path: "/api/probe", probe: true, json: true, body: big})
	if rec.Code != 413 {
		t.Fatalf("known length = %d, want 413", rec.Code)
	}
	wantError(t, rec.Code, rec.Body.String(), "too_large", rec)
	if hn.probeHits.Load() != 0 {
		t.Fatal("an oversized body reached the handler")
	}

	// Unknown length (chunked): refused by the capped reader.
	hr, _ := http.NewRequest("POST", "/api/probe", io.NopCloser(strings.NewReader(big)))
	hr.ContentLength = -1
	hr.Host = testHost
	hr.Header.Set("X-Test-Email", testEmail)
	hr.Header.Set("Content-Type", "application/json")
	rr := &recorder{header: http.Header{}}
	hn.probe.ServeHTTP(rr, hr)
	if rr.status != 413 {
		t.Fatalf("chunked = %d, want 413", rr.status)
	}

	// Exactly 4 KiB still passes.
	hn = newHarness(t)
	exact := `{"x":"` + strings.Repeat("p", 4096-len(`{"x":""}`)) + `"}`
	if len(exact) != 4096 {
		t.Fatalf("test body is %d bytes", len(exact))
	}
	if rec := hn.do(req{method: "POST", path: "/api/probe", probe: true, json: true, body: exact}); rec.Code != 204 {
		t.Fatalf("a 4096-byte body = %d, want 204", rec.Code)
	}
	if hn.probeBytes.Load() != 4096 {
		t.Fatalf("the handler read %d bytes, want 4096", hn.probeBytes.Load())
	}
}

// recorder is a bare ResponseWriter, used where the request has an unknown length.
type recorder struct {
	header http.Header
	status int
	body   strings.Builder
}

func (r *recorder) Header() http.Header { return r.header }
func (r *recorder) WriteHeader(s int)   { r.status = s }
func (r *recorder) Write(b []byte) (int, error) {
	if r.status == 0 {
		r.status = 200
	}
	return r.body.Write(b)
}

func TestAPIUnknownAndWrongMethod(t *testing.T) {
	hn := newHarness(t)
	for _, path := range []string{"/api/nope", "/api/me/1", "/api/", "/api"} {
		rec := hn.do(req{method: "GET", path: path})
		if rec.Code != 404 {
			t.Errorf("GET %s = %d, want 404", path, rec.Code)
			continue
		}
		wantError(t, rec.Code, rec.Body.String(), "not_found", rec)
	}
	for _, c := range []struct{ method, path string }{{"POST", "/api/me"}, {"PUT", "/api/me"}, {"DELETE", "/api/me"}, {"PATCH", "/api/me"}} {
		rec := hn.do(req{method: c.method, path: c.path, json: true, body: `{}`})
		if rec.Code != 405 {
			t.Errorf("%s %s = %d, want 405", c.method, c.path, rec.Code)
			continue
		}
		wantError(t, rec.Code, rec.Body.String(), "method_not_allowed", rec)
	}
}

func TestUnsupportedMediaTypeWinsOverTooLarge(t *testing.T) {
	rec := newHarness(t).do(req{method: "POST", path: "/api/probe", probe: true, body: strings.Repeat("p", 5000)})
	if rec.Code != 415 {
		t.Fatalf("an oversized non-JSON body = %d, want 415 (the content-type gate runs first)", rec.Code)
	}
}

func TestAPanicAnswers500WithSecurityHeaders(t *testing.T) {
	srv := &Server{
		Store: newFakeStore(), Queue: &fakeQueue{}, Static: testStatic, Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		Jobs: http.HandlerFunc(func(http.ResponseWriter, *http.Request) { panic("boom") }),
		Auth: fakeAuth.Middleware, EmailOf: fakeAuth.EmailOf,
	}
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, httptest.NewRequest("POST", "/_jobs/reminder-scan", nil))
	if rec.Code != 500 || rec.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("panic = %d, headers %v", rec.Code, rec.Header())
	}
}

func TestNeverAnswers502503504(t *testing.T) {
	hn := newHarness(t)
	for _, r := range []req{
		{method: "GET", path: "/api/me"}, {method: "POST", path: "/api/me", json: true, body: `{}`},
		{method: "GET", path: "/api/items"}, {method: "GET", path: "/nope"},
		{method: "POST", path: "/api/probe", probe: true, json: true, body: strings.Repeat("p", 5000)},
	} {
		if rec := hn.do(r); rec.Code >= 502 && rec.Code <= 504 {
			t.Errorf("%s %s = %d", r.method, r.path, rec.Code)
		}
	}
}

func TestSecurityHeadersOnEveryResponse(t *testing.T) {
	big := strings.Repeat("p", 5000)
	for name, r := range map[string]req{
		"200 healthz":   {method: "GET", path: "/healthz", noAuth: true},
		"200 spa":       {method: "GET", path: "/", noAuth: true},
		"200 api":       {method: "GET", path: "/api/me"},
		"204 write":     {method: "POST", path: "/api/probe", probe: true, json: true, body: `{}`},
		"401":           {method: "GET", path: "/api/me", noAuth: true},
		"403":           {method: "POST", path: "/api/probe", probe: true, json: true, body: `{}`, header: map[string]string{"Origin": "https://evil.example"}},
		"404 api":       {method: "GET", path: "/api/nope"},
		"404 spa":       {method: "GET", path: "/favicon.ico", noAuth: true},
		"405 api":       {method: "DELETE", path: "/api/me"},
		"405 spa":       {method: "POST", path: "/", noAuth: true},
		"413":           {method: "POST", path: "/api/probe", probe: true, json: true, body: big},
		"415":           {method: "POST", path: "/api/probe", probe: true, body: `{}`},
		"jobs route":    {method: "POST", path: "/_jobs/reminder-scan", noAuth: true},
		"cdn-cgi route": {method: "GET", path: "/cdn-cgi/access/logout", noAuth: true},
	} {
		rec := newHarness(t).do(r)
		for header, want := range map[string]string{
			"Content-Security-Policy": "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'",
			"X-Content-Type-Options":  "nosniff",
			"Referrer-Policy":         "same-origin",
		} {
			if got := rec.Header().Get(header); got != want {
				t.Errorf("%s (%d): %s = %q, want %q", name, rec.Code, header, got, want)
			}
		}
	}
}

func TestJobsRouteReachesTheJobsHandler(t *testing.T) {
	rec := newHarness(t).do(req{method: "POST", path: "/_jobs/reminder-scan", noAuth: true})
	if rec.Code != http.StatusTeapot {
		t.Fatalf("/_jobs/reminder-scan = %d, want the jobs handler", rec.Code)
	}
}

func TestSPAServing(t *testing.T) {
	hn := newHarness(t)
	index := string(testStatic["index.html"].Data)
	for name, c := range map[string]struct {
		method, path string
		status       int
		body         string
		cache        string
	}{
		"root":                 {"GET", "/", 200, index, "no-cache"},
		"index.html":           {"GET", "/index.html", 200, index, "no-cache"},
		"client route":         {"GET", "/some/route", 200, index, "no-cache"},
		"trailing slash":       {"GET", "/some/route/", 200, index, "no-cache"},
		"cdn-cgi falls to spa": {"GET", "/cdn-cgi/access/logout", 200, index, "no-cache"},
		"hashed asset":         {"GET", "/assets/app-abc123.js", 200, "console.log(1)", "public, max-age=31536000, immutable"},
		"root file":            {"GET", "/robots.txt", 200, "User-agent: *\n", "no-cache"},
		"missing asset":        {"GET", "/assets/x.js", 404, "not found\n", ""},
		"missing asset noext":  {"GET", "/assets/x", 404, "not found\n", ""},
		"assets dir":           {"GET", "/assets/", 404, "not found\n", ""},
		"favicon":              {"GET", "/favicon.ico", 404, "not found\n", ""},
		"missing with ext":     {"GET", "/docs/guide.html", 404, "not found\n", ""},
		"dot dot":              {"GET", "/../../etc/passwd", 200, index, "no-cache"},
		"head route":           {"HEAD", "/some/route", 200, "", "no-cache"},
		"head missing":         {"HEAD", "/favicon.ico", 404, "", ""},
		"post":                 {"POST", "/", 405, "method not allowed\n", ""},
		"put route":            {"PUT", "/some/route", 405, "method not allowed\n", ""},
		"post healthz":         {"POST", "/healthz", 405, "method not allowed\n", ""},
	} {
		rec := hn.do(req{method: c.method, path: c.path, noAuth: true})
		if rec.Code != c.status {
			t.Errorf("%s: %s %s = %d, want %d", name, c.method, c.path, rec.Code, c.status)
			continue
		}
		// net/http drops a HEAD response body on the wire; the recorder does not, so only GET bodies are compared.
		if c.method != "HEAD" && rec.Body.String() != c.body {
			t.Errorf("%s: body %q, want %q", name, rec.Body.String(), c.body)
		}
		if got := rec.Header().Get("Cache-Control"); got != c.cache {
			t.Errorf("%s: Cache-Control %q, want %q", name, got, c.cache)
		}
	}
}

func TestRealAccessGateFailsClosedWithoutAVerifier(t *testing.T) {
	// The real middleware with no verifier must 401, never pass (even if a dev shell exports ACCESS_DEV_EMAIL).
	t.Setenv("ACCESS_DEV_EMAIL", "")
	hn := newHarness(t)
	srv := &Server{
		Store: hn.store, Queue: hn.queue, Jobs: http.NotFoundHandler(), Static: testStatic,
		Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		Auth:   platform.RequireAccess(nil),
		EmailOf: func(r *http.Request) (string, bool) {
			id, ok := platform.IdentityFrom(r.Context())
			return id.Email, ok
		},
	}
	h := srv.Handler()
	for _, c := range []struct{ method, path string }{{"GET", "/api/me"}, {"POST", "/api/me"}, {"GET", "/api/birthdays"}} {
		hr := httptest.NewRequest(c.method, c.path, strings.NewReader(`{}`))
		hr.Header.Set("Content-Type", "application/json")
		hr.Header.Set("Cf-Access-Jwt-Assertion", "not-a-jwt")
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, hr)
		if rec.Code != 401 {
			t.Errorf("%s %s = %d, want 401", c.method, c.path, rec.Code)
		}
	}
	if len(hn.queue.calls) != 0 {
		t.Fatal("an unauthenticated request had an effect")
	}
}
