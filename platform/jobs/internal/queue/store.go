package queue

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"strings"

	"github.com/redis/go-redis/v9"
)

// Cmd is one Redis command inside a MULTI/EXEC block. Arguments are plain strings: keys, values, and numbers in
// decimal.
type Cmd struct {
	Name string
	Args []string
}

// Store is exactly the set of Redis commands the consumer uses. The production implementation wraps go-redis; the
// unit tests use an in-memory fake with error injection.
//
// Every method returns the server's error unchanged so Classify can sort it. A nil reply is (zero, false, nil).
type Store interface {
	// LIndexLast peeks the rightmost list item (LINDEX key -1).
	LIndexLast(ctx context.Context, key string) (string, bool, error)
	// LMove is LMOVE src dst from to, with from/to "LEFT" or "RIGHT".
	LMove(ctx context.Context, src, dst, from, to string) (string, bool, error)
	// LPos reports whether val is in the list (LPOS key val).
	LPos(ctx context.Context, key, val string) (bool, error)
	// LRem removes one occurrence of val (LREM key 1 val).
	LRem(ctx context.Context, key, val string) (int64, error)
	// LRangeAll returns the whole list, leftmost first.
	LRangeAll(ctx context.Context, key string) ([]string, error)
	// ZCard is the size of a sorted set.
	ZCard(ctx context.Context, key string) (int64, error)
	// ZRangeDue returns up to limit members whose score is <= max, lowest score first.
	ZRangeDue(ctx context.Context, key string, max int64, limit int) ([]string, error)
	// Type is TYPE key ("none" for a missing key).
	Type(ctx context.Context, key string) (string, error)
	// Exec runs the commands in one MULTI/EXEC. The returned slice has one entry per command (nil when it
	// applied). A non-nil error means the block as a whole failed: EXECABORT or a queue-time error applies
	// nothing, and a connection error leaves the outcome unknown.
	Exec(ctx context.Context, cmds []Cmd) ([]error, error)
	// Close releases the connection.
	Close() error
}

// Kind is how a Redis error is handled.
type Kind int

const (
	// KindDeterministic is the zero value on purpose: an error nobody classified fails closed (the app is
	// parked) instead of being retried in a loop.
	KindDeterministic Kind = iota
	// KindTransient is retried with backoff: connection loss, timeout, OOM, EXECABORT, LOADING, BUSY.
	KindTransient
	// KindAuth is NOPERM, WRONGPASS or NOAUTH: redis_state=invalid, retried slowly.
	KindAuth
)

// Class is the classification of one error.
type Class struct {
	Kind Kind
	Conn bool // connection loss or timeout: the server may or may not have applied the command
	OOM  bool
}

var transientPrefixes = []string{"OOM", "EXECABORT", "LOADING", "BUSY", "TRYAGAIN", "MASTERDOWN", "MISCONF"}
var authPrefixes = []string{"NOPERM", "WRONGPASS", "NOAUTH"}

// Classify sorts an error from the Store.
func Classify(err error) Class {
	if err == nil {
		return Class{}
	}
	s := err.Error()
	for _, p := range authPrefixes {
		if strings.HasPrefix(s, p) {
			return Class{Kind: KindAuth}
		}
	}
	for _, p := range transientPrefixes {
		if strings.HasPrefix(s, p) {
			return Class{Kind: KindTransient, OOM: p == "OOM" || (p == "EXECABORT" && strings.Contains(s, "OOM"))}
		}
	}
	if isConn(err) {
		return Class{Kind: KindTransient, Conn: true}
	}
	return Class{Kind: KindDeterministic}
}

func isConn(err error) bool {
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, redis.ErrClosed) ||
		errors.Is(err, context.DeadlineExceeded) || errors.Is(err, os.ErrDeadlineExceeded) || errors.Is(err, net.ErrClosed) {
		return true
	}
	var ne net.Error
	if errors.As(err, &ne) {
		return true
	}
	s := err.Error()
	for _, frag := range []string{"connection refused", "connection reset", "broken pipe", "i/o timeout", "no such host", "use of closed network connection", "EOF"} {
		if strings.Contains(s, frag) {
			return true
		}
	}
	return false
}
