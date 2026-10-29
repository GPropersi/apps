package notify

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// WebhookKey is the one key jobs.env may hold.
const WebhookKey = "DISCORD_WEBHOOK"

const maxEnvBytes = 8192

// LoadEnv reads jobs.env as literal KEY=VALUE lines (no quoting, no expansion). It allows exactly one key,
// DISCORD_WEBHOOK, with an https:// value; blank lines and # comments are skipped. Any other key, a duplicate, a
// malformed line or a missing key is an error, so the runner refuses to start. Errors never include the value.
func LoadEnv(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("jobs.env: %w", err)
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxEnvBytes+1))
	if err != nil {
		return "", fmt.Errorf("jobs.env: %w", err)
	}
	if len(b) > maxEnvBytes {
		return "", errors.New("jobs.env: file is too large")
	}
	var hook string
	seen := false
	for i, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSuffix(line, "\r")
		if strings.TrimSpace(line) == "" || strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			return "", fmt.Errorf("jobs.env: line %d is not KEY=VALUE", i+1)
		}
		if k != WebhookKey {
			return "", fmt.Errorf("jobs.env: line %d has an unexpected key (only %s is allowed)", i+1, WebhookKey)
		}
		if seen {
			return "", fmt.Errorf("jobs.env: line %d repeats %s", i+1, WebhookKey)
		}
		seen = true
		if !strings.HasPrefix(v, "https://") || strings.ContainsAny(v, " \t\"'") || len(v) <= len("https://") {
			return "", fmt.Errorf("jobs.env: %s must be an https:// URL without spaces or quotes", WebhookKey)
		}
		hook = v
	}
	if !seen {
		return "", fmt.Errorf("jobs.env: %s is missing", WebhookKey)
	}
	return hook, nil
}
