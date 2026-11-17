package platform

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// NotifsSecretsDir is where deploy.sh mounts the app's secrets; the notifs-* files appear there once the key has been
// delivered (platform `notifs-key` helper).
const NotifsSecretsDir = "/run/platform/secrets"

const (
	notifsKeyFile      = "notifs-key"
	notifsClientIDFile = "notifs-access-client-id"
	notifsSecretFile   = "notifs-access-client-secret"
	notifsBaseURLFile  = "notifs-base-url"

	notifsTimeout      = 10 * time.Second
	notifsMaxBodyBytes = 1 << 20
	notifsMaxErrorText = 200

	// NotifsAppIDPrefix is the registrar prefix: an app's notifs app_id is this plus its name with `-` as `_`. The
	// shell twin is platform/lib/notifs-app-id.sh; both read testdata/notifs-app-ids.txt.
	NotifsAppIDPrefix = "apps_"
)

var (
	// ErrNotifsUnconfigured: a notifs-* file is missing or empty (the key has not been delivered yet). No request
	// was made.
	ErrNotifsUnconfigured = errors.New("platform: notifs is not configured")
	// ErrNotifsRetryable: a network failure, a timeout or a 5xx answer; the same call may succeed later. A 5xx is also
	// a *NotifsError (errors.As) so the caller can log its status.
	ErrNotifsRetryable = errors.New("platform: notifs call failed, retryable")

	notifsNameRE  = regexp.MustCompile(`^[a-z][a-z0-9-]{1,30}$`)
	notifsAppIDRE = regexp.MustCompile(`^[a-z0-9][a-z0-9_]{0,62}$`)
)

// NotifsError is a non-success answer from delivery-api (or Cloudflare Access in front of it). Message is
// delivery-api's error text (never a request value). Callers classify 401, 403 and 429 by Status; errors.Is(err,
// ErrNotifsRetryable) is true for Status >= 500.
type NotifsError struct {
	Status  int
	Message string
}

func (e *NotifsError) Error() string {
	return fmt.Sprintf("notifs: status %d: %s", e.Status, e.Message)
}

// Is makes a 5xx answer match ErrNotifsRetryable.
func (e *NotifsError) Is(target error) bool {
	return target == ErrNotifsRetryable && e.Status >= 500
}

// NotifsAppID maps an app name to its 4irl-notifs app_id (`birthdays` -> `apps_birthdays`, `my-app` ->
// `apps_my_app`). A name the registry would refuse is an error.
func NotifsAppID(name string) (string, error) {
	if !notifsNameRE.MatchString(name) {
		return "", errors.New("platform: invalid app name for notifs")
	}
	id := NotifsAppIDPrefix + strings.ReplaceAll(name, "-", "_")
	if !notifsAppIDRE.MatchString(id) {
		return "", errors.New("platform: invalid app name for notifs")
	}
	return id, nil
}

// Message is one notification. Via is "ntfy", "personal" or "both" and decides which of Recipient's destinations
// receive it; PersonalDestinationIDs lists the personal destinations to use.
type Message struct {
	Channel                string
	IdempotencyKey         string
	Recipient              string
	Via                    string
	PersonalDestinationIDs []int64
	Title                  string
	Body                   string
}

// Result is delivery-api's acceptance of a Message. Duplicate is true when the idempotency key was already used.
type Result struct {
	Status    int
	MessageID string
	Duplicate bool
}

// Provisioned is the answer to Provision. Password is set only when this call generated one (a person's first
// provision): show it once and never store or log it. The subscriber token is deliberately not exposed.
type Provisioned struct {
	UserID     string
	PersonHash string
	Password   string
}

// PasswordReset is the answer to ResetPassword; Password is shown once and never stored or logged.
type PasswordReset struct {
	UserID   string
	Password string
}

// PersonalDestinationInput is what an app registers for one person: a Discord or webhook destination.
type PersonalDestinationInput struct {
	Label   string
	Type    string
	Config  map[string]string
	Secrets map[string]string
}

// NotifsClient talks to 4irl-notifs delivery-api as one app. It holds no credentials: every call re-reads the
// notifs-* files, so a rotated key is picked up without a restart and construction never needs the files.
type NotifsClient struct {
	dir    string
	appID  string
	hc     *http.Client
	Logger *slog.Logger // optional; slog.Default() when nil
}

