package registry

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const base = `schema_version: 1
name: chores
owner: family
purpose: Shared chore tracker
template: go-react
memory_cap: 64m
port: 8080
health_path: /healthz
access: family
`

func parse(t *testing.T, content string) (*App, error) {
	t.Helper()
	return ParseApp("chores", []byte(content))
}

func TestExampleFileParses(t *testing.T) {
	b, err := os.ReadFile("../../../registry/app.yaml.example")
	if err != nil {
		t.Fatal(err)
	}
	app, err := ParseApp("chores", b)
	if err != nil {
		t.Fatalf("the documented example must satisfy the runner: %v", err)
	}
	if app.Name != "chores" || app.Port != 8080 || len(app.Jobs) != 2 {
		t.Fatalf("app = %+v", app)
	}
	j := app.Jobs[0]
	if j.Name != "daily-digest" || !j.Scheduled() || j.Schedule != "0 7 * * *" || j.Timeout != 2*time.Minute || !j.CatchUp {
		t.Fatalf("job 0 = %+v", j)
	}
	if j := app.Jobs[1]; j.Name != "send-reminder" || j.Scheduled() || j.Timeout != 30*time.Second || j.CatchUp {
		t.Fatalf("job 1 = %+v", j)
	}
}

func TestMinimalAppWithoutJobs(t *testing.T) {
	min := "schema_version: 1\nname: chores\nowner: family\npurpose: x\ntemplate: flask\nmemory_cap: 16m\nport: 1\n"
	app, err := parse(t, min)
	if err != nil || app.Port != 1 || len(app.Jobs) != 0 {
		t.Fatalf("app=%+v err=%v", app, err)
	}
}

