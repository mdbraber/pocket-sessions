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
	reopened := store.EpisodeProgress{PlayedUpTo: 120, PlayingStatus: pc.StatusInProgress, Duration: 1000, Reopened: 1}

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
		// Reopened in PC: OwnTube's sticky "watched" flag echoes back as
		// completed at the position PC just sent — that must not re-complete.
		{"sticky completion after a reopen is an echo", reopened, true,
			playbackReport{PositionSeconds: 120, DurationSeconds: 1000, Completed: true}, false, "behind"},
		{"watching further after a reopen moves the position", reopened, true,
			playbackReport{PositionSeconds: 400, DurationSeconds: 1000, Completed: true}, true, ""},
		{"finishing after a reopen completes", reopened, true,
			playbackReport{PositionSeconds: 990, DurationSeconds: 1000, Completed: true}, true, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, reason, _ := applyPlayback(tc.prev, tc.known, tc.report)
			if got != tc.want || reason != tc.reason {
				t.Errorf("applyPlayback = (%v, %q), want (%v, %q)", got, reason, tc.want, tc.reason)
			}
		})
	}
}

// After a reopen only a report at the end may complete; the rest apply as
// positions.
func TestApplyPlaybackReopenedCompletion(t *testing.T) {
	prev := store.EpisodeProgress{PlayedUpTo: 120, PlayingStatus: pc.StatusInProgress, Duration: 1000, Reopened: 1}
	if _, _, completed := applyPlayback(prev, true, playbackReport{PositionSeconds: 400, Completed: true}); completed {
		t.Error("mid-episode report after a reopen must not complete")
	}
	if _, _, completed := applyPlayback(prev, true, playbackReport{PositionSeconds: 990, Completed: true}); !completed {
		t.Error("report at the end after a reopen should complete")
	}
	prev.Reopened = 0
	if _, _, completed := applyPlayback(prev, true, playbackReport{PositionSeconds: 400, Completed: true}); !completed {
		t.Error("without a reopen, completion applies as reported")
	}
}

// A remembered miss must answer without a sweep; a rebuild clears it; the
// limiter allows one rebuild per cooldown.
func TestNegativeCacheAndRefreshLimiter(t *testing.T) {
	c := newNegativeCache(50 * time.Millisecond)
	if c.hit(1, "vid1") {
		t.Error("fresh cache should miss")
	}
	c.add(1, "vid1")
	if !c.hit(1, "vid1") {
		t.Error("added fragment should hit")
	}
	if c.hit(2, "vid1") {
		t.Error("one user's miss must not hide the video from another")
	}
	c.add(2, "vid1")
	c.clear(1)
	if c.hit(1, "vid1") {
		t.Error("cleared cache should miss")
	}
	if !c.hit(2, "vid1") {
		t.Error("clearing one user must keep another's entries")
	}
	c.add(1, "vid2")
	time.Sleep(60 * time.Millisecond)
	if c.hit(1, "vid2") {
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
