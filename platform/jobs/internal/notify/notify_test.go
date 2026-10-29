package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/logx"
)

const hook = "https://discord.example.invalid/api/webhooks/000/placeholder-token"

func TestNotifierCollapse(t *testing.T) {
	clk := clock.NewFake(time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC))
	d := NewWithPost(clk, nil, hook, nil)
	drain := func() []string {
		var out []string
		for {
			select {
			case m := <-d.out:
				out = append(out, m)
			default:
				return out
			}
		}
	}
	d.Alert("a", "j", "dead_lettered", "first")
	for i := 0; i < 3; i++ {
		clk.Advance(time.Minute)
		d.Alert("a", "j", "dead_lettered", "again")
	}
	got := drain()
	if len(got) != 1 || !strings.HasPrefix(got[0], Prefix+": first") {
		t.Fatalf("within 15 minutes want exactly the first alert, got %q", got)
	}
	d.Alert("a", "j", "failed", "other result") // another (app, job, result) is not collapsed
	d.Alert("b", "j", "dead_lettered", "other app")
	if got := drain(); len(got) != 2 {
		t.Fatalf("distinct keys must each send, got %q", got)
	}
	clk.Advance(15 * time.Minute)
	d.Alert("a", "j", "dead_lettered", "later")
	got = drain()
	if len(got) != 1 || !strings.Contains(got[0], "(3 more since 12:00Z)") {
		t.Fatalf("after the window want the N more since count, got %q", got)
	}
}

func TestNotifierMaskAndCut(t *testing.T) {
	d := NewWithPost(clock.NewFake(time.Now()), nil, hook, nil)
	d.Alert("a", "j", "r", "leak "+hook+" "+strings.Repeat("x", 3000))
	m := <-d.out
	if strings.Contains(m, hook) || !strings.Contains(m, "***") {
		t.Fatalf("webhook not masked: %q", m)
	}
	if n := len([]rune(m)); n > MaxText {
		t.Fatalf("text has %d chars, max %d", n, MaxText)
	}
}

func TestNotifierPayloadAndFailedPost(t *testing.T) {
	var mu sync.Mutex
	var bodies [][]byte
	calls := 0
	post := func(_ context.Context, b []byte) error {
		mu.Lock()
		defer mu.Unlock()
		calls++
		bodies = append(bodies, b)
		return errors.New("boom " + hook)
	}
	var logs bytes.Buffer
	fclk := clock.NewFake(time.Now())
	d := NewWithPost(fclk, logx.New(&logs, fclk), hook, post)
	d.Alert("a", "j", "r1", "one")
	d.Alert("a", "j", "r2", "two") // a failed post must not stop the next delivery
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { d.Run(ctx); close(done) }()
	deadline := time.Now().Add(5 * time.Second)
	for {
		mu.Lock()
		n := calls
		mu.Unlock()
		if n == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("both messages must be attempted even though the first post failed")
		}
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	<-done
	if l := logs.String(); strings.Contains(l, hook) || !strings.Contains(l, "post_failed") || !strings.Contains(l, "***") {
		t.Fatalf("the failed post must be logged with the webhook masked, got %q", l)
	}
	var p struct {
		Content string `json:"content"`
		Allowed struct {
			Parse []string `json:"parse"`
		} `json:"allowed_mentions"`
	}
	if err := json.Unmarshal(bodies[0], &p); err != nil {
		t.Fatal(err)
	}
	if p.Allowed.Parse == nil || len(p.Allowed.Parse) != 0 {
		t.Fatalf("allowed_mentions.parse must be an empty list, got %s", bodies[0])
	}
	if !strings.HasPrefix(p.Content, "platform-jobs") {
		t.Fatalf("content %q lacks the prefix", p.Content)
	}
}

func TestDiscordHTTPPost(t *testing.T) {
	var got string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b := make([]byte, 4096)
		n, _ := r.Body.Read(b)
		got = string(b[:n])
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()
	d := New(clock.NewFake(time.Now()), nil, srv.URL+"/hook", srv.Client())
	if err := d.post(context.Background(), []byte(`{"content":"x"}`)); err != nil || got != `{"content":"x"}` {
		t.Fatalf("post: err=%v body=%q", err, got)
	}
	srv.Close()
	err := d.post(context.Background(), []byte(`{}`))
	if err == nil || strings.Contains(err.Error(), srv.URL) || !strings.Contains(err.Error(), "***") {
		t.Fatalf("a transport error must be returned with the URL masked (***), got %v", err)
	}
}

func TestNotifyStateAlertsAreNotCollapsed(t *testing.T) {
	clk := clock.NewFake(time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC))
	d := NewWithPost(clk, nil, hook, nil)
	for i := 0; i < 3; i++ { // a flap: down, ok, down within 15 minutes
		d.Notify("redis down")
		clk.Advance(time.Minute)
		d.Notify("redis ok")
		clk.Advance(time.Minute)
	}
	if n := len(d.out); n != 6 {
		t.Fatalf("every state alert must be sent, queued %d of 6", n)
	}
}

func TestLoadEnv(t *testing.T) {
	dir := t.TempDir()
	write := func(s string) string {
		p := filepath.Join(dir, "jobs.env")
		if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	if v, err := LoadEnv(write("# note\n\nDISCORD_WEBHOOK=" + hook + "\n")); err != nil || v != hook {
		t.Fatalf("valid file: %q %v", v, err)
	}
	for name, body := range map[string]string{
		"extra key":   "DISCORD_WEBHOOK=" + hook + "\nOTHER=1\n",
		"duplicate":   "DISCORD_WEBHOOK=" + hook + "\nDISCORD_WEBHOOK=" + hook + "\n",
		"missing":     "# nothing\n",
		"not https":   "DISCORD_WEBHOOK=http://x.example.invalid/a\n",
		"no equals":   "DISCORD_WEBHOOK\n",
		"quoted":      "DISCORD_WEBHOOK=\"" + hook + "\"\n",
		"wrong key":   "OTHER=" + hook + "\n",
		"empty value": "DISCORD_WEBHOOK=\n",
	} {
		_, err := LoadEnv(write(body))
		if err == nil {
			t.Errorf("%s: want an error", name)
		} else if strings.Contains(err.Error(), hook) {
			t.Errorf("%s: the error leaks the webhook: %v", name, err)
		}
	}
	if _, err := LoadEnv(filepath.Join(dir, "absent")); err == nil {
		t.Error("a missing file must be an error")
	}
}
