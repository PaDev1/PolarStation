import Foundation

/// A deep-sky object or named star from the catalog.
struct MessierObject: Identifiable {
    let id: String          // e.g. "M1", "NGC7000", "IC434", "B033"
    let name: String        // Common name or designation
    let raDeg: Double       // J2000
    let decDeg: Double      // J2000
    let magnitude: Double
    let type: ObjectType
    let constellation: String
    let commonNames: String // Additional common names
    let identifiers: String // Cross-references (Messier, NGC, IC, etc.)
    let sizeMajor: Double   // Major axis in arcmin (0 if unknown)
    let sizeMinor: Double   // Minor axis in arcmin (0 if unknown)

    var raHours: Double { raDeg / 15.0 }

    /// All searchable text: id + name + common names + identifiers
    var searchText: String {
        "\(id) \(name) \(commonNames) \(identifiers)".lowercased()
    }

    enum ObjectType: String {
        case galaxy = "Galaxy"
        case nebula = "Nebula"
        case cluster = "Cluster"
        case planetary = "Planetary"
        case globular = "Globular"
        case star = "Star"
        case other = "Other"
    }

    init(id: String, name: String, raDeg: Double, decDeg: Double, magnitude: Double, type: ObjectType,
         constellation: String = "", commonNames: String = "", identifiers: String = "",
         sizeMajor: Double = 0, sizeMinor: Double = 0) {
        self.id = id
        self.name = name
        self.raDeg = raDeg
        self.decDeg = decDeg
        self.magnitude = magnitude
        self.type = type
        self.constellation = constellation
        self.commonNames = commonNames
        self.identifiers = identifiers
        self.sizeMajor = sizeMajor
        self.sizeMinor = sizeMinor
    }
}

/// The full deep-sky + named star catalog, loaded from bundled CSV files.
let messierCatalog: [MessierObject] = CatalogLoader.loadAll()

// MARK: - CSV Catalog Loader

enum CatalogLoader {

    static func loadAll() -> [MessierObject] {
        var objects: [MessierObject] = []

        // Load OpenNGC (NGC + IC objects)
        if let url = Bundle.main.url(forResource: "OpenNGC", withExtension: "csv") {
            objects.append(contentsOf: parseOpenNGC(url: url))
        }

        // Load OpenNGC addendum (Barnard, Caldwell, Sharpless, etc.)
        if let url = Bundle.main.url(forResource: "OpenNGC_addendum", withExtension: "csv") {
            objects.append(contentsOf: parseOpenNGC(url: url))
        }

        // Load named stars
        if let url = Bundle.main.url(forResource: "NamedStars", withExtension: "csv") {
            objects.append(contentsOf: parseNamedStars(url: url))
        }

        // Filter out objects without valid coordinates or that are duplicates/non-existent
        objects = objects.filter { $0.raDeg != 0 || $0.decDeg != 0 }

        return objects
    }

    // MARK: - OpenNGC Parser

