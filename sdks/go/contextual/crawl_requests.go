package contextual

import (
	"context"
	"sync"
	"sync/atomic"
)

// Publisher is the one method of a Pub/Sub client that crawl requests need.
type Publisher interface {
	Publish(ctx context.Context, data []byte, attributes map[string]string) (string, error)
}

// RequestOutcome says what Request did with a page, for the caller's metrics.
type RequestOutcome int

const (
	Queued       RequestOutcome = iota // handed to the workers
	AlreadyAsked                       // asked before and not forgotten
	Dropped                            // queue full or closed; the next miss asks again
)

// maxAsked bounds the memory of pages already asked for. Past it the set
// starts over, so a page that is still missing is asked for again; the
// crawler drops URLs it has seen.
const maxAsked = 100_000

// CrawlRequests asks the crawler for the pages the bidder serves without a
// profile: one Pub/Sub message per page, its URL as the data. Publish waits
// for the server, so a fixed pool of workers sends them off the bid path.
//
//	Request (bid path, never blocks)          worker (one of n)
//
//	asked before? ── yes ─▶ AlreadyAsked
//	  │ no: mark it asked
//	  ▼
//	closed? ──────── yes ─▶ forget it, Dropped
//	  │ no
//	  ▼
//	jobs full? ───── yes ─▶ forget it, Dropped
//	  │ no
//	  ▼
//	jobs <- page ─▶ Queued    jobs ─────────▶ Publish(pageURL)
//	                                            │ error: forget it, Failed() + 1
//	                                            ▼
//	                                          next job, until Close
//
// A forgotten page is asked for again on its next miss.
type CrawlRequests struct {
	publisher Publisher

	jobs chan crawlRequest
	quit chan struct{}
	wg   sync.WaitGroup

	closeOnce sync.Once
	failed    atomic.Uint64

	mu    sync.Mutex
	asked map[string]struct{}
}

type crawlRequest struct {
	normalizedURL string
	pageURL       string
}

// NewCrawlRequests starts workers goroutines that publish through publisher
// from a queue of queueSize requests. Close stops them.
func NewCrawlRequests(publisher Publisher, workers, queueSize int) *CrawlRequests {
	c := &CrawlRequests{
		publisher: publisher,
		jobs:      make(chan crawlRequest, queueSize),
		quit:      make(chan struct{}),
		asked:     make(map[string]struct{}),
	}
	c.wg.Add(workers)
	for range workers {
		go c.work()
	}

	return c
}

// Request asks for a page that missed its profile. It never blocks: the page
// is queued, skipped as already asked, or dropped when the queue is full or
// closed. normalizedURL (as for [Key]) deduplicates; pageURL, the URL as the
// bid request gave it, is what the crawler fetches.
func (c *CrawlRequests) Request(normalizedURL, pageURL string) RequestOutcome {
	if !c.claim(normalizedURL) {
		return AlreadyAsked
	}
	select {
	case <-c.quit:
		c.release(normalizedURL)

		return Dropped
	default:
	}
	select {
	case c.jobs <- crawlRequest{normalizedURL: normalizedURL, pageURL: pageURL}:
		return Queued
	default:
		c.release(normalizedURL)

		return Dropped
	}
}

// Failed counts the requests Pub/Sub refused. Each one can be asked again.
func (c *CrawlRequests) Failed() uint64 {
	return c.failed.Load()
}

func (c *CrawlRequests) claim(normalizedURL string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, ok := c.asked[normalizedURL]; ok {
		return false
	}
	if len(c.asked) >= maxAsked {
		c.asked = make(map[string]struct{})
	}
	c.asked[normalizedURL] = struct{}{}

	return true
}

func (c *CrawlRequests) release(normalizedURL string) {
	c.mu.Lock()
	delete(c.asked, normalizedURL)
	c.mu.Unlock()
}

func (c *CrawlRequests) work() {
	defer c.wg.Done()
	for {
		// Quit first: with both cases ready, select would pick at random and
		// keep publishing after Close.
		select {
		case <-c.quit:
			return
		default:
		}
		select {
		case r := <-c.jobs:
			c.publish(r)
		case <-c.quit:
			return
		}
	}
}

func (c *CrawlRequests) publish(r crawlRequest) {
	if _, err := c.publisher.Publish(context.Background(), []byte(r.pageURL), nil); err != nil {
		c.failed.Add(1)
		c.release(r.normalizedURL)
	}
}

// Close stops the workers after the publishes in flight. Queued requests are
// abandoned: the next miss asks again.
func (c *CrawlRequests) Close() error {
	c.closeOnce.Do(func() { close(c.quit) })
	c.wg.Wait()

	return nil
}
