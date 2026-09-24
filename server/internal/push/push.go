// Package push abstracts the "tell other devices to sync" signal. Locally the
// log pusher runs (no APNs key needed — sync still works via foreground fetches
// and nudges); deployment slots the APNs implementation (apns.go) behind the
// same interface once a .p8 key is configured.
package push

import (
	"log/slog"
	"sync"
	"time"

	"github.com/mdbraber/pocket-sessions-server/internal/store"
)

type Pusher interface {
	// NotifyChanged tells every device in the fan-out set that the user's data
	// moved past `cursor`. Implementations debounce internally.
	NotifyChanged(userID int64, cursor int64, devices []store.Device)
	// NotifyNewEpisodes shows visible "new episode" notifications on every
	// device — the fork's replacement for PC's own episode pushes (which can
	// never reach this bundle id). No debounce: the watcher's poll interval is
	// the cadence, and each alert is user-facing.
	NotifyNewEpisodes(userID int64, alerts []EpisodeAlert, devices []store.Device)
	// NotifyEpisodeRecovery sends a SILENT push naming the episodes just found,
	// so a backgrounded app can repair a delivery PC's refresh service will not
	// repeat. The visible alert above carries the same uuids but cannot run app
	// code: an alert push has no content-available, so iOS draws the banner and
	// the app only sees it if the user taps. A background push runs code but the
	// general NotifyChanged wake carries no uuids — hence this third signal,
	// which carries both. See NewEpisodePushRecovery in the app.
	//
	// Deliberately NOT gated on notification settings: recovery is about the
	// app's data being correct, which has nothing to do with whether the user
	// wanted to be told. No debounce, for the same reason as NotifyNewEpisodes.
	NotifyEpisodeRecovery(userID int64, episodes []EpisodeRef, devices []store.Device)
}

// EpisodeRef is the minimum an app needs to re-anchor one podcast's refresh:
// which podcast, and which episode it is missing.
type EpisodeRef struct {
	PodcastUUID string `json:"podcast_uuid"`
	EpisodeUUID string `json:"eu"`
}

// EpisodeAlert mimics PC's episode notification payload (category "ep",
// eu + podcast_uuid), so the app's existing notification actions — Download,
// Play Now, Play Next/Last, Archive — work unchanged.
type EpisodeAlert struct {
	PodcastUUID  string
	PodcastTitle string
	EpisodeUUID  string
	EpisodeTitle string
}

const debounce = 2 * time.Second

// debouncer coalesces bursts of NotifyChanged per user: one flush per burst,
// carrying the latest cursor and device set. Shared by the log and APNs pushers.
type debouncer struct {
	flush func(userID int64, cursor int64, devices []store.Device)

	mu      sync.Mutex
	pending map[int64]*pendingPush
}

type pendingPush struct {
	timer   *time.Timer
	cursor  int64
	devices []store.Device
}

func newDebouncer(flush func(int64, int64, []store.Device)) *debouncer {
	return &debouncer{flush: flush, pending: map[int64]*pendingPush{}}
}

func (d *debouncer) NotifyChanged(userID int64, cursor int64, devices []store.Device) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if existing, ok := d.pending[userID]; ok {
		existing.cursor = cursor
		existing.devices = devices
		return // timer already running; latest cursor rides the same flush
	}
	pend := &pendingPush{cursor: cursor, devices: devices}
	pend.timer = time.AfterFunc(debounce, func() {
		d.mu.Lock()
		flush := d.pending[userID]
		delete(d.pending, userID)
		d.mu.Unlock()
		if flush == nil {
			return
		}
		d.flush(userID, flush.cursor, flush.devices)
	})
	d.pending[userID] = pend
}

// LogPusher logs what an APNs pusher would send.
type LogPusher struct {
	*debouncer
	logger *slog.Logger
}

func NewLogPusher(logger *slog.Logger) *LogPusher {
	return &LogPusher{logger: logger, debouncer: newDebouncer(func(userID, cursor int64, devices []store.Device) {
		logger.Info("push (log-only): would send content-available",
			"user", userID, "cursor", cursor, "devices", len(devices))
	})}
}

func (p *LogPusher) NotifyNewEpisodes(userID int64, alerts []EpisodeAlert, devices []store.Device) {
	for _, alert := range alerts {
		p.logger.Info("push (log-only): would send episode alert",
			"user", userID, "podcast", alert.PodcastTitle, "episode", alert.EpisodeTitle, "devices", len(devices))
	}
}

func (p *LogPusher) NotifyEpisodeRecovery(userID int64, episodes []EpisodeRef, devices []store.Device) {
	p.logger.Info("push (log-only): would send episode recovery",
		"user", userID, "episodes", len(episodes), "devices", len(devices))
}
