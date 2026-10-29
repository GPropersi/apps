// Package registry reads the per-app registry files <root>/<app>/app.yaml with the same rules as
// platform/registry/validate-app-yaml.sh: unknown keys, wrong types, bad values and a name that differs from the
// directory are all errors. An invalid file disables that app only; the other apps keep running.
//
// The reserved-names list is enforced here too, as defense in depth behind the deploy-time validator: the runner
// embeds reserved-names.txt (a copy of platform/registry/reserved-names.txt, kept equal by TestReservedNamesLockstep)
// and marks a registry directory with a reserved name disabled. The Postgres-identifier check is deliberately not
// repeated: it is a provisioning concern the validator enforces when the file is deployed.
package registry

import (
	"bytes"
	_ "embed"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"gopkg.in/yaml.v3"

	"github.com/gpropersi/apps/platform/jobs/internal/cron"
)

// maxFileBytes bounds an app.yaml read; a real file is a few hundred bytes.
const maxFileBytes = 64 * 1024

var (
	appRE      = regexp.MustCompile(`^[a-z][a-z0-9-]{1,30}$`)
	jobRE      = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,62}$`)
	timeoutRE  = regexp.MustCompile(`^[0-9]{1,6}(s|m|h)$`)
	memCapRE   = regexp.MustCompile(`^[1-9][0-9]{0,2}m$`)
	portRE     = regexp.MustCompile(`^[1-9][0-9]{0,4}$`)
	healthRE   = regexp.MustCompile(`^/[A-Za-z0-9._~/%-]*$`)
	topKeys    = []string{"schema_version", "name", "owner", "purpose", "template", "memory_cap", "port", "health_path", "access", "jobs"}
	topReqd    = []string{"schema_version", "name", "owner", "purpose", "template", "memory_cap", "port"}
	jobKeys    = []string{"name", "schedule", "timeout", "catch_up"}
	templates  = []string{"go-react", "go-htmx", "fastapi-react", "flask", "node-hono"}
	accessVals = []string{"family", "public", "restricted"}
)

//go:embed reserved-names.txt
var reservedRaw string

// reservedNames returns the names in the embedded list (comments and blank lines dropped).
func reservedNames() map[string]bool {
	out := map[string]bool{}
	for _, line := range strings.Split(reservedRaw, "\n") {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") {
			out[line] = true
		}
	}
	return out
}

// Job is one declared job.
type Job struct {
	Name     string
	Schedule string         // the raw quoted cron, "" for an enqueue-only job
	Cron     *cron.Schedule // nil for an enqueue-only job
	Timeout  time.Duration
	CatchUp  bool
}

// Scheduled reports whether the job has a cron schedule.
func (j Job) Scheduled() bool { return j.Cron != nil }

// App is a valid app registry file.
type App struct {
	Name       string
	Port       int
	HealthPath string
	Jobs       []Job
}

// Entry is the outcome for one registry directory: exactly one of App and Err is set. A non-nil Err means the
// app is disabled (state disabled_invalid_config) and Err.Error() is the one-line reason to log.
type Entry struct {
	Dir string
	App *App
	Err error
}

// Load reads every <root>/<app>/app.yaml. Directories whose names start with "." and plain files are ignored.
// It returns an error only when root itself cannot be read; per-app problems are Entry.Err. Entries are sorted
// by directory name.
func Load(root string) ([]Entry, error) {
	des, err := os.ReadDir(root)
	if err != nil {
		return nil, fmt.Errorf("registry root unreadable: %w", err)
	}
	reserved := reservedNames()
	if len(reserved) == 0 { // fail closed: an empty list would silently allow every reserved name
		return nil, errors.New("embedded reserved-names list has no entries")
	}
	var out []Entry
	for _, de := range des {
		name := de.Name()
		if strings.HasPrefix(name, ".") {
			continue
		}
		switch {
		case de.IsDir() && reserved[name]:
			out = append(out, Entry{Dir: name, Err: fmt.Errorf("name '%s' is reserved", name)})
		case de.IsDir():
			app, err := loadOne(filepath.Join(root, name), name)
			out = append(out, Entry{Dir: name, App: app, Err: err})
		case de.Type()&os.ModeSymlink != 0:
			out = append(out, Entry{Dir: name, Err: errors.New("app directory must be a real directory, not a symlink")})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Dir < out[j].Dir })
	return out, nil
}

func loadOne(dir, name string) (*App, error) {
	path := filepath.Join(dir, "app.yaml")
	fi, err := os.Lstat(path)
	if err != nil {
		return nil, errors.New("app.yaml is missing or unreadable")
	}
	if !fi.Mode().IsRegular() {
		return nil, errors.New("app.yaml must be a regular file, not a symlink")
	}
	if fi.Size() > maxFileBytes {
		return nil, fmt.Errorf("app.yaml is over %d bytes", maxFileBytes)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("app.yaml is unreadable")
	}
	return ParseApp(name, b)
}

type validator struct {
	problems []string
}

func (v *validator) errf(format string, a ...any) {
	v.problems = append(v.problems, fmt.Sprintf(format, a...))
}

// ParseApp validates app.yaml content for the app directory `dir`. The error lists every problem found.
func ParseApp(dir string, b []byte) (*App, error) {
	if !utf8.Valid(b) {
		return nil, errors.New("not valid app.yaml syntax: invalid UTF-8")
	}
	dec := yaml.NewDecoder(bytes.NewReader(b))
	var doc yaml.Node
	if err := dec.Decode(&doc); err != nil {
		if errors.Is(err, io.EOF) {
			return nil, errors.New("not valid app.yaml syntax: empty file")
		}
		return nil, fmt.Errorf("not valid app.yaml syntax: %s", firstLine(err.Error()))
	}
	var extra yaml.Node
	if err := dec.Decode(&extra); !errors.Is(err, io.EOF) {
		return nil, errors.New("not valid app.yaml syntax: more than one YAML document")
	}
	if doc.Kind != yaml.DocumentNode || len(doc.Content) != 1 {
		return nil, errors.New("not valid app.yaml syntax: no document")
	}
	root := doc.Content[0]
	v := &validator{}
	if !v.plainTree(root, "") {
		return nil, v.error()
	}
	if root.Kind != yaml.MappingNode {
		return nil, errors.New("app.yaml must be a map of keys")
	}
	top := v.mapping(root, "", topKeys)
	for _, k := range topReqd {
		if _, ok := top[k]; !ok {
			v.errf("missing required key '%s'", k)
		}
	}
	app := &App{}
	for _, k := range topKeys {
		n, ok := top[k]
		if !ok || k == "jobs" {
			continue
		}
		v.scalarKey(dir, k, n, app)
	}
	if n, ok := top["jobs"]; ok {
		app.Jobs = v.jobs(n)
	}
	if len(v.problems) > 0 {
		return nil, v.error()
	}
	return app, nil
}

func (v *validator) error() error {
	return errors.New(strings.Join(v.problems, "; "))
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// plainTree rejects the YAML features the repo's subset forbids (anchors, aliases, tags, flow collections,
// merge keys) anywhere in the tree. It reports false when it found any.
func (v *validator) plainTree(n *yaml.Node, path string) bool {
	ok := true
	if n.Kind == yaml.AliasNode || n.Anchor != "" {
		v.errf("anchors and aliases are not allowed%s", at(path))
		ok = false
	}
	if n.Style&yaml.TaggedStyle != 0 {
		v.errf("explicit tags are not allowed%s", at(path))
		ok = false
	}
	if n.Style&yaml.FlowStyle != 0 {
		v.errf("flow collections are not allowed%s", at(path))
		ok = false
	}
	if n.Kind == yaml.ScalarNode && n.Style&(yaml.LiteralStyle|yaml.FoldedStyle) != 0 {
		v.errf("block scalars are not allowed%s", at(path))
		ok = false
	}
	for _, c := range n.Content {
		if !v.plainTree(c, path) {
			ok = false
		}
	}
	return ok
}

func at(path string) string {
	if path == "" {
		return ""
	}
	return " at " + path
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// mapping returns the key -> value nodes of a mapping node. It reports unknown keys (against allowed),
// non-scalar keys and duplicate keys. where prefixes messages ("" for the top level, "jobs[0]" for a job).
func (v *validator) mapping(n *yaml.Node, where string, allowed []string) map[string]*yaml.Node {
	out := map[string]*yaml.Node{}
	prefix := ""
	if where != "" {
		prefix = where + " "
	}
	for i := 0; i+1 < len(n.Content); i += 2 {
		kn, vn := n.Content[i], n.Content[i+1]
		if kn.Kind != yaml.ScalarNode {
			v.errf("%shas a non-scalar key", prefix)
			continue
		}
		k := kn.Value
		if _, dup := out[k]; dup {
			v.errf("%shas a duplicate key '%s'", prefix, k)
			continue
		}
		if !contains(allowed, k) {
			if where == "" {
				v.errf("unknown key '%s'", k)
			} else {
				v.errf("%s has unknown key '%s'", where, k)
			}
			continue
		}
		out[k] = vn
	}
	return out
}

func quoted(n *yaml.Node) bool {
	return n.Style&(yaml.DoubleQuotedStyle|yaml.SingleQuotedStyle) != 0
}

func (v *validator) scalarKey(dir, k string, n *yaml.Node, app *App) {
	if n.Kind != yaml.ScalarNode {
		v.errf("%s must be a scalar value", k)
		return
	}
	val := n.Value
	switch k {
	case "schema_version", "port":
		if quoted(n) {
			v.errf("%s must be an unquoted value, not a string", k)
			return
		}
	}
	if val == "" {
		v.errf("%s must not be empty", k)
		return
	}
	switch k {
	case "schema_version":
		if val != "1" {
			v.errf("schema_version '%s' must be 1", val)
		}
	case "name":
		switch {
		case !appRE.MatchString(val):
			v.errf("name '%s' must match %s", val, appRE)
		case val != dir:
			v.errf("name '%s' must equal the parent directory name '%s'", val, dir)
		default:
			app.Name = val
		}
	case "owner":
		if strings.Contains(val, "@") {
			v.errf("owner must be a short handle, not an email address")
		} else if !appRE.MatchString(val) {
			v.errf("owner '%s' must match %s", val, appRE)
		}
	case "purpose":
		if strings.TrimSpace(val) == "" {
			v.errf("purpose must not be only whitespace")
		} else if n := utf8.RuneCountInString(val); n > 120 {
			v.errf("purpose is %d characters, the maximum is 120", n)
		}
	case "template":
		if !contains(templates, val) {
			v.errf("template '%s' is not one of: %s", val, strings.Join(templates, " "))
		}
	case "memory_cap":
		if !memCapRE.MatchString(val) {
			v.errf("memory_cap '%s' must be a number of MiB with the unit m, like 64m", val)
		} else if mib, _ := strconv.Atoi(strings.TrimSuffix(val, "m")); mib < 16 || mib > 512 {
			v.errf("memory_cap '%s' must be between 16m and 512m", val)
		}
	case "port":
		p, _ := strconv.Atoi(val)
		if !portRE.MatchString(val) || p > 65535 {
			v.errf("port '%s' must be an integer from 1 to 65535", val)
		} else {
			app.Port = p
		}
	case "health_path":
		if !strings.HasPrefix(val, "/") {
			v.errf("health_path '%s' must start with /", val)
		} else if !healthRE.MatchString(val) {
			v.errf("health_path '%s' may only contain letters, digits and . _ ~ / %% -", val)
		} else {
			app.HealthPath = val
		}
	case "access":
		if !contains(accessVals, val) {
			v.errf("access '%s' must be family, public or restricted", val)
		}
	}
}

func (v *validator) jobs(n *yaml.Node) []Job {
	if n.Kind == yaml.ScalarNode && n.Value == "" && !quoted(n) || (n.Kind == yaml.SequenceNode && len(n.Content) == 0) {
		v.errf("jobs is present but has no entries (omit the key instead)")
		return nil
	}
	if n.Kind != yaml.SequenceNode {
		v.errf("jobs must be a list of maps, not a scalar")
		return nil
	}
	var out []Job
	seen := map[string]bool{}
	for i, jn := range n.Content {
		where := fmt.Sprintf("jobs[%d]", i)
		if jn.Kind != yaml.MappingNode {
			v.errf("jobs items must be maps (name, schedule, timeout, catch_up), not plain values")
			continue
		}
		j, ok := v.job(where, jn)
		if !ok {
			continue
		}
		if seen[j.Name] {
			v.errf("duplicate job name '%s'", j.Name)
			continue
		}
		seen[j.Name] = true
		out = append(out, j)
	}
	return out
}

func (v *validator) job(where string, n *yaml.Node) (Job, bool) {
	before := len(v.problems)
	m := v.mapping(n, where, jobKeys)
	for k, vn := range m {
		if vn.Kind != yaml.ScalarNode {
			v.errf("%s/%s must be a scalar", where, k)
			delete(m, k)
		}
	}
	var j Job
	if nn, ok := m["name"]; !ok {
		v.errf("%s is missing required key 'name'", where)
	} else if !jobRE.MatchString(nn.Value) {
		v.errf("%s name '%s' must match %s", where, nn.Value, jobRE)
	} else {
		j.Name = nn.Value
	}
	if tn, ok := m["timeout"]; !ok {
		v.errf("%s is missing required key 'timeout'", where)
	} else if d, err := parseTimeout(tn.Value); err != nil {
		v.errf("%s %s", where, err)
	} else {
		j.Timeout = d
	}
	if sn, ok := m["schedule"]; ok {
		switch {
		case !quoted(sn):
			v.errf("%s schedule must be a quoted cron string", where)
		case sn.Value == "":
			v.errf("%s schedule must not be empty", where)
		default:
			c, err := cron.Parse(sn.Value)
			if err != nil {
				v.errf("%s schedule: %s", where, err)
			} else {
				j.Schedule, j.Cron = sn.Value, c
			}
		}
	}
	if cn, ok := m["catch_up"]; ok {
		switch {
		case quoted(cn) || (cn.Value != "true" && cn.Value != "false"):
			v.errf("%s catch_up '%s' must be true or false (unquoted)", where, cn.Value)
		default:
			j.CatchUp = cn.Value == "true"
		}
	}
	return j, len(v.problems) == before
}

// parseTimeout accepts Ns|Nm|Nh, 1 second to 1 hour, with the same digits rule as the validator.
func parseTimeout(s string) (time.Duration, error) {
	if !timeoutRE.MatchString(s) {
		return 0, fmt.Errorf("timeout '%s' must look like 30s, 2m or 1h", s)
	}
	n, _ := strconv.Atoi(s[:len(s)-1])
	if n < 1 {
		return 0, errors.New("timeout must be greater than zero")
	}
	var unit time.Duration
	switch s[len(s)-1] {
	case 's':
		unit = time.Second
	case 'm':
		unit = time.Minute
	case 'h':
		unit = time.Hour
	default:
		return 0, fmt.Errorf("timeout '%s' has an unknown unit", s)
	}
	d := time.Duration(n) * unit
	if d > time.Hour {
		return 0, fmt.Errorf("timeout '%s' is over the 1h maximum", s)
	}
	return d, nil
}
