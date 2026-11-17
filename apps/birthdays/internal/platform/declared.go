package platform

import (
	"errors"
	"fmt"
	"slices"

	"gopkg.in/yaml.v3"
)

// DeclaredJobs returns the job names in an app.yaml `jobs[]`, in file order. The app embeds its own app.yaml (the
// root appmeta package), so the registry file is the one source of truth for what the app may enqueue and answer.
func DeclaredJobs(appYAML []byte) ([]string, error) {
	var doc struct {
		Jobs []struct {
			Name string `yaml:"name"`
		} `yaml:"jobs"`
	}
	if err := yaml.Unmarshal(appYAML, &doc); err != nil {
		return nil, fmt.Errorf("platform: app.yaml is not valid: %w", err)
	}
	names := make([]string, 0, len(doc.Jobs))
	seen := map[string]bool{}
	for i, j := range doc.Jobs {
		if !jobNameRE.MatchString(j.Name) {
			return nil, fmt.Errorf("platform: app.yaml jobs[%d] has an invalid name", i)
		}
		if seen[j.Name] {
			return nil, fmt.Errorf("platform: app.yaml jobs[%d] repeats the name %q", i, j.Name)
		}
		seen[j.Name] = true
		names = append(names, j.Name)
	}
	return names, nil
}

// VerifyJobs errors, naming the differing job names, unless the declared names and the handler map keys are the same
// set. A declared job without a JobFunc would answer 404 and dead-letter; a JobFunc for an undeclared job could never
// be called. The server calls it before it listens.
func VerifyJobs(declared []string, jobs map[string]JobFunc) error {
	have := make(map[string]bool, len(declared))
	var noFunc, noDecl []string
	for _, name := range declared {
		have[name] = true
		if fn := jobs[name]; fn == nil { // absent, or present but nil (which would answer 200 and do nothing)
			noFunc = append(noFunc, name)
		}
	}
	for name := range jobs {
		if !have[name] {
			noDecl = append(noDecl, name)
		}
	}
	if len(noFunc) == 0 && len(noDecl) == 0 {
		return nil
	}
	slices.Sort(noFunc)
	slices.Sort(noDecl)
	var problems []error
	if len(noFunc) > 0 {
		problems = append(problems, fmt.Errorf("declared in app.yaml but no JobFunc: %q", noFunc))
	}
	if len(noDecl) > 0 {
		problems = append(problems, fmt.Errorf("JobFunc but not declared in app.yaml: %q", noDecl))
	}
	return fmt.Errorf("platform: jobs mismatch: %w", errors.Join(problems...))
}
