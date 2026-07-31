package pc

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Episode playback progress, read by acting as just another sync device.
//
// POST /user/sync/update with a lastModified cursor and NO records is the
// read-only shape: PC replies with everything that changed since, including
// episode records carrying playedUpTo / playingStatus / duration. Verified
// against a real account — a cursor of 0 returns the full account (thousands
// of records), so callers seed once and then poll with the returned cursor.
//
// Wire: SyncUpdateRequest{1:device_utc_time_ms, 2:last_modified, 4:device_id,
// 5:repeated Record}; SyncUpdateResponse{1:last_modified, 2:repeated Record};
// Record{2:SyncUserEpisode}; SyncUserEpisode{1:uuid, 2:podcast_uuid,
// 5:duration, 7:playing_status, 9:played_up_to} — each value wrapped in a
// protobuf scalar wrapper whose field 1 carries the number.

// PlayingStatus mirrors the app's enum.
const (
	StatusNotPlayed  = 1
	StatusInProgress = 2
	StatusCompleted  = 3
)

type EpisodeProgress struct {
	EpisodeUUID   string
	PodcastUUID   string
	PlayedUpTo    int64
	PlayingStatus int64
	Duration      int64
	// The app's "archived" flag (SyncUserEpisode.is_deleted, field 3).
	// -1 = the record didn't carry it (keep what we knew), 0/1 otherwise.
	Archived int64
	// Starred (field 11), same -1/0/1 presence convention.
	Starred int64
	// The SyncUserEpisode message exactly as PC sent it — the replica stores
	// this so nothing is lost to parsing gaps (unknown fields included).
	Raw []byte
}

// RawRecord is a non-episode sync record (Record oneof fields other than 2),
// kept raw for the replica. UUID is a best-effort read of the message's
// field 1 (uuid across all sync record types).
type RawRecord struct {
	Kind string // podcast | playlist | device | folder | bookmark
	UUID string
	Raw  []byte
}

type ProgressSync struct {
	LastModified int64
	Episodes     []EpisodeProgress
	Others       []RawRecord
}

// Record oneof field numbers (from the app's api.pb.swift Api_Record).
var recordKinds = map[int]string{
	1: "podcast",
	3: "playlist",
	4: "device",
	5: "folder",
	6: "bookmark",
}

// FetchProgress returns episode changes since `lastModified` (0 = everything).
func FetchProgress(ctx context.Context, accessToken, deviceID string, lastModified int64) (ProgressSync, error) {
	body := appendVarintField(nil, 1, uint64(time.Now().UnixMilli()))
	body = appendVarintField(body, 2, uint64(lastModified))
	body = appendStringField(body, 4, deviceID)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiBase+"/user/sync/update", bytesReader(body))
	if err != nil {
		return ProgressSync{}, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Accept", "application/octet-stream")
	req.Header.Set("User-Agent", "Pocket Casts")

	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return ProgressSync{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return ProgressSync{}, fmt.Errorf("sync/update: HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	if err != nil {
		return ProgressSync{}, err
	}
	return parseProgressResponse(data)
}

// parseProgressResponse decodes a SyncUpdateResponse — shared by the read
// (FetchProgress) and write (PushProgress) paths.
func parseProgressResponse(data []byte) (ProgressSync, error) {
	top, err := parseAllFields(data)
	if err != nil {
		return ProgressSync{}, err
	}
	out := ProgressSync{LastModified: int64(top.varints[1])}
	for _, raw := range top.repeated[2] {
		record, err := parseAllFields(raw)
		if err != nil {
			continue
		}
		episodeBytes, ok := record.bytes[2] // Record.episode
		if !ok {
			// A non-episode record — keep it raw for the replica.
			for field, kind := range recordKinds {
				if body, present := record.bytes[field]; present {
					uuid := ""
					if f, err := parseAllFields(body); err == nil {
						uuid = string(f.bytes[1])
					}
					out.Others = append(out.Others, RawRecord{Kind: kind, UUID: uuid, Raw: body})
					break
				}
			}
			continue
		}
		progress, err := ParseSyncEpisode(episodeBytes)
		if err != nil || progress.EpisodeUUID == "" {
			continue
		}
		out.Episodes = append(out.Episodes, progress)
	}
	return out, nil
}

// ParseSyncEpisode decodes one SyncUserEpisode message, keeping the raw bytes.
func ParseSyncEpisode(episodeBytes []byte) (EpisodeProgress, error) {
	fields, err := parseAllFields(episodeBytes)
	if err != nil {
		return EpisodeProgress{}, err
	}
	progress := EpisodeProgress{
		EpisodeUUID: string(fields.bytes[1]),
		PodcastUUID: string(fields.bytes[2]),
		Duration:    unwrapScalar(fields.bytes[5]),
		// A status of 0 means "PC didn't send one" — callers keep what they had.
		PlayingStatus: unwrapScalar(fields.bytes[7]),
		PlayedUpTo:    unwrapScalar(fields.bytes[9]),
		Archived:      -1,
		Starred:       -1,
		Raw:           episodeBytes,
	}
	// BoolValue false arrives as an empty wrapper, so absent-vs-false needs
	// a presence check rather than unwrapScalar's zero.
	if wrapper, ok := fields.bytes[3]; ok {
		progress.Archived = unwrapScalar(wrapper)
	}
	if wrapper, ok := fields.bytes[11]; ok {
		progress.Starred = unwrapScalar(wrapper)
	}
	return progress, nil
}

// unwrapScalar reads a protobuf scalar wrapper (Int32Value/Int64Value/…),
// whose payload is field 1. Absent or unparseable wrappers read as 0.
func unwrapScalar(wrapper []byte) int64 {
	if len(wrapper) == 0 {
		return 0
	}
	fields, err := parseAllFields(wrapper)
	if err != nil {
		return 0
	}
	return int64(fields.varints[1])
}
