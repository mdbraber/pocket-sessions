package pc

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Playback-progress write-through: the write half of the same POST
// /user/sync/update the watcher reads from. A record is attached to the usual
// request; PC applies it and replies with changes since the cursor we sent —
// so, like the up-next write, one call both writes and reads back.
//
// SyncUserEpisode pairs every mutable field with a modified-timestamp field
// (duration 5/6, playing_status 7/8, played_up_to 9/10, unix ms in a scalar
// wrapper); PC merges per field by those stamps, so each value we set is
// stamped with now.

// buildProgressPush assembles the request body. Split out for the wire test.
func buildProgressPush(deviceID string, ep EpisodeProgress, nowMS, cursor uint64) []byte {
	wrap := func(v int64) []byte { return appendVarintField(nil, 1, uint64(v)) }

	episode := appendStringField(nil, 1, ep.EpisodeUUID)
	episode = appendStringField(episode, 2, ep.PodcastUUID)
	if ep.Duration > 0 {
		episode = appendBytesField(episode, 5, wrap(ep.Duration))
		episode = appendBytesField(episode, 6, wrap(int64(nowMS)))
	}
	episode = appendBytesField(episode, 7, wrap(ep.PlayingStatus))
	episode = appendBytesField(episode, 8, wrap(int64(nowMS)))
	episode = appendBytesField(episode, 9, wrap(ep.PlayedUpTo))
	episode = appendBytesField(episode, 10, wrap(int64(nowMS)))

	record := appendBytesField(nil, 2, episode)

	body := appendVarintField(nil, 1, nowMS)
	body = appendVarintField(body, 2, cursor)
	body = appendStringField(body, 4, deviceID)
	body = appendBytesField(body, 5, record)
	return body
}

// PushProgress writes one episode's playback state. The cursor should be the
// caller's current sync cursor: PC replies with changes since then (including
// this write), which the caller can use to keep its baseline coherent.
func PushProgress(ctx context.Context, accessToken, deviceID string, ep EpisodeProgress, cursor int64) (ProgressSync, error) {
	if ep.EpisodeUUID == "" {
		return ProgressSync{}, fmt.Errorf("push progress: empty episode uuid")
	}
	body := buildProgressPush(deviceID, ep, uint64(time.Now().UnixMilli()), uint64(cursor))

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
		return ProgressSync{}, fmt.Errorf("sync/update (write): HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	if err != nil {
		return ProgressSync{}, err
	}
	return parseProgressResponse(data)
}
