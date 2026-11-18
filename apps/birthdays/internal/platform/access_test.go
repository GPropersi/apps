package platform

import (
	"bytes"
	"context"
	"crypto"
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"log"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const (
	testTeam  = "acme.cloudflareaccess.com"
	testAud   = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	testEmail = "Alice.Secret@Example.com"
)

// testKey is a throwaway RSA signing key; nothing here is a real credential and no token is committed.
type testKey struct {
	kid string
	key *rsa.PrivateKey
}

func newTestKey(t *testing.T, kid string) testKey {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	return testKey{kid: kid, key: k}
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return b
}

// claims returns a valid claim set; a test overrides or deletes fields to make one invalid.
func claims() map[string]any {
	now := time.Now()
	return map[string]any{
		"iss":   "https://" + testTeam,
		"aud":   []string{testAud},
		"exp":   now.Add(time.Hour).Unix(),
		"nbf":   now.Add(-time.Minute).Unix(),
		"iat":   now.Add(-time.Minute).Unix(),
		"email": testEmail,
	}
}

// rs256 signs claims with the key under its kid.
func (k testKey) rs256(t *testing.T, c map[string]any) string {
	t.Helper()
	signing := b64(mustJSON(t, map[string]any{"alg": "RS256", "typ": "JWT", "kid": k.kid})) + "." + b64(mustJSON(t, c))
	sum := sha256.Sum256([]byte(signing))
	sig, err := rsa.SignPKCS1v15(rand.Reader, k.key, crypto.SHA256, sum[:])
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	return signing + "." + b64(sig)
}

// none is an unsigned alg:none token.
func (k testKey) none(t *testing.T, c map[string]any) string {
	t.Helper()
	return b64(mustJSON(t, map[string]any{"alg": "none", "typ": "JWT", "kid": k.kid})) + "." + b64(mustJSON(t, c)) + "."
}

// hs256 is the classic confusion attack: an HS256 token whose HMAC key is the RSA public key.
func (k testKey) hs256(t *testing.T, c map[string]any) string {
	t.Helper()
	der, err := x509.MarshalPKIXPublicKey(&k.key.PublicKey)
	if err != nil {
		t.Fatalf("marshal public key: %v", err)
	}
	signing := b64(mustJSON(t, map[string]any{"alg": "HS256", "typ": "JWT", "kid": k.kid})) + "." + b64(mustJSON(t, c))
	mac := hmac.New(sha256.New, der)
	mac.Write([]byte(signing))
	return signing + "." + b64(mac.Sum(nil))
}

// jwksServer serves the public halves of its keys; keys can be swapped to simulate rotation. hits counts requests.
type jwksServer struct {
	*httptest.Server
	mu   sync.Mutex
	keys []testKey
	hits atomic.Int64
}

func newJWKS(t *testing.T, keys ...testKey) *jwksServer {
	t.Helper()
	s := &jwksServer{keys: keys}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		s.hits.Add(1)
		s.mu.Lock()
		defer s.mu.Unlock()
		type jwk struct {
			Kty string `json:"kty"`
			Kid string `json:"kid"`
			Alg string `json:"alg"`
			Use string `json:"use"`
			N   string `json:"n"`
			E   string `json:"e"`
		}
		out := struct {
			Keys []jwk `json:"keys"`
		}{}
		for _, k := range s.keys {
			out.Keys = append(out.Keys, jwk{
				Kty: "RSA", Kid: k.kid, Alg: "RS256", Use: "sig",
				N: b64(k.key.N.Bytes()), E: b64(big.NewInt(int64(k.key.E)).Bytes()),
			})
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(out); err != nil {
			t.Errorf("jwks write: %v", err)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func (s *jwksServer) setKeys(keys ...testKey) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.keys = keys
}

// captureLog redirects the standard logger for one test and returns the buffer.
func captureLog(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	log.SetOutput(&buf)
	t.Cleanup(func() { log.SetOutput(os.Stderr) })
	return &buf
}

func newVerifier(t *testing.T, jwksURL string) *AccessVerifier {
	t.Helper()
	// The dev build would bypass validation if this leaked in from the environment.
	t.Setenv("ACCESS_DEV_EMAIL", "")
	v, err := NewAccessVerifier(context.Background(), testTeam, testAud, WithJWKSURL(jwksURL), WithMinRefetchInterval(0))
	if err != nil {
		t.Fatalf("NewAccessVerifier: %v", err)
	}
	return v
}

// A flood of unknown kids must not become a flood of certs requests (default throttle).
func TestUnknownKidFloodIsThrottled(t *testing.T) {
	known := newTestKey(t, "k1")
	srv := newJWKS(t, known)
	t.Setenv("ACCESS_DEV_EMAIL", "")
	v, err := NewAccessVerifier(context.Background(), testTeam, testAud, WithJWKSURL(srv.URL))
	if err != nil {
		t.Fatal(err)
	}
	captureLog(t)
	for i := range 20 {
		unknown := newTestKey(t, "rand-"+string(rune('a'+i)))
		if status, _, reached, _ := do(t, v, withToken(unknown.rs256(t, claims()))); status != http.StatusUnauthorized || reached {
			t.Fatalf("unknown kid %d: status %d, reached %v", i, status, reached)
		}
	}
	if n := srv.hits.Load(); n != 1 {
		t.Fatalf("20 unknown-kid requests made %d certs requests, want 1", n)
	}
}

// Claims text is attacker-controlled and echoed in library errors; it must not steer the reason class.
func TestCraftedClaimsCannotSpoofTheReasonClass(t *testing.T) {
	k := newTestKey(t, "k1")
	srv := newJWKS(t, k)
	v := newVerifier(t, srv.URL)
	c := claims()
	c["aud"] = []string{"oidc: current time before the nbf failed to verify signature: fetching keys"}
	buf := captureLog(t)
	if status, _, _, _ := do(t, v, withToken(k.rs256(t, c))); status != http.StatusUnauthorized {
		t.Fatalf("status %d", status)
	}
	if !strings.Contains(buf.String(), "reason="+ReasonWrongAudience) {
		t.Fatalf("log %q is not classed as %q", buf.String(), ReasonWrongAudience)
	}
}

// do sends a request through RequireAccess and reports the status, the body and whether the handler ran.
func do(t *testing.T, v *AccessVerifier, header map[string]string) (status int, body string, reached bool, id Identity) {
	t.Helper()
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reached = true
		id, _ = IdentityFrom(r.Context())
		w.WriteHeader(http.StatusOK)
	})
	req := httptest.NewRequest(http.MethodGet, "/api/me", nil)
	for k, val := range header {
		req.Header.Set(k, val)
	}
	rec := httptest.NewRecorder()
	RequireAccess(v)(next).ServeHTTP(rec, req)
	return rec.Code, rec.Body.String(), reached, id
}

func withToken(tok string) map[string]string { return map[string]string{accessHeader: tok} }

func TestValidTokenPassesAndEmailIsLowercased(t *testing.T) {
	k := newTestKey(t, "k1")
	srv := newJWKS(t, k)
	v := newVerifier(t, srv.URL)
	status, _, reached, id := do(t, v, withToken(k.rs256(t, claims())))
	if status != http.StatusOK || !reached {
		t.Fatalf("valid token: status %d, reached %v", status, reached)
	}
	if id.Email != strings.ToLower(testEmail) {
		t.Fatalf("identity email = %q, want lowercased %q", id.Email, strings.ToLower(testEmail))
	}
}

func TestRejectedTokens(t *testing.T) {
	good := newTestKey(t, "k1")
	other := newTestKey(t, "k1") // same kid, different key material
	srv := newJWKS(t, good)
	v := newVerifier(t, srv.URL)

	mutate := func(f func(c map[string]any)) map[string]any {
		c := claims()
		f(c)
		return c
	}
	cases := []struct {
		name   string
		token  string
		reason string
	}{
		{"wrong aud", good.rs256(t, mutate(func(c map[string]any) { c["aud"] = []string{"other"} })), ReasonWrongAudience},
		{"wrong iss", good.rs256(t, mutate(func(c map[string]any) { c["iss"] = "https://evil.cloudflareaccess.com" })), ReasonWrongIssuer},
		{"expired", good.rs256(t, mutate(func(c map[string]any) { c["exp"] = time.Now().Add(-time.Hour).Unix() })), ReasonExpired},
		{"not yet valid (nbf)", good.rs256(t, mutate(func(c map[string]any) { c["nbf"] = time.Now().Add(time.Hour).Unix() })), ReasonNotYetValid},
		{"issued in the future (iat)", good.rs256(t, mutate(func(c map[string]any) { c["iat"] = time.Now().Add(time.Hour).Unix() })), ReasonNotYetValid},
		{"alg none", good.none(t, claims()), ReasonBadSignature},
		{"HS256 signed with the public key", good.hs256(t, claims()), ReasonBadSignature},
		{"known kid, different signing key", other.rs256(t, claims()), ReasonBadSignature},
		{"missing email", good.rs256(t, mutate(func(c map[string]any) { delete(c, "email") })), ReasonNoEmail},
		{"empty email", good.rs256(t, mutate(func(c map[string]any) { c["email"] = "  " })), ReasonNoEmail},
		{"service token (common_name, no email)", good.rs256(t, mutate(func(c map[string]any) {
			delete(c, "email")
			c["common_name"] = "ci.access"
		})), ReasonNoEmail},
		{"garbage", "not-a-jwt", ReasonBadSignature},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			buf := captureLog(t)
			status, body, reached, _ := do(t, v, withToken(tc.token))
			if status != http.StatusUnauthorized || reached {
				t.Fatalf("status %d, reached %v; want 401 and an unreached handler", status, reached)
			}
			if body != `{"error":"unauthenticated"}` {
				t.Fatalf("body = %q", body)
			}
			if !strings.Contains(buf.String(), "reason="+tc.reason) {
				t.Fatalf("log %q does not name reason class %q", buf.String(), tc.reason)
			}
		})
	}
}

