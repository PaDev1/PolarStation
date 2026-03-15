import Foundation

/// Exports a SequenceDocument to NINA Advanced Sequencer JSON format.
struct NINAExporter {
    static func export(document: SequenceDocument, to url: URL) throws {
        let json = containerToNINA(document.rootContainer)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Private

    private static func containerToNINA(_ container: SequenceContainer) -> [String: Any] {
        var json: [String: Any] = [
            "$type": ninaContainerType(container.type),
            "Name": container.name,
        ]

        if let target = container.target {
            json["Target"] = [
                "TargetName": target.name,
                "InputCoordinates": [
                    "RAHours": target.ra,
                    "DecDegrees": target.dec
                ],
                "Rotation": target.rotation ?? 0
            ]
        }

        var ninaItems: [[String: Any]] = []
        for item in container.items {
            switch item {
            case .container(let child):
                ninaItems.append(containerToNINA(child))
            case .instruction(let instr):
                ninaItems.append(instructionToNINA(instr))
            }
        }
        json["Items"] = ninaItems

        var ninaConditions: [[String: Any]] = []
        for cond in container.conditions {
            ninaConditions.append(conditionToNINA(cond))
        }
        json["Conditions"] = ninaConditions

        var ninaTriggers: [[String: Any]] = []
        for trigger in container.triggers {
            ninaTriggers.append(triggerToNINA(trigger))
        }
        json["Triggers"] = ninaTriggers

        return json
    }

    private static func ninaContainerType(_ type: ContainerType) -> String {
        switch type {
        case .sequential: return "NINA.Sequencer.Container.SequentialContainer, NINA.Sequencer"
        case .parallel: return "NINA.Sequencer.Container.ParallelContainer, NINA.Sequencer"
        case .deepSkyObject: return "NINA.Sequencer.Container.DeepSkyObjectContainer, NINA.Sequencer"
        }
    }

    private static func instructionToNINA(_ instruction: SequenceInstruction) -> [String: Any] {
        var json: [String: Any] = [
            "$type": ninaInstructionType(instruction.type)
        ]

        for (key, value) in instruction.params {
            switch key {
            case "exposure_sec": json["ExposureTime"] = value.doubleValue ?? 0
            case "count": json["ExposureCount"] = value.intValue ?? 1
            case "gain": json["Gain"] = value.intValue ?? -1
            case "binning":
                if let b = value.intValue { json["Binning"] = ["X": b, "Y": b] }
            case "filter_name":
                if let f = value.stringValue { json["Filter"] = ["Name": f] }
            case "seconds": json["Time"] = value.doubleValue ?? 0
            case "dither_every_n": json["DitherEvery"] = value.intValue ?? 0
            case "message": json["Text"] = value.stringValue ?? ""
            default: break
            }
        }

        return json
    }

    private static func ninaInstructionType(_ type: String) -> String {
        let mapping: [String: String] = [
            SequenceInstruction.captureFrames: "NINA.Sequencer.SequenceItem.TakeExposure, NINA.Sequencer",
            SequenceInstruction.slewToTarget: "NINA.Sequencer.SequenceItem.SlewScopeToRaDec, NINA.Sequencer",
            SequenceInstruction.centerTarget: "NINA.Sequencer.SequenceItem.CenterSolver, NINA.Sequencer",
            SequenceInstruction.switchFilter: "NINA.Sequencer.SequenceItem.SwitchFilter, NINA.Sequencer",
            SequenceInstruction.startGuiding: "NINA.Sequencer.SequenceItem.StartGuiding, NINA.Sequencer",
            SequenceInstruction.stopGuiding: "NINA.Sequencer.SequenceItem.StopGuiding, NINA.Sequencer",
            SequenceInstruction.parkMount: "NINA.Sequencer.SequenceItem.ParkScope, NINA.Sequencer",
            SequenceInstruction.unparkMount: "NINA.Sequencer.SequenceItem.UnparkScope, NINA.Sequencer",
            SequenceInstruction.waitTime: "NINA.Sequencer.SequenceItem.WaitForTimeSpan, NINA.Sequencer",
            SequenceInstruction.waitUntilTime: "NINA.Sequencer.SequenceItem.WaitForTime, NINA.Sequencer",
            SequenceInstruction.dither: "NINA.Sequencer.SequenceItem.Dither, NINA.Sequencer",
            SequenceInstruction.setCooler: "NINA.Sequencer.SequenceItem.CoolCamera, NINA.Sequencer",
            SequenceInstruction.warmup: "NINA.Sequencer.SequenceItem.WarmCamera, NINA.Sequencer",
            SequenceInstruction.plateSolve: "NINA.Sequencer.SequenceItem.SolveAndSync, NINA.Sequencer",
        ]
        return mapping[type] ?? "NINA.Sequencer.SequenceItem.Annotation, NINA.Sequencer"
    }

    private static func conditionToNINA(_ condition: SequenceCondition) -> [String: Any] {
        switch condition.type {
        case "loop_count":
            return ["$type": "NINA.Sequencer.Conditions.LoopCondition, NINA.Sequencer",
                    "Iterations": condition.params["count"]?.intValue ?? 1]
        case "loop_until_time":
            return ["$type": "NINA.Sequencer.Conditions.TimeCondition, NINA.Sequencer"]
        default:
            return ["$type": "NINA.Sequencer.Conditions.LoopCondition, NINA.Sequencer"]
        }
    }

    private static func triggerToNINA(_ trigger: SequenceTrigger) -> [String: Any] {
        switch trigger.type {
        case "meridian_flip":
            return ["$type": "NINA.Sequencer.Trigger.MeridianFlipTrigger, NINA.Sequencer"]
        case "autofocus_interval":
            return ["$type": "NINA.Sequencer.Trigger.AutofocusAfterExposures, NINA.Sequencer",
                    "AfterExposures": trigger.params["every_n_frames"]?.intValue ?? 50]
        default:
            return ["$type": "NINA.Sequencer.Trigger.AutofocusAfterExposures, NINA.Sequencer"]
        }
    }
}
