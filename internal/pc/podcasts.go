package pc

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Podcast is one subscription as Pocket Casts reports it.
type Podcast struct {
	UUID         string `json:"uuid"`
	Title        string `json:"title"`
	Author       string `json:"author,omitempty"`
	FolderUUID   string `json:"folderUuid,omitempty"`
	SortPosition int    `json:"sortPosition,omitempty"`
}

type PodcastFolder struct {
	UUID         string `json:"uuid"`
	Name         string `json:"name"`
	Color        int    `json:"color,omitempty"`
	SortPosition int    `json:"sortPosition,omitempty"`
}

type PodcastList struct {
	Podcasts []Podcast       `json:"podcasts"`
	Folders  []PodcastFolder `json:"folders,omitempty"`
}

// FetchPodcasts reads the subscription list via POST /user/podcast/list — the
// same call the app's RetrievePodcastsTask makes (it sends only m="mobile").
//
// Wire (from the app's api.pb.swift): UserPodcastListRequest{1:v, 2:m};
// UserPodcastListResponse{1:repeated UserPodcastResponse, 2:repeated PodcastFolder}.
// UserPodcastResponse{1:uuid, 4:title, 5:author, 14:folder_uuid(StringValue),
// 15:sort_position(Int32Value)}; PodcastFolder{1:folder_uuid, 2:name, 3:color,
// 4:sort_position}.
func FetchPodcasts(ctx context.Context, accessToken string) (PodcastList, error) {
	body := appendStringField(nil, 2, "mobile")

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiBase+"/user/podcast/list", bytesReader(body))
	if err != nil {
		return PodcastList{}, err
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Accept", "application/octet-stream")
	req.Header.Set("User-Agent", "Pocket Casts")

	client := &http.Client{Timeout: 45 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return PodcastList{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return PodcastList{}, fmt.Errorf("user/podcast/list: HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return PodcastList{}, err
	}
	return parsePodcastList(data)
}

func parsePodcastList(data []byte) (PodcastList, error) {
	top, err := parseAllFields(data)
	if err != nil {
		return PodcastList{}, err
	}
	out := PodcastList{}
	for _, raw := range top.repeated[1] {
		fields, err := parseAllFields(raw)
		if err != nil {
			continue
		}
		p := Podcast{
			UUID:   string(fields.bytes[1]),
			Title:  string(fields.bytes[4]),
			Author: string(fields.bytes[5]),
		}
		// folder_uuid and sort_position are protobuf wrapper messages (field 1
		// inside carries the value).
		if wrapped, err := parseAllFields(fields.bytes[14]); err == nil {
			p.FolderUUID = string(wrapped.bytes[1])
		}
		if wrapped, err := parseAllFields(fields.bytes[15]); err == nil {
			p.SortPosition = int(wrapped.varints[1])
		}
		out.Podcasts = append(out.Podcasts, p)
	}
	for _, raw := range top.repeated[2] {
		fields, err := parseAllFields(raw)
		if err != nil {
			continue
		}
		out.Folders = append(out.Folders, PodcastFolder{
			UUID:         string(fields.bytes[1]),
			Name:         string(fields.bytes[2]),
			Color:        int(fields.varints[3]),
			SortPosition: int(fields.varints[4]),
		})
	}
	return out, nil
}
