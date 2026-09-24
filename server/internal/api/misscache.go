package api

import (
	"sync"
	"time"
)

// negativeCache remembers enclosure fragments that resolved to nothing, so a
// non-feed video being re-reported every push cycle doesn't trigger a full
// catalog sweep each time (§3 of SYNC-ARCHITECTURE.md). Entries are per user,
// expire after a TTL, and a user's entries clear whenever their index is
// rebuilt — a new feed episode may make yesterday's miss a hit.
type negativeCache struct {
	mu  sync.Mutex
	ttl time.Duration
	m   map[missKey]time.Time // → expiry
}

type missKey struct {
	userID   int64
	fragment string
}

func newNegativeCache(ttl time.Duration) *negativeCache {
	return &negativeCache{ttl: ttl, m: map[missKey]time.Time{}}
}

func (c *negativeCache) hit(userID int64, fragment string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	key := missKey{userID, fragment}
	expiry, ok := c.m[key]
	if !ok {
		return false
	}
	if time.Now().After(expiry) {
		delete(c.m, key)
		return false
	}
	return true
}

func (c *negativeCache) add(userID int64, fragment string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.m[missKey{userID, fragment}] = time.Now().Add(c.ttl)
}

func (c *negativeCache) clear(userID int64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for key := range c.m {
		if key.userID == userID {
			delete(c.m, key)
		}
	}
}

// refreshLimiter allows at most one enclosure-index rebuild per user per
// cooldown — a burst of unknown videos costs one sweep, not one each.
type refreshLimiter struct {
	mu       sync.Mutex
	cooldown time.Duration
	last     map[int64]time.Time
}

func newRefreshLimiter(cooldown time.Duration) *refreshLimiter {
	return &refreshLimiter{cooldown: cooldown, last: map[int64]time.Time{}}
}

// allow reports whether a rebuild may run now, and if so claims the slot.
func (l *refreshLimiter) allow(userID int64) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if time.Since(l.last[userID]) < l.cooldown {
		return false
	}
	l.last[userID] = time.Now()
	return true
}
