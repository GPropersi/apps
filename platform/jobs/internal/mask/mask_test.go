package mask

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestTextMasksSanitisesAndCaps(t *testing.T) {
	got := Text("a\tb\nc testsecretvalue Bearer xyz.123 d", "testsecretvalue")
	if got != "a b c *** Bearer *** d" {
		t.Fatalf("got %q", got)
	}
	long := Text(strings.Repeat("é", 400))
	if utf8.RuneCountInString(long) != MaxLen || !utf8.ValidString(long) {
		t.Fatalf("cap/UTF-8 broken: %d runes", utf8.RuneCountInString(long))
	}
	if Text("  \n ") != "" {
		t.Fatal("whitespace only must be empty")
	}
	if got := Text("bad \xff byte"); !utf8.ValidString(got) {
		t.Fatalf("invalid UTF-8 survived: %q", got)
	}
}

func TestSecretStraddlingTheCutIsMaskedFirst(t *testing.T) {
	secret := "testsecretvalue"
	// Eight of the secret's characters sit before character 300: cutting first would leave "testsecr" behind.
	in := strings.Repeat("x", MaxLen-8) + secret
	got := Text(in, secret)
	want := strings.Repeat("x", MaxLen-8) + "***"
	if strings.Contains(got, "testsec") || got != want {
		t.Fatalf("secret fragment leaked or text changed: ...%q", got[len(got)-20:])
	}
}