func TestMissingHeaderAndCookieOnly(t *testing.T) {
	k := newTestKey(t, "k1")
	srv := newJWKS(t, k)
	v := newVerifier(t, srv.URL)

	buf := captureLog(t)
	status, _, reached, _ := do(t, v, nil)
	if status != http.StatusUnauthorized || reached {
		t.Fatalf("no header: status %d, reached %v", status, reached)
	}
	if !strings.Contains(buf.String(), "reason="+ReasonMissing) {
		t.Fatalf("log %q does not name %q", buf.String(), ReasonMissing)
	}

	// A valid token in the CF_Authorization cookie alone is not accepted: only the header is read.
	status, _, reached, _ = do(t, v, map[string]string{"Cookie": "CF_Authorization=" + k.rs256(t, claims())})
	if status != http.StatusUnauthorized || reached {
		t.Fatalf("cookie only: status %d, reached %v", status, reached)
	}
}

func TestNilVerifierFailsClosed(t *testing.T) {
	t.Setenv("ACCESS_DEV_EMAIL", "")
	captureLog(t)
	status, _, reached, _ := do(t, nil, withToken("anything"))
	if status != http.StatusUnauthorized || reached {
		t.Fatalf("nil verifier: status %d, reached %v", status, reached)
	}
}

func TestContentTypeIsJSON(t *testing.T) {
	t.Setenv("ACCESS_DEV_EMAIL", "")
	captureLog(t)
	rec := httptest.NewRecorder()
	RequireAccess(nil)(http.NotFoundHandler()).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("Content-Type = %q", ct)
	}
}

