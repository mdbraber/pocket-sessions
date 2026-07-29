package pc

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// The sync endpoint /user/podcast/list returns only uuids + folder/sort state;
// names live in PC's PUBLIC catalog. One small JSON per podcast, no auth —
// the server caches results in podcast_meta so each uuid is fetched once.
const catalogBase = "https://podcast-api.pocketcasts.com"

// FetchPodcastMeta resolves a podcast's title/author from the public catalog.
func FetchPodcastMeta(ctx context.Context, uuid string) (title, author string, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, catalogBase+"/podcast/full/"+uuid, nil)
	if err != nil {
		return "", "", err
	}
	req.Header.Set("User-Agent", "Pocket Casts")

	client := &http.Client{Timeout: 15 * time.Second} // follows the redirect to the static JSON
	resp, err := client.Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("catalog %s: HTTP %d", uuid, resp.StatusCode)
	}
	var doc struct {
		Podcast struct {
			Title  string `json:"title"`
			Author string `json:"author"`
		} `json:"podcast"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return "", "", fmt.Errorf("catalog %s: %w", uuid, err)
	}
	return doc.Podcast.Title, doc.Podcast.Author, nil
}
