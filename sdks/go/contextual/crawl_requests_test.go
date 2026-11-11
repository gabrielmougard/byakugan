package contextual

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const (
	testTimeout = time.Second
	testTick    = time.Millisecond
)

type fakePublisher struct {
	gate chan struct{} // each Publish waits for one value
	fail bool

	mu   sync.Mutex
	sent []string
}

func (f *fakePublisher) Publish(_ context.Context, data []byte, _ map[string]string) (string, error) {
	<-f.gate
	if f.fail {
		return "", errors.New("unavailable")
	}
	f.mu.Lock()
	f.sent = append(f.sent, string(data))
	f.mu.Unlock()

	return "id", nil
}

func (f *fakePublisher) published() []string {
	f.mu.Lock()
	defer f.mu.Unlock()

	return append([]string(nil), f.sent...)
}

func TestCrawlRequestsPublishesEachPageOnce(t *testing.T) {
	pub := &fakePublisher{gate: make(chan struct{})}
	c := NewCrawlRequests(pub, 1, 4)

	assert.Equal(t, Queued, c.Request("example.com/a", "https://example.com/a?utm=1"))
	assert.Equal(t, AlreadyAsked, c.Request("example.com/a", "https://example.com/a"))
	close(pub.gate)

	assert.Eventually(t, func() bool { return len(pub.published()) == 1 }, testTimeout, testTick)
	require.NoError(t, c.Close())
	assert.Equal(t, []string{"https://example.com/a?utm=1"}, pub.published())
}

func TestCrawlRequestsDropsWhenTheQueueIsFull(t *testing.T) {
	pub := &fakePublisher{gate: make(chan struct{})}
	c := NewCrawlRequests(pub, 1, 1)

	assert.Equal(t, Queued, c.Request("a", "https://a"))
	assert.Eventually(t, func() bool { return len(c.jobs) == 0 }, testTimeout, testTick) // the worker holds "a"
	assert.Equal(t, Queued, c.Request("b", "https://b"))
	assert.Equal(t, Dropped, c.Request("c", "https://c"))
	assert.Equal(t, Dropped, c.Request("c", "https://c"), "a dropped page is not remembered as asked")
	close(pub.gate)
	require.NoError(t, c.Close())
}

func TestCrawlRequestsAsksAgainAfterAFailedPublish(t *testing.T) {
	pub := &fakePublisher{gate: make(chan struct{}), fail: true}
	close(pub.gate)
	c := NewCrawlRequests(pub, 1, 1)

	assert.Equal(t, Queued, c.Request("a", "https://a"))
	assert.Eventually(t, func() bool { return c.Failed() == 1 }, testTimeout, testTick)
	assert.Equal(t, Queued, c.Request("a", "https://a"))
	require.NoError(t, c.Close())
}

func TestCrawlRequestsDropsAfterClose(t *testing.T) {
	pub := &fakePublisher{gate: make(chan struct{})}
	close(pub.gate)
	c := NewCrawlRequests(pub, 2, 4)
	require.NoError(t, c.Close())

	assert.Equal(t, Dropped, c.Request("a", "https://a"))
	assert.Empty(t, pub.published())
}
