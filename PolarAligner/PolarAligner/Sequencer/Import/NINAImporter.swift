import Foundation

/// Imports NINA Advanced Sequencer .json files into SequenceDocument.
struct NINAImporter {
    /// Import a NINA sequence JSON file.
    static func importFile(from url: URL) throws -> SequenceDocument {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.invalidFormat("Not a valid JSON object")
        }

        let name = (json["Name"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let rootContainer = try parseContainer(from: json, name: name)

        return SequenceDocument(name: name, rootContainer: rootContainer)
    }

    // MARK: - Private

    private static func parseContainer(from json: [String: Any], name: String) throws -> SequenceContainer {
        let typeStr = json["$type"] as? String ?? ""
        let containerType = mapContainerType(typeStr)

        var items: [SequenceItem] = []
        var conditions: [SequenceCondition] = []
        var triggers: [SequenceTrigger] = []
        var target: TargetInfo? = nil

        // Parse target if present
        if let targetJson = json["Target"] as? [String: Any] {
            let tName = targetJson["TargetName"] as? String ?? name
            let coords = targetJson["InputCoordinates"] as? [String: Any]
            let ra = coords?["RAHours"] as? Double ?? 0
            let dec = coords?["DecDegrees"] as? Double ?? 0
            let rotation = targetJson["Rotation"] as? Double
            target = TargetInfo(name: tName, ra: ra, dec: dec, rotation: rotation)
        }

        // Parse items array
        if let itemsJson = json["Items"] as? [[String: Any]] {
            for itemJson in itemsJson {
                let itemType = itemJson["$type"] as? String ?? ""
                if isContainerType(itemType) {
                    let childName = itemJson["Name"] as? String ?? "Container"
                    let child = try parseContainer(from: itemJson, name: childName)
                    items.append(.container(child))
                } else {
                    let instruction = parseInstruction(from: itemJson)
                    items.append(.instruction(instruction))
                }
            }
        }

        // Parse conditions
        if let conditionsJson = json["Conditions"] as? [[String: Any]] {
            for cJson in conditionsJson {
                if let cond = parseCondition(from: cJson) {
                    conditions.append(cond)
                }
            }
        }

        // Parse triggers
        if let triggersJson = json["Triggers"] as? [[String: Any]] {
            for tJson in triggersJson {
                if let trigger = parseTrigger(from: tJson) {
                    triggers.append(trigger)
                }
            }
        }

        return SequenceContainer(
            name: name,
            type: containerType,
            target: target,
            items: items,
            conditions: conditions,
            triggers: triggers
        )
    }

    private static func mapContainerType(_ type: String) -> ContainerType {
        if type.contains("ParallelContainer") { return .parallel }
        if type.contains("DeepSkyObject") { return .deepSkyObject }
        return .sequential
    }

    private static func isContainerType(_ type: String) -> Bool {
        let containerTypes = ["SequentialContainer", "ParallelContainer", "DeepSkyObjectContainer"]
        return containerTypes.contains(where: { type.contains($0) })
    }

    private static func parseInstruction(from json: [String: Any]) -> SequenceInstruction {
        let ninaType = json["$type"] as? String ?? ""
        let type = mapInstructionType(ninaType)

        var params: [String: AnyCodableValue] = [:]

        // Map common NINA parameters
        if let exposure = json["ExposureTime"] as? Double {
            params["exposure_sec"] = .double(exposure)
        }
        if let count = json["ExposureCount"] as? Int {
            params["count"] = .int(count)
        }
        if let gain = json["Gain"] as? Int {
            params["gain"] = .int(gain)
        }
        if let binning = json["Binning"] as? [String: Any], let x = binning["X"] as? Int {
            params["binning"] = .int(x)
        }
        if let filter = json["Filter"] as? [String: Any], let name = filter["Name"] as? String {
            params["filter_name"] = .string(name)
        }
        if let waitTime = json["Time"] as? Double {
            params["seconds"] = .double(waitTime)
        }
        if let ditherEvery = json["DitherEvery"] as? Int {
            params["dither_every_n"] = .int(ditherEvery)
        }

        return SequenceInstruction(type: type, deviceRole: deviceRoleForType(type), params: params)
    }

    private static func mapInstructionType(_ ninaType: String) -> String {
        let mapping: [String: String] = [
            "TakeExposure": SequenceInstruction.captureFrames,
            "TakeSubframeExposure": SequenceInstruction.captureFrames,
            "SlewScopeToRaDec": SequenceInstruction.slewToTarget,
            "CenterSolver": SequenceInstruction.centerTarget,
            "SwitchFilter": SequenceInstruction.switchFilter,
            "StartGuiding": SequenceInstruction.startGuiding,
            "StopGuiding": SequenceInstruction.stopGuiding,
            "ParkScope": SequenceInstruction.parkMount,
            "UnparkScope": SequenceInstruction.unparkMount,
            "WaitForTime": SequenceInstruction.waitUntilTime,
            "WaitForTimeSpan": SequenceInstruction.waitTime,
            "Dither": SequenceInstruction.dither,
            "CoolCamera": SequenceInstruction.setCooler,
            "WarmCamera": SequenceInstruction.warmup,
            "SolveAndSync": SequenceInstruction.plateSolve,
        ]

        for (key, value) in mapping {
            if ninaType.contains(key) { return value }
        }

        // Unknown type — preserve with prefix
        let shortType = ninaType.components(separatedBy: ",").first?.components(separatedBy: ".").last ?? ninaType
        return "unknown_nina_\(shortType)"
    }

    private static func deviceRoleForType(_ type: String) -> String? {
        switch type {
        case SequenceInstruction.captureFrames, SequenceInstruction.setCooler, SequenceInstruction.warmup:
            return "imaging_camera"
        case SequenceInstruction.slewToTarget, SequenceInstruction.parkMount, SequenceInstruction.unparkMount,
             SequenceInstruction.startTracking, SequenceInstruction.centerTarget:
            return "mount"
        case SequenceInstruction.startGuiding, SequenceInstruction.stopGuiding, SequenceInstruction.dither:
            return "guide_camera"
        case SequenceInstruction.switchFilter:
            return "filter_wheel"
        default:
            return nil
        }
    }

    private static func parseCondition(from json: [String: Any]) -> SequenceCondition? {
        let ninaType = json["$type"] as? String ?? ""
        var params: [String: AnyCodableValue] = [:]

        if ninaType.contains("LoopCondition") {
            if let count = json["CompletedIterations"] as? Int ?? json["Iterations"] as? Int {
                params["count"] = .int(count)
            }
            return SequenceCondition(type: "loop_count", params: params)
        }
        if ninaType.contains("TimeCondition") {
            return SequenceCondition(type: "loop_until_time", params: params)
        }

        return nil
    }

    private static func parseTrigger(from json: [String: Any]) -> SequenceTrigger? {
        let ninaType = json["$type"] as? String ?? ""

        if ninaType.contains("MeridianFlip") {
            return SequenceTrigger(type: "meridian_flip", params: [:])
        }
        if ninaType.contains("AutofocusAfterExposures") {
            var params: [String: AnyCodableValue] = [:]
            if let count = json["AfterExposures"] as? Int {
                params["every_n_frames"] = .int(count)
            }
            return SequenceTrigger(type: "autofocus_interval", params: params)
        }

        return nil
    }
}

enum ImportError: LocalizedError {
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): return "Import error: \(msg)"
        }
    }
}