// NewNotifsClient returns a client reading the notifs-* files from secretsDir (NotifsSecretsDir in production) for
// the app id NotifsAppID produced. It never fails and never touches the files.
func NewNotifsClient(secretsDir, appID string) *NotifsClient {
	return &NotifsClient{
		dir:   secretsDir,
		appID: appID,
		hc: &http.Client{
			Timeout:       notifsTimeout,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}
}

type notifsConfig struct {
	key, clientID, clientSecret, baseURL string
}

// config reads the four files now. Any missing or empty file, or a base URL that is not an absolute http(s) URL, is
// ErrNotifsUnconfigured.
func (c *NotifsClient) config() (notifsConfig, error) {
	read := func(name string) (string, bool) {
		b, err := os.ReadFile(filepath.Join(c.dir, name))
		if err != nil {
			return "", false
		}
		v := strings.TrimSpace(string(b))
		return v, v != ""
	}
	var (
		cfg                        notifsConfig
		okKey, okID, okSecret, okU bool
	)
	cfg.key, okKey = read(notifsKeyFile)
	cfg.clientID, okID = read(notifsClientIDFile)
	cfg.clientSecret, okSecret = read(notifsSecretFile)
	cfg.baseURL, okU = read(notifsBaseURLFile)
	if !okKey || !okID || !okSecret || !okU {
		return notifsConfig{}, ErrNotifsUnconfigured
	}
	u, err := url.Parse(cfg.baseURL)
	if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") {
		return notifsConfig{}, ErrNotifsUnconfigured
	}
	cfg.baseURL = strings.TrimRight(cfg.baseURL, "/")
	return cfg, nil
}

// Configured reads the notifs-* files like a call would, with no network, and returns ErrNotifsUnconfigured when any
// is missing. The reminder scan calls it first so a missing key is one failed run, not one failed job per reminder.
func (c *NotifsClient) Configured() error {
	_, err := c.config()
	return err
}

func (c *NotifsClient) logger() *slog.Logger {
	if c.Logger != nil {
		return c.Logger
	}
	return slog.Default()
}

// do sends one request. body is JSON-encoded (nil sends none). A 2xx answer returns its body; anything else is an
// error that carries no request value: not the key, the Access pair, an email, a URL or a body.
func (c *NotifsClient) do(ctx context.Context, op, method, path string, body any) ([]byte, int, error) {
	started := time.Now()
	log := c.logger()
	fail := func(status int, class string, err error) ([]byte, int, error) {
		log.Warn("notifs call failed", "op", op, "status", status, "class", class,
			"duration_ms", time.Since(started).Milliseconds())
		return nil, status, err
	}

	cfg, err := c.config()
	if err != nil {
		return fail(0, "unconfigured", err)
	}
	if !notifsAppIDRE.MatchString(c.appID) {
		return fail(0, "bad_app_id", errors.New("platform: notifs: invalid app id"))
	}
	var rdr io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return fail(0, "encode", fmt.Errorf("platform: notifs %s: cannot encode request", op))
		}
		rdr = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, cfg.baseURL+"/v1"+path, rdr)
	if err != nil {
		return fail(0, "request", fmt.Errorf("platform: notifs %s: cannot build request", op))
	}
	req.Header.Set("CF-Access-Client-Id", cfg.clientID)
	req.Header.Set("CF-Access-Client-Secret", cfg.clientSecret)
	req.Header.Set("Authorization", "Bearer "+cfg.key)
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.hc.Do(req)
	if err != nil {
		// The transport error text names the URL, so it is classified and dropped.
		class := "network"
		var ne interface{ Timeout() bool }
		if errors.Is(err, context.DeadlineExceeded) || (errors.As(err, &ne) && ne.Timeout()) {
			class = "timeout"
		} else if errors.Is(err, context.Canceled) {
			class = "canceled"
		}
		out := fmt.Errorf("%w: notifs %s: %s", ErrNotifsRetryable, op, class)
		// The context error text carries no URL, so it is safe to keep for errors.Is.
		if class == "canceled" {
			out = errors.Join(out, context.Canceled)
		} else if class == "timeout" && errors.Is(ctx.Err(), context.DeadlineExceeded) {
			out = errors.Join(out, context.DeadlineExceeded)
		}
		return fail(0, class, out)
	}
	defer func() { _ = resp.Body.Close() }()
	data, readErr := io.ReadAll(io.LimitReader(resp.Body, notifsMaxBodyBytes))

	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		if readErr != nil {
			return fail(resp.StatusCode, "read", fmt.Errorf("%w: notifs %s: unreadable response", ErrNotifsRetryable, op))
		}
		log.Info("notifs call", "op", op, "status", resp.StatusCode, "duration_ms", time.Since(started).Milliseconds())
		return data, resp.StatusCode, nil
	}
	return fail(resp.StatusCode, "status", &NotifsError{Status: resp.StatusCode, Message: errorText(data)})
}

