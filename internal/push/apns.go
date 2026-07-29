package push

import (
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
// other devices fetch /session/v1/changes. Dev-signed builds live in the APNs
// sandbox, TestFlight/App Store in production — each device registers which
// environment it wants (apns_env), and the pusher picks the matching client.
type APNSPusher struct {
	*debouncer
}

func NewAPNSPusher(cfg APNSConfig, logger *slog.Logger) (*APNSPusher, error) {
	authKey, err := token.AuthKeyFromFile(cfg.KeyPath)
	if err != nil {
		return nil, fmt.Errorf("apns key %s: %w", cfg.KeyPath, err)
	}
	tok := &token.Token{AuthKey: authKey, KeyID: cfg.KeyID, TeamID: cfg.TeamID}
	sandbox := apns2.NewTokenClient(tok).Development()
	production := apns2.NewTokenClient(tok).Production()

	flush := func(userID, cursor int64, devices []store.Device) {
		sent := 0
		for _, device := range devices {
			if device.APNSToken == "" {
				continue
			}
			client := production
			if device.APNSEnv == "sandbox" {
				client = sandbox
			}
			notification := &apns2.Notification{
				DeviceToken: device.APNSToken,
				Topic:       cfg.Topic,
				PushType:    apns2.PushTypeBackground,
				Priority:    apns2.PriorityLow, // required for background pushes
				Payload:     []byte(fmt.Sprintf(`{"aps":{"content-available":1},"pcsCursor":%d}`, cursor)),
			}
			resp, err := client.Push(notification)
			if err != nil {
				logger.Warn("apns push", "device", device.DeviceID, "err", err)
				continue
			}
			if !resp.Sent() {
				// 410/Unregistered etc. — log only; the device re-registers its
				// token on every launch, so stale entries heal themselves.
				logger.Warn("apns rejected", "device", device.DeviceID, "status", resp.StatusCode, "reason", resp.Reason)
				continue
			}
			sent++
		}
		logger.Info("push sent", "user", userID, "cursor", cursor, "devices", sent)
	}

	return &APNSPusher{debouncer: newDebouncer(flush)}, nil
}
