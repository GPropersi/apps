//go:build !dev

package platform

import (
	"net/http"
	"testing"
)

// The production build ignores ACCESS_DEV_EMAIL: a request without a JWT is rejected even when it is set.
func TestProductionBuildIgnoresDevEmail(t *testing.T) {
	k := newTestKey(t, "k1")
	srv := newJWKS(t, k)
	v := newVerifier(t, srv.URL)
	t.Setenv("ACCESS_DEV_EMAIL", "dev@example.com")
	captureLog(t)

	status, _, reached, _ := do(t, v, nil)
	if status != http.StatusUnauthorized || reached {
		t.Fatalf("with ACCESS_DEV_EMAIL set and no JWT: status %d, reached %v; want 401", status, reached)
	}
	// Also with a nil verifier, the case a misconfigured start would produce.
	status, _, reached, _ = do(t, nil, nil)
	if status != http.StatusUnauthorized || reached {
		t.Fatalf("nil verifier with ACCESS_DEV_EMAIL set: status %d, reached %v; want 401", status, reached)
	}
	if _, ok := devIdentity(); ok {
		t.Fatal("devIdentity must be false in the production build")
	}
}