// errorText is delivery-api's `{"error": "..."}` text, capped; empty when the body is anything else.
func errorText(data []byte) string {
	var e struct {
		Error string `json:"error"`
	}
	if json.Unmarshal(data, &e) != nil {
		return ""
	}
	if len(e.Error) > notifsMaxErrorText {
		return strings.ToValidUTF8(e.Error[:notifsMaxErrorText], "")
	}
	return e.Error
}

func (c *NotifsClient) decode(op string, data []byte, v any) error {
	if err := json.Unmarshal(data, v); err != nil {
		return fmt.Errorf("%w: notifs %s: unreadable response", ErrNotifsRetryable, op)
	}
	return nil
}

func (c *NotifsClient) appPath(suffix string) string {
	return "/apps/" + url.PathEscape(c.appID) + suffix
}

type personBody struct {
	Email string `json:"email"`
}

// Send submits one message (`POST /v1/messages`). A retry with the same IdempotencyKey is safe: delivery-api answers
// Duplicate and sends nothing twice. Send does not wait for delivery: Result.Status is the 202 acceptance.
func (c *NotifsClient) Send(ctx context.Context, m Message) (Result, error) {
	to := map[string]any{"recipient": m.Recipient}
	if m.Via != "" {
		to["via"] = m.Via
	}
	if m.PersonalDestinationIDs != nil {
		to["personal_destination_ids"] = m.PersonalDestinationIDs
	}
	data, status, err := c.do(ctx, "send", http.MethodPost, "/messages", map[string]any{
		"app_id":          c.appID,
		"channel":         m.Channel,
		"idempotency_key": m.IdempotencyKey,
		"to":              to,
		"payload":         map[string]any{},
		"display":         map[string]string{"title": m.Title, "body": m.Body},
	})
	if err != nil {
		return Result{}, err
	}
	// The message was accepted; an unreadable body must not turn that into a failure (a retry would only be a
	// duplicate), so decode errors leave the optional fields empty.
	var out struct {
		Message struct {
			MessageID string `json:"message_id"`
		} `json:"message"`
		Duplicate bool `json:"duplicate"`
	}
	_ = json.Unmarshal(data, &out)
	return Result{Status: status, MessageID: out.Message.MessageID, Duplicate: out.Duplicate}, nil
}

// Provision registers the person for ntfy push in this app (`POST /v1/apps/{app_id}/provision`). Only call it for an
// email the person verified.
func (c *NotifsClient) Provision(ctx context.Context, email string) (Provisioned, error) {
	data, _, err := c.do(ctx, "provision", http.MethodPost, c.appPath("/provision"), personBody{Email: email})
	if err != nil {
		return Provisioned{}, err
	}
	var out struct {
		UserID     string `json:"user_id"`
		PersonHash string `json:"person_hash"`
		Password   string `json:"password"`
	}
	if err := c.decode("provision", data, &out); err != nil {
		return Provisioned{}, err
	}
	return Provisioned{UserID: out.UserID, PersonHash: out.PersonHash, Password: out.Password}, nil
}

// ResetPassword generates a new ntfy password for a provisioned person (`POST .../reset-password`). A 404 `user does
// not exist` and a 429 arrive as *NotifsError.
func (c *NotifsClient) ResetPassword(ctx context.Context, email string) (PasswordReset, error) {
	data, _, err := c.do(ctx, "reset_password", http.MethodPost, c.appPath("/reset-password"), personBody{Email: email})
	if err != nil {
		return PasswordReset{}, err
	}
	var out struct {
		UserID   string `json:"user_id"`
		Password string `json:"password"`
	}
	if err := c.decode("reset_password", data, &out); err != nil {
		return PasswordReset{}, err
	}
	return PasswordReset{UserID: out.UserID, Password: out.Password}, nil
}

