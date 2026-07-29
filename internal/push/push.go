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
}

func NewLogPusher(logger *slog.Logger) *LogPusher {
	return &LogPusher{debouncer: newDebouncer(func(userID, cursor int64, devices []store.Device) {
		logger.Info("push (log-only): would send content-available",
			"user", userID, "cursor", cursor, "devices", len(devices))
	})}
}
