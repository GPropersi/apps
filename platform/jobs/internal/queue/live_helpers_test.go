//go:build live

package queue

import (
	"bytes"
	"context"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/gpropersi/apps/platform/jobs/internal/clock"
	"github.com/gpropersi/apps/platform/jobs/internal/logx"
)

// liveCfg is what test_jobs_live.sh exports: the address of the real Redis and throwaway credentials.
type liveCfg struct {
	addr, adminPW, runnerPW, app, appPW, other, otherPW string
}

func loadLiveCfg(t *testing.T) liveCfg {
	t.Helper()
	get := func(k string) string {
		v := os.Getenv(k)
		if v == "" {
			t.Fatalf("%s is not set: run these tests through platform/jobs/test_jobs_live.sh", k)
		}
		return v
	}
	return liveCfg{
		addr: get("PJLIVE_ADDR"), adminPW: get("PJLIVE_ADMIN_PW"), runnerPW: get("PJLIVE_RUNNER_PW"),
		app: get("PJLIVE_APP"), appPW: get("PJLIVE_APP_PW"), other: get("PJLIVE_OTHER"), otherPW: get("PJLIVE_OTHER_PW"),
	}
}

func rawClient(addr, user, pw string) *redis.Client {
	return redis.NewClient(&redis.Options{Addr: addr, Username: user, Password: pw, Protocol: 2, DisableIdentity: true, MaxRetries: -1,
		DialTimeout: 2 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 5 * time.Second})
}

// ---- TCP proxy: lets a test sever the connection, and lose the reply of an EXEC ----

type tcpProxy struct {
	target string
	addr   string
	mu     sync.Mutex
	ln     net.Listener
	conns  map[net.Conn]bool
	// armExec makes the proxy forward the next EXEC to the server, discard everything the server sends back and
	// sever the connection shortly after: the server applied the block, the client never sees the reply.
	armExec atomic.Bool
}

func newProxy(t *testing.T, target string) *tcpProxy {
	t.Helper()
	p := &tcpProxy{target: target, conns: map[net.Conn]bool{}}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p.addr = ln.Addr().String()
	p.serve(ln)
	t.Cleanup(p.Stop)
	return p
}

func (p *tcpProxy) serve(ln net.Listener) {
	p.mu.Lock()
	p.ln = ln
	p.mu.Unlock()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go p.handle(c)
		}
	}()
}

// Stop closes the listener and every open connection, like Redis going away.
func (p *tcpProxy) Stop() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.ln != nil {
		p.ln.Close()
		p.ln = nil
	}
	for c := range p.conns {
		c.Close()
		delete(p.conns, c)
	}
}

