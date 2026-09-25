import Foundation

public class Debounce {
    private let delay: Double
    private weak var timer: Timer?

    public init(delay: TimeInterval) {
        self.delay = delay
    }

    /// Always schedules on the main run loop. `Timer.scheduledTimer` attaches to the CURRENT
    /// thread's run loop, and GCD worker threads never run theirs — so a call from a background
    /// thread (a notification posted by a sync operation, say) scheduled a timer that silently
    /// never fired. The callback therefore runs on the main thread.
    public func call(_ callback: @escaping (() -> Void)) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.call(callback) }
            return
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            callback()
        }
    }

    public func cancel() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.cancel() }
            return
        }
        timer?.invalidate()
    }
}
