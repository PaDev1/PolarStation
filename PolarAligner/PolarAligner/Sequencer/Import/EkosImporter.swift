import Foundation

/// Imports Ekos Scheduler .esq XML files into SequenceDocument.
struct EkosImporter {
    /// Import an Ekos .esq XML file.
    static func importFile(from url: URL) throws -> SequenceDocument {
        let data = try Data(contentsOf: url)
        let parser = EkosXMLParser(data: data)
        let jobs = try parser.parse()

        let name = url.deletingPathExtension().lastPathComponent
        var items: [SequenceItem] = []

        for job in jobs {
            var instructions: [SequenceItem] = []

            // Filter change if specified
            if let filter = job.filter {
                instructions.append(.instruction(
                    SequenceInstruction(type: SequenceInstruction.switchFilter,
                                       deviceRole: "filter_wheel",
                                       params: ["filter_name": .string(filter)])
                ))
            }

            // Capture instruction
            var captureParams: [String: AnyCodableValue] = [
                "exposure_sec": .double(job.exposure),
                "count": .int(job.count)
            ]
            if let gain = job.gain {
                captureParams["gain"] = .int(gain)
            }
            instructions.append(.instruction(
                SequenceInstruction(type: SequenceInstruction.captureFrames,
                                   deviceRole: "imaging_camera",
                                   params: captureParams)
            ))

            let target = job.targetName.map { name in
                TargetInfo(name: name, ra: job.ra ?? 0, dec: job.dec ?? 0)
            }

            let container = SequenceContainer(
                name: job.targetName ?? "Job \(items.count + 1)",
                type: target != nil ? .deepSkyObject : .sequential,
                target: target,
                items: instructions
            )
            items.append(.container(container))
        }

        let root = SequenceContainer(name: name, type: .sequential, items: items)
        return SequenceDocument(name: name, rootContainer: root)
    }
}

// MARK: - Ekos XML Parser

private struct EkosJob {
    var targetName: String?
    var ra: Double?
    var dec: Double?
    var exposure: Double = 60
    var count: Int = 1
    var filter: String?
    var gain: Int?
}

private class EkosXMLParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var jobs: [EkosJob] = []
    private var currentJob: EkosJob?
    private var currentElement: String = ""
    private var currentText: String = ""
    private var parseError: Error?

    init(data: Data) {
        self.data = data
    }

    func parse() throws -> [EkosJob] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        if let error = parseError ?? parser.parserError {
            throw ImportError.invalidFormat(error.localizedDescription)
        }
        return jobs
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        currentText = ""
        if elementName == "Job" {
            currentJob = EkosJob()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if elementName == "Job", let job = currentJob {
            jobs.append(job)
            currentJob = nil
        } else if currentJob != nil {
            switch elementName {
            case "Name", "TargetName": currentJob?.targetName = text
            case "RA", "RAHours": currentJob?.ra = Double(text)
            case "DEC", "DECDegrees": currentJob?.dec = Double(text)
            case "Exposure": currentJob?.exposure = Double(text) ?? 60
            case "Count": currentJob?.count = Int(text) ?? 1
            case "Filter": currentJob?.filter = text
            case "Gain": currentJob?.gain = Int(text)
            default: break
            }
        }
    }
}
