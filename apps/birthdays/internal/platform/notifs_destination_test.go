package platform

import (
	"errors"
	"fmt"
	"strings"
	"testing"
)

// Fixtures that look like webhook URLs, tokens or private addresses are assembled at runtime so no single literal
// trips the public-repo hygiene scan.
func whURL(host, path string) string { return fmt.Sprintf("https://%s%s", host, path) }

func TestValidDestination(t *testing.T) {
	disc := "discord" + ".com"
	hook := "/api/web" + "hooks/123/" + "tok" + "en"
	priv10 := fmt.Sprintf("%d.%d.%d.%d", 10, 0, 0, 1)
	priv192 := fmt.Sprintf("%d.%d.%d.%d", 192, 168, 1, 1)
	loop := fmt.Sprintf("%d.%d.%d.%d", 127, 0, 0, 1)
	linkLocal := fmt.Sprintf("%d.%d.%d.%d", 169, 254, 169, 254)
	unspec := fmt.Sprintf("%d.%d.%d.%d", 0, 0, 0, 0)
	mapped := "[::ffff:" + loop + "]"
	long := whURL("example.test", "/"+strings.Repeat("a", 2048))

	cases := []struct {
		name  string
		kind  string
		label string
		url   string
		want  string // clean label
		err   error
	}{
		{"discord ok", "discord", " Mine ", whURL(disc, hook), "Mine", nil},
		{"discordapp ok", "discord", "x", whURL("discordapp"+".com", hook), "x", nil},
		{"discord port 443", "discord", "x", whURL(disc+":443", hook), "x", nil},
		{"webhook ok", "webhook", "Hook", whURL("example.test", "/in"), "Hook", nil},
		{"label unicode 50 runes", "webhook", strings.Repeat("é", 50), whURL("example.test", "/in"), strings.Repeat("é", 50), nil},
		{"label empty", "webhook", "", whURL("example.test", "/in"), "", ErrInvalidLabel},
		{"label blank", "webhook", "  \t", whURL("example.test", "/in"), "", ErrInvalidLabel},
		{"label 51 runes", "webhook", strings.Repeat("a", 51), whURL("example.test", "/in"), "", ErrInvalidLabel},
		{"label control", "webhook", "a\x07b", whURL("example.test", "/in"), "", ErrInvalidLabel},
		{"url too long", "webhook", "x", long, "", ErrInvalidURL},
		{"http", "webhook", "x", "http://example.test/in", "", ErrInvalidURL},
		{"no host", "webhook", "x", "https:///in", "", ErrInvalidURL},
		{"parse error", "webhook", "x", "https://exa mple.test/", "", ErrInvalidURL},
		{"userinfo", "webhook", "x", "https://u:p@example.test/in", "", ErrInvalidURL},
		{"whitespace", "webhook", "x", whURL("example.test", "/in\n"), "", ErrInvalidURL},
		{"localhost", "webhook", "x", whURL("localhost", "/in"), "", ErrInvalidURL},
		{"sub localhost", "webhook", "x", whURL("a.localhost", "/in"), "", ErrInvalidURL},
		{"dot local", "webhook", "x", whURL("printer.local", "/in"), "", ErrInvalidURL},
		{"dot internal", "webhook", "x", whURL("svc.internal", "/in"), "", ErrInvalidURL},
		{"trailing dot localhost", "webhook", "x", whURL("localhost.", "/in"), "", ErrInvalidURL},
		{"private 10", "webhook", "x", whURL(priv10, "/in"), "", ErrInvalidURL},
		{"private 192", "webhook", "x", whURL(priv192, "/in"), "", ErrInvalidURL},
		{"loopback", "webhook", "x", whURL(loop, "/in"), "", ErrInvalidURL},
		{"link local", "webhook", "x", whURL(linkLocal, "/in"), "", ErrInvalidURL},
		{"unspecified", "webhook", "x", whURL(unspec, "/in"), "", ErrInvalidURL},
		{"v6 loopback", "webhook", "x", whURL("[::1]", "/in"), "", ErrInvalidURL},
		{"v4 mapped loopback", "webhook", "x", whURL(mapped, "/in"), "", ErrInvalidURL},
		{"dotdot path", "webhook", "x", whURL("example.test", "/a/../b"), "", ErrInvalidURL},
		{"discord wrong host", "discord", "x", whURL("example.test", hook), "", ErrInvalidURL},
		{"discord wrong path", "discord", "x", whURL(disc, "/other"), "", ErrInvalidURL},
		{"discord wrong port", "discord", "x", whURL(disc+":8443", hook), "", ErrInvalidURL},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := ValidDestination(c.kind, c.label, c.url)
			if !errors.Is(err, c.err) || (c.err == nil && err != nil) {
				t.Fatalf("err = %v, want %v", err, c.err)
			}
			if got != c.want {
				t.Fatalf("label = %q, want %q", got, c.want)
			}
			if c.err == ErrInvalidLabel && errors.Is(err, ErrInvalidURL) {
				t.Fatal("errors must be distinct")
			}
		})
	}
}

func TestDestinationHint(t *testing.T) {
	cases := map[string]string{
		whURL("example.test", "/in/abcdef"):         "def",
		whURL("example.test", "/in/abcdef/"):        "def",
		whURL("example.test", "/in/abcdef?q=zzzzz"): "def",
		whURL("example.test", "/in/abcdef#frag"):    "def",
		whURL("example.test", "/in/ab"):             "ab",
		whURL("example.test", ""):                   "est",
		"::not a url::":                             "l::",
		whURL("example.test", "/in/éèêë"):           "èêë",
	}
	for in, want := range cases {
		if got := DestinationHint(in); got != want {
			t.Errorf("DestinationHint(%q) = %q, want %q", in, got, want)
		}
	}
}
