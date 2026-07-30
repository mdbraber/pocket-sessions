package pc

import "testing"

// The push body must round-trip through the same parser the read path uses:
// SyncUpdateRequest{1:now, 2:cursor, 4:device, 5:Record{2:SyncUserEpisode}}
// with every mutable episode field paired to a modified stamp.
func TestBuildProgressPushWire(t *testing.T) {
	ep := EpisodeProgress{
		EpisodeUUID:   "ep-uuid",
		PodcastUUID:   "pod-uuid",
		PlayedUpTo:    123,
		PlayingStatus: StatusInProgress,
		Duration:      4567,
	}
	body := buildProgressPush("pcs-server", ep, 1_700_000_000_000, 42)

	top, err := parseAllFields(body)
	if err != nil {
		t.Fatal(err)
	}
	if got := top.varints[1]; got != 1_700_000_000_000 {
		t.Errorf("device time = %d", got)
	}
	if got := top.varints[2]; got != 42 {
		t.Errorf("cursor = %d", got)
	}
	if got := string(top.bytes[4]); got != "pcs-server" {
		t.Errorf("device id = %q", got)
	}

	record, err := parseAllFields(top.bytes[5])
	if err != nil {
		t.Fatal(err)
	}
	fields, err := parseAllFields(record.bytes[2])
	if err != nil {
		t.Fatal(err)
	}
	if got := string(fields.bytes[1]); got != "ep-uuid" {
		t.Errorf("episode uuid = %q", got)
	}
	if got := string(fields.bytes[2]); got != "pod-uuid" {
		t.Errorf("podcast uuid = %q", got)
	}
	if got := unwrapScalar(fields.bytes[5]); got != 4567 {
		t.Errorf("duration = %d", got)
	}
	if got := unwrapScalar(fields.bytes[7]); got != StatusInProgress {
		t.Errorf("status = %d", got)
	}
	if got := unwrapScalar(fields.bytes[9]); got != 123 {
		t.Errorf("playedUpTo = %d", got)
	}
	for _, stamp := range []int{6, 8, 10} {
		if got := unwrapScalar(fields.bytes[stamp]); got != 1_700_000_000_000 {
			t.Errorf("modified stamp %d = %d", stamp, got)
		}
	}
}

// Zero duration means "unknown" — the field (and its stamp) must be absent so
// PC keeps whatever it has, rather than learning a zero-length episode.
func TestBuildProgressPushOmitsUnknownDuration(t *testing.T) {
	ep := EpisodeProgress{EpisodeUUID: "e", PodcastUUID: "p", PlayedUpTo: 9, PlayingStatus: StatusCompleted}
	body := buildProgressPush("d", ep, 1, 0)
	top, _ := parseAllFields(body)
	record, _ := parseAllFields(top.bytes[5])
	fields, _ := parseAllFields(record.bytes[2])
	if _, present := fields.bytes[5]; present {
		t.Error("duration wrapper present for unknown duration")
	}
	if _, present := fields.bytes[6]; present {
		t.Error("duration modified stamp present for unknown duration")
	}
}
