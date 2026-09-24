package pc

import (
	"fmt"
	"time"
)

func timeNowMS() int64 { return time.Now().UnixMilli() }

// Exported parsers for the relay's observation path — the same decoders the
// fetch functions use, applied to copies of relayed traffic.

// ParseProgressResponseExported decodes a SyncUpdateResponse body.
func ParseProgressResponseExported(data []byte) (ProgressSync, error) {
	return parseProgressResponse(data)
}

// ParseSyncRequestRecords decodes the records a device ATTACHED to its
// SyncUpdateRequest (field 5) — the app's outgoing changes.
func ParseSyncRequestRecords(data []byte) (ProgressSync, error) {
	top, err := parseAllFields(data)
	if err != nil {
		return ProgressSync{}, err
	}
	out := ProgressSync{}
	for _, raw := range top.repeated[5] {
		record, err := parseAllFields(raw)
		if err != nil {
			continue
		}
		if episodeBytes, ok := record.bytes[2]; ok {
			if episode, err := ParseSyncEpisode(episodeBytes); err == nil && episode.EpisodeUUID != "" {
				out.Episodes = append(out.Episodes, episode)
			}
			continue
		}
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
	}
	return out, nil
}

// ParseHistoryResponse decodes a HistoryResponse body.
func ParseHistoryResponse(data []byte) (History, error) {
	return parseHistoryResponse(data)
}

// ParseUUIDRequest reads the uuid (field 3) out of a UuidRequest body.
func ParseUUIDRequest(data []byte) string {
	top, err := parseAllFields(data)
	if err != nil {
		return ""
	}
	return string(top.bytes[3])
}

// ParseSyncEpisodesResponse decodes a SyncEpisodesResponse: field 1 repeated
// EpisodeSyncResponse — a FLAT message, not the wrapper-heavy SyncUserEpisode:
// {1:uuid, 2:playing_status, 3:played_up_to, 4:is_deleted, 5:starred,
// 6:duration, 7:bookmarks, 8:deselected_chapters}, plain varints throughout
// (proto3: absent = zero). Raw stays empty on purpose — the replica's raw
// column holds SyncUserEpisode bytes and merging a different schema into it
// would corrupt re-parsing; the columns carry this state instead.
func ParseSyncEpisodesResponse(data []byte, podcastUUID string) ([]EpisodeProgress, error) {
	top, err := parseAllFields(data)
	if err != nil {
		return nil, err
	}
	var out []EpisodeProgress
	for _, raw := range top.repeated[1] {
		fields, err := parseAllFields(raw)
		if err != nil {
			continue
		}
		uuid := string(fields.bytes[1])
		if uuid == "" {
			continue
		}
		out = append(out, EpisodeProgress{
			EpisodeUUID:   uuid,
			PodcastUUID:   podcastUUID,
			PlayingStatus: int64(fields.varints[2]),
			PlayedUpTo:    int64(fields.varints[3]),
			// The flat response is a full snapshot: 0 really is 0.
			HasPlayedUpTo: true,
			Archived:      int64(fields.varints[4]),
			Starred:       int64(fields.varints[5]),
			Duration:      int64(fields.varints[6]),
		})
	}
	return out, nil
}

// BuildProgressPushForTest exposes the request builder to other packages'
// tests (the relay test uses it as a realistic SyncUpdateRequest body).
func BuildProgressPushForTest(deviceID string, ep EpisodeProgress, nowMS, cursor uint64) []byte {
	return buildProgressPush(deviceID, ep, nowMS, cursor)
}

// ParseUpdateEpisodeRequest decodes the single-episode position sync the app
// sends to /sync/update_episode: UpdateEpisodeRequest{1:uuid, 2:podcast,
// 3:position(Int32Value), 4:status, 5:duration} — position is wrapped, the
// rest are plain varints.
func ParseUpdateEpisodeRequest(data []byte) (EpisodeProgress, error) {
	fields, err := parseAllFields(data)
	if err != nil {
		return EpisodeProgress{}, err
	}
	_, hasPosition := fields.bytes[3]
	return EpisodeProgress{
		EpisodeUUID:   string(fields.bytes[1]),
		PodcastUUID:   string(fields.bytes[2]),
		PlayedUpTo:    unwrapScalar(fields.bytes[3]),
		HasPlayedUpTo: hasPosition,
		PlayingStatus: int64(fields.varints[4]),
		Duration:      int64(fields.varints[5]),
		Archived:      -1,
		Starred:       -1,
	}, nil
}

// BuildReadOnlySyncBody builds the record-free SyncUpdateRequest shape the
// watcher polls with (probe/testing helper).
func BuildReadOnlySyncBody(deviceID, cursorMS string) []byte {
	var cursor uint64
	fmt.Sscanf(cursorMS, "%d", &cursor)
	body := appendVarintField(nil, 1, uint64(timeNowMS()))
	body = appendVarintField(body, 2, cursor)
	return appendStringField(body, 4, deviceID)
}
