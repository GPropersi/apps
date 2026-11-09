//go:build dev

package app

import "testing"

func TestDevBuildAcceptsPlainHTTPAndViteOrigins(t *testing.T) {
	for _, origin := range []string{"http://" + testHost, "http://localhost:5173", "https://" + testHost} {
		hn := newHarness(t)
		rec := hn.do(req{method: "POST", path: "/api/items", json: true, body: `{"text":"x"}`, header: map[string]string{"Origin": origin}})
		if rec.Code != 201 {
			t.Errorf("origin %q = %d, want 201", origin, rec.Code)
		}
	}
}

func TestDevBuildStillRefusesForeignOrigins(t *testing.T) {
	for _, origin := range []string{"https://evil.example", "http://evil.example", "http://localhost:5174", "http://localhost", "https://localhost:5173", "null"} {
		hn := newHarness(t)
		rec := hn.do(req{method: "POST", path: "/api/items", json: true, body: `{"text":"x"}`, header: map[string]string{"Origin": origin}})
		if rec.Code != 403 {
			t.Errorf("origin %q = %d, want 403", origin, rec.Code)
		}
		if hn.store.count() != 0 {
			t.Errorf("origin %q created an item", origin)
		}
	}
}
