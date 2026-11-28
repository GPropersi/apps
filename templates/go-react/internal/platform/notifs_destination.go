package platform

import (
	"errors"
	"net/netip"
	"net/url"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	maxLabelRunes = 50
	maxURLLen     = 2048
	hintLen       = 3
)

var (
	// ErrInvalidLabel: the label is empty, too long or has a control character.
	ErrInvalidLabel = errors.New("platform: invalid destination label")
	// ErrInvalidURL: every other destination rule (kind, scheme, host, path, length).
	ErrInvalidURL = errors.New("platform: invalid destination url")
)

// ValidDestination checks the label and URL of a personal destination and returns the trimmed label. The discord kind
// accepts only Discord's own webhook host and path; every kind needs https. delivery-api's public-address check is the
// real SSRF control, the host rules here only refuse the obvious.
func ValidDestination(kind, label, rawURL string) (cleanLabel string, err error) {
	label = strings.TrimSpace(label)
	if n := utf8.RuneCountInString(label); n < 1 || n > maxLabelRunes || strings.IndexFunc(label, unicode.IsControl) >= 0 {
		return "", ErrInvalidLabel
	}
	if len(rawURL) > maxURLLen {
		return "", ErrInvalidURL
	}
	u, perr := url.Parse(rawURL)
	if perr != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || strings.ContainsAny(rawURL, " \t\r\n\x00") {
		return "", ErrInvalidURL
	}
	host := strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") || strings.HasSuffix(host, ".internal") {
		return "", ErrInvalidURL
	}
	if ip, aerr := netip.ParseAddr(host); aerr == nil {
		ip = ip.Unmap()
		if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsMulticast() || ip.IsUnspecified() {
			return "", ErrInvalidURL
		}
	}
	if slices.Contains(strings.Split(u.Path, "/"), "..") {
		return "", ErrInvalidURL
	}
	if kind == "discord" {
		if (host != "discord.com" && host != "discordapp.com") || !strings.HasPrefix(u.Path, "/api/webhooks/") ||
			(u.Port() != "" && u.Port() != "443") {
			return "", ErrInvalidURL
		}
	}
	return label, nil
}

// DestinationHint is the 3-char display hint: the end of the URL path's last segment (query and fragment never
// count), or of the whole URL when the path has no segment.
func DestinationHint(rawURL string) string {
	if u, err := url.Parse(rawURL); err == nil {
		seg := strings.TrimRight(u.Path, "/")
		if i := strings.LastIndex(seg, "/"); i >= 0 {
			seg = seg[i+1:]
		}
		if seg != "" {
			return lastN(seg, hintLen)
		}
	}
	return lastN(rawURL, hintLen)
}

func lastN(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		r = r[len(r)-n:]
	}
	return string(r)
}
