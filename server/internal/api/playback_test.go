package api

import (
	"testing"
	"time"

	"github.com/mdbraber/pocket-sessions-server/internal/pc"
	"github.com/mdbraber/pocket-sessions-server/internal/store"
)

// The echo guard is what keeps PC→hook→OwnTube→report from looping: anything
// not strictly ahead of the watcher baseline must be dropped.
func TestApplyPlayback(t *testing.T) {
	prev := store.EpisodeProgress{PlayedUpTo: 100, PlayingStatus: pc.StatusInProgress}

	cases := []struct {
		name   string
		prev   store.EpisodeProgress
		known  bool
		report playbackReport
		want   bool
		reason string
	}{
		{"ahead position applies", prev, true,
			playbackReport{PositionSeconds: 150}, true, ""},
		{"equal position is an echo", prev, true,
			playbackReport{PositionSeconds: 100}, false, "behind"},
		{"behind position is stale", prev, true,
			playbackReport{PositionSeconds: 50}, false, "behind"},
		{"completion applies even when behind", prev, true,
			playbackReport{PositionSeconds: 50, Completed: true}, true, ""},
		{"completion echo dropped",
			store.EpisodeProgress{PlayingStatus: pc.StatusCompleted}, true,
			playbackReport{PositionSeconds: 100, Completed: true}, false, "already-completed"},
		{"position never un-completes",
			store.EpisodeProgress{PlayedUpTo: 10, PlayingStatus: pc.StatusCompleted}, true,
			playbackReport{PositionSeconds: 500}, false, "pc-completed"},
		{"unknown episode applies", store.EpisodeProgress{}, false,
			playbackReport{PositionSeconds: 5}, true, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, reason := applyPlayback(tc.prev, tc.known, tc.report)
			if got != tc.want || reason != tc.reason {
				t.Errorf("applyPlayback = (%v, %q), want (%v, %q)", got, reason, tc.want, tc.reason)
			}
		})
	}
}

// A remembered miss must answer without a sweep; a rebuild clears it; the
// limiter allows one rebuild per cooldown.
func TestNegativeCacheAndRefreshLimiter(t *testing.T) {
	c := newNegativeCache(50 * time.Millisecond)
	if c.hit("vid1") {
		t.Error("fresh cache should miss")
	}
	c.add("vid1")
	if !c.hit("vid1") {
		t.Error("added fragment should hit")
	}
	c.clear()
	if c.hit("vid1") {
		t.Error("cleared cache should miss")
	}
	c.add("vid2")
	time.Sleep(60 * time.Millisecond)
	if c.hit("vid2") {
		t.Error("expired entry should miss")
	}

	l := newRefreshLimiter(time.Hour)
	if !l.allow(1) {
		t.Error("first rebuild should be allowed")
	}
	if l.allow(1) {
		t.Error("second rebuild within cooldown should be denied")
	}
	if !l.allow(2) {
		t.Error("another user's rebuild should be independent")
	}
}