func TestInvalidFilesAreRejected(t *testing.T) {
	jobs := func(body string) string { return base + "jobs:\n" + body }
	cases := map[string]string{
		"unknown top-level key":   base + "extra: 1\n",
		"unknown job key":         jobs("  - name: a\n    timeout: 5s\n    retries: 3\n"),
		"quoted catch_up":         jobs("  - name: a\n    timeout: 5s\n    catch_up: \"true\"\n"),
		"catch_up not a bool":     jobs("  - name: a\n    timeout: 5s\n    catch_up: yes\n"),
		"name differs from dir":   strings.Replace(base, "name: chores", "name: other", 1),
		"bad app name":            strings.Replace(base, "name: chores", "name: Chores", 1),
		"quoted port":             strings.Replace(base, "port: 8080", "port: \"8080\"", 1),
		"port zero":               strings.Replace(base, "port: 8080", "port: 0", 1),
		"port too high":           strings.Replace(base, "port: 8080", "port: 65536", 1),
		"quoted schema_version":   strings.Replace(base, "schema_version: 1", "schema_version: \"1\"", 1),
		"schema_version 2":        strings.Replace(base, "schema_version: 1", "schema_version: 2", 1),
		"missing required key":    strings.Replace(base, "owner: family\n", "", 1),
		"owner is an email":       strings.Replace(base, "owner: family", "owner: a@b", 1),
		"unknown template":        strings.Replace(base, "go-react", "rails", 1),
		"memory_cap too small":    strings.Replace(base, "64m", "8m", 1),
		"memory_cap too big":      strings.Replace(base, "64m", "513m", 1),
		"memory_cap no unit":      strings.Replace(base, "64m", "64", 1),
		"health_path no slash":    strings.Replace(base, "/healthz", "healthz", 1),
		"health_path bad chars":   strings.Replace(base, "/healthz", "/he?x", 1),
		"bad access":              strings.Replace(base, "access: family", "access: everyone", 1),
		"purpose too long":        strings.Replace(base, "Shared chore tracker", strings.Repeat("x", 121), 1),
		"empty value":             strings.Replace(base, "owner: family", "owner:", 1),
		"duplicate top key":       base + "port: 9090\n",
		"duplicate job name":      jobs("  - name: a\n    timeout: 5s\n  - name: a\n    timeout: 5s\n"),
		"job missing timeout":     jobs("  - name: a\n"),
		"job missing name":        jobs("  - timeout: 5s\n"),
		"bad job name":            jobs("  - name: A_b\n    timeout: 5s\n"),
		"timeout 0s":              jobs("  - name: a\n    timeout: 0s\n"),
		"timeout over 1h":         jobs("  - name: a\n    timeout: 61m\n"),
		"timeout 2h":              jobs("  - name: a\n    timeout: 2h\n"),
		"timeout no unit":         jobs("  - name: a\n    timeout: 30\n"),
		"unquoted schedule":       jobs("  - name: a\n    timeout: 5s\n    schedule: 0 7 * * 1\n"),
		"empty schedule":          jobs("  - name: a\n    timeout: 5s\n    schedule: \"\"\n"),
		"schedule minute 99":      jobs("  - name: a\n    timeout: 5s\n    schedule: \"99 * * * *\"\n"),
		"schedule step 0":         jobs("  - name: a\n    timeout: 5s\n    schedule: \"*/0 * * * *\"\n"),
		"schedule 4 fields":       jobs("  - name: a\n    timeout: 5s\n    schedule: \"0 7 * *\"\n"),
		"jobs empty":              base + "jobs:\n",
		"jobs empty list":         base + "jobs: []\n",
		"jobs scalar":             base + "jobs: nope\n",
		"jobs plain items":        jobs("  - a\n  - b\n"),
		"job value not a scalar":  jobs("  - name: a\n    timeout:\n      x: 1\n"),
		"anchor":                  base + "x-a: &a 1\n",
		"alias":                   strings.Replace(base, "owner: family", "owner: *x", 1),
		"tag":                     strings.Replace(base, "port: 8080", "port: !!str 8080", 1),
		"flow job list":           base + "jobs: [{name: a, timeout: 5s}]\n",
		"two documents":           base + "---\n" + base,
		"empty file":              "",
		"not a map":               "- a\n- b\n",
		"tab indentation":         base + "jobs:\n\t- name: a\n",
		"broken yaml":             base + "jobs: [\n",
		"invalid utf8":            base + "purpose2: \xff\n",
		"non-scalar top-level":    strings.Replace(base, "owner: family", "owner:\n  - a", 1),
		"timeout leading minus":   jobs("  - name: a\n    timeout: -5s\n"),
		"block scalar":            strings.Replace(base, "purpose: Shared chore tracker", "purpose: |\n  text", 1),
		"purpose only whitespace": strings.Replace(base, "Shared chore tracker", "\"   \"", 1),
	}
	for name, content := range cases {
		if app, err := parse(t, content); err == nil {
			t.Errorf("%s: accepted as %+v", name, app)
		}
	}
}

func TestValidSchedulesAndCatchUp(t *testing.T) {
	in := base + "jobs:\n  - name: a\n    schedule: '*/15 9-17 * * 1-5'\n    timeout: 1h\n    catch_up: false\n  - name: b_2\n    timeout: 05s\n"
	app, err := parse(t, in)
	if err != nil {
		t.Fatal(err)
	}
	if app.Jobs[0].Timeout != time.Hour || app.Jobs[0].CatchUp || !app.Jobs[0].Scheduled() {
		t.Fatalf("job 0 = %+v", app.Jobs[0])
	}
	if app.Jobs[1].Timeout != 5*time.Second {
		t.Fatalf("job 1 = %+v", app.Jobs[1])
	}
}

func TestErrorReportsEveryProblem(t *testing.T) {
	_, err := parse(t, strings.Replace(base, "port: 8080", "port: 0", 1)+"extra: 1\n")
	if err == nil || !strings.Contains(err.Error(), "port") || !strings.Contains(err.Error(), "extra") {
		t.Fatalf("err = %v", err)
	}
}

