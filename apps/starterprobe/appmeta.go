// Package app_starterprobe exposes the app's registry file to the binary, so the server reads the same declarations the
// platform registers (jobs and so on) instead of repeating them.
package app_starterprobe

import _ "embed"

// AppYAML is the app.yaml that sits next to this file.
//
//go:embed app.yaml
var AppYAML []byte
