package platform

import (
	"context"
	"slices"
	"strings"
	"testing"
)

func TestDeclaredJobsReadsNamesInOrder(t *testing.T) {
	got, err := DeclaredJobs([]byte("name: x\njobs:\n  - name: add-note\n    timeout: 30s\n  - name: nightly\n    schedule: '0 3 * * *'\n"))
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(got, []string{"add-note", "nightly"}) {
		t.Fatalf("got %v", got)
	}
}

func TestDeclaredJobsNoJobsAndBadInput(t *testing.T) {
	if got, err := DeclaredJobs([]byte("name: x\n")); err != nil || len(got) != 0 {
		t.Fatalf("no jobs: %v %v", got, err)
	}
	if _, err := DeclaredJobs([]byte("jobs: [")); err == nil {
		t.Error("invalid yaml accepted")
	}
	if _, err := DeclaredJobs([]byte("jobs:\n  - name: Bad_Name\n")); err == nil {
		t.Error("invalid job name accepted")
	}
	if _, err := DeclaredJobs([]byte("jobs:\n  - timeout: 5s\n")); err == nil {
		t.Error("job without a name accepted")
	}
}

func TestVerifyJobsMatchingSetsPass(t *testing.T) {
	jobs := map[string]JobFunc{"a": noop, "b": noop}
	if err := VerifyJobs([]string{"b", "a"}, jobs); err != nil {
		t.Fatal(err)
	}
	if err := VerifyJobs(nil, nil); err != nil {
		t.Fatal(err)
	}
}

func TestVerifyJobsDeclaredWithoutJobFuncFails(t *testing.T) {
	err := VerifyJobs([]string{"a", "b"}, map[string]JobFunc{"a": noop})
	if err == nil || !strings.Contains(err.Error(), `"b"`) || strings.Contains(err.Error(), `"a"`) {
		t.Fatalf("err = %v, want it to name only b", err)
	}
}

func TestVerifyJobsJobFuncWithoutDeclarationFails(t *testing.T) {
	err := VerifyJobs([]string{"a"}, map[string]JobFunc{"a": noop, "z": noop})
	if err == nil || !strings.Contains(err.Error(), `"z"`) || strings.Contains(err.Error(), `"a"`) {
		t.Fatalf("err = %v, want it to name only z", err)
	}
}

func noop(context.Context, JobRequest) error { return nil }

func TestVerifyJobsNilJobFuncFails(t *testing.T) {
	err := VerifyJobs([]string{"a"}, map[string]JobFunc{"a": nil})
	if err == nil || !strings.Contains(err.Error(), `"a"`) {
		t.Fatalf("err = %v, want it to name a", err)
	}
}

func TestDeclaredJobsRejectsDuplicates(t *testing.T) {
	if _, err := DeclaredJobs([]byte("jobs:\n  - name: a\n  - name: a\n")); err == nil {
		t.Fatal("duplicate name accepted")
	}
}

func TestVerifyJobsReportsBothDirections(t *testing.T) {
	err := VerifyJobs([]string{"a"}, map[string]JobFunc{"z": noop})
	if err == nil || !strings.Contains(err.Error(), `"a"`) || !strings.Contains(err.Error(), `"z"`) {
		t.Fatalf("err = %v", err)
	}
}