// Start listens again on the same address.
func (p *tcpProxy) Start(t *testing.T) {
	t.Helper()
	var ln net.Listener
	var err error
	for i := 0; i < 50; i++ {
		if ln, err = net.Listen("tcp", p.addr); err == nil {
			p.serve(ln)
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("proxy cannot listen again on %s: %v", p.addr, err)
}

func (p *tcpProxy) track(c net.Conn) {
	p.mu.Lock()
	p.conns[c] = true
	p.mu.Unlock()
}

func (p *tcpProxy) handle(client net.Conn) {
	server, err := net.Dial("tcp", p.target)
	if err != nil {
		client.Close()
		return
	}
	p.track(client)
	p.track(server)
	var swallow atomic.Bool
	closeBoth := func() { client.Close(); server.Close() }
	go func() {
		buf := make([]byte, 64*1024)
		for {
			n, err := client.Read(buf)
			if n > 0 {
				if p.armExec.Load() && bytes.Contains(bytes.ToUpper(buf[:n]), []byte("$4\r\nEXEC\r\n")) && p.armExec.CompareAndSwap(true, false) {
					swallow.Store(true)
					time.AfterFunc(200*time.Millisecond, closeBoth)
				}
				if _, werr := server.Write(buf[:n]); werr != nil {
					closeBoth()
					return
				}
			}
			if err != nil {
				closeBoth()
				return
			}
		}
	}()
	buf := make([]byte, 64*1024)
	for {
		n, err := server.Read(buf)
		if n > 0 && !swallow.Load() {
			if _, werr := client.Write(buf[:n]); werr != nil {
				closeBoth()
				return
			}
		}
		if err != nil {
			closeBoth()
			return
		}
	}
}

// ---- live environment ----

type live struct {
	*harness
	cfg   liveCfg
	admin *redis.Client
	proxy *tcpProxy
	store *RedisStore
	ctx   context.Context
}

func (l *live) buildConsumer(st Store, reg *fakeReg, caller *fakeCaller) *Consumer {
	h := l.harness
	c := New(Config{
		Clock: h.clk, Store: st, Caller: caller, Registry: reg, SecretsDir: h.secrets, Status: h.status,
		Notifier: h.notes, Log: logx.New(h.logbuf, h.clk), Jitter: clock.FixedJitter(0),
		NewRunID: func() string { return "RUNID" },
	})
	c.tick = h.clk.NewTicker(PromoteEvery)
	l.t.Cleanup(func() { c.wg.Wait() })
	return c
}

// newLive returns a harness whose consumer talks to the real Redis through a TCP proxy, as the runner user.
func newLive(t *testing.T) *live {
	t.Helper()
	cfg := loadLiveCfg(t)
	admin := rawClient(cfg.addr, "admin", cfg.adminPW)
	ctx := context.Background()
	if err := admin.FlushAll(ctx).Err(); err != nil {
		t.Fatalf("admin FLUSHALL: %v", err)
	}
	h := newHarness(t)
	h.addApp("a2", "j")
	h.reg.declare("a1", "j3")
	p := newProxy(t, cfg.addr)
	st := NewRedisStore(p.addr, RedisUser, cfg.runnerPW, 2*time.Second)
	l := &live{harness: h, cfg: cfg, admin: admin, proxy: p, store: st, ctx: ctx}
	h.c = l.buildConsumer(st, h.reg, h.caller)
	t.Cleanup(func() {
		if t.Failed() {
			t.Logf("consumer log:\n%s", h.logbuf.String())
		}
		st.Close()
		admin.ConfigSet(ctx, "maxmemory", "96mb")
		admin.FlushAll(ctx)
		admin.Close()
	})
	return l
}

func (l *live) must(args ...any) any {
	l.t.Helper()
	v, err := l.admin.Do(l.ctx, args...).Result()
	if err != nil {
		l.t.Fatalf("admin %v: %v", args[0], err)
	}
	return v
}

func (l *live) lrange(key string) []string {
	l.t.Helper()
	v, err := l.admin.LRange(l.ctx, key, 0, -1).Result()
	if err != nil {
		l.t.Fatalf("LRANGE %s: %v", key, err)
	}
	return v
}

func (l *live) queueOf(app string) []string      { return l.lrange(app + ":jobs:queue") }
func (l *live) processingOf(app string) []string { return l.lrange(app + ":jobs:processing") }
func (l *live) deadOf(app string) []string       { return l.lrange(app + ":jobs:dead") }

func (l *live) delayedOf(app string) []string {
	l.t.Helper()
	v, err := l.admin.ZRange(l.ctx, app+":jobs:delayed", 0, -1).Result()
	if err != nil {
		l.t.Fatalf("ZRANGE: %v", err)
	}
	return v
}

func (l *live) deadRec(app string, i int) DeadRecord {
	l.t.Helper()
	d := l.deadOf(app)
	if i >= len(d) {
		l.t.Fatalf("dead list of %s: %d records, want index %d: %q", app, len(d), i, d)
	}
	var r DeadRecord
	if err := jsonUnmarshal(d[i], &r); err != nil {
		l.t.Fatalf("dead record is not valid JSON: %v: %q", err, d[i])
	}
	return r
}

// settleAdv runs passes, moving the fake clock one second per round so backoffs and probes elapse.
func (l *live) settleAdv(cond func() bool) {
	l.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		l.c.pass()
		if cond() {
			return
		}
		if time.Now().After(deadline) {
			l.t.Fatalf("condition not reached; log:\n%s", l.logbuf.String())
		}
		l.clk.Advance(time.Second)
		time.Sleep(3 * time.Millisecond)
	}
}

// oomOn lowers maxmemory below used_memory until oomOff; every denyoom command is then rejected.
func (l *live) oomOn() {
	l.t.Helper()
	info, err := l.admin.Info(l.ctx, "memory").Result()
	if err != nil {
		l.t.Fatal(err)
	}
	used := int64(0)
	for _, line := range strings.Split(info, "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "used_memory:"); ok {
			used, _ = strconv.ParseInt(v, 10, 64)
		}
	}
	if used < 2 {
		l.t.Fatalf("cannot read used_memory from INFO: %q", info)
	}
	// Far below used_memory (which includes buffers that come and go), so the rejection cannot fade by itself.
	if err := l.admin.ConfigSet(l.ctx, "maxmemory", strconv.FormatInt(used/100+1, 10)).Err(); err != nil {
		l.t.Fatal(err)
	}
	if err := l.admin.Set(l.ctx, "oomprobe", "x", 0).Err(); err == nil || !strings.Contains(err.Error(), "OOM") {
		l.t.Fatalf("OOM case did not trigger: maxmemory was not lowered below used_memory (used=%d, SET err=%v)", used, err)
	}
}

func (l *live) oomOff() {
	l.t.Helper()
	if err := l.admin.ConfigSet(l.ctx, "maxmemory", "96mb").Err(); err != nil {
		l.t.Fatal(err)
	}
}

func (l *live) putAdmin(key string, items ...string) { // oldest first, like enqueue order
	l.t.Helper()
	for _, it := range items {
		l.must("LPUSH", key, it)
	}
}
