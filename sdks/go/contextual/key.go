// Package contextual reads the contextual profiles the OCaml pipeline writes
// to Redis and checks curated deals against them (integration option A of
// study/matching.md §8: OCaml writes, Go reads).
//
// A request's page goes through three steps:
//   - [Key]: the Redis key, from the page URL normalised by DoubleVerify's
//     IQC rules 1-3 (src/lib/url_key.ml);
//   - [Reader.Lookup]: the profile, decoded into a reusable [Profile];
//   - [Rule.Check]: whether a deal's context holds, and why.
package contextual

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
)

// KeyPrefix namespaces profiles in Redis.
const KeyPrefix = "contextual:"

// Key is the Redis key of a page's profile: [KeyPrefix] and the hex SHA-256
// of the page URL normalised by DoubleVerify's IQC rules 1-3. It is the key
// the OCaml writer uses (src/lib/url_key.ml).
//
//	Key("example.com/page") ==
//		"contextual:d641f3ecfa3d1007cb7e145a76a12b4d969513a43ec173d57480df068534f9b8"
func Key(normalizedURL string) string {
	sum := sha256.Sum256([]byte(normalizedURL))
	var b [len(KeyPrefix) + 2*sha256.Size]byte
	copy(b[:], KeyPrefix)
	hex.Encode(b[len(KeyPrefix):], sum[:])

	return string(b[:])
}

// SectionKeyPrefix namespaces section and site profiles, apart from pages: a
// section's top page normalises to the same string as the section.
const SectionKeyPrefix = "contextual:section:"

// SectionKey is the Redis key of a section's or a site's profile, the mean
// of the pages crawled there, given a prefix from [Sections].
//
//	SectionKey("example.com") ==
//		"contextual:section:a379a6f6eeafb9a55e378c118034e2751e682fab9f2d30ab13d2125586ce1947"
func SectionKey(prefix string) string {
	sum := sha256.Sum256([]byte(prefix))
	var b [len(SectionKeyPrefix) + 2*sha256.Size]byte
	copy(b[:], SectionKeyPrefix)
	hex.Encode(b[len(SectionKeyPrefix):], sum[:])

	return string(b[:])
}

// Sections returns what a page inherits before it is crawled: its top
// section (host and first path segment, "" for a site's top page) and its
// site (the host), both prefixes of the normalised URL with the query left
// out, as the OCaml writer spells them (Store.sections). Both are "" when
// the URL has no host.
//
//	Sections("news.example/sport/derby?id=1")  // "news.example/sport", "news.example"
//	Sections("example.com/page?gclid=abc123")  // "example.com/page", "example.com"
//	Sections("news.example/?q=1")              // "", "news.example"
func Sections(normalizedURL string) (section, site string) {
	path, _, _ := strings.Cut(normalizedURL, "?")
	site, rest, hasPath := strings.Cut(path, "/")
	if site == "" {
		return "", ""
	}
	first, _, _ := strings.Cut(rest, "/")
	if !hasPath || first == "" {
		return "", site
	}

	return path[:len(site)+1+len(first)], site
}
