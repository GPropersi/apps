package platform

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The package is copied byte-for-byte into every app, so it must never name the template's placeholder app. The
// word is assembled here so this file does not contain it either.
func TestPackageNeverNamesThePlaceholderApp(t *testing.T) {
	placeholder := "tmpl" + "goreact"
	var checked int
	err := filepath.WalkDir(".", func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		checked++
		if strings.Contains(string(b), placeholder) {
			t.Errorf("%s contains the placeholder app name", path)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if checked == 0 {
		t.Fatal("no files were checked")
	}
}

// And it imports nothing from the app module.
func TestPackageImportsNothingFromTheAppModule(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".go") {
			continue
		}
		b, err := os.ReadFile(e.Name())
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(b), "github.com/gpropersi/"+"apps/apps/") {
			t.Errorf("%s imports from an app module", e.Name())
		}
	}
}
