import Foundation

/// A reactive trigger on a container.
///
/// Triggers are checked before/after each instruction within a container.
/// When a trigger fires, it executes its associated action (e.g., meridian flip,
/// autofocus) before the next instruction proceeds.
struct SequenceTrigger: Codable, Identifiable, Hashable {
    let id: UUID
    var type: String
    var enabled: Bool
    var params: [String: AnyCodableValue]

    init(type: String, params: [String: AnyCodableValue] = [:]) {
        self.id = UUID()
        self.type = type
        self.enabled = true
        self.params = params
    }
}

extension SequenceTrigger {
    static let typeMeridianFlip = "meridian_flip"
    static let typeAutofocusInterval = "autofocus_interval"
    static let typeAutofocusOnFilterChange = "autofocus_on_filter_change"
    static let typeGuideDeviationPause = "guide_deviation_pause"
    static let typeHfrRefocus = "hfr_refocus"
    static let typeErrorRecovery = "error_recovery"
}
