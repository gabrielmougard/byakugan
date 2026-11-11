package contextual

import (
	"context"
	"fmt"
)

// Cache is what the SDK needs from Redis: wrap your Redis client in it. Get
// reports a missing key as found == false with a nil error.
type Cache interface {
	Get(ctx context.Context, key string) ([]byte, bool, error)
}

// Reader looks profiles up in the Redis the OCaml pipeline writes to.
type Reader struct {
	cache Cache
}

func NewReader(cache Cache) Reader {
	return Reader{cache: cache}
}

// Lookup reads the profile of a page, given its URL normalised as for [Key],
// into p. found is false when the page has no profile yet (not crawled, or
// expired after 30 days).
func (r Reader) Lookup(ctx context.Context, normalizedURL string, p *Profile) (found bool, err error) {
	return r.get(ctx, Key(normalizedURL), p)
}

// Level says which profile a lookup found.
type Level int8

const (
	NotFound Level = iota // no profile: not even the site has one
	Page                  // the page's own
	Section               // its top section's: the mean of the pages crawled there
	Site                  // its site's: the mean of the pages crawled there
)

// LookupWithBackoff is [Reader.Lookup], then, for a page not crawled yet,
// its top section's profile, then its site's ([Sections]). Section and site
// profiles exist from 5 crawled pages on. A miss costs one GET per level.
//
//	"news.example/sport/derby?id=1"
//	  │
//	  ├─ GET contextual:<sha256 of the whole URL>              hit ─▶ Page
//	  ├─ GET contextual:section:<sha256 "news.example/sport">  hit ─▶ Section
//	  ├─ GET contextual:section:<sha256 "news.example">        hit ─▶ Site
//	  └─ NotFound
//
// The section step is skipped when the URL has no first path segment. An
// error ends the walk: NotFound and the error.
func (r Reader) LookupWithBackoff(ctx context.Context, normalizedURL string, p *Profile) (Level, error) {
	if found, err := r.Lookup(ctx, normalizedURL, p); found || err != nil {
		return levelIf(found, Page), err
	}
	section, site := Sections(normalizedURL)
	if section != "" {
		if found, err := r.get(ctx, SectionKey(section), p); found || err != nil {
			return levelIf(found, Section), err
		}
	}
	if site == "" {
		return NotFound, nil
	}
	found, err := r.get(ctx, SectionKey(site), p)

	return levelIf(found, Site), err
}

func levelIf(found bool, l Level) Level {
	if found {
		return l
	}

	return NotFound
}

func (r Reader) get(ctx context.Context, key string, p *Profile) (bool, error) {
	value, found, err := r.cache.Get(ctx, key)
	if err != nil {
		return false, fmt.Errorf("contextual: reading the profile: %w", err)
	}
	if !found {
		return false, nil
	}
	if err := p.Decode(value); err != nil {
		return false, err
	}

	return true, nil
}
