//go:build dev

package platform

import (
	"os"
	"strings"
)

// devIdentity is the local-development identity: ACCESS_DEV_EMAIL stands in for a validated JWT. This file exists
// only in builds with the `dev` tag; the production build has no code path that reads the variable.
func devIdentity() (Identity, bool) {
	email := strings.ToLower(strings.TrimSpace(os.Getenv("ACCESS_DEV_EMAIL")))
	if email == "" {
		return Identity{}, false
	}
	return Identity{Email: email}, true
}
