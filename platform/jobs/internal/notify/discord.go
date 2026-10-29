// Package notify delivers the runner's Discord alerts, mirroring backup.sh notify(): the webhook comes from
// jobs.env, mentions are disabled, the text is prefixed, masked and cut, a post has a 30s timeout and a failed post
// only logs. Run-failure alerts for the same (app, job, result) collapse to one per 15 minutes with a "N more since"
// count; state-change alerts (Notify) are not collapsed.
package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/logx"
)

const (
	// CollapseWindow is the shortest gap between two alerts for the same (app, job, result).
	CollapseWindow = 15 * time.Minute
	// PostTimeout bounds one webhook post.
	PostTimeout = 30 * time.Second
	// MaxText is the longest message sent, in characters.
	MaxText = 1900
	// Prefix starts every message.
	Prefix = "platform-jobs"

	queueLen   = 64
	maxEntries = 1024
)

// PostFunc sends one JSON body to the webhook.
type PostFunc func(ctx context.Context, body []byte) error

type key struct{ app, job, result string }

type entry struct {
	sentAt     time.Time
	suppressed int
}

// Discord is the alert sink. Notify and Alert never block: a message is queued and a goroutine (Run) posts it.
type Discord struct {
	clk     clock.Clock
	log     *logx.Logger
	webhook string
	post    PostFunc

	mu   sync.Mutex
	seen map[key]*entry
	out  chan string
}

// New returns a Discord notifier that posts to webhook over client (nil gets a client with the 30s timeout).
func New(clk clock.Clock, log *logx.Logger, webhook string, client *http.Client) *Discord {
	if client == nil {
		client = &http.Client{Timeout: PostTimeout}
	}
	d := NewWithPost(clk, log, webhook, nil)
	d.post = func(ctx context.Context, body []byte) error {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, webhook, bytes.NewReader(body))
		if err != nil {
			return fmt.Errorf("build request: %s", d.mask(err.Error()))
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			return fmt.Errorf("post: %s", d.mask(err.Error())) // a transport error carries the URL
		}
		defer resp.Body.Close()
		if resp.StatusCode < 200 || resp.StatusCode > 299 {
			return fmt.Errorf("webhook answered http %d", resp.StatusCode)
		}
		return nil
	}
	return d
}

// NewWithPost returns a Discord notifier that delivers through post (tests).
func NewWithPost(clk clock.Clock, log *logx.Logger, webhook string, post PostFunc) *Discord {
	return &Discord{
		clk: clk, log: log, webhook: webhook, post: post,
		seen: map[key]*entry{}, out: make(chan string, queueLen),
	}
}

// mask removes the webhook URL and control characters, and cuts the text to MaxText characters.
func (d *Discord) mask(s string) string {
	s = strings.ToValidUTF8(s, "?")
	if d.webhook != "" {
		s = strings.ReplaceAll(s, d.webhook, "***")
	}
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) && r != '\n' {
			return ' '
		}
		return r
	}, s)
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) > MaxText {
		s = string([]rune(s)[:MaxText])
	}
	return s
}

// decide applies the collapse rule: it returns the text to send, or false when the alert is suppressed.
func (d *Discord) decide(k key, msg string) (string, bool) {
	now := d.clk.Now()
	d.mu.Lock()
	defer d.mu.Unlock()
	e := d.seen[k]
	if e != nil && now.Sub(e.sentAt) < CollapseWindow {
		e.suppressed++
		return "", false
	}
	text := msg
	if e != nil && e.suppressed > 0 {
		text = fmt.Sprintf("%s (%d more since %s)", msg, e.suppressed, e.sentAt.UTC().Format("15:04Z"))
	}
	if len(d.seen) >= maxEntries { // bound the table: forget what is past its window
		for kk, ee := range d.seen {
			if now.Sub(ee.sentAt) >= CollapseWindow {
				delete(d.seen, kk)
			}
		}
	}
	d.seen[k] = &entry{sentAt: now}
	return text, true
}

// Notify sends a state-change alert. State alerts are never collapsed: each is sent once per change by the caller, and
// a repeated "down" or "parked" after a recovery must reach the operator. Only the bounded queue limits them.
func (d *Discord) Notify(msg string) { d.enqueue(msg) }

// Alert sends a run alert, collapsed per (app, job, result).
func (d *Discord) Alert(app, job, result, msg string) {
	text, ok := d.decide(key{app, job, result}, msg)
	if !ok {
		return
	}
	d.enqueue(text)
}

func (d *Discord) enqueue(text string) {
	text = d.mask(Prefix + ": " + text)
	select {
	case d.out <- text:
	default:
		d.log.Printf("notify dropped queue_full=%d", queueLen)
	}
}

// Run delivers queued messages until ctx ends.
func (d *Discord) Run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case text := <-d.out:
			d.deliver(ctx, text)
		}
	}
}

func (d *Discord) deliver(ctx context.Context, text string) {
	body, err := json.Marshal(map[string]any{
		"content":          text,
		"allowed_mentions": map[string]any{"parse": []string{}},
	})
	if err != nil {
		d.log.Printf("notify marshal_failed err=%q", err.Error())
		return
	}
	pctx, cancel := context.WithCancel(ctx)
	defer cancel()
	deadline := d.clk.After(PostTimeout) // the 30s bound goes through the injected clock
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-deadline:
			cancel()
		case <-done:
		}
	}()
	if err := d.post(pctx, body); err != nil {
		d.log.Printf("notify post_failed err=%q", d.mask(err.Error())) // a failed post never affects a run
	}
}
