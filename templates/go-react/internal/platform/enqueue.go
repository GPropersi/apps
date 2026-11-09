package platform

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"regexp"
	"strconv"
	"time"

	"github.com/oklog/ulid/v2"
	"github.com/redis/go-redis/v9"
)

// Limits from platform/jobs/CONTRACT.md section 1.
const (
	MaxEnvelopeBytes = 65536
	MaxQueueLen      = 1000
)

var (
	// ErrUndeclaredJob: the job is not in the app's app.yaml `jobs[]`. Returned before any Redis command.
	ErrUndeclaredJob = errors.New("platform: job is not declared in app.yaml")
	// ErrEnvelopeTooLarge: the serialized envelope is over MaxEnvelopeBytes; nothing was written.
	ErrEnvelopeTooLarge = errors.New("platform: job envelope is over 65536 bytes")
	// ErrQueueFull: the queue already holds MaxQueueLen items; nothing was written.
	ErrQueueFull = errors.New("platform: job queue is full")

	jobNameRE = regexp.MustCompile(`^[a-z][a-z0-9_-]{0,62}$`)
)

// RedisClient is the part of *redis.Client the Enqueuer uses, so tests can count and fail commands.
type RedisClient interface {
	LLen(ctx context.Context, key string) *redis.IntCmd
	LPush(ctx context.Context, key string, values ...any) *redis.IntCmd
}

// NewRedisClient builds the app's Redis client from the deploy environment: a tiny pool (the shared Redis serves many
// apps), timeouts on every call, and no automatic retries (a retried LPUSH could enqueue a job twice).
func NewRedisClient(c Config) *redis.Client {
	return redis.NewClient(&redis.Options{
		Addr:            net.JoinHostPort(c.RedisHost, strconv.Itoa(c.RedisPort)),
		Username:        c.RedisUser,
		Password:        c.RedisPassword,
		PoolSize:        2,
		Protocol:        2,
		DisableIdentity: true, // no CLIENT SETINFO round trip; mirrors the runner
		MaxRetries:      -1,
		DialTimeout:     2 * time.Second,
		ReadTimeout:     5 * time.Second,
		WriteTimeout:    5 * time.Second,
	})
}

// Enqueuer adds jobs to the app's queue (`<prefix>jobs:queue`).
type Enqueuer struct {
	rdb      RedisClient
	queueKey string
	declared map[string]bool
	now      func() time.Time
}

type envelope struct {
	V          int             `json:"v"`
	ID         string          `json:"id"`
	Job        string          `json:"job"`
	Payload    json.RawMessage `json:"payload"`
	EnqueuedAt string          `json:"enqueued_at"`
}

// NewEnqueuer takes the Redis client, the key prefix (REDIS_KEY_PREFIX, e.g. "myapp:") and the declared job names.
func NewEnqueuer(rdb RedisClient, keyPrefix string, declared []string) (*Enqueuer, error) {
	if rdb == nil {
		return nil, errors.New("platform: enqueuer needs a redis client")
	}
	if !prefixRE.MatchString(keyPrefix) {
		return nil, &ConfigError{Key: "REDIS_KEY_PREFIX", Problem: "is invalid"}
	}
	set := make(map[string]bool, len(declared))
	for _, name := range declared {
		if !jobNameRE.MatchString(name) {
			return nil, errors.New("platform: enqueuer given an invalid job name")
		}
		set[name] = true
	}
	return &Enqueuer{rdb: rdb, queueKey: keyPrefix + "jobs:queue", declared: set, now: time.Now}, nil
}

// marshalPlain is json.Marshal without HTML escaping, as the runner's own encoder does: `<`, `>` and `&` stay one
// byte each, so the 65536-byte limit measures the same envelope the runner sees.
func marshalPlain(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

// Enqueue follows CONTRACT section 1 in order and returns the new job id (a ULID). The LLEN check and the LPUSH are
// two commands, so the cap is a soft bound under concurrent enqueues.
func (e *Enqueuer) Enqueue(ctx context.Context, job string, payload any) (string, error) {
	if !e.declared[job] {
		return "", ErrUndeclaredJob
	}
	raw, err := marshalPlain(payload)
	if err != nil {
		return "", fmt.Errorf("platform: enqueue %q: payload: %w", job, err)
	}
	now := e.now().UTC()
	id, err := ulid.New(ulid.Timestamp(now), rand.Reader)
	if err != nil {
		return "", fmt.Errorf("platform: enqueue %q: id: %w", job, err)
	}
	body, err := marshalPlain(envelope{V: 1, ID: id.String(), Job: job, Payload: raw, EnqueuedAt: now.Format(time.RFC3339)})
	if err != nil {
		return "", fmt.Errorf("platform: enqueue %q: envelope: %w", job, err)
	}
	if len(body) > MaxEnvelopeBytes {
		return "", ErrEnvelopeTooLarge
	}
	n, err := e.rdb.LLen(ctx, e.queueKey).Result()
	if err != nil {
		return "", fmt.Errorf("platform: enqueue %q: LLEN: %w", job, err)
	}
	if n >= MaxQueueLen {
		return "", ErrQueueFull
	}
	if err := e.rdb.LPush(ctx, e.queueKey, body).Err(); err != nil {
		return "", fmt.Errorf("platform: enqueue %q: LPUSH: %w", job, err)
	}
	return id.String(), nil
}
