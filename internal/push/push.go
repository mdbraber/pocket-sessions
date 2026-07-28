// Package push abstracts the "tell other devices to sync" signal. M1 ships
// the log pusher — locally there is no APNs key, and sync still works via
// foreground fetches and nudges. The APNs implementation (sideshow/apns2,
// token-based .p8 auth, sandbox vs production per device) slots in behind the
// same interface at deploy time.
package push

import (
	"log/slog"
	"sync"
	"time"

	"github.com/mdbraber/pocket-casts-sessions-server/internal/store"
)

type Pusher interface {
	// NotifyChanged tells every device in the fan-out set that the user's data
	// moved past `cursor`. Implementations debounce internally.
	NotifyChanged(userID int64, cursor int64, devices []store.Device)
}

// LogPusher logs what an APNs pusher would send. It still debounces, so the
// log mirrors real push behavior (one line per burst, not per write).
type LogPusher struct {
	logger *slog.Logger

	mu      sync.Mutex
	pending map[int64]*pendingPush
}

type pendingPush struct {
	timer   *time.Timer
	cursor  int64
	devices []store.Device
}

const debounce = 2 * time.Second

func NewLogPusher(logger *slog.Logger) *LogPusher {
	return &LogPusher{logger: logger, pending: map[int64]*pendingPush{}}
}

func (p *LogPusher) NotifyChanged(userID int64, cursor int64, devices []store.Device) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if existing, ok := p.pending[userID]; ok {
		existing.cursor = cursor
		existing.devices = devices
		return // timer already running; latest cursor rides the same flush
	}
	pend := &pendingPush{cursor: cursor, devices: devices}
	pend.timer = time.AfterFunc(debounce, func() {
		p.mu.Lock()
		flush := p.pending[userID]
		delete(p.pending, userID)
		p.mu.Unlock()
		if flush == nil {
			return
		}
		p.logger.Info("push (log-only): would send content-available",
			"user", userID, "cursor", flush.cursor, "devices", len(flush.devices))
	})
	p.pending[userID] = pend
}
