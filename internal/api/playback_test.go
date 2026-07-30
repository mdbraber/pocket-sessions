package api

import (
	"testing"

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
