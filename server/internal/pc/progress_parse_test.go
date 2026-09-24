package pc

import "testing"

// "Mark unplayed" sends played_up_to as an empty Int32Value wrapper — a real
// 0, which must be told apart from a record that carries no position at all.
func TestParseSyncEpisodeZeroPosition(t *testing.T) {
	withZero := appendStringField(nil, 1, "e1")
	withZero = append(withZero, 9<<3|2, 0) // field 9, length 0
	got, err := ParseSyncEpisode(withZero)
	if err != nil {
		t.Fatal(err)
	}
	if !got.HasPlayedUpTo || got.PlayedUpTo != 0 {
		t.Errorf("explicit 0: HasPlayedUpTo=%v PlayedUpTo=%d, want true/0", got.HasPlayedUpTo, got.PlayedUpTo)
	}

	without := appendStringField(nil, 1, "e1")
	got, err = ParseSyncEpisode(without)
	if err != nil {
		t.Fatal(err)
	}
	if got.HasPlayedUpTo {
		t.Error("absent position must not read as an explicit 0")
	}
}
