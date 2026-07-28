package pc

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"time"
)

// UpNextEpisode is one queue entry as Pocket Casts reports it.
type UpNextEpisode struct {
	UUID        string `json:"uuid"`
	Title       string `json:"title"`
	PodcastUUID string `json:"podcastUuid"`
	URL         string `json:"url,omitempty"`
	Position    int    `json:"position"`
}

type UpNext struct {
	ServerModified int64           `json:"serverModified"`
	Episodes       []UpNextEpisode `json:"episodes"`
}

// FetchUpNext reads the account's queue via POST /up_next/sync. Sending only
// deviceTime + version (no changes) is the read-only shape: PC applies nothing
// and returns the current queue — exactly what a mirror wants.
//
// Wire (from the app's api.pb.swift): UpNextSyncRequest{1:deviceTime int64,
// 2:version string, 6:deviceId string}; UpNextResponse{1:serverModified int64,
// 4:repeated EpisodeResponse{1:title, 2:url, 3:podcast, 4:uuid}}.
func FetchUpNext(ctx context.Context, accessToken, deviceID string) (UpNext, error) {
	body := appendVarintField(nil, 1, uint64(time.Now().UnixMilli()))
	body = appendStringField(body, 2, "2")
	body = appendStringField(body, 6, deviceID)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiBase+"/up_next/sync", bytesReader(body))
	if err != nil {
		return UpNext{}, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Accept", "application/octet-stream")
	req.Header.Set("User-Agent", "Pocket Casts")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return UpNext{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return UpNext{}, fmt.Errorf("up_next/sync: HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return UpNext{}, err
	}

	out := UpNext{}
	top, err := parseAllFields(data)
	if err != nil {
		return UpNext{}, err
	}
	if v, ok := top.varints[1]; ok {
		out.ServerModified = int64(v)
	}
	for i, raw := range top.repeated[4] {
		fields, err := parseAllFields(raw)
		if err != nil {
			continue
		}
		out.Episodes = append(out.Episodes, UpNextEpisode{
			Title:       string(fields.bytes[1]),
			URL:         string(fields.bytes[2]),
			PodcastUUID: string(fields.bytes[3]),
			UUID:        string(fields.bytes[4]),
			Position:    i,
		})
	}
	return out, nil
}
