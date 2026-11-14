package platform

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Distinctive values, so a leak into an error or log line is unmistakable.
const (
	secretDBPass    = "db-pass-SENTINEL-1"
	secretRedisPass = "redis-pass-SENTINEL-2"
	secretJobs      = "jobs-secret-SENTINEL-3"
)

func validEnv(t *testing.T) map[string]string {
	t.Helper()
	dir := t.TempDir()
	write := func(name, content string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
		return p
	}
	return map[string]string{
		"DB_HOST":             "pg.internal",
		"DB_PORT":             "5432",
		"DB_NAME":             "my_app",
		"DB_USER":             "my_app",
		"DB_PASSWORD_FILE":    write("db-password", secretDBPass+"\n"),
		"REDIS_HOST":          "redis.internal",
		"REDIS_PORT":          "6379",
		"REDIS_USER":          "my-app",
		"REDIS_PASSWORD_FILE": write("redis-password", secretRedisPass+"\n"),
		"REDIS_KEY_PREFIX":    "my-app:",
		"JOBS_SECRET_FILE":    write("jobs-secret", secretJobs),
		"ACCESS_TEAM_DOMAIN":  testTeam,
		"ACCESS_AUD":          testAud,
	}
}

func load(env map[string]string) (Config, error) {
	return loadConfig(func(k string) string { return env[k] }, os.ReadFile)
}

func TestLoadConfigValid(t *testing.T) {
	c, err := load(validEnv(t))
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if c.DBHost != "pg.internal" || c.DBPort != 5432 || c.DBName != "my_app" || c.RedisPort != 6379 || c.RedisKeyPrefix != "my-app:" {
		t.Fatalf("unexpected config fields: %+v", c)
	}
	// Exactly one trailing newline is stripped.
	if c.DBPassword != secretDBPass || c.RedisPassword != secretRedisPass || c.JobsSecret != secretJobs {
		t.Fatal("secrets were not read from their files with one trailing newline stripped")
	}
}

func TestLoadConfigStripsOnlyOneNewline(t *testing.T) {
	env := validEnv(t)
	if err := os.WriteFile(env["DB_PASSWORD_FILE"], []byte("pw\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	c, err := load(env)
	if err != nil || c.DBPassword != "pw\n" {
		t.Fatalf("got %q, %v; want %q", c.DBPassword, err, "pw\n")
	}
}

func TestLoadConfigErrorsNameTheKeyNeverTheValue(t *testing.T) {
	missing := []string{
		"DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD_FILE", "REDIS_HOST", "REDIS_PORT", "REDIS_USER",
		"REDIS_PASSWORD_FILE", "REDIS_KEY_PREFIX", "JOBS_SECRET_FILE", "ACCESS_TEAM_DOMAIN", "ACCESS_AUD",
	}
	for _, key := range missing {
		t.Run("missing "+key, func(t *testing.T) {
			env := validEnv(t)
			delete(env, key)
			c, err := load(env)
			if err == nil {
				t.Fatal("LoadConfig succeeded, want an error")
			}
			var ce *ConfigError
			if !errors.As(err, &ce) || ce.Key != key {
				t.Fatalf("error %q does not name %s", err, key)
			}
			if c != (Config{}) {
				t.Fatal("a failed load must return the zero Config (fail closed)")
			}
		})
	}
}

func TestLoadConfigInvalidValues(t *testing.T) {
	bad := map[string]string{
		"DB_HOST":            "bad host/leak-SENTINEL",
		"DB_PORT":            "99999-leak-SENTINEL",
		"DB_NAME":            "has space leak-SENTINEL",
		"REDIS_PORT":         "0",
		"REDIS_KEY_PREFIX":   "no-colon-leak-SENTINEL",
		"ACCESS_TEAM_DOMAIN": "evil.example.com-leak-SENTINEL",
		"ACCESS_AUD":         "not-hex-leak-SENTINEL",
		"JOBS_SECRET_FILE":   "relative/leak-SENTINEL",
	}
	for key, val := range bad {
		t.Run("invalid "+key, func(t *testing.T) {
			env := validEnv(t)
			env[key] = val
			_, err := load(env)
			if err == nil {
				t.Fatal("LoadConfig succeeded, want an error")
			}
			if !strings.Contains(err.Error(), key) {
				t.Fatalf("error %q does not name %s", err, key)
			}
			if strings.Contains(err.Error(), "leak-SENTINEL") {
				t.Fatalf("error %q leaks the value", err)
			}
		})
	}
}

func TestLoadConfigUnreadableAndEmptySecretFiles(t *testing.T) {
	env := validEnv(t)
	env["DB_PASSWORD_FILE"] = filepath.Join(t.TempDir(), "absent")
	if _, err := load(env); err == nil || !strings.Contains(err.Error(), "DB_PASSWORD_FILE") {
		t.Fatalf("unreadable file: %v", err)
	}
	env = validEnv(t)
	if err := os.WriteFile(env["JOBS_SECRET_FILE"], []byte("\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := load(env); err == nil || !strings.Contains(err.Error(), "JOBS_SECRET_FILE") {
		t.Fatalf("empty file: %v", err)
	}
}

func TestLoadConfigReportsEveryProblem(t *testing.T) {
	_, err := load(map[string]string{})
	if err == nil {
		t.Fatal("empty env succeeded")
	}
	for _, key := range []string{"DB_HOST", "REDIS_HOST", "ACCESS_AUD", "JOBS_SECRET_FILE"} {
		if !strings.Contains(err.Error(), key) {
			t.Errorf("error does not name %s: %v", key, err)
		}
	}
}

// Errors and printed configs never contain a config value or a secret.
func TestConfigNeverPrintsValues(t *testing.T) {
	env := validEnv(t)
	c, err := load(env)
	if err != nil {
		t.Fatal(err)
	}
	printed := fmt.Sprintf("%v|%+v|%#v|%s", c, c, c, c)
	for _, v := range []string{secretDBPass, secretRedisPass, secretJobs, "pg.internal", testAud} {
		if strings.Contains(printed, v) {
			t.Fatalf("printed Config leaks %q: %s", v, printed)
		}
	}

	env["DB_HOST"] = "pg.internal bad"
	delete(env, "ACCESS_AUD")
	_, err = load(env)
	if err == nil {
		t.Fatal("want an error")
	}
	for _, v := range []string{secretDBPass, secretRedisPass, secretJobs, "pg.internal", testAud, env["DB_PASSWORD_FILE"]} {
		if strings.Contains(err.Error(), v) {
			t.Fatalf("error leaks %q: %v", v, err)
		}
	}
}

func TestLoadConfigReadsTheProcessEnvironment(t *testing.T) {
	for k, v := range validEnv(t) {
		t.Setenv(k, v)
	}
	if _, err := LoadConfig(); err != nil {
		t.Fatalf("LoadConfig from the process environment: %v", err)
	}
	t.Setenv("DB_HOST", "")
	if _, err := LoadConfig(); err == nil {
		t.Fatal("an empty DB_HOST must fail")
	}
}
