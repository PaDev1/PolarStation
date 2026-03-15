import Foundation

/// Top-level sequence document, serialised as `.polarseq` JSON.
///
/// A document is a self-contained description of an imaging session:
/// device role bindings, the sequence tree, and optional resume progress.
struct SequenceDocument: Codable, Identifiable {
    static let currentVersion = 1

    let id: UUID
    var version: Int
    var name: String
    var author: String?
    var createdAt: Date
    var modifiedAt: Date
    var deviceRoles: [DeviceRoleBinding]
    var rootContainer: SequenceContainer
    var progress: SequenceProgress?

    init(
        name: String,
        author: String? = nil,
        deviceRoles: [DeviceRoleBinding] = DeviceRoleBinding.defaultRoles,
        rootContainer: SequenceContainer = SequenceContainer(name: "Root")
    ) {
        self.id = UUID()
        self.version = Self.currentVersion
        self.name = name
        self.author = author
        let now = Date()
        self.createdAt = now
        self.modifiedAt = now
        self.deviceRoles = deviceRoles
        self.rootContainer = rootContainer
        self.progress = nil
    }

    // MARK: - File I/O

    static let fileExtension = "polarseq"

    static func load(from url: URL) throws -> SequenceDocument {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SequenceDocument.self, from: data)
    }

    func save(to url: URL) throws {
        var doc = self
        doc.modifiedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)
        try data.write(to: url, options: .atomic)
    }
}
