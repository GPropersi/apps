//go:build !dev

package app

// extraOriginAllowed is false in the production build: a state-changing request is accepted only from
// https://<Host>. The `dev` build (origin_dev.go) is the one place that relaxes this.
func extraOriginAllowed(_, _ string) bool { return false }
