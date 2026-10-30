package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/logx"
)

func envOf(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestLoadConfigDefaultsAndOverrides(t *testing.T) {
	c := loadConfig(envOf(nil))
	if c.JobsEnv != "/etc/platform/jobs.env" || c.PasswordFile != "/etc/platform/jobs-redis.password" ||
		c.WindowDir != "/opt/platform/backup" || c.StatusDir != "/var/lib/platform/jobs-status" ||
		c.StateDir != "/var/lib/platform/jobs-state" || c.RedisAddr != "redis:6379" {
		t.Fatalf("unexpected defaults: %+v", c)
	}
	if c.windowPath() != "/opt/platform/backup/window.env" {
		t.Fatalf("window path %q", c.windowPath())
	}
	c = loadConfig(envOf(map[string]string{envStatusDir: "/x", envRedisAddr: "h:1"}))
	if c.StatusDir != "/x" || c.RedisAddr != "h:1" || c.runnerTSV() != "/x/runner.tsv" {
		t.Fatalf("override ignored: %+v", c)
	}
}

func TestDispatchMode(t *testing.T) {
	for args, want := range map[string]string{"": "runner", "runner": "runner", "healthcheck": "healthcheck", "bogus": ""} {
		var a []string
		if args != "" {
			a = []string{args}
		}
		if got := dispatchMode(a); got != want {
			t.Errorf("dispatchMode(%q) = %q, want %q", args, got, want)
		}
	}
}

func TestRunUnknownModeExits2(t *testing.T) {
	var out, errb bytes.Buffer
	if rc := run([]string{"bogus"}, envOf(nil), &out, &errb); rc != 2 {
		t.Fatalf("rc = %d, want 2", rc)
	}
}

func fileIn(t *testing.T, dir, name, content string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadInputsStripsOneNewline(t *testing.T) {
	d := t.TempDir()
	c := config{
		JobsEnv:      fileIn(t, d, "jobs.env", "DISCORD_WEBHOOK=https://example.invalid/hook\n"),
		PasswordFile: fileIn(t, d, "pw", "s3cret\n\n"),
	}
	in, err := loadInputs(c)
	if err != nil {
		t.Fatal(err)
	}
	if in.password != "s3cret\n" {
		t.Fatalf("exactly one newline must be stripped, got %q", in.password)
	}
}

func TestDefectiveJobsEnvRefusesToStart(t *testing.T) {
	d := t.TempDir()
	const secret = "https://example.invalid/topsecret"
	c := config{
		JobsEnv:      fileIn(t, d, "jobs.env", "OTHER_KEY="+secret+"\n"),
		PasswordFile: fileIn(t, d, "pw", "pw\n"),
		StatusDir:    filepath.Join(d, "status"),
		StateDir:     filepath.Join(d, "state"),
	}
	var out bytes.Buffer
	if rc := runRunner(context.Background(), c, &out); rc == 0 {
		t.Fatal("a defective jobs.env must give a non-zero exit")
	}
	if strings.Contains(out.String(), secret) {
		t.Fatal("log leaked the jobs.env value")
	}
}

func TestRunRunnerStopsCleanlyOnContextEnd(t *testing.T) {
	d := t.TempDir()
	c := config{
		JobsEnv:      fileIn(t, d, "jobs.env", "DISCORD_WEBHOOK=https://example.invalid/hook\n"),
		PasswordFile: fileIn(t, d, "pw", "pw\n"),
		Registry:     filepath.Join(d, "registry"),
		Secrets:      filepath.Join(d, "secrets"),
		WindowDir:    filepath.Join(d, "window"),
		StatusDir:    filepath.Join(d, "status"),
		StateDir:     filepath.Join(d, "state"),
		RedisAddr:    "127.0.0.1:1",
	}
	for _, p := range []string{c.Registry, c.Secrets, c.WindowDir, c.StateDir} {
		if err := os.MkdirAll(p, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	var out bytes.Buffer
	if rc := runRunner(ctx, c, &out); rc != 0 {
		t.Fatalf("rc %d, log:\n%s", rc, out.String())
	}
	if !strings.Contains(out.String(), "runner stopped") || strings.Contains(out.String(), "fault") {
		t.Fatalf("want a clean stop, log:\n%s", out.String())
	}
}

// A component that returns before shutdown is a fault: everything stops and the exit code is 1, so the restart
// policy brings the runner back.
func TestSuperviseComponentFaultExits1(t *testing.T) {
	var out bytes.Buffer
	log := logx.New(&out, clock.Real{})
	stopped := make(chan struct{})
	comps := []component{
		{name: "alerts", run: func(ctx context.Context) { <-ctx.Done() }, last: true},
		{name: "steady", run: func(ctx context.Context) { <-ctx.Done(); close(stopped) }},
		{name: "faulty", run: func(ctx context.Context) {}}, // returns at once
	}
	done := make(chan int, 1)
	go func() { done <- supervise(context.Background(), log, comps, "runner started") }()
	select {
	case rc := <-done:
		if rc != 1 {
			t.Fatalf("rc %d, want 1; log:\n%s", rc, out.String())
		}
	case <-time.After(10 * time.Second):
		t.Fatalf("supervise did not return after a component fault; log:\n%s", out.String())
	}
	select {
	case <-stopped:
	default:
		t.Fatal("the other components must be stopped by the fault")
	}
	for _, want := range []string{"runner faulty exited before shutdown", "runner stopped with a component fault"} {
		if !strings.Contains(out.String(), want) {
			t.Fatalf("log lacks %q:\n%s", want, out.String())
		}
	}
	if strings.Contains(out.String(), "runner stopped\n") {
		t.Fatalf("a fault must not log a clean stop:\n%s", out.String())
	}
}

func TestHealthcheckMode(t *testing.T) {
	d := t.TempDir()
	c := config{StatusDir: d}
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	clk := clock.NewFake(now)
	var errb bytes.Buffer
	if rc := runHealthcheck(c, clk, &errb); rc == 0 {
		t.Fatal("missing runner.tsv must be unhealthy")
	}
	ts := now.Format(time.RFC3339)
	fileIn(t, d, "runner.tsv", ts+"\t"+ts+"\tok\tok\tok\tdev\n")
	if rc := runHealthcheck(c, clk, &errb); rc != 0 {
		t.Fatalf("fresh heartbeat must be healthy: %s", errb.String())
	}
}
