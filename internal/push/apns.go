package push

import (
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/token"

	"github.com/mdbraber/pocket-sessions-server/internal/store"
)

// APNSConfig comes from the environment (see config.FromEnv). The .p8 key is
// token-based auth: one key for the whole team, sandbox and production alike.
type APNSConfig struct {
	KeyPath string // PCS_APNS_KEY — path to AuthKey_<KEYID>.p8
	KeyID   string // PCS_APNS_KEY_ID — the 10-char id from the developer portal
	TeamID  string // PCS_APNS_TEAM_ID
	Topic   string // PCS_APNS_TOPIC — the app's bundle id
}

func (c APNSConfig) Configured() bool {
	return c.KeyPath != "" && c.KeyID != "" && c.TeamID != "" && c.Topic != ""
}

// APNSPusher sends silent pushes ({content-available:1, cursor}) so the user's
// other devices fetch /session/v1/changes, and visible episode alerts for the
// watcher. Dev-signed builds live in the APNs sandbox, TestFlight/App Store in
// production — each device registers which environment it wants (apns_env),
// and the pusher picks the matching client.
type APNSPusher struct {
	*debouncer
	logger     *slog.Logger
	topic      string
	sandbox    *apns2.Client
	production *apns2.Client
}

func NewAPNSPusher(cfg APNSConfig, logger *slog.Logger) (*APNSPusher, error) {
	authKey, err := token.AuthKeyFromFile(cfg.KeyPath)
	if err != nil {
		return nil, fmt.Errorf("apns key %s: %w", cfg.KeyPath, err)
	}
	tok := &token.Token{AuthKey: authKey, KeyID: cfg.KeyID, TeamID: cfg.TeamID}
	p := &APNSPusher{
		logger:     logger,
		topic:      cfg.Topic,
		sandbox:    apns2.NewTokenClient(tok).Development(),
		production: apns2.NewTokenClient(tok).Production(),
	}

	p.debouncer = newDebouncer(func(userID, cursor int64, devices []store.Device) {
		sent := 0
		for _, device := range devices {
			payload := []byte(fmt.Sprintf(`{"aps":{"content-available":1},"pcsCursor":%d}`, cursor))
			if p.send(device, apns2.PushTypeBackground, apns2.PriorityLow, payload) {
				sent++
			}
		}
		logger.Info("push sent", "user", userID, "cursor", cursor, "devices", sent)
	})
	return p, nil
}

// send delivers one notification; false means skipped or rejected (logged).
func (p *APNSPusher) send(device store.Device, pushType apns2.EPushType, priority int, payload []byte) bool {
	if device.APNSToken == "" {
		return false
	}
	client := p.production
	if device.APNSEnv == "sandbox" {
		client = p.sandbox
	}
	resp, err := client.Push(&apns2.Notification{
		DeviceToken: device.APNSToken,
		Topic:       p.topic,
		PushType:    pushType,
		Priority:    priority,
		Payload:     payload,
	})
	if err != nil {
		p.logger.Warn("apns push", "device", device.DeviceID, "err", err)
		return false
	}
	if !resp.Sent() {
		// 410/Unregistered etc. — log only; the device re-registers its token
		// on every launch, so stale entries heal themselves.
		p.logger.Warn("apns rejected", "device", device.DeviceID, "status", resp.StatusCode, "reason", resp.Reason)
		return false
	}
	return true
}

// NotifyNewEpisodes sends visible alerts shaped like PC's own episode pushes
// (category "ep", eu, podcast_uuid) so the app's notification actions work.
func (p *APNSPusher) NotifyNewEpisodes(userID int64, alerts []EpisodeAlert, devices []store.Device) {
	for _, alert := range alerts {
		payload, err := json.Marshal(map[string]any{
			"aps": map[string]any{
				"alert":    map[string]string{"title": alert.PodcastTitle, "body": alert.EpisodeTitle},
				"sound":    "default",
				"category": "ep",
			},
			"eu":           alert.EpisodeUUID,
			"podcast_uuid": alert.PodcastUUID,
		})
		if err != nil {
			continue
		}
		sent := 0
		for _, device := range devices {
			if p.send(device, apns2.PushTypeAlert, apns2.PriorityHigh, payload) {
				sent++
			}
		}
		p.logger.Info("episode alert sent", "user", userID, "podcast", alert.PodcastTitle, "episode", alert.EpisodeTitle, "devices", sent)
	}
}
