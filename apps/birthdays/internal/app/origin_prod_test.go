//go:build !dev

package app

import "testing"

func TestProductionBuildRefusesDevOrigins(t *testing.T) {
	for _, origin := range []string{"http://" + testHost, "http://localhost:5173", "http://localhost:8080", "https://localhost:5173"} {
		hn := newHarness(t)
		rec := hn.do(req{method: "POST", path: "/api/probe", probe: true, json: true, body: `{"x":1}`, header: map[string]string{"Origin": origin}})
		if rec.Code != 403 {
			t.Errorf("origin %q = %d, want 403", origin, rec.Code)
		}
		if hn.probeHits.Load() != 0 {
			t.Errorf("origin %q reached the handler", origin)
		}
	}
}
