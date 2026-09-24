package pc

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Up Next write-through. Same POST /up_next/sync endpoint as the read, but with
// a change attached: PC applies it to the stored queue and returns the resulting
// queue, so one call both writes and refreshes the mirror.
//
// VERIFIED against a real account: play_last adds an episode (pass title +
// podcastUuid so PC can resolve a new one) and remove takes it out again. The
// single-episode actions are MEMBERSHIP changes — play_next on an episode
// already queued is a no-op, not a move. Reordering is a separate job: the
// replace action (5) carrying the full ordered uuid list in UpNextChanges{3:order}.
//
// Action codes (app's UpNextChanges.Actions): 1=playNow, 2=playNext, 3=playLast,
// 4=remove, 5=replace. Wire: UpNextSyncRequest{1:deviceTime, 2:version,
// 4:UpNextChanges{2:repeated Change}, 6:deviceId};
// Change{1:uuid, 2:action, 3:modified, 4:title, 5:url, 6:podcast}.
type QueueAction int32

const (
	ActionPlayNow  QueueAction = 1
	ActionPlayNext QueueAction = 2
	ActionPlayLast QueueAction = 3
	ActionRemove   QueueAction = 4
)

func ParseQueueAction(s string) (QueueAction, error) {
	switch s {
	case "play_now":
		return ActionPlayNow, nil
	case "play_next":
		return ActionPlayNext, nil
	case "play_last":
		return ActionPlayLast, nil
	case "remove":
		return ActionRemove, nil
	}
	return 0, fmt.Errorf("unknown action %q (want play_now, play_next, play_last, remove)", s)
}

// ReplaceUpNext sets the ENTIRE queue to the given ordered episode list — PC's
// replace action (5), the only way to reorder (single-episode actions are
// membership changes). The app sends the full episode list inside the change
// (Change{2:action=5, 3:modified, 7:repeated UpNextEpisodeRequest{1:uuid,
// 4:title, 5:url, 6:podcast}}), so entries PC can't resolve still resolve;
// anything not in the list is REMOVED from the queue.
func ReplaceUpNext(ctx context.Context, accessToken, deviceID string, episodes []UpNextEpisode, serverModified int64) (UpNext, error) {
	now := time.Now().UnixMilli()

	change := appendVarintField(nil, 2, 5) // action: replace
	change = appendVarintField(change, 3, uint64(now))
	for _, ep := range episodes {
		entry := appendStringField(nil, 1, ep.UUID)
		entry = appendStringField(entry, 4, ep.Title)
		entry = appendStringField(entry, 5, ep.URL)
		entry = appendStringField(entry, 6, ep.PodcastUUID)
		change = appendBytesField(change, 7, entry)
	}

	changes := appendVarintField(nil, 1, uint64(serverModified))
	changes = appendBytesField(changes, 2, change)

	body := appendVarintField(nil, 1, uint64(now))
	body = appendStringField(body, 2, "2")
	body = appendBytesField(body, 4, changes)
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
		return UpNext{}, fmt.Errorf("up_next/sync (replace): HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return UpNext{}, err
	}
	return parseUpNextResponse(data)
}

// ChangeUpNext applies one queue change and returns the queue PC reports back.
// Title/podcast are optional: PC needs them when ADDING an episode it can't
// resolve, and ignores them otherwise. serverModified is the value from the last
// read — PC uses it to order changes and silently ignores stale ones.
func ChangeUpNext(ctx context.Context, accessToken, deviceID string, action QueueAction, episodeUUID, title, podcastUUID string, serverModified int64) (UpNext, error) {
	now := time.Now().UnixMilli()

	change := appendStringField(nil, 1, episodeUUID)
	change = appendVarintField(change, 2, uint64(action))
	change = appendVarintField(change, 3, uint64(now))
	change = appendStringField(change, 4, title)
	change = appendStringField(change, 6, podcastUUID)

	// PC needs the last-known serverModified to accept the change; without it the
	// request looks stale and the queue comes back untouched (200, no-op).
	changes := appendVarintField(nil, 1, uint64(serverModified))
	changes = appendBytesField(changes, 2, change)

	body := appendVarintField(nil, 1, uint64(now))
	body = appendStringField(body, 2, "2")
	body = appendBytesField(body, 4, changes)
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
		return UpNext{}, fmt.Errorf("up_next/sync (write): HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return UpNext{}, err
	}
	return parseUpNextResponse(data)
}
