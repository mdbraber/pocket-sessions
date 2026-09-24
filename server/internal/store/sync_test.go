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

func TestFindEpisodeByEnclosure(t *testing.T) {
	s := testStore(t)
	err := s.SaveEpisodeEnclosures(1, []EpisodeEnclosure{
		{EpisodeUUID: "e1", PodcastUUID: "p1", URL: "https://media.example/enclosure/qyPCVqFUyDo.m4a"},
		{EpisodeUUID: "e2", PodcastUUID: "p1", URL: "https://media.example/enclosure/Tn4iP3H3TXI.mp4"},
	})
	if err != nil {
		t.Fatal(err)
	}
	hit, found, err := s.FindEpisodeByEnclosure(1, "Tn4iP3H3TXI")
	if err != nil || !found || hit.EpisodeUUID != "e2" {
		t.Fatalf("find = %+v found=%v err=%v", hit, found, err)
	}
	_, found, err = s.FindEpisodeByEnclosure(1, "nosuchvideo")
	if err != nil || found {
		t.Fatalf("miss should be (false, nil), got found=%v err=%v", found, err)
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
