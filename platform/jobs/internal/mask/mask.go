// Package mask turns arbitrary text (a response body, a transport error) into a short single-line string that is
// safe to log and to write into the run history: secrets and bearer tokens are replaced, control characters
// become spaces and the length is capped.
package mask

import (
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// MaxLen is the longest masked text, in characters.
const MaxLen = 300

var bearerRE = regexp.MustCompile(`(?i)bearer\s+[A-Za-z0-9._~+/=-]+`)

// Text masks s. Every occurrence of a non-empty secret is replaced by ***, any "Bearer <token>" is replaced by
// "Bearer ***", control characters (tabs and newlines included) become spaces, surrounding whitespace is
// trimmed and the result is cut to MaxLen characters. Masking happens before the cut, so a secret that
// straddles the cut point is already gone.
func Text(s string, secrets ...string) string { return TextN(MaxLen, s, secrets...) }

// TextN is Text with a caller-chosen length cap (the consumer's log lines keep up to 4096 characters of a raw item).
func TextN(max int, s string, secrets ...string) string {
	s = strings.ToValidUTF8(s, "?")
	for _, sec := range secrets {
		if sec != "" {
			s = strings.ReplaceAll(s, sec, "***")
		}
	}
	s = bearerRE.ReplaceAllString(s, "Bearer ***")
	s = strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return ' '
		}
		return r
	}, s)
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) > max {
		r := []rune(s)
		s = string(r[:max])
	}
	return s
}