func TestKeyRefreshOnUnknownKid(t *testing.T) {
	k1 := newTestKey(t, "k1")
	k2 := newTestKey(t, "k2")
	k3 := newTestKey(t, "k3")
	srv := newJWKS(t, k1)
	v := newVerifier(t, srv.URL)

	if status, _, _, _ := do(t, v, withToken(k1.rs256(t, claims()))); status != http.StatusOK {
		t.Fatalf("k1 token: status %d", status)
	}
	before := srv.hits.Load()
	if status, _, _, _ := do(t, v, withToken(k1.rs256(t, claims()))); status != http.StatusOK || srv.hits.Load() != before {
		t.Fatalf("a cached key must not refetch: status %d, hits %d -> %d", status, before, srv.hits.Load())
	}

	// Rotation: the server now also serves k2; the unknown kid triggers a refresh and then validates.
	srv.setKeys(k1, k2)
	if status, _, _, _ := do(t, v, withToken(k2.rs256(t, claims()))); status != http.StatusOK {
		t.Fatalf("k2 token after rotation: status %d", status)
	}
	if srv.hits.Load() <= before {
		t.Fatalf("an unknown kid must refresh the keys: hits %d -> %d", before, srv.hits.Load())
	}

	// A kid the server never serves stays rejected after the refresh.
	captureLog(t)
	if status, _, reached, _ := do(t, v, withToken(k3.rs256(t, claims()))); status != http.StatusUnauthorized || reached {
		t.Fatalf("unknown kid: status %d, reached %v", status, reached)
	}
}

