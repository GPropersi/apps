package app

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gpropersi/apps/apps/tmplgoreact/internal/platform"
)

func newJobs(store *fakeStore) *Jobs {
	return &Jobs{Tx: store, Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
}

func strp(s string) *string { return &s }

func TestAddNoteSameQueueIDTwiceMakesOneItem(t *testing.T) {
	store := newFakeStore()
	j := newJobs(store)
	for i := 1; i <= 2; i++ {
		req := platform.JobRequest{V: 1, RunID: "run-" + string(rune('0'+i)), Job: "add-note", Attempt: i, QueueID: strp("01Q")}
		if err := j.AddNote(context.Background(), req); err != nil {
			t.Fatalf("delivery %d: %v", i, err)
		}
	}
	if len(store.items) != 1 {
		t.Fatalf("%d items after a redelivery, want 1", len(store.items))
	}
	it := store.items[0]
	if it.Source != "task" || it.CreatedBy != "Background task" || it.Text != "Added by a background task" {
		t.Fatalf("item = %+v", it)
	}
}

func TestAddNoteDifferentKeysMakeTwoItems(t *testing.T) {
	store := newFakeStore()
	j := newJobs(store)
	for _, q := range []string{"01A", "01B"} {
		if err := j.AddNote(context.Background(), platform.JobRequest{V: 1, RunID: "r", Job: "add-note", Attempt: 1, QueueID: strp(q)}); err != nil {
			t.Fatal(err)
		}
	}
	if len(store.items) != 2 {
		t.Fatalf("%d items, want 2", len(store.items))
	}
}

func TestAddNoteWithoutQueueIDDedupesOnRunID(t *testing.T) {
	store := newFakeStore()
	j := newJobs(store)
	for range 2 {
		if err := j.AddNote(context.Background(), platform.JobRequest{V: 1, RunID: "scheduled-run", Job: "add-note", Attempt: 1}); err != nil {
			t.Fatal(err)
		}
	}
	if len(store.items) != 1 || store.jobRuns["scheduled-run"] != "add-note" {
		t.Fatalf("items %d, job_runs %v", len(store.items), store.jobRuns)
	}
}

func TestAddNoteFailureRollsBackTheKeyAndRetrySucceeds(t *testing.T) {
	store := newFakeStore()
	j := newJobs(store)
	req := platform.JobRequest{V: 1, RunID: "r", Job: "add-note", Attempt: 1, QueueID: strp("01F")}
	store.failItems = errBoom
	if err := j.AddNote(context.Background(), req); err == nil {
		t.Fatal("a failed insert returned nil: the runner would never retry")
	}
	if len(store.jobRuns) != 0 || len(store.items) != 0 {
		t.Fatalf("a failed transaction left state: job_runs %v, items %d", store.jobRuns, len(store.items))
	}
	store.failItems = nil
	if err := j.AddNote(context.Background(), req); err != nil {
		t.Fatalf("retry: %v", err)
	}
	if len(store.items) != 1 {
		t.Fatalf("%d items after the retry, want 1", len(store.items))
	}
}

func TestAddNoteBeforeTheDatabaseIsReadyFails(t *testing.T) {
	j := &Jobs{Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
	if err := j.AddNote(context.Background(), platform.JobRequest{V: 1, RunID: "r", Job: "add-note", Attempt: 1}); err == nil {
		t.Fatal("AddNote with no database returned nil")
	}
}

func TestAddNoteThroughTheJobsHandler(t *testing.T) {
	store := newFakeStore()
	j := newJobs(store)
	h, err := platform.JobsHandler([]byte("s3cret"), j.Funcs())
	if err != nil {
		t.Fatal(err)
	}
	body := `{"v":1,"run_id":"R1","job":"add-note","trigger":"queue","attempt":1,"queue_id":"01Z","payload":{"by":"x"}}`
	post := func(auth string) int {
		r := httptest.NewRequest(http.MethodPost, "/_jobs/add-note", strings.NewReader(body))
		if auth != "" {
			r.Header.Set("Authorization", auth)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, r)
		return rec.Code
	}
	if code := post(""); code != 401 {
		t.Fatalf("no bearer = %d, want 401", code)
	}
	for i := range 2 {
		if code := post("Bearer s3cret"); code != 200 {
			t.Fatalf("delivery %d = %d, want 200", i, code)
		}
	}
	if len(store.items) != 1 {
		t.Fatalf("%d items after two deliveries, want 1", len(store.items))
	}
}

func TestDeclaredJobsMatchTheHandlers(t *testing.T) {
	declared, err := platform.DeclaredJobs(appYAMLForTest)
	if err != nil {
		t.Fatal(err)
	}
	if err := platform.VerifyJobs(declared, newJobs(newFakeStore()).Funcs()); err != nil {
		t.Fatal(err)
	}
}
