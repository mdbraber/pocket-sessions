package store

import (
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/mdbraber/pocket-sessions-server/internal/pc"
)

func testStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	if err := s.EnsureBootstrapUser(""); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestSessionLastWriterWins(t *testing.T) {
	s := testStore(t)

	_, _, err := s.ApplyChanges(1, Changes{Sessions: []Record{{UUID: "a", UpdatedAt: 200, Payload: json.RawMessage(`{"v":"new"}`)}}})
	if err != nil {
		t.Fatal(err)
	}
	// A stale write (older updatedAt) must not clobber.
	cursor, changed, err := s.ApplyChanges(1, Changes{Sessions: []Record{{UUID: "a", UpdatedAt: 100, Payload: json.RawMessage(`{"v":"old"}`)}}})
	if err != nil {
		t.Fatal(err)
	}
	if changed {
		t.Fatal("stale write reported as change")
	}
	out, err := s.ChangesSince(1, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(out.Sessions) != 1 || string(out.Sessions[0].Payload) != `{"v":"new"}` {
		t.Fatalf("stale write clobbered: %+v", out.Sessions)
	}
	if out.Cursor != cursor {
		t.Fatalf("cursor mismatch: %d vs %d", out.Cursor, cursor)
	}
}

func TestOfferedNeverRegresses(t *testing.T) {
	s := testStore(t)
	if _, _, err := s.ApplyChanges(1, Changes{Offered: map[string]int64{"pod": 500}}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.ApplyChanges(1, Changes{Offered: map[string]int64{"pod": 300}}); err != nil {
		t.Fatal(err)
	}
	out, err := s.ChangesSince(1, 0)
	if err != nil {
		t.Fatal(err)
	}
	if out.Offered["pod"] != 500 {
		t.Fatalf("watermark regressed: %v", out.Offered)
	}
}

func TestLedgerUnionNewest(t *testing.T) {
	s := testStore(t)
	if _, _, err := s.ApplyChanges(1, Changes{Ledger: &SeenLedger{SeenAt: map[string]int64{"e1": 100, "e2": 100}, UnseenAt: map[string]int64{}}}); err != nil {
		t.Fatal(err)
	}
	// Second device: newer seen for e2, its own e3, no e1 — e1 must survive.
	if _, _, err := s.ApplyChanges(1, Changes{Ledger: &SeenLedger{SeenAt: map[string]int64{"e2": 200, "e3": 150}, UnseenAt: map[string]int64{}}}); err != nil {
		t.Fatal(err)
	}
	out, err := s.ChangesSince(1, 0)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]int64{"e1": 100, "e2": 200, "e3": 150}
	if out.Ledger == nil || !equalMaps(out.Ledger.SeenAt, want) {
		t.Fatalf("bad union: %+v", out.Ledger)
	}
}

func TestDeltaCursor(t *testing.T) {
	s := testStore(t)
	c1, _, err := s.ApplyChanges(1, Changes{Sessions: []Record{{UUID: "a", UpdatedAt: 1, Payload: json.RawMessage(`{}`)}}})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.ApplyChanges(1, Changes{Sessions: []Record{{UUID: "b", UpdatedAt: 2, Payload: json.RawMessage(`{}`)}}}); err != nil {
		t.Fatal(err)
	}
	out, err := s.ChangesSince(1, c1)
	if err != nil {
		t.Fatal(err)
	}
	if len(out.Sessions) != 1 || out.Sessions[0].UUID != "b" {
		t.Fatalf("delta wrong: %+v", out.Sessions)
	}
}

func TestFindEpisodesByEnclosure(t *testing.T) {
	s := testStore(t)
	// One video published as an audio and a video episode in different feeds.
	err := s.SaveEpisodeEnclosures(1, map[string][]EpisodeEnclosure{
		"p1": {
			{EpisodeUUID: "e1", URL: "https://media.example/enclosure/qyPCVqFUyDo.m4a"},
			{EpisodeUUID: "e2", URL: "https://media.example/enclosure/Tn4iP3H3TXI.m4a"},
		},
		"p2": {
			{EpisodeUUID: "e3", URL: "https://media.example/enclosure/Tn4iP3H3TXI.mp4"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	hits, err := s.FindEpisodesByEnclosure(1, "Tn4iP3H3TXI")
	if err != nil || len(hits) != 2 || hits[0].EpisodeUUID != "e2" || hits[1].EpisodeUUID != "e3" {
		t.Fatalf("find = %+v err=%v, want e2 and e3", hits, err)
	}
	if hits[1].PodcastUUID != "p2" {
		t.Errorf("podcast = %q, want p2", hits[1].PodcastUUID)
	}
	hits, err = s.FindEpisodesByEnclosure(1, "nosuchvideo")
	if err != nil || len(hits) != 0 {
		t.Fatalf("miss should be empty, got %+v err=%v", hits, err)
	}

	// Refreshing p1 replaces its rows: an episode the feed dropped stops
	// resolving, while p2 (not refreshed this round) keeps its rows.
	if err := s.SaveEpisodeEnclosures(1, map[string][]EpisodeEnclosure{
		"p1": {{EpisodeUUID: "e1", URL: "https://media.example/enclosure/qyPCVqFUyDo.m4a"}},
	}); err != nil {
		t.Fatal(err)
	}
	hits, _ = s.FindEpisodesByEnclosure(1, "Tn4iP3H3TXI")
	if len(hits) != 1 || hits[0].EpisodeUUID != "e3" {
		t.Fatalf("after refresh = %+v, want only e3", hits)
	}
}

// A poll commits baseline, queued events and cursor together, and the cursor
// never moves backwards (a slower overlapping writer can't rewind it).
func TestCommitProgressPollAndOutbox(t *testing.T) {
	s := testStore(t)
	events := []OutboxEvent{{EpisodeUUID: "e1", Payload: []byte(`{"event":"completed"}`)}}
	if err := s.CommitProgressPoll(1, []EpisodeProgress{{EpisodeUUID: "e1", PlayingStatus: 3, Reopened: 0}}, events, 500); err != nil {
		t.Fatal(err)
	}
	if err := s.SetProgressCursor(1, 400); err != nil {
		t.Fatal(err)
	}
	if cursor, _ := s.ProgressCursor(1); cursor != 500 {
		t.Errorf("cursor = %d, want 500 (never backwards)", cursor)
	}
	pending, err := s.PendingHookEvents(10)
	if err != nil || len(pending) != 1 || pending[0].EpisodeUUID != "e1" || pending[0].UserID != 1 {
		t.Fatalf("pending = %+v err=%v", pending, err)
	}
	if err := s.DeleteHookEvent(pending[0].ID); err != nil {
		t.Fatal(err)
	}
	if pending, _ = s.PendingHookEvents(10); len(pending) != 0 {
		t.Fatalf("delivered event still queued: %+v", pending)
	}
	// A user without a meta row still gets a cursor.
	if err := s.SetProgressCursor(2, 42); err != nil {
		t.Fatal(err)
	}
	if cursor, err := s.ProgressCursor(2); err != nil || cursor != 42 {
		t.Errorf("user 2 cursor = %d err=%v, want 42", cursor, err)
	}
}

func TestReplicaMergeAndLedger(t *testing.T) {
	s := testStore(t)

	// Full record first, then a sparse update — merged columns, concatenated raw.
	full := pc.EpisodeProgress{
		EpisodeUUID: "e1", PodcastUUID: "p1",
		PlayedUpTo: 100, PlayingStatus: 2, Duration: 900,
		Archived: 0, Starred: -1, Raw: []byte{0x01, 0x02},
	}
	if err := s.UpsertReplicaEpisodes(1, "seed-sync", []pc.EpisodeProgress{full}); err != nil {
		t.Fatal(err)
	}
	sparse := pc.EpisodeProgress{
		EpisodeUUID: "e1", PlayingStatus: 3,
		Archived: 1, Starred: -1, Raw: []byte{0x03},
	}
	if err := s.UpsertReplicaEpisodes(1, "relay-req", []pc.EpisodeProgress{sparse}); err != nil {
		t.Fatal(err)
	}
	var podcast string
	var played, status, archived int64
	var raw []byte
	err := s.db.QueryRow(`SELECT podcast_uuid, played_up_to, playing_status, archived, raw
FROM pc_replica WHERE user_id=1 AND kind='episode' AND uuid='e1'`).
		Scan(&podcast, &played, &status, &archived, &raw)
	if err != nil {
		t.Fatal(err)
	}
	if podcast != "p1" || played != 100 || status != 3 || archived != 1 {
		t.Errorf("merged = %s/%d/%d/%d", podcast, played, status, archived)
	}
	if string(raw) != "\x01\x02\x03" {
		t.Errorf("raw not concatenated: %v", raw)
	}

	// The ledger accumulates and never regresses modified_at.
	entries := []pc.HistoryEntry{{EpisodeUUID: "e1", PodcastUUID: "p1", Title: "T", ModifiedAt: 200}}
	if err := s.UpsertHistoryLedger(1, entries); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertHistoryLedger(1, []pc.HistoryEntry{{EpisodeUUID: "e1", ModifiedAt: 50}}); err != nil {
		t.Fatal(err)
	}
	ledger, err := s.HistoryLedger(1, 10)
	if err != nil || len(ledger) != 1 {
		t.Fatalf("ledger = %v err=%v", ledger, err)
	}
	if ledger[0].ModifiedAt != 200 || ledger[0].Title != "T" {
		t.Errorf("ledger entry regressed: %+v", ledger[0])
	}

	status2, err := s.ReplicaStatus(1)
	if err != nil || status2.Episodes != 1 || status2.Played != 1 || status2.Archived != 1 || status2.LedgerEntries != 1 {
		t.Errorf("status = %+v err=%v", status2, err)
	}
}

// Removing one entry in the app removes it from the ledger; "clear all" does
// not wipe the ledger (outliving PC's window is its purpose).
func TestHistoryLedgerRemovals(t *testing.T) {
	s := testStore(t)
	if err := s.UpsertHistoryLedger(1, []pc.HistoryEntry{
		{EpisodeUUID: "e1", ModifiedAt: 1}, {EpisodeUUID: "e2", ModifiedAt: 2},
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.UpsertHistoryLedger(1, []pc.HistoryEntry{
		{EpisodeUUID: "e1", Action: pc.HistoryActionDelete},
		{EpisodeUUID: "e2", Action: pc.HistoryActionClearAll},
	}); err != nil {
		t.Fatal(err)
	}
	ledger, err := s.HistoryLedger(1, 10)
	if err != nil || len(ledger) != 1 || ledger[0].EpisodeUUID != "e2" {
		t.Fatalf("ledger = %+v err=%v, want only e2", ledger, err)
	}
}
