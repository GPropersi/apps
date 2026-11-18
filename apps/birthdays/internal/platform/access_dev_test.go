//go:build dev

package platform

import (
	"net/http"
	"testing"
)

// The dev build accepts ACCESS_DEV_EMAIL (lowercased) without a JWT, and still validates when it is unset.
func TestDevBuildAcceptsDevEmail(t *testing.T) {
	t.Setenv("ACCESS_DEV_EMAIL", "Dev.User@Example.com")
	status, _, reached, id := do(t, nil, nil)
	if status != http.StatusOK || !reached || id.Email != "dev.user@example.com" {
		t.Fatalf("status %d, reached %v, email %q", status, reached, id.Email)
	}
}

func TestDevBuildStillRejectsWhenUnset(t *testing.T) {
	t.Setenv("ACCESS_DEV_EMAIL", "")
	captureLog(t)
	status, _, reached, _ := do(t, nil, nil)
	if status != http.StatusUnauthorized || reached {
		t.Fatalf("status %d, reached %v; want 401", status, reached)
	}
}