// CreatePersonalDestination registers a Discord or webhook destination for the person, already opted in to this app
// (`POST .../personal-destinations`), and returns its id.
func (c *NotifsClient) CreatePersonalDestination(ctx context.Context, email string, in PersonalDestinationInput) (int64, error) {
	if in.Config == nil {
		in.Config = map[string]string{}
	}
	if in.Secrets == nil {
		in.Secrets = map[string]string{}
	}
	data, _, err := c.do(ctx, "create_personal_destination", http.MethodPost, c.appPath("/personal-destinations"), map[string]any{
		"email":   email,
		"label":   in.Label,
		"type":    in.Type,
		"config":  in.Config,
		"secrets": in.Secrets,
		"opt_in":  true,
	})
	if err != nil {
		return 0, err
	}
	var out struct {
		PersonalDestination struct {
			ID int64 `json:"id"`
		} `json:"personal_destination"`
	}
	if err := c.decode("create_personal_destination", data, &out); err != nil {
		return 0, err
	}
	if out.PersonalDestination.ID == 0 {
		return 0, fmt.Errorf("%w: notifs create_personal_destination: response has no id", ErrNotifsRetryable)
	}
	return out.PersonalDestination.ID, nil
}

// DeletePersonalDestination removes one (`DELETE .../personal-destinations/{id}`). The person goes in the JSON body:
// an empty DELETE body is a 400 `invalid JSON body`. A 404 arrives as *NotifsError (already gone).
func (c *NotifsClient) DeletePersonalDestination(ctx context.Context, email string, id int64) error {
	_, _, err := c.do(ctx, "delete_personal_destination", http.MethodDelete,
		c.appPath(fmt.Sprintf("/personal-destinations/%d", id)), personBody{Email: email})
	return err
}

type lookedUp struct {
	ID      int64 `json:"id"`
	Enabled bool  `json:"enabled"`
	OptedIn bool  `json:"opted_in"`
}

// deliverable reports, for each requested id, whether it appears in the lookup with enabled and opted_in both true.
// An id that is absent, disabled or not opted in is false; ids the caller did not ask about are ignored.
func deliverable(found []lookedUp, ids []int64) map[int64]bool {
	byID := make(map[int64]lookedUp, len(found))
	for _, f := range found {
		byID[f.ID] = f
	}
	out := make(map[int64]bool, len(ids))
	for _, id := range ids {
		f, ok := byID[id]
		out[id] = ok && f.Enabled && f.OptedIn
	}
	return out
}

// LookupPersonalDestinations asks delivery-api for all of the person's personal destinations
// (`POST .../personal-destinations/lookup`, which takes only the person) and reports, for each of ids, whether it is
// deliverable: present with enabled and opted_in both true. Other destinations in the answer are ignored. With no ids
// it returns an empty map without a request.
func (c *NotifsClient) LookupPersonalDestinations(ctx context.Context, email string, ids []int64) (map[int64]bool, error) {
	if len(ids) == 0 {
		return map[int64]bool{}, nil
	}
	data, _, err := c.do(ctx, "lookup_personal_destinations", http.MethodPost,
		c.appPath("/personal-destinations/lookup"), personBody{Email: email})
	if err != nil {
		return nil, err
	}
	var out struct {
		PersonalDestinations []lookedUp `json:"personal_destinations"`
	}
	if err := c.decode("lookup_personal_destinations", data, &out); err != nil {
		return nil, err
	}
	return deliverable(out.PersonalDestinations, ids), nil
}

// EnsurePublisher mints this app's ntfy publisher (`POST .../ntfy-publisher` with `{}`), which `to.recipient` sends
// need once. The token is never returned. A 404 `app has no approved binding`, 409 and 429 arrive as *NotifsError.
func (c *NotifsClient) EnsurePublisher(ctx context.Context) error {
	_, _, err := c.do(ctx, "ensure_publisher", http.MethodPost, c.appPath("/ntfy-publisher"), struct{}{})
	return err
}
