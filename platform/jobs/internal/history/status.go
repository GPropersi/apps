package history

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/logx"
)

// HeartbeatEvery is the runner.tsv heartbeat period.
const HeartbeatEvery = 15 * time.Second

// Snapshot is the content of runner.tsv.
type Snapshot struct {
	StartedAt   time.Time
	HeartbeatAt time.Time
	Window      string // ok | invalid
	Config      string // ok | invalid
	Redis       string // ok | down | invalid
	Version     string
}

// Status owns runner.tsv. Setters update one field under a mutex and wake the single status goroutine (Run),
// which is the only writer of the file; a 15s ticker rewrites it regardless of any other activity, so the
// heartbeat advances while Redis is down, the window file is invalid and nothing runs.
type Status struct {
	clk  clock.Clock
	path string
	log  *logx.Logger

	mu   sync.Mutex
	snap Snapshot

	kick  chan struct{}
	ready chan struct{}
	once  sync.Once
}

// NewStatus returns a Status that writes path. Window, config and redis start as ok; the Step 7 manager moves
// redis_state.
func NewStatus(clk clock.Clock, path, version string, log *logx.Logger) *Status {
	now := clk.Now()
	return &Status{
		clk: clk, path: path, log: log,
		snap:  Snapshot{StartedAt: now, HeartbeatAt: now, Window: "ok", Config: "ok", Redis: "ok", Version: version},
		kick:  make(chan struct{}, 1),
		ready: make(chan struct{}),
	}
}

// Ready is closed once Run has written the first line and armed its ticker.
func (s *Status) Ready() <-chan struct{} { return s.ready }

// Snapshot returns a copy of the current state.
func (s *Status) Snapshot() Snapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snap
}

// SetWindow records window_state; anything but ok is stored as invalid (fail closed).
func (s *Status) SetWindow(v string) {
	s.set(func(sn *Snapshot) { sn.Window = pick(v, "ok", "invalid") })
}

// SetConfig records config_state; anything but ok is stored as invalid.
func (s *Status) SetConfig(v string) {
	s.set(func(sn *Snapshot) { sn.Config = pick(v, "ok", "invalid") })
}

// SetRedis records redis_state; anything but ok or down is stored as invalid.
func (s *Status) SetRedis(v string) {
	s.set(func(sn *Snapshot) { sn.Redis = pick(v, "ok", "down", "invalid") })
}

func pick(v string, allowed ...string) string {
	for _, a := range allowed {
		if v == a {
			return v
		}
	}
	return "invalid"
}

func (s *Status) set(f func(*Snapshot)) {
	s.mu.Lock()
	f(&s.snap)
	s.mu.Unlock()
	select {
	case s.kick <- struct{}{}:
	default: // a write is already pending and will read the newest state
	}
}

// Line renders a snapshot as the runner.tsv line (with its newline).
func Line(sn Snapshot) string {
	ver := strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return ' '
		}
		return r
	}, sn.Version)
	if ver == "" {
		ver = "-"
	}
	return strings.Join([]string{ts(sn.StartedAt), ts(sn.HeartbeatAt), sn.Window, sn.Config, sn.Redis, ver}, "\t") + "\n"
}

func (s *Status) write() {
	s.mu.Lock()
	s.snap.HeartbeatAt = s.clk.Now()
	line := Line(s.snap)
	s.mu.Unlock()
	if err := WriteAtomic(s.path, []byte(line), 0o644); err != nil {
		s.log.Printf("status write_failed file=runner.tsv err=%q", err.Error())
	}
}

// Run writes runner.tsv now, on every state change and on every heartbeat tick until ctx ends.
func (s *Status) Run(ctx context.Context) {
	tick := s.clk.NewTicker(HeartbeatEvery)
	defer tick.Stop()
	s.write()
	s.once.Do(func() { close(s.ready) })
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C():
		case <-s.kick:
		}
		s.write()
	}
}