func writeApp(t *testing.T, root, dir, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, dir, "app.yaml"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestLoadDisablesOnlyTheInvalidApp(t *testing.T) {
	root := t.TempDir()
	writeApp(t, root, "chores", base)
	writeApp(t, root, "notes", strings.Replace(base, "name: chores", "name: notes", 1)+"jobs:\n  - name: a\n    timeout: 5s\n    surprise: 1\n")
	writeApp(t, root, "wrongname", strings.Replace(base, "name: chores", "name: other", 1))
	writeApp(t, root, "quoted", strings.Replace(strings.Replace(base, "name: chores", "name: quoted", 1), "port: 8080", "port: 8080\njobs:\n  - name: a\n    timeout: 5s\n    catch_up: \"true\"", 1))
	if err := os.MkdirAll(filepath.Join(root, "empty"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".staging"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "README"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	entries, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]Entry{}
	for _, e := range entries {
		got[e.Dir] = e
		if (e.App == nil) == (e.Err == nil) {
			t.Errorf("%s: exactly one of App and Err must be set: %+v", e.Dir, e)
		}
	}
	if len(entries) != 5 {
		t.Fatalf("entries = %d, want 5 (dot-dirs and plain files ignored): %v", len(entries), got)
	}
	if got["chores"].App == nil {
		t.Errorf("chores must stay enabled: %v", got["chores"].Err)
	}
	for _, d := range []string{"notes", "wrongname", "quoted", "empty"} {
		if got[d].Err == nil {
			t.Errorf("%s must be disabled", d)
		}
	}
	for i := 1; i < len(entries); i++ {
		if entries[i-1].Dir >= entries[i].Dir {
			t.Errorf("entries not sorted: %v", entries)
		}
	}
}

func TestLoadRejectsSymlinkedFileAndDir(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	writeApp(t, outside, "linked", strings.Replace(base, "name: chores", "name: linked", 1))
	if err := os.Symlink(filepath.Join(outside, "linked"), filepath.Join(root, "linked")); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "filelink"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(outside, "linked", "app.yaml"), filepath.Join(root, "filelink", "app.yaml")); err != nil {
		t.Fatal(err)
	}
	entries, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("entries = %+v", entries)
	}
	for _, e := range entries {
		if e.Err == nil {
			t.Errorf("%s: symlink must disable the app", e.Dir)
		}
	}
}

// A reserved name is disabled even when its app.yaml is otherwise valid (defense in depth behind the validator).
func TestLoadDisablesReservedNames(t *testing.T) {
	root := t.TempDir()
	writeApp(t, root, "redis", strings.Replace(base, "name: chores", "name: redis", 1))
	writeApp(t, root, "chores", base)
	entries, err := Load(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("entries = %+v", entries)
	}
	for _, e := range entries {
		switch e.Dir {
		case "redis":
			if e.App != nil || e.Err == nil || !strings.Contains(e.Err.Error(), "reserved") {
				t.Errorf("redis must be disabled as reserved: %+v", e)
			}
		case "chores":
			if e.App == nil {
				t.Errorf("chores must stay enabled: %v", e.Err)
			}
		}
	}
}

// The embedded copy must equal platform/registry/reserved-names.txt, the file the validator and new-db read.
func TestReservedNamesLockstep(t *testing.T) {
	want, err := os.ReadFile("../../../registry/reserved-names.txt")
	if err != nil {
		t.Fatal(err)
	}
	if reservedRaw != string(want) {
		t.Fatal("internal/registry/reserved-names.txt differs from platform/registry/reserved-names.txt; copy the latter over it (then make embed)")
	}
	if len(reservedNames()) == 0 {
		t.Fatal("the embedded reserved-names list has no entries")
	}
}

func TestLoadMissingRootIsAnError(t *testing.T) {
	if _, err := Load(filepath.Join(t.TempDir(), "nope")); err == nil {
		t.Fatal("an unreadable registry root must be an error")
	}
}

func TestLoadRejectsOversizeFile(t *testing.T) {
	root := t.TempDir()
	writeApp(t, root, "chores", base+"# "+strings.Repeat("x", maxFileBytes)+"\n")
	entries, err := Load(root)
	if err != nil || len(entries) != 1 || entries[0].Err == nil {
		t.Fatalf("entries=%+v err=%v", entries, err)
	}
}
