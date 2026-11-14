// Command server is the template app's entry point: it wires the logger and signals and hands off to app.Run.
package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/gpropersi/apps/apps/starterprobe/internal/app"
)

// version is set at build time: -ldflags '-X main.version=<VERSION>'.
var version = "dev"

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger) // the platform helpers log through the standard log package, which now lands here too

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	deps, err := app.ProductionDeps(version, logger)
	if err == nil {
		err = app.Run(ctx, deps)
	}
	if err != nil {
		logger.Error("server exited", "error", err)
		stop()
		os.Exit(1)
	}
}
