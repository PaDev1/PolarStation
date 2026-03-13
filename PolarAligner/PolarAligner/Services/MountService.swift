import Foundation
import PolarCore

/// Async wrapper around the Rust MountController.
///
/// Publishes mount state for SwiftUI views. All Rust calls dispatched
/// to a background queue to avoid blocking the main thread.
@MainActor
final class MountService: ObservableObject {
    @Published var isConnected = false
    @Published var backendName: String?
    @Published var status: MountStatus?
    @Published var error: String?

    private let controller = MountController()
    private let mountQueue = DispatchQueue(label: "com.polaraligner.mount", qos: .userInitiated)
    private var statusTimer: Timer?

    /// Connect to an ASCOM Alpaca mount over HTTP.
    func connectAlpaca(host: String, port: UInt32) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mountQueue.async { [controller] in
                do {
                    try controller.connectAlpaca(host: host, port: port)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        isConnected = controller.isConnected()
        backendName = controller.backendName()
        error = nil
        startStatusPolling()
    }

    /// Connect via LX200 serial protocol (AM5 USB, etc.).
    /// Automatically syncs mount clock and location from observer settings.
    func connectLx200(devicePath: String, baudRate: UInt32 = 9600) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mountQueue.async { [controller] in
                do {
                    try controller.connectLx200(devicePath: devicePath, baudRate: baudRate)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        isConnected = controller.isConnected()
        backendName = controller.backendName()
        error = nil
        startStatusPolling()
    }

    /// Connect via LX200 protocol over TCP/WiFi. AM5 default: 192.168.4.1:4030.
    func connectLx200Tcp(host: String, port: UInt32 = 4030) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mountQueue.async { [controller] in
                do {
                    try controller.connectLx200Tcp(host: host, port: port)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        isConnected = controller.isConnected()
        backendName = controller.backendName()
        error = nil
        startStatusPolling()
    }

    /// Sync mount's clock and location using stored observer settings.
    private func syncMountDatetime() async {
        let lat = UserDefaults.standard.double(forKey: "observerLat")
        let lon = UserDefaults.standard.double(forKey: "observerLon")
        let utcOffset = Double(TimeZone.current.secondsFromGMT()) / 3600.0
        do {
            try await syncDatetime(observerLat: lat, observerLon: lon, utcOffsetHours: utcOffset)
            print("[MountService] Synced mount time: lat=\(lat), lon=\(lon), utcOffset=\(utcOffset)h")
        } catch {
            print("[MountService] Time sync failed: \(error)")
        }
    }

    /// Establish alignment by syncing the mount's own reported RA/Dec.
    /// This tells the mount "you are where you think you are" via :CM#,
    /// which clears the "not aligned" state and allows GoTo to work.
    private func syncMountPosition() async {
        do {
            try await refreshStatus()
            if let s = status {
                try await syncPosition(raHours: s.raHours, decDeg: s.decDeg)
                print("[MountService] Synced mount position: RA=\(s.raHours)h Dec=\(s.decDeg)°")
            }
        } catch {
            print("[MountService] Position sync failed: \(error)")
        }
    }

    /// Disconnect from mount.
    func disconnect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mountQueue.async { [controller] in
                do {
                    try controller.disconnect()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        isConnected = false
        backendName = nil
        status = nil
        stopStatusPolling()
    }

    /// Refresh mount status (position, tracking, slewing).
    func refreshStatus() async throws {
        let newStatus: MountStatus = try await withCheckedThrowingContinuation { continuation in
            mountQueue.async { [controller] in
                do {
                    let s = try controller.getStatus()
                    continuation.resume(returning: s)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        status = newStatus
    }

    /// Slew RA axis by given degrees. Positive = east.
    func slewRA(degrees: Double) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mountQueue.async { [controller] in
                do {
                    try controller.slewRaDegrees(degrees: degrees)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try await refreshStatus()
    }

    /// Start or stop sidereal tracking.
    func setTracking(_ enabled: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mountQueue.async { [controller] in
                do {
                    try controller.setTracking(enabled: enabled)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Emergency stop all motion.
    func abort() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mountQueue.async { [controller] in
                do {
                    try controller.abort()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// GoTo a specific RA/Dec (J2000). Starts async slew.
    func gotoRADec(raHours: Double, decDeg: Double) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mountQueue.async { [controller] in
                do {
                    try controller.gotoRadec(raHours: raHours, decDeg: decDeg)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Set tracking rate (0=sidereal, 1=lunar, 2=solar, 3=king).
    func setTrackingRate(_ rate: UInt8) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mountQueue.async { [controller] in
                do {
                    try controller.setTrackingRate(rate: rate)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Move an axis at given rate (deg/sec). 0=stop. axis: 0=RA, 1=Dec.
    func moveAxis(_ axis: UInt8, rateDegPerSec: Double) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mountQueue.async { [controller] in
                do {
                    try controller.moveAxis(axis: axis, rateDegPerSec: rateDegPerSec)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Park the mount.
    func park() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mountQueue.async { [controller] in
                do {
                    try controller.park()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Sync mount position: tell the mount "you are pointing at (raHours, decDeg)".
    /// Establishes alignment so GoTo works. Call after plate solving, or on connect.
    func syncPosition(raHours: Double, decDeg: Double) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mountQueue.async { [controller] in
                do {
                    try controller.syncPosition(raHours: raHours, decDeg: decDeg)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Sync mount's internal clock and site location with computer.
    /// Call after connecting to LX200 mounts so their alt/az is correct.
    func syncDatetime(observerLat: Double, observerLon: Double, utcOffsetHours: Double) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mountQueue.async { [controller] in
                do {
                    try controller.syncDatetime(observerLatDeg: observerLat, observerLonDeg: observerLon, utcOffsetHours: utcOffsetHours)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Unpark the mount.
    func unpark() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mountQueue.async { [controller] in
                do {
                    try controller.unpark()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Slew to home position. Alpaca: native findhome. LX200: GoTo Polaris.
    func findHome() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            mountQueue.async { [controller] in
                do {
                    try controller.findHome()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Start auto-refreshing mount status every second.
    func startStatusPolling() {
        stopStatusPolling()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isConnected else { return }
                try? await self.refreshStatus()
            }
        }
    }

    /// Stop auto-refreshing mount status.
    func stopStatusPolling() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    /// Discover Alpaca devices on local network.
    func discoverAlpaca(timeoutMs: UInt32 = 3000) async -> [String] {
        await withCheckedContinuation { continuation in
            mountQueue.async {
                let results = PolarCore.discoverAlpaca(timeoutMs: timeoutMs)
                continuation.resume(returning: results)
            }
        }
    }

    /// List available serial ports.
    func serialPorts() -> [String] {
        PolarCore.listSerialPorts()
    }
}
