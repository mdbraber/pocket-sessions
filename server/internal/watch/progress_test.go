package watch

import (
	"testing"

	"github.com/mdbraber/pocket-sessions-server/internal/hooks"
	"github.com/mdbraber/pocket-sessions-server/internal/pc"
	"github.com/mdbraber/pocket-sessions-server/internal/store"
)

func TestClassify(t *testing.T) {
	const minDelta = 30
	progress := func(playedUpTo, status int64) store.EpisodeProgress {
		return store.EpisodeProgress{PlayedUpTo: playedUpTo, PlayingStatus: status}
	}

	cases := []struct {
		name     string
		known    bool
		previous store.EpisodeProgress
		current  store.EpisodeProgress
		want     string
	}{
		// A poll that re-reports the same state must stay silent, or every sync
		// would replay a hook.
		{"unchanged", true, progress(400, pc.StatusInProgress), progress(400, pc.StatusInProgress), ""},
		{"tiny move below threshold", true, progress(400, pc.StatusInProgress), progress(415, pc.StatusInProgress), ""},
		{"listened on", true, progress(400, pc.StatusInProgress), progress(600, pc.StatusInProgress), hooks.EventProgress},
		{"scrubbed backwards", true, progress(600, pc.StatusInProgress), progress(120, pc.StatusInProgress), hooks.EventProgress},
		{"finished", true, progress(1800, pc.StatusInProgress), progress(1900, pc.StatusCompleted), hooks.EventCompleted},
		// Completion wins over the progress delta in the same update.
		{"finished from far behind", true, progress(10, pc.StatusInProgress), progress(1900, pc.StatusCompleted), hooks.EventCompleted},
		{"still finished", true, progress(1900, pc.StatusCompleted), progress(1900, pc.StatusCompleted), ""},
		{"marked unplayed again", true, progress(1900, pc.StatusCompleted), progress(0, pc.StatusNotPlayed), hooks.EventReopened},

		// First sighting: PC only sends an episode when something about it
		// changed, so an unseen episode arriving finished or well-played is a
		// real event — but an untouched one is not.
		{"new and untouched", false, store.EpisodeProgress{}, progress(0, pc.StatusNotPlayed), ""},
		{"new but barely started", false, store.EpisodeProgress{}, progress(5, pc.StatusInProgress), ""},
		{"new and part-played", false, store.EpisodeProgress{}, progress(300, pc.StatusInProgress), hooks.EventProgress},
		{"new and already finished", false, store.EpisodeProgress{}, progress(1900, pc.StatusCompleted), hooks.EventCompleted},

		// Archiving is deliberate cleanup and outranks whatever else the same
		// sync carried; un-archiving and archived first sights are not events.
		{"archived", true, progress(400, pc.StatusInProgress),
			store.EpisodeProgress{PlayedUpTo: 400, PlayingStatus: pc.StatusInProgress, Archived: 1}, hooks.EventArchived},
		{"archived while finishing", true, progress(400, pc.StatusInProgress),
			store.EpisodeProgress{PlayedUpTo: 1900, PlayingStatus: pc.StatusCompleted, Archived: 1}, hooks.EventArchived},
		{"still archived", true,
			store.EpisodeProgress{PlayedUpTo: 400, PlayingStatus: pc.StatusInProgress, Archived: 1},
			store.EpisodeProgress{PlayedUpTo: 400, PlayingStatus: pc.StatusInProgress, Archived: 1}, ""},
		{"unarchived", true,
			store.EpisodeProgress{PlayedUpTo: 400, PlayingStatus: pc.StatusInProgress, Archived: 1},
			store.EpisodeProgress{PlayedUpTo: 400, PlayingStatus: pc.StatusInProgress, Archived: 0}, ""},
		{"new and already archived", false, store.EpisodeProgress{},
			store.EpisodeProgress{PlayedUpTo: 1900, PlayingStatus: pc.StatusCompleted, Archived: 1}, hooks.EventArchived},
		{"new, unplayed, archived", false, store.EpisodeProgress{},
			store.EpisodeProgress{Archived: 1}, hooks.EventArchived},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := classify(tc.known, tc.previous, tc.current, minDelta); got != tc.want {
				t.Errorf("classify() = %q, want %q", got, tc.want)
			}
		})
	}
}

// PC omits fields it has nothing new to say about; a partial update must not
// erase what we already knew (a status-only change keeping its position).
func TestOrPrevious(t *testing.T) {
	if got := orPrevious(0, 450); got != 450 {
		t.Errorf("orPrevious(0, 450) = %d, want 450 (absent value keeps the old one)", got)
	}
	if got := orPrevious(500, 450); got != 500 {
		t.Errorf("orPrevious(500, 450) = %d, want 500", got)
	}
}
