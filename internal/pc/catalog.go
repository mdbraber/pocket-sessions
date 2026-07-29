package pc

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// The sync endpoint /user/podcast/list returns only uuids + folder/sort state;
// names and episode lists live in PC's PUBLIC catalog (static CDN-cached JSON,
// no auth). One fetch serves both the title enrichment (cached in podcast_meta)
// and the new-episode watcher.
const catalogBase = "https://podcast-api.pocketcasts.com"

type CatalogEpisode struct {
	UUID      string
	Title     string
	Published time.Time
}

type CatalogPodcast struct {
	Title    string
	Author   string
	Episodes []CatalogEpisode
}

// FetchCatalog resolves a podcast's public catalog document.
func FetchCatalog(ctx context.Context, uuid string) (CatalogPodcast, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, catalogBase+"/podcast/full/"+uuid, nil)
	if err != nil {
		return CatalogPodcast{}, err
	}
	req.Header.Set("User-Agent", "Pocket Casts")

	client := &http.Client{Timeout: 20 * time.Second} // follows the redirect to the static JSON
	resp, err := client.Do(req)
	if err != nil {
		return CatalogPodcast{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return CatalogPodcast{}, fmt.Errorf("catalog %s: HTTP %d", uuid, resp.StatusCode)
	}
	var doc struct {
		Podcast struct {
			Title    string `json:"title"`
			Author   string `json:"author"`
			Episodes []struct {
				UUID      string `json:"uuid"`
				Title     string `json:"title"`
				Published string `json:"published"`
			} `json:"episodes"`
		} `json:"podcast"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&doc); err != nil {
		return CatalogPodcast{}, fmt.Errorf("catalog %s: %w", uuid, err)
	}
	out := CatalogPodcast{Title: doc.Podcast.Title, Author: doc.Podcast.Author}
	for _, ep := range doc.Podcast.Episodes {
		published, _ := time.Parse(time.RFC3339, ep.Published)
		out.Episodes = append(out.Episodes, CatalogEpisode{UUID: ep.UUID, Title: ep.Title, Published: published})
	}
	return out, nil
}
