package queue

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

// RedisAddr is the shared Redis on the platform network.
const RedisAddr = "redis:6379"

// RedisUser is the runner's ACL user.
const RedisUser = "runner"

// CommandTimeout bounds every Redis command (dial, write and read).
const CommandTimeout = 5 * time.Second

// ReadPassword reads the runner password file and strips exactly one trailing newline (the Password normalisation
// rule), so a file written with echo and one written with printf give the same value.
func ReadPassword(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("jobs-redis.password: %w", err)
	}
	pw := strings.TrimSuffix(string(b), "\n")
	if pw == "" {
		return "", errors.New("jobs-redis.password is empty")
	}
	return pw, nil
}

// RedisStore is the go-redis Store. The client's own retries are off (MaxRetries -1), so the consumer's loop is the
// only retry and its LPOS check sees every ambiguous write.
type RedisStore struct {
	c *redis.Client
}

// NewRedisStore returns a Store for addr. bound is the per-command timeout (CommandTimeout in production).
func NewRedisStore(addr, user, password string, bound time.Duration) *RedisStore {
	return &RedisStore{c: redis.NewClient(&redis.Options{
		Addr: addr, Username: user, Password: password,
		DialTimeout: bound, ReadTimeout: bound, WriteTimeout: bound, PoolTimeout: bound,
		MaxRetries: -1, Protocol: 2, DisableIdentity: true,
		PoolSize: 2, MinIdleConns: 0,
	})}
}

func args(name string, a ...any) []any { return append([]any{name}, a...) }

// LIndexLast implements Store.
func (r *RedisStore) LIndexLast(ctx context.Context, key string) (string, bool, error) {
	s, err := r.c.Do(ctx, args("LINDEX", key, -1)...).Text()
	return nilAware(s, err)
}

// LMove implements Store.
func (r *RedisStore) LMove(ctx context.Context, src, dst, from, to string) (string, bool, error) {
	s, err := r.c.Do(ctx, args("LMOVE", src, dst, from, to)...).Text()
	return nilAware(s, err)
}

func nilAware(s string, err error) (string, bool, error) {
	if errors.Is(err, redis.Nil) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return s, true, nil
}

// LPos implements Store.
func (r *RedisStore) LPos(ctx context.Context, key, val string) (bool, error) {
	_, err := r.c.Do(ctx, args("LPOS", key, val)...).Int64()
	if errors.Is(err, redis.Nil) {
		return false, nil
	}
	return err == nil, err
}

// LRem implements Store.
func (r *RedisStore) LRem(ctx context.Context, key, val string) (int64, error) {
	return r.c.Do(ctx, args("LREM", key, 1, val)...).Int64()
}

// LRangeAll implements Store.
func (r *RedisStore) LRangeAll(ctx context.Context, key string) ([]string, error) {
	return r.c.Do(ctx, args("LRANGE", key, 0, -1)...).StringSlice()
}

// ZCard implements Store.
func (r *RedisStore) ZCard(ctx context.Context, key string) (int64, error) {
	return r.c.Do(ctx, args("ZCARD", key)...).Int64()
}

// ZRangeDue implements Store.
func (r *RedisStore) ZRangeDue(ctx context.Context, key string, max int64, limit int) ([]string, error) {
	return r.c.Do(ctx, args("ZRANGEBYSCORE", key, "-inf", max, "LIMIT", 0, limit)...).StringSlice()
}

// Type implements Store.
func (r *RedisStore) Type(ctx context.Context, key string) (string, error) {
	return r.c.Do(ctx, args("TYPE", key)...).Text()
}

// Exec implements Store.
func (r *RedisStore) Exec(ctx context.Context, cmds []Cmd) ([]error, error) {
	pipe := r.c.TxPipeline()
	out := make([]*redis.Cmd, len(cmds))
	for i, c := range cmds {
		a := make([]any, 0, len(c.Args)+1)
		a = append(a, c.Name)
		for _, s := range c.Args {
			a = append(a, s)
		}
		out[i] = pipe.Do(ctx, a...)
	}
	_, err := pipe.Exec(ctx)
	if err != nil && wholeFailure(err) {
		return nil, err
	}
	errs := make([]error, len(cmds))
	found := false
	for i, c := range out {
		if e := c.Err(); e != nil && !errors.Is(e, redis.Nil) {
			errs[i] = e
			found = true
		}
	}
	if err != nil && !found {
		return nil, err // fail closed: an EXEC error that no command explains must not read as success
	}
	return errs, nil
}

// wholeFailure reports whether an Exec error means the block as a whole did not run (or its outcome is unknown),
// as opposed to a runtime error of one command inside a block that did run.
func wholeFailure(err error) bool {
	var re redis.Error
	if !errors.As(err, &re) {
		return true // a connection error, a timeout, a closed client
	}
	c := Classify(err)
	return c.Kind != KindDeterministic
}

// Close implements Store.
func (r *RedisStore) Close() error { return r.c.Close() }
