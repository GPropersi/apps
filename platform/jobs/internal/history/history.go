// Package history writes what the Step 13 status page reads: the run history (runs-YYYY-MM-DD.tsv, one line per
// finished or skipped run), the job table (jobs.tsv) and the runner heartbeat (runner.tsv). The column order of
// each file is part of the platform contract.
package history

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	// KeepRunFiles is how many runs-*.tsv files survive pruning (the newest by date).
	KeepRunFiles = 30
	// maxErrChars is the longest error column.
	maxErrChars = 300
	// maxNameChars caps the app, job and other identifier cells (the registry name limit).
	maxNameChars = 63
	// maxLineBytes keeps one run line inside a single atomic write(2).
	maxLineBytes = 4096
)

var runsFileRE = regexp.MustCompile(`^runs-[0-9]{4}-[0-9]{2}-[0-9]{2}\.tsv$`)

// Run is one run record.
type Run struct {
	RunID        string
	App          string
	Job          string
	Trigger      string
	ScheduledFor time.Time // zero prints -
	Started      time.Time
	Ended        time.Time
	HTTPStatus   int // 0 prints -
	Result       string
	Attempt      int
	Err          string // sanitised and capped here; callers mask secrets first
}

// JobRow is one row of jobs.tsv.
type JobRow struct {
	App         string
	Job         string
	Schedule    string // "" prints -
	CatchUp     bool
	LastResult  string
	LastStarted time.Time
	LastEnded   time.Time
	NextDue     time.Time
	State       string
}

// Writer writes the run history and the job table under one directory.
type Writer struct {
	dir string

	runMu    sync.Mutex
	lastDate string // the date last pruned for

	// appendWrite writes one run line to the open file; the default is a single f.WriteString (one write(2)).
	// Tests replace it to count the calls.
	appendWrite func(f *os.File, line string) (int, error)

	jobsMu sync.Mutex
}

// NewWriter returns a Writer for dir (created when missing, mode 0755).
func NewWriter(dir string) (*Writer, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("history dir: %w", err)
	}
	return &Writer{dir: dir, appendWrite: func(f *os.File, line string) (int, error) { return f.WriteString(line) }}, nil
}

// cell makes a value safe for a TSV cell: tabs, newlines and other control characters become spaces, empty
// becomes -.
func cell(s string) string {
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, strings.ToValidUTF8(s, "?"))
	if s == "" {
		return "-"
	}
	return s
}

func ts(t time.Time) string {
	if t.IsZero() {
		return "-"
	}
	return t.UTC().Format(time.RFC3339)
}

func capErr(s string, n int) string {
	if utf8.RuneCountInString(s) > n {
		return string([]rune(s)[:n])
	}
	return s
}

// FormatRun renders the run line (with its newline). The line is always under 4 KiB: the error column shrinks
// until it fits.
func FormatRun(r Run) string {
	// The free-text cells are capped first (63 runes is the registry name limit), so even with the error column
	// reduced to "-" the line stays under maxLineBytes (5 cells x 63 runes x 4 bytes plus the fixed columns).
	idCell, appCell, jobCell := capErr(cell(r.RunID), maxNameChars), capErr(cell(r.App), maxNameChars), capErr(cell(r.Job), maxNameChars)
	trigCell, resCell := capErr(cell(r.Trigger), maxNameChars), capErr(cell(r.Result), maxNameChars)
	errText := capErr(cell(r.Err), maxErrChars)
	for {
		cols := []string{
			idCell, appCell, jobCell, trigCell, ts(r.ScheduledFor), ts(r.Started), ts(r.Ended),
			strconv.FormatInt(r.Ended.Sub(r.Started).Milliseconds(), 10), resCell, httpCell(r.HTTPStatus),
			strconv.Itoa(r.Attempt), errText,
		}
		line := strings.Join(cols, "\t") + "\n"
		if len(line) < maxLineBytes || errText == "-" {
			return line
		}
		if utf8.RuneCountInString(errText) <= 1 {
			errText = "-"
			continue
		}
		errText = capErr(errText, utf8.RuneCountInString(errText)/2)
	}
}

func httpCell(s int) string {
	if s == 0 {
		return "-"
	}
	return strconv.Itoa(s)
}

// AppendRun appends one line to runs-<UTC date of Ended>.tsv with a single write(2) (O_APPEND), then prunes old
// files when the date changed since the last prune (and on the first write).
func (w *Writer) AppendRun(r Run) error {
	date := r.Ended.UTC().Format("2006-01-02")
	line := FormatRun(r)
	w.runMu.Lock()
	defer w.runMu.Unlock()
	f, err := os.OpenFile(filepath.Join(w.dir, "runs-"+date+".tsv"), os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("open run file: %w", err)
	}
	n, werr := w.appendWrite(f, line)
	cerr := f.Close()
	if werr != nil {
		return fmt.Errorf("append run line: %w", werr)
	}
	if n != len(line) {
		return fmt.Errorf("append run line: short write (%d of %d bytes)", n, len(line))
	}
	if cerr != nil {
		return fmt.Errorf("close run file: %w", cerr)
	}
	if w.lastDate != date {
		if err := w.prune(); err != nil {
			return fmt.Errorf("prune (the run line was appended): %w", err)
		}
		w.lastDate = date
	}
	return nil
}

// prune removes all but the newest KeepRunFiles runs-*.tsv files. The caller holds runMu.
func (w *Writer) prune() error {
	des, err := os.ReadDir(w.dir)
	if err != nil {
		return fmt.Errorf("list history dir: %w", err)
	}
	var names []string
	for _, de := range des {
		if !de.IsDir() && runsFileRE.MatchString(de.Name()) {
			names = append(names, de.Name())
		}
	}
	sort.Strings(names) // the date in the name sorts chronologically
	for len(names) > KeepRunFiles {
		if err := os.Remove(filepath.Join(w.dir, names[0])); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("prune %s: %w", names[0], err)
		}
		names = names[1:]
	}
	return nil
}

// WriteJobs rewrites jobs.tsv atomically, rows sorted by app then job.
func (w *Writer) WriteJobs(rows []JobRow) error {
	sorted := append([]JobRow(nil), rows...)
	sort.SliceStable(sorted, func(i, j int) bool {
		if sorted[i].App != sorted[j].App {
			return sorted[i].App < sorted[j].App
		}
		return sorted[i].Job < sorted[j].Job
	})
	var b strings.Builder
	for _, r := range sorted {
		cu := "false"
		if r.CatchUp {
			cu = "true"
		}
		b.WriteString(strings.Join([]string{
			cell(r.App), cell(r.Job), cell(r.Schedule), cu, cell(r.LastResult),
			ts(r.LastStarted), ts(r.LastEnded), ts(r.NextDue), cell(r.State),
		}, "\t"))
		b.WriteByte('\n')
	}
	w.jobsMu.Lock()
	defer w.jobsMu.Unlock()
	return WriteAtomic(filepath.Join(w.dir, "jobs.tsv"), []byte(b.String()), 0o644)
}
