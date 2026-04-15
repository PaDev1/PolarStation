import Foundation

/// Periodic EDSDK event pump. Canon EDSDK on macOS requires `EdsGetEvent()` to be
/// called regularly to deliver ObjectEvent / PropertyEvent / StateEvent callbacks.
///
/// A single pumper is shared while any Canon camera is connected.
final class CanonEventPump {
    static let shared = CanonEventPump()

    private var timer: Timer?
    private var refCount = 0
    private let lock = NSLock()

    private init() {}

    /// Register interest in event pumping. First call starts the pump.
    func retain() {
        lock.lock(); defer { lock.unlock() }
        refCount += 1
        if refCount == 1 {
            startPump()
        }
    }

    /// Release interest. Last release stops the pump.
    func release() {
        lock.lock(); defer { lock.unlock() }
        refCount = max(0, refCount - 1)
        if refCount == 0 {
            stopPump()
        }
    }

    private func startPump() {
        // Run on main run loop — EDSDK events must be pumped on the main thread on macOS
        let start: () -> Void = { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                CanonCameraBridge.pumpEvents()
            }
        }
        if Thread.isMainThread { start() }
        else { DispatchQueue.main.async(execute: start) }
    }

    private func stopPump() {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }
}