    /// Parse OpenNGC semicolon-separated CSV.
    /// Format: Name;Type;RA;Dec;Const;MajAx;MinAx;PosAng;B-Mag;V-Mag;...;M;NGC;IC;...;Common names;...
    private static func parseOpenNGC(url: URL) -> [MessierObject] {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = data.components(separatedBy: .newlines)
        guard lines.count > 1 else { return [] }

        // Parse header to find column indices
        let header = lines[0].components(separatedBy: ";")
        let colIndex = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0) })

        guard let nameCol = colIndex["Name"],
              let typeCol = colIndex["Type"],
              let raCol = colIndex["RA"],
              let decCol = colIndex["Dec"] else { return [] }

        let constCol = colIndex["Const"]
        let majAxCol = colIndex["MajAx"]
        let minAxCol = colIndex["MinAx"]
        let vMagCol = colIndex["V-Mag"]
        let bMagCol = colIndex["B-Mag"]
        let messierCol = colIndex["M"]
        let ngcCol = colIndex["NGC"]
        let icCol = colIndex["IC"]
        let identCol = colIndex["Identifiers"]
        let commonCol = colIndex["Common names"]

        var objects: [MessierObject] = []

        for i in 1..<lines.count {
            let line = lines[i]
            guard !line.isEmpty else { continue }
            let fields = line.components(separatedBy: ";")
            guard fields.count > decCol else { continue }

            let rawName = fields[nameCol]
            let rawType = fields[typeCol]
            let raStr = fields[raCol]
            let decStr = fields[decCol]

            // Skip objects without coordinates
            guard !raStr.isEmpty, !decStr.isEmpty else { continue }
            // Skip non-existent and duplicate entries
            guard rawType != "NonEx", rawType != "Dup" else { continue }

            guard let raDeg = parseRA(raStr), let decDeg = parseDec(decStr) else { continue }

            let magnitude: Double
            if let vCol = vMagCol, fields.count > vCol, let v = Double(fields[vCol]) {
                magnitude = v
            } else if let bCol = bMagCol, fields.count > bCol, let b = Double(fields[bCol]) {
                magnitude = b
            } else {
                magnitude = 99.0
            }

            let constellation = constCol.flatMap { fields.count > $0 ? fields[$0] : nil } ?? ""
            let sizeMajor = majAxCol.flatMap { fields.count > $0 ? Double(fields[$0]) : nil } ?? 0
            let sizeMinor = minAxCol.flatMap { fields.count > $0 ? Double(fields[$0]) : nil } ?? 0
            let commonNames = commonCol.flatMap { fields.count > $0 ? fields[$0] : nil } ?? ""
            let identifiers = identCol.flatMap { fields.count > $0 ? fields[$0] : nil } ?? ""
            let messierRef = messierCol.flatMap { fields.count > $0 ? fields[$0] : nil } ?? ""

            // Build display name: prefer Messier, then common name, then catalog name
            let displayName: String
            let objectId: String
            if !messierRef.isEmpty {
                objectId = "M\(messierRef)"
                displayName = commonNames.isEmpty ? rawName : commonNames.components(separatedBy: ",").first!.trimmingCharacters(in: .whitespaces)
            } else if !commonNames.isEmpty {
                objectId = rawName
                displayName = commonNames.components(separatedBy: ",").first!.trimmingCharacters(in: .whitespaces)
            } else {
                objectId = rawName
                displayName = rawName
            }

            // Build cross-reference identifiers
            var xref: [String] = []
            if !messierRef.isEmpty { xref.append("M\(messierRef)") }
            let ngcRef = ngcCol.flatMap { fields.count > $0 ? fields[$0] : nil } ?? ""
            if !ngcRef.isEmpty { xref.append("NGC\(ngcRef)") }
            let icRef = icCol.flatMap { fields.count > $0 ? fields[$0] : nil } ?? ""
            if !icRef.isEmpty { xref.append("IC\(icRef)") }
            if !identifiers.isEmpty { xref.append(identifiers) }
            let allIdentifiers = xref.joined(separator: ",")

            let objType = mapOpenNGCType(rawType)

            objects.append(MessierObject(
                id: objectId,
                name: displayName,
                raDeg: raDeg,
                decDeg: decDeg,
                magnitude: magnitude,
                type: objType,
                constellation: constellation,
                commonNames: commonNames,
                identifiers: allIdentifiers,
                sizeMajor: sizeMajor,
                sizeMinor: sizeMinor
            ))
        }

        return objects
    }

    // MARK: - Named Stars Parser

    /// Parse named stars CSV: name;designation;ra_deg;dec_deg;mag
    private static func parseNamedStars(url: URL) -> [MessierObject] {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = data.components(separatedBy: .newlines)
        guard lines.count > 1 else { return [] }

        var stars: [MessierObject] = []
        for i in 1..<lines.count {
            let line = lines[i]
            guard !line.isEmpty else { continue }
            let fields = line.components(separatedBy: ";")
            guard fields.count >= 5 else { continue }

            let name = fields[0]
            let designation = fields[1]
            guard let raDeg = Double(fields[2]),
                  let decDeg = Double(fields[3]),
                  let mag = Double(fields[4]) else { continue }

            stars.append(MessierObject(
                id: "star_\(name.lowercased().replacingOccurrences(of: " ", with: "_"))",
                name: name,
                raDeg: raDeg,
                decDeg: decDeg,
                magnitude: mag,
                type: .star,
                identifiers: designation
            ))
        }

        return stars
    }

    // MARK: - Coordinate Parsing

    /// Parse RA string "HH:MM:SS.SS" to degrees.
    private static func parseRA(_ s: String) -> Double? {
        let parts = s.components(separatedBy: ":")
        guard parts.count >= 2,
              let h = Double(parts[0]),
              let m = Double(parts[1]) else { return nil }
        let sec = parts.count >= 3 ? (Double(parts[2]) ?? 0) : 0
        return (h + m / 60.0 + sec / 3600.0) * 15.0
    }

    /// Parse Dec string "+/-DD:MM:SS.SS" to degrees.
    private static func parseDec(_ s: String) -> Double? {
        let cleaned = s.trimmingCharacters(in: .whitespaces)
        let sign: Double = cleaned.hasPrefix("-") ? -1.0 : 1.0
        let abs = cleaned.replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "-", with: "")
        let parts = abs.components(separatedBy: ":")
        guard parts.count >= 2,
              let d = Double(parts[0]),
              let m = Double(parts[1]) else { return nil }
        let sec = parts.count >= 3 ? (Double(parts[2]) ?? 0) : 0
        return sign * (d + m / 60.0 + sec / 3600.0)
    }

    // MARK: - Type Mapping

    /// Map OpenNGC type codes to our ObjectType.
    private static func mapOpenNGCType(_ t: String) -> MessierObject.ObjectType {
        switch t {
        case "G", "GPair", "GTrpl", "GGroup": return .galaxy
        case "OCl": return .cluster
        case "GCl": return .globular
        case "PN": return .planetary
        case "HII", "EmN", "RfN", "SNR", "Neb": return .nebula
        case "DrkN": return .nebula
        case "*", "**", "*Ass": return .star
        case "Cl+N": return .nebula
        default: return .other
        }
    }
}
