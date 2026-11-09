//go:build !dev

package platform

// devIdentity is always false in the production build: there is no development identity and nothing reads the
// environment.
func devIdentity() (Identity, bool) {
	return Identity{}, false
}
