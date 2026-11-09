package platform

import (
	"context"
	"errors"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

// Reason classes for a rejected request. They are the only detail logged: never the token or the email.
const (
	ReasonMissing         = "missing"
	ReasonBadSignature    = "bad signature"
	ReasonExpired         = "expired"
	ReasonNotYetValid     = "not yet valid"
	ReasonWrongIssuer     = "wrong iss"
	ReasonWrongAudience   = "wrong aud"
	ReasonNoEmail         = "no email"
	ReasonKeysUnavailable = "keys unavailable"
	ReasonInvalid         = "invalid token"
)

const (
	accessHeader = "Cf-Access-Jwt-Assertion"
	fetchTimeout = 10 * time.Second
	iatLeeway    = time.Minute

	defaultMinRefetch = 30 * time.Second
)

var errRefetchThrottled = errors.New("certs refetch throttled")

// throttledTransport lets at most one certs request through per gap. The first request is always allowed.
type throttledTransport struct {
	base http.RoundTripper
	gap  time.Duration
	now  func() time.Time

	mu   sync.Mutex
	last time.Time
}

func (t *throttledTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if t.gap > 0 {
		t.mu.Lock()
		now := t.now()
		if !t.last.IsZero() && now.Sub(t.last) < t.gap {
			t.mu.Unlock()
			return nil, errRefetchThrottled
		}
		t.last = now
		t.mu.Unlock()
	}
	base := t.base
	if base == nil {
		base = http.DefaultTransport
	}
	return base.RoundTrip(r)
}

// Identity is the signed-in user, as proven by a validated Access JWT.
type Identity struct {
	Email string
}

type identityKey struct{}

// IdentityFrom returns the identity RequireAccess stored in the request context.
func IdentityFrom(ctx context.Context) (Identity, bool) {
	id, ok := ctx.Value(identityKey{}).(Identity)
	return id, ok
}

func withIdentity(ctx context.Context, id Identity) context.Context {
	return context.WithValue(ctx, identityKey{}, id)
}

// AccessError is a rejected token. Reason is one of the Reason* classes.
type AccessError struct {
	Reason string
	Err    error
}

func (e *AccessError) Error() string { return "access: " + e.Reason }
func (e *AccessError) Unwrap() error { return e.Err }

type accessOptions struct {
	jwksURL    string
	client     *http.Client
	now        func() time.Time
	minRefetch time.Duration
}

// AccessOption customises NewAccessVerifier. They exist for tests and are never fed from the environment.
type AccessOption func(*accessOptions)

// WithJWKSURL overrides the certs URL (default https://<team>/cdn-cgi/access/certs).
func WithJWKSURL(u string) AccessOption { return func(o *accessOptions) { o.jwksURL = u } }

// WithHTTPClient overrides the client that fetches the certs. A client without a timeout gets the 10 s default.
func WithHTTPClient(c *http.Client) AccessOption { return func(o *accessOptions) { o.client = c } }

// WithClock overrides the clock used for the exp/nbf/iat checks.
func WithClock(now func() time.Time) AccessOption { return func(o *accessOptions) { o.now = now } }

// WithMinRefetchInterval sets the minimum time between certs requests (default 30 s; 0 disables the throttle).
func WithMinRefetchInterval(d time.Duration) AccessOption {
	return func(o *accessOptions) { o.minRefetch = d }
}

// AccessVerifier validates Cloudflare Access login JWTs.
type AccessVerifier struct {
	verifier *oidc.IDTokenVerifier
	now      func() time.Time
}

// NewAccessVerifier builds a verifier for an Access team domain and application audience tag. It does no network
// I/O: the certs are fetched on the first validation (and again on an unknown kid, at most once per minimum refetch
// interval, so a flood of random kids cannot turn into a flood of requests to Cloudflare). go-oidc keeps ctx and
// uses it (with its HTTP client) for every key fetch, so the startup ctx governs the fetches: cancelling it fails them.
// The client timeout bounds each fetch.
func NewAccessVerifier(ctx context.Context, teamDomain, aud string, opts ...AccessOption) (*AccessVerifier, error) {
	if !teamRE.MatchString(teamDomain) {
		return nil, &ConfigError{Key: "ACCESS_TEAM_DOMAIN", Problem: "is missing or invalid"}
	}
	if aud == "" {
		return nil, &ConfigError{Key: "ACCESS_AUD", Problem: "is missing"}
	}
	o := accessOptions{now: time.Now, minRefetch: defaultMinRefetch}
	for _, opt := range opts {
		opt(&o)
	}
	issuer := "https://" + teamDomain
	if o.jwksURL == "" {
		o.jwksURL = issuer + "/cdn-cgi/access/certs"
	}
	client := &http.Client{Timeout: fetchTimeout}
	if o.client != nil {
		c := *o.client
		if c.Timeout == 0 {
			c.Timeout = fetchTimeout
		}
		client = &c
	}
	client.Transport = &throttledTransport{base: client.Transport, gap: o.minRefetch, now: o.now}
	keys := oidc.NewRemoteKeySet(oidc.ClientContext(ctx, client), o.jwksURL)
	v := oidc.NewVerifier(issuer, keys, &oidc.Config{
		ClientID:             aud,
		SupportedSigningAlgs: []string{oidc.RS256},
		Now:                  o.now,
	})
	return &AccessVerifier{verifier: v, now: o.now}, nil
}

// Verify validates one Cf-Access-Jwt-Assertion value and returns the identity. Every failure is an *AccessError.
func (a *AccessVerifier) Verify(ctx context.Context, token string) (Identity, error) {
	if token == "" {
		return Identity{}, &AccessError{Reason: ReasonMissing}
	}
	idt, err := a.verifier.Verify(ctx, token)
	if err != nil {
		return Identity{}, &AccessError{Reason: classify(err), Err: err}
	}
	if idt.IssuedAt.IsZero() || idt.IssuedAt.After(a.now().Add(iatLeeway)) {
		return Identity{}, &AccessError{Reason: ReasonNotYetValid}
	}
	var claims struct {
		Email string `json:"email"`
	}
	if err := idt.Claims(&claims); err != nil {
		return Identity{}, &AccessError{Reason: ReasonInvalid, Err: err}
	}
	email := strings.ToLower(strings.TrimSpace(claims.Email))
	if email == "" {
		return Identity{}, &AccessError{Reason: ReasonNoEmail}
	}
	return Identity{Email: email}, nil
}

// fetchCause names why the certs could not be fetched, as a fixed word. The library's error text can carry response
// bodies, so it is never logged.
func fetchCause(err error) string {
	var ne net.Error
	msg := err.Error()
	// go-oidc formats the fetch error with %v, which drops the error chain, so the text is matched too.
	switch {
	case errors.Is(err, errRefetchThrottled), strings.Contains(msg, errRefetchThrottled.Error()):
		return "throttled"
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &ne) && ne.Timeout(),
		strings.Contains(msg, "Client.Timeout"), strings.Contains(msg, "deadline exceeded"):
		return "timeout"
	case strings.Contains(msg, "unable to read response body"), strings.Contains(msg, "unmarshal"):
		return "bad response"
	default:
		return "fetch failed"
	}
}

// classify maps a go-oidc verification error to a reason class. It matches go-oidc v3.14.1 messages; the tests
// exercise every class, so a library bump that changes a message fails them. Anything unrecognised is rejected as
// ReasonInvalid.
func classify(err error) string {
	var expired *oidc.TokenExpiredError
	msg := err.Error()
	// Anchored prefixes: the messages embed the token's own iss/aud text after the prefix, so a substring match could
	// be spoofed by a crafted claim.
	switch {
	case errors.As(err, &expired):
		return ReasonExpired
	case strings.HasPrefix(msg, "oidc: current time"):
		return ReasonNotYetValid
	case strings.HasPrefix(msg, "oidc: id token issued by a different provider"):
		return ReasonWrongIssuer
	case strings.HasPrefix(msg, "oidc: expected audience"):
		return ReasonWrongAudience
	case strings.HasPrefix(msg, "failed to verify signature: fetching keys"):
		return ReasonKeysUnavailable
	case strings.HasPrefix(msg, "failed to verify signature"), strings.HasPrefix(msg, "oidc: malformed jwt"):
		return ReasonBadSignature
	default:
		return ReasonInvalid
	}
}
