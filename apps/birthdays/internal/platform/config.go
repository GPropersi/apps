// Package platform holds the helpers every app built from the go-react template shares: the deploy-time
// configuration loader and the Cloudflare Access identity check. It imports nothing from the app module, so `make
// app-new` copies it byte-for-byte into each app and a lint keeps the copies identical to the template.
package platform

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// Config is the deploy environment (platform/deploy/deploy.sh `swap`). Secrets were read from their *_FILE paths.
type Config struct {
	DBHost           string
	DBPort           int
	DBName           string
	DBUser           string
	DBPassword       string
	RedisHost        string
	RedisPort        int
	RedisUser        string
	RedisPassword    string
	RedisKeyPrefix   string
	JobsSecret       string
	AccessTeamDomain string
	AccessAud        string
}

// String and GoString keep the secrets out of any log line or %v/%#v/%+v print of a Config.
func (Config) String() string   { return "platform.Config{redacted}" }
func (Config) GoString() string { return "platform.Config{redacted}" }

// ConfigError names the key that is missing or invalid and why. It never carries the value.
type ConfigError struct {
	Key     string
	Problem string
}

func (e *ConfigError) Error() string { return "config: " + e.Key + " " + e.Problem }

var (
	hostRE   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)
	identRE  = regexp.MustCompile(`^[A-Za-z0-9_-]{1,63}$`)
	prefixRE = regexp.MustCompile(`^[A-Za-z0-9_-]{1,63}:$`)
	teamRE   = regexp.MustCompile(`^[a-z0-9-]+\.cloudflareaccess\.com$`)
	audRE    = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

// LoadConfig reads the deploy environment. Any missing or invalid value is an error naming the key, never the value;
// every problem found is reported, joined.
func LoadConfig() (Config, error) {
	return loadConfig(os.Getenv, os.ReadFile)
}

func loadConfig(getenv func(string) string, readFile func(string) ([]byte, error)) (Config, error) {
	var (
		c    Config
		errs []error
	)
	note := func(key, problem string) { errs = append(errs, &ConfigError{Key: key, Problem: problem}) }

	text := func(key string, re *regexp.Regexp) string {
		v := getenv(key)
		switch {
		case v == "":
			note(key, "is missing")
			return ""
		case !re.MatchString(v):
			note(key, "is invalid")
			return ""
		}
		return v
	}
	port := func(key string) int {
		v := getenv(key)
		if v == "" {
			note(key, "is missing")
			return 0
		}
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 || n > 65535 {
			note(key, "is invalid")
			return 0
		}
		return n
	}
	// secret reads the file the key names; one trailing newline is stripped.
	secret := func(key string) string {
		path := getenv(key)
		if path == "" {
			note(key, "is missing")
			return ""
		}
		if !filepath.IsAbs(path) {
			note(key, "is not an absolute path")
			return ""
		}
		b, err := readFile(path)
		if err != nil {
			note(key, "names a file that cannot be read")
			return ""
		}
		v := strings.TrimSuffix(string(b), "\n")
		if v == "" {
			note(key, "names an empty file")
			return ""
		}
		return v
	}

	c.DBHost = text("DB_HOST", hostRE)
	c.DBPort = port("DB_PORT")
	c.DBName = text("DB_NAME", identRE)
	c.DBUser = text("DB_USER", identRE)
	c.DBPassword = secret("DB_PASSWORD_FILE")
	c.RedisHost = text("REDIS_HOST", hostRE)
	c.RedisPort = port("REDIS_PORT")
	c.RedisUser = text("REDIS_USER", identRE)
	c.RedisPassword = secret("REDIS_PASSWORD_FILE")
	c.RedisKeyPrefix = text("REDIS_KEY_PREFIX", prefixRE)
	c.JobsSecret = secret("JOBS_SECRET_FILE")
	c.AccessTeamDomain = text("ACCESS_TEAM_DOMAIN", teamRE)
	c.AccessAud = text("ACCESS_AUD", audRE)

	if len(errs) > 0 {
		return Config{}, fmt.Errorf("platform: %w", errors.Join(errs...))
	}
	return c, nil
}
