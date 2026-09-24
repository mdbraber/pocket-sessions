package pc

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"time"
)

// HistoryEntry is one listened episode as Pocket Casts reports it.
type HistoryEntry struct {
	EpisodeUUID string `json:"episodeUuid"`
	PodcastUUID string `json:"podcastUuid"`
	Title       string `json:"title"`
	URL         string `json:"url,omitempty"`
	ModifiedAt  int64  `json:"modifiedAt"`
	// HistoryChange.action: 1 add, 2 delete, 3 clear all (the app's
	// HistoryAction); 0 when absent.
	Action int64 `json:"action,omitempty"`
}

const (
	HistoryActionDelete   = 2
	HistoryActionClearAll = 3
)

type History struct {
	ServerModified int64          `json:"serverModified"`
	Entries        []HistoryEntry `json:"entries"`
}

// FetchHistory reads listening history via POST /history/sync with no changes
// attached — the same read-only shape the queue mirror uses.
//
// Wire: HistorySyncRequest{1:deviceTime, 2:serverModified, 3:repeated change,
// 4:version}; HistoryResponse{1:serverModified, 2:lastCleared,
// 3:repeated HistoryChange{1:action, 2:podcast, 3:episode, 4:modifiedAt,
// 5:title, 6:url}}.
func FetchHistory(ctx context.Context, accessToken string) (History, error) {
	body := appendVarintField(nil, 1, uint64(time.Now().UnixMilli()))
	body = appendStringField(body, 4, "2")

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiBase+"/history/sync", bytesReader(body))
	if err != nil {
		return History{}, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Accept", "application/octet-stream")
	req.Header.Set("User-Agent", "Pocket Casts")

	client := &http.Client{Timeout: 45 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return History{}, err
	}
	defer resp.Body.Close()
	// 304 means "nothing since serverModified" — an empty history, not an error.
	if resp.StatusCode == http.StatusNotModified {
		return History{}, nil
	}
	if resp.StatusCode != http.StatusOK {
		return History{}, fmt.Errorf("history/sync: HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return History{}, err
	}

	return parseHistoryResponse(data)
}

func parseHistoryResponse(data []byte) (History, error) {
	out := History{}
	top, err := parseAllFields(data)
	if err != nil {
		return History{}, err
	}
	if v, ok := top.varints[1]; ok {
		out.ServerModified = int64(v)
	}
	for _, raw := range top.repeated[3] {
		f, err := parseAllFields(raw)
		if err != nil {
			continue
		}
		out.Entries = append(out.Entries, HistoryEntry{
			PodcastUUID: string(f.bytes[2]),
			EpisodeUUID: string(f.bytes[3]),
			ModifiedAt:  int64(f.varints[4]),
			Title:       string(f.bytes[5]),
			URL:         string(f.bytes[6]),
			Action:      int64(f.varints[1]),
		})
	}
	return out, nil
}
