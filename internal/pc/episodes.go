package pc

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Per-podcast episode state: POST /user/podcast/episodes returns the user's
// SyncUserEpisode for EVERY episode of one podcast — including archived ones,
// which full syncs exclude. This is the deep-history workhorse for the
// replica seed (the app uses it to show played state on years-old episodes).
//
// Wire (api.pb.swift): UuidRequest{1:v, 2:m, 3:uuid, 4:include_bookmarks};
// SyncEpisodesResponse{1:repeated SyncUserEpisode}.
func FetchPodcastEpisodes(ctx context.Context, accessToken, podcastUUID string) ([]EpisodeProgress, error) {
	body := appendStringField(nil, 2, "mobile")
	body = appendStringField(body, 3, podcastUUID)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiBase+"/user/podcast/episodes", bytesReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Accept", "application/octet-stream")
	req.Header.Set("User-Agent", "Pocket Casts")

	client := &http.Client{Timeout: 45 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("user/podcast/episodes: HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return nil, err
	}

	return ParseSyncEpisodesResponse(data, podcastUUID)
}
