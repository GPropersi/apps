// Package migrations embeds the goose SQL migrations, so the server applies them from its own binary on start.
//
// Rule: every migration must stay compatible with the previous version of the app. A rollback restores the old
// container but never reverts the schema, so the old code runs against the new schema.
package migrations

import "embed"

// FS holds the *.sql migrations at its root.
//
//go:embed *.sql
var FS embed.FS
