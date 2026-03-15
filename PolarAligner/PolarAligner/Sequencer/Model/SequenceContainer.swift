import Foundation

/// The type of a sequence container, determining how its children are executed.
enum ContainerType: String, Codable, Hashable {
    case sequential
    case parallel
    case deepSkyObject
}

/// Tracking rate for mount during target observation.
enum TrackingRate: Int, Codable, Hashable, CaseIterable {
    case sidereal = 0
    case lunar = 1
    case solar = 2
    case king = 3

    var label: String {
        switch self {
        case .sidereal: return "Sidereal"
        case .lunar: return "Lunar"
        case .solar: return "Solar"
        case .king: return "King"
        }
    }
}

/// Celestial target coordinates for a deep-sky-object container.
struct TargetInfo: Codable, Hashable {
    var name: String
    var ra: Double          // hours (0–24)
    var dec: Double         // degrees (−90–+90)
    var rotation: Double?   // degrees
    var minimumAltitude: Double?  // degrees
    var trackingRate: TrackingRate?  // nil = sidereal (default)

    var effectiveTrackingRate: TrackingRate {
        trackingRate ?? .sidereal
    }
}

/// A single item inside a container — either a nested container or an instruction.
enum SequenceItem: Codable, Identifiable, Hashable {
    case container(SequenceContainer)
    case instruction(SequenceInstruction)

    var id: UUID {
        switch self {
        case .container(let c): return c.id
        case .instruction(let i): return i.id
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case container
        case instruction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let c = try container.decodeIfPresent(SequenceContainer.self, forKey: .container) {
            self = .container(c)
        } else if let i = try container.decodeIfPresent(SequenceInstruction.self, forKey: .instruction) {
            self = .instruction(i)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "SequenceItem must contain either 'container' or 'instruction'")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .container(let c):
            try container.encode(c, forKey: .container)
        case .instruction(let i):
            try container.encode(i, forKey: .instruction)
        }
    }
}

/// A container node in the sequence tree.
///
/// Containers hold child items (instructions or nested containers),
/// loop conditions (ANY met → stop), and reactive triggers (checked
/// before/after each child item).
struct SequenceContainer: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var type: ContainerType
    var enabled: Bool
    var target: TargetInfo?
    var items: [SequenceItem]
    var conditions: [SequenceCondition]
    var triggers: [SequenceTrigger]

    init(
        name: String,
        type: ContainerType = .sequential,
        target: TargetInfo? = nil,
        items: [SequenceItem] = [],
        conditions: [SequenceCondition] = [],
        triggers: [SequenceTrigger] = []
    ) {
        self.id = UUID()
        self.name = name
        self.type = type
        self.enabled = true
        self.target = target
        self.items = items
        self.conditions = conditions
        self.triggers = triggers
    }
}
