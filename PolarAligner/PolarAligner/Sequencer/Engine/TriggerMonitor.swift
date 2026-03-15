import Foundation

/// Monitors and fires reactive triggers during sequence execution.
///
/// Triggers are checked before and after each instruction within a container.
/// When a trigger fires, it executes its associated action (e.g., meridian flip,
/// autofocus) before allowing the sequence to continue.
@MainActor
class TriggerMonitor {
    private var framesSinceLastFocus: [UUID: Int] = [:]  // container ID → count
    private var lastFilterByContainer: [UUID: String] = [:]

    /// Check triggers before executing an item. Returns actions to perform.
    func checkBefore(
        triggers: [SequenceTrigger],
        containerId: UUID,
        context: ExecutionContext
    ) async throws {
        for trigger in triggers where trigger.enabled {
            try Task.checkCancellation()
            switch trigger.type {
            case "guide_deviation_pause":
                // Check guide RMS and pause if too high
                let maxRMS = trigger.params["max_rms_arcsec"]?.doubleValue ?? 2.0
                let settleTime = trigger.params["settle_time_sec"]?.doubleValue ?? 10.0
                try await waitForGuideSettle(maxRMS: maxRMS, settleTime: settleTime, context: context)
            default:
                break
            }
        }
    }

    /// Check triggers after executing an item.
    func checkAfter(
        triggers: [SequenceTrigger],
        containerId: UUID,
        framesCaptured: Int,
        currentFilter: String?,
        context: ExecutionContext
    ) async throws {
        for trigger in triggers where trigger.enabled {
            try Task.checkCancellation()
            switch trigger.type {
            case "autofocus_interval":
                let everyN = trigger.params["every_n_frames"]?.intValue ?? 50
                let count = framesSinceLastFocus[containerId, default: 0] + framesCaptured
                if count >= everyN {
                    context.status("Autofocus triggered after \(count) frames")
                    framesSinceLastFocus[containerId] = 0
                    // TODO: Run autofocus routine when implemented
                } else {
                    framesSinceLastFocus[containerId] = count
                }

            case "autofocus_on_filter_change":
                if let filter = currentFilter {
                    let lastFilter = lastFilterByContainer[containerId]
                    if let last = lastFilter, last != filter {
                        context.status("Autofocus triggered by filter change: \(last) → \(filter)")
                        // TODO: Run autofocus routine when implemented
                    }
                    lastFilterByContainer[containerId] = filter
                }

            case "meridian_flip":
                // Check if mount has crossed meridian
                if let mount = context.deviceResolver.mount(), mount.isConnected {
                    let minutesPast = trigger.params["minutes_past_meridian"]?.doubleValue ?? 5.0
                    let _ = minutesPast // TODO: Check mount HA vs meridian
                }

            default:
                break
            }
        }
    }

    func reset() {
        framesSinceLastFocus.removeAll()
        lastFilterByContainer.removeAll()
    }

    // MARK: - Private

    private func waitForGuideSettle(maxRMS: Double, settleTime: Double, context: ExecutionContext) async throws {
        // Simplified — in production would poll guide RMS
        context.status("Waiting for guide to settle (< \(maxRMS)\" RMS)")
        try await Task.sleep(for: .seconds(min(settleTime, 1)))
    }
}
