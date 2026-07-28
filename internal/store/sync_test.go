package store

import (
	"encoding/json"
	"path/filepath"
	"testing"
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
