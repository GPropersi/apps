package app

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gpropersi/apps/apps/starterprobe/internal/platform"
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
	hn.store.failList = errBoom
	rec := hn.do(req{method: "GET", path: "/healthz", noAuth: true})
	if rec.Code != 200 || strings.TrimSpace(rec.Body.String()) != "ok" {
		t.Fatalf("healthz = %d %q", rec.Code, rec.Body.String())
	}
}

func TestEveryAPIRouteIs401WithoutIdentity(t *testing.T) {
	hn := newHarness(t)
	for _, c := range []struct{ method, path string }{
		{"GET", "/api/me"}, {"GET", "/api/items"}, {"POST", "/api/items"}, {"POST", "/api/tasks"},
		{"GET", "/api/unknown"}, {"DELETE", "/api/items"}, {"GET", "/api"},
	} {
		rec := hn.do(req{method: c.method, path: c.path, noAuth: true, json: true, body: `{"text":"x"}`})
		if rec.Code != 401 {
			t.Errorf("%s %s = %d, want 401", c.method, c.path, rec.Code)
		}
	}
	if hn.store.count() != 0 || len(hn.queue.calls) != 0 {
		t.Fatal("an unauthenticated request had an effect")
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

func TestListItemsNewestFirstAndEmptyIsAnArray(t *testing.T) {
	hn := newHarness(t)
	rec := hn.do(req{method: "GET", path: "/api/items"})
	if rec.Code != 200 || strings.TrimSpace(rec.Body.String()) != `{"items":[]}` {
		t.Fatalf("empty list = %d %q", rec.Code, rec.Body.String())
	}
	for _, text := range []string{"first", "second"} {
		hn.do(req{method: "POST", path: "/api/items", json: true, body: `{"text":"` + text + `"}`})
	}
	rec = hn.do(req{method: "GET", path: "/api/items"})
	var got struct {
		Items []struct {
			ID        int64  `json:"id"`
			Text      string `json:"text"`
			CreatedBy string `json:"created_by"`
			Source    string `json:"source"`
			CreatedAt string `json:"created_at"`
		}
	}
	decode(t, rec.Body.String(), &got)
	if len(got.Items) != 2 || got.Items[0].Text != "second" || got.Items[1].Text != "first" {
		t.Fatalf("items = %+v", got.Items)
	}
	if got.Items[0].CreatedAt != "2026-01-02T03:04:05Z" || got.Items[0].Source != "user" || got.Items[0].CreatedBy != testEmail {
		t.Fatalf("item fields = %+v", got.Items[0])
	}
}

func TestListItemsStoreFailureIs500(t *testing.T) {
	hn := newHarness(t)
	hn.store.failList = errBoom
	rec := hn.do(req{method: "GET", path: "/api/items"})
	if rec.Code != 500 {
		t.Fatalf("status %d, want 500", rec.Code)
	}
	wantError(t, rec.Code, rec.Body.String(), "internal", rec)
}

func TestCreateItem(t *testing.T) {
	hn := newHarness(t)
	rec := hn.do(req{method: "POST", path: "/api/items", json: true, body: `{"text":"  hello  "}`})
	if rec.Code != 201 {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	var got struct {
		ID        int64  `json:"id"`
		Text      string `json:"text"`
		CreatedBy string `json:"created_by"`
		Source    string `json:"source"`
	}
	decode(t, rec.Body.String(), &got)
	if got.Text != "hello" || got.CreatedBy != testEmail || got.Source != "user" || got.ID == 0 {
		t.Fatalf("created = %+v", got)
	}
	if hn.store.count() != 1 {
		t.Fatalf("store holds %d items", hn.store.count())
	}
}

func TestCreateItemTextLimits(t *testing.T) {
	ok := []string{strings.Repeat("a", 200), strings.Repeat("é", 200), " x "}
	for _, text := range ok {
		hn := newHarness(t)
		b, _ := json.Marshal(map[string]string{"text": text})
		if rec := hn.do(req{method: "POST", path: "/api/items", json: true, body: string(b)}); rec.Code != 201 {
			t.Errorf("text of %d runes = %d, want 201", len([]rune(text)), rec.Code)
		}
	}
	bad := map[string]string{
		"malformed JSON": `{"text":`,
		"empty body":     ``,
		"missing text":   `{}`,
		"null text":      `{"text":null}`,
		"number text":    `{"text":5}`,
		"object text":    `{"text":{"a":1}}`,
		"array body":     `["x"]`,
		"empty text":     `{"text":""}`,
		"blank text":     `{"text":"   \n\t "}`,
		"201 characters": `{"text":"` + strings.Repeat("a", 201) + `"}`,
		"201 multibyte":  `{"text":"` + strings.Repeat("é", 201) + `"}`,
		"NUL character":  `{"text":"a\u0000b"}`,
	}
	for name, body := range bad {
		hn := newHarness(t)
		rec := hn.do(req{method: "POST", path: "/api/items", json: true, body: body})
		if rec.Code != 400 {
			t.Errorf("%s = %d, want 400", name, rec.Code)
			continue
		}
		wantError(t, rec.Code, rec.Body.String(), "invalid_text", rec)
		if hn.store.count() != 0 {
			t.Errorf("%s created an item", name)
		}
	}
}

func TestCreateItemStoreFailureIs500(t *testing.T) {
	hn := newHarness(t)
	hn.store.failItems = errBoom
	rec := hn.do(req{method: "POST", path: "/api/items", json: true, body: `{"text":"x"}`})
	if rec.Code != 500 {
		t.Fatalf("status %d, want 500", rec.Code)
	}
	wantError(t, rec.Code, rec.Body.String(), "internal", rec)
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
		for _, path := range []string{"/api/items", "/api/tasks"} {
			hn := newHarness(t)
			rec := hn.do(req{method: "POST", path: path, json: true, body: `{"text":"x"}`, header: header})
			if rec.Code != 403 {
				t.Errorf("%s %s = %d, want 403", name, path, rec.Code)
				continue
			}
			wantError(t, rec.Code, rec.Body.String(), "cross_site", rec)
			if hn.store.count() != 0 || len(hn.queue.calls) != 0 {
				t.Errorf("%s %s had an effect", name, path)
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
		if rec := hn.do(req{method: "POST", path: "/api/items", json: true, body: `{"text":"x"}`, header: header}); rec.Code != 201 {
			t.Errorf("%s = %d, want 201", name, rec.Code)
		}
	}
}

func TestStateChangesNeedJSONContentType(t *testing.T) {
	for _, ct := range []string{"", "text/plain", "application/x-www-form-urlencoded", "application/jsonx", "multipart/form-data; boundary=x"} {
		for _, path := range []string{"/api/items", "/api/tasks"} {
			hn := newHarness(t)
			header := map[string]string{}
			if ct != "" {
				header["Content-Type"] = ct
			}
			rec := hn.do(req{method: "POST", path: path, body: `{"text":"x"}`, header: header})
			if rec.Code != 415 {
				t.Errorf("%s with %q = %d, want 415", path, ct, rec.Code)
				continue
			}
			wantError(t, rec.Code, rec.Body.String(), "unsupported_media_type", rec)
			if hn.store.count() != 0 || len(hn.queue.calls) != 0 {
				t.Errorf("%s with %q had an effect", path, ct)
			}
		}
	}
	hn := newHarness(t)
	if rec := hn.do(req{method: "POST", path: "/api/items", body: `{"text":"x"}`,
		header: map[string]string{"Content-Type": "application/json; charset=utf-8"}}); rec.Code != 201 {
		t.Errorf("json with a charset = %d, want 201", rec.Code)
	}
}

func TestBodiesOver4KiBAre413(t *testing.T) {
	big := `{"text":"x","pad":"` + strings.Repeat("p", 4096) + `"}`
	for _, path := range []string{"/api/items", "/api/tasks"} {
		// Known length: refused before the body is read.
		hn := newHarness(t)
		rec := hn.do(req{method: "POST", path: path, json: true, body: big})
		if rec.Code != 413 {
			t.Fatalf("%s known length = %d, want 413", path, rec.Code)
		}
		wantError(t, rec.Code, rec.Body.String(), "too_large", rec)
		if hn.store.count() != 0 || len(hn.queue.calls) != 0 {
			t.Fatalf("%s had an effect", path)
		}

		// Unknown length (chunked): refused by the capped reader.
		hr, _ := http.NewRequest("POST", path, io.NopCloser(strings.NewReader(big)))
		hr.ContentLength = -1
		hr.Host = testHost
		hr.Header.Set("X-Test-Email", testEmail)
		hr.Header.Set("Content-Type", "application/json")
		rr := &recorder{header: http.Header{}}
		hn.h.ServeHTTP(rr, hr)
		if rr.status != 413 {
			t.Fatalf("%s chunked = %d, want 413", path, rr.status)
		}
	}
	// Exactly 4 KiB still passes.
	hn := newHarness(t)
	exact := `{"text":"x","pad":"` + strings.Repeat("p", 4096-len(`{"text":"x","pad":""}`)) + `"}`
	if len(exact) != 4096 {
		t.Fatalf("test body is %d bytes", len(exact))
	}
	if rec := hn.do(req{method: "POST", path: "/api/items", json: true, body: exact}); rec.Code != 201 {
		t.Fatalf("a 4096-byte body = %d, want 201", rec.Code)
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

func TestTasksIgnoreTheBody(t *testing.T) {
	for name, body := range map[string]string{
		"empty": ``, "object": `{}`, "malformed": `{"a":`, "array": `[1,2]`, "string": `"hi"`,
		"non-empty object": `{"by":"someone-else","x":1}`, "not json at all": `<xml/>`,
	} {
		hn := newHarness(t)
		rec := hn.do(req{method: "POST", path: "/api/tasks", json: true, body: body})
		if rec.Code != 202 {
			t.Errorf("%s = %d, want 202", name, rec.Code)
			continue
		}
		var got struct{ ID string }
		decode(t, rec.Body.String(), &got)
		if got.ID == "" {
			t.Errorf("%s: no id in %q", name, rec.Body.String())
		}
		if len(hn.queue.calls) != 1 || hn.queue.calls[0]["by"] != testEmail || len(hn.queue.calls[0]) != 1 {
			t.Errorf("%s: payload = %v, want only by=%s", name, hn.queue.calls, testEmail)
		}
	}
}

func TestTasksQueueErrors(t *testing.T) {
	for name, c := range map[string]struct {
		err    error
		status int
		code   string
	}{
		"queue full":    {platform.ErrQueueFull, 429, "queue_full"},
		"redis failure": {errBoom, 500, "queue_error"},
		"too large":     {platform.ErrEnvelopeTooLarge, 500, "queue_error"},
	} {
		hn := newHarness(t)
		hn.queue.err = c.err
		rec := hn.do(req{method: "POST", path: "/api/tasks", json: true, body: `{}`})
		if rec.Code != c.status {
			t.Errorf("%s = %d, want %d", name, rec.Code, c.status)
			continue
		}
		wantError(t, rec.Code, rec.Body.String(), c.code, rec)
	}
}

func TestAPIUnknownAndWrongMethod(t *testing.T) {
	hn := newHarness(t)
	for _, path := range []string{"/api/nope", "/api/items/1", "/api/", "/api"} {
		rec := hn.do(req{method: "GET", path: path})
		if rec.Code != 404 {
			t.Errorf("GET %s = %d, want 404", path, rec.Code)
			continue
		}
		wantError(t, rec.Code, rec.Body.String(), "not_found", rec)
	}
	for _, c := range []struct{ method, path string }{
		{"DELETE", "/api/items"}, {"PUT", "/api/items"}, {"POST", "/api/me"}, {"GET", "/api/tasks"}, {"PATCH", "/api/tasks"},
	} {
		rec := hn.do(req{method: c.method, path: c.path, json: true, body: `{}`})
		if rec.Code != 405 {
			t.Errorf("%s %s = %d, want 405", c.method, c.path, rec.Code)
			continue
		}
		wantError(t, rec.Code, rec.Body.String(), "method_not_allowed", rec)
	}
}

func TestUnsupportedMediaTypeWinsOverTooLarge(t *testing.T) {
	rec := newHarness(t).do(req{method: "POST", path: "/api/items", body: strings.Repeat("p", 5000)})
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
	srv.Handler().ServeHTTP(rec, httptest.NewRequest("POST", "/_jobs/add-note", nil))
	if rec.Code != 500 || rec.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("panic = %d, headers %v", rec.Code, rec.Header())
	}
}

func TestNeverAnswers502503504(t *testing.T) {
	hn := newHarness(t)
	hn.store.failList = errBoom
	hn.queue.err = errBoom
	for _, r := range []req{
		{method: "GET", path: "/api/items"}, {method: "POST", path: "/api/tasks", json: true, body: `{}`},
		{method: "POST", path: "/api/items", json: true, body: `{"text":"x"}`}, {method: "GET", path: "/nope"},
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
		"201 create":    {method: "POST", path: "/api/items", json: true, body: `{"text":"x"}`},
		"202 task":      {method: "POST", path: "/api/tasks", json: true, body: `{}`},
		"400":           {method: "POST", path: "/api/items", json: true, body: `{}`},
		"401":           {method: "GET", path: "/api/me", noAuth: true},
		"403":           {method: "POST", path: "/api/items", json: true, body: `{}`, header: map[string]string{"Origin": "https://evil.example"}},
		"404 api":       {method: "GET", path: "/api/nope"},
		"404 spa":       {method: "GET", path: "/favicon.ico", noAuth: true},
		"405 api":       {method: "DELETE", path: "/api/items"},
		"405 spa":       {method: "POST", path: "/", noAuth: true},
		"413":           {method: "POST", path: "/api/items", json: true, body: big},
		"415":           {method: "POST", path: "/api/items", body: `{}`},
		"jobs route":    {method: "POST", path: "/_jobs/add-note", noAuth: true},
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
	rec := newHarness(t).do(req{method: "POST", path: "/_jobs/add-note", noAuth: true})
	if rec.Code != http.StatusTeapot {
		t.Fatalf("/_jobs/add-note = %d, want the jobs handler", rec.Code)
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
	for _, c := range []struct{ method, path string }{{"GET", "/api/me"}, {"GET", "/api/items"}, {"POST", "/api/items"}, {"POST", "/api/tasks"}} {
		hr := httptest.NewRequest(c.method, c.path, strings.NewReader(`{"text":"x"}`))
		hr.Header.Set("Content-Type", "application/json")
		hr.Header.Set("Cf-Access-Jwt-Assertion", "not-a-jwt")
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, hr)
		if rec.Code != 401 {
			t.Errorf("%s %s = %d, want 401", c.method, c.path, rec.Code)
		}
	}
	if hn.store.count() != 0 || len(hn.queue.calls) != 0 {
		t.Fatal("an unauthenticated request had an effect")
	}
}