func TestConstructionDoesNoNetworkIO(t *testing.T) {
	k := newTestKey(t, "k1")
	srv := newJWKS(t, k)
	t.Setenv("ACCESS_DEV_EMAIL", "")
	if _, err := NewAccessVerifier(context.Background(), testTeam, testAud, WithJWKSURL(srv.URL)); err != nil {
		t.Fatalf("NewAccessVerifier: %v", err)
	}
	if n := srv.hits.Load(); n != 0 {
		t.Fatalf("construction made %d requests, want 0", n)
	}
}

func TestUnreachableJWKSIsLazyThenKeysUnavailable(t *testing.T) {
	k := newTestKey(t, "k1")
	srv := newJWKS(t, k)
	url := srv.URL
	srv.Close() // connections to url are now refused
	t.Setenv("ACCESS_DEV_EMAIL", "")

	v, err := NewAccessVerifier(context.Background(), testTeam, testAud, WithJWKSURL(url))
	if err != nil {
		t.Fatalf("construction against an unreachable JWKS URL must succeed: %v", err)
	}
	buf := captureLog(t)
	status, body, reached, _ := do(t, v, withToken(k.rs256(t, claims())))
	if status != http.StatusUnauthorized || reached || body != `{"error":"unauthenticated"}` {
		t.Fatalf("status %d, reached %v, body %q", status, reached, body)
	}
	if !strings.Contains(buf.String(), "reason="+ReasonKeysUnavailable) {
		t.Fatalf("log %q does not name %q", buf.String(), ReasonKeysUnavailable)
	}
}

func TestHungCertsFetchIsBoundedByTheClientTimeout(t *testing.T) {
	if fetchTimeout != 10*time.Second {
		t.Fatalf("fetchTimeout = %v, want 10s", fetchTimeout)
	}
	release := make(chan struct{})
	hung := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { <-release }))
	t.Cleanup(hung.Close)
	t.Cleanup(func() { close(release) })
	t.Setenv("ACCESS_DEV_EMAIL", "")

	v, err := NewAccessVerifier(context.Background(), testTeam, testAud, WithJWKSURL(hung.URL),
		WithHTTPClient(&http.Client{Timeout: 100 * time.Millisecond}))
	if err != nil {
		t.Fatalf("NewAccessVerifier: %v", err)
	}
	buf := captureLog(t)
	start := time.Now()
	status, _, _, _ := do(t, v, withToken(newTestKey(t, "k1").rs256(t, claims())))
	if status != http.StatusUnauthorized || time.Since(start) > 5*time.Second {
		t.Fatalf("hung fetch: status %d after %v", status, time.Since(start))
	}
	if !strings.Contains(buf.String(), "cause=timeout") {
		t.Fatalf("log %q does not name the timeout cause", buf.String())
	}
	if !strings.Contains(buf.String(), "reason="+ReasonKeysUnavailable) {
		t.Fatalf("log %q does not name %q", buf.String(), ReasonKeysUnavailable)
	}
}

func TestNewAccessVerifierRefusesBadInput(t *testing.T) {
	for _, tc := range []struct{ team, aud string }{
		{"", testAud}, {"https://acme.cloudflareaccess.com", testAud}, {"a/b", testAud}, {testTeam, ""},
	} {
		if _, err := NewAccessVerifier(context.Background(), tc.team, tc.aud); err == nil {
			t.Errorf("NewAccessVerifier(%q, %q) succeeded, want an error", tc.team, tc.aud)
		}
	}
}

// Rejected requests must log neither the token, any part of it, nor the email inside it.
func TestRejectionLogsContainNoSecrets(t *testing.T) {
	good := newTestKey(t, "k1")
	srv := newJWKS(t, good)
	v := newVerifier(t, srv.URL)

	expired := claims()
	expired["exp"] = time.Now().Add(-time.Hour).Unix()
	tokens := []string{
		good.rs256(t, expired),
		good.none(t, claims()),
		good.hs256(t, claims()),
		newTestKey(t, "k1").rs256(t, claims()),
	}
	for _, tok := range tokens {
		buf := captureLog(t)
		if status, _, _, _ := do(t, v, withToken(tok)); status != http.StatusUnauthorized {
			t.Fatalf("status %d, want 401", status)
		}
		out := buf.String()
		for _, secret := range append(strings.Split(tok, "."), tok, testEmail, strings.ToLower(testEmail), "Alice.Secret") {
			if secret != "" && strings.Contains(out, secret) {
				t.Fatalf("log line %q leaks %q", out, secret)
			}
		}
	}
}
