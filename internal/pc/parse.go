package pc

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

// ParseSyncEpisodesResponse decodes a SyncEpisodesResponse (field 1 repeated
// SyncUserEpisode), filling the podcast uuid the records omit.
func ParseSyncEpisodesResponse(data []byte, podcastUUID string) ([]EpisodeProgress, error) {
	top, err := parseAllFields(data)
	if err != nil {
		return nil, err
	}
	var out []EpisodeProgress
	for _, raw := range top.repeated[1] {
		episode, err := ParseSyncEpisode(raw)
		if err != nil || episode.EpisodeUUID == "" {
			continue
		}
		if episode.PodcastUUID == "" {
			episode.PodcastUUID = podcastUUID
		}
		out = append(out, episode)
	}
	return out, nil
}

// BuildProgressPushForTest exposes the request builder to other packages'
// tests (the relay test uses it as a realistic SyncUpdateRequest body).
func BuildProgressPushForTest(deviceID string, ep EpisodeProgress, nowMS, cursor uint64) []byte {
	return buildProgressPush(deviceID, ep, nowMS, cursor)
}
