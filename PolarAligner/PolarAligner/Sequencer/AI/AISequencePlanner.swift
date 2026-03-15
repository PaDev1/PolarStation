import Foundation

/// AI-powered sequence planner that generates imaging sequences based on
/// connected devices, observer location, time, and optionally weather.
@MainActor
class AISequencePlanner: ObservableObject {
    @Published var isPlanning = false
    @Published var statusMessage = ""
    @Published var lastError: String?

    /// Generate a sequence using the configured LLM.
    func generateSequence(
        llmService: LLMService,
        provider: LLMProvider,
        endpoint: String,
        apiKey: String,
        model: String,
        deviceRoles: [DeviceRoleBinding],
        observerLat: Double,
        observerLon: Double,
        sessionDurationHours: Double = 6,
        filterNames: [String] = [],
        focalLengthMM: Double = 200,
        notes: String = ""
    ) async throws -> SequenceDocument {
        isPlanning = true
        statusMessage = "Generating sequence with AI..."
        lastError = nil

        defer { isPlanning = false }

        let systemPrompt = buildSystemPrompt()
        let userPrompt = buildUserPrompt(
            deviceRoles: deviceRoles,
            observerLat: observerLat,
            observerLon: observerLon,
            sessionDurationHours: sessionDurationHours,
            filterNames: filterNames,
            focalLengthMM: focalLengthMM,
            notes: notes
        )

        do {
            statusMessage = "Waiting for AI response..."
            let response = try await llmService.complete(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                provider: provider,
                endpoint: endpoint,
                apiKey: apiKey,
                model: model,
                maxTokens: 4096,
                jsonMode: true
            )

            statusMessage = "Parsing sequence..."
            let document = try parseResponse(response)
            statusMessage = "Sequence generated: \(document.name)"
            return document
        } catch {
            lastError = error.localizedDescription
            statusMessage = "AI planning failed, using rule-based fallback"
            return generateFallbackSequence(
                observerLat: observerLat,
                observerLon: observerLon,
                sessionDurationHours: sessionDurationHours,
                filterNames: filterNames
            )
        }
    }

    // MARK: - Prompt Construction

    private func buildSystemPrompt() -> String {
        """
        You are an expert astronomical imaging sequence planner. Generate a \
        .polarseq JSON sequence document for the user's imaging session.

        The JSON format:
        {
          "version": 1,
          "name": "Session Name",
          "deviceRoles": [{"role": "imaging_camera", "deviceType": "camera", "displayName": "Camera"}],
          "rootContainer": {
            "name": "Root",
            "type": "sequential",
            "items": [...],
            "conditions": [],
            "triggers": []
          }
        }

        Container types: "sequential", "parallel", "deepSkyObject"
        DeepSkyObject containers need a "target" with "name", "ra" (hours 0-24), "dec" (degrees).

        Item format: {"container": {...}} or {"instruction": {...}}
        Instruction format: {"type": "...", "enabled": true, "deviceRole": "...", "params": {...}}

        Available instruction types:
        - slew_to_target (mount) - uses parent container target
        - center_target (mount) - params: attempts
        - start_guiding (guide_camera)
        - stop_guiding (guide_camera)
        - capture_frames (imaging_camera) - params: exposure_sec, count, gain, binning, frame_type, dither_every_n
        - switch_filter (filter_wheel) - params: filter_name
        - wait_time - params: seconds
        - park_mount (mount)
        - unpark_mount (mount)
        - dither (guide_camera) - params: pixels, settle_time_sec
        - annotation - params: message

        Conditions (loop control): loop_count (count), time_elapsed (seconds)
        Triggers: meridian_flip, autofocus_interval (every_n_frames), guide_deviation_pause (max_rms_arcsec)

        Rules:
        1. Always start with unpark_mount
        2. For each target: slew → center → start guiding → capture (with filter changes if available) → stop guiding
        3. Use dither_every_n: 3 for broadband, 1 for narrowband
        4. End with park_mount
        5. Choose targets that are well-placed for the observer's location and current date/time
        6. Prefer popular deep sky objects visible during the session

        Return ONLY valid JSON, no markdown fences or explanation.
        """
    }

    private func buildUserPrompt(
        deviceRoles: [DeviceRoleBinding],
        observerLat: Double,
        observerLon: Double,
        sessionDurationHours: Double,
        filterNames: [String],
        focalLengthMM: Double,
        notes: String
    ) -> String {
        let dateFormatter = ISO8601DateFormatter()
        let now = dateFormatter.string(from: Date())
        let devices = deviceRoles.map { "\($0.role): \($0.displayName) (\($0.deviceType))" }.joined(separator: "\n")
        let filters = filterNames.isEmpty ? "No filter wheel" : filterNames.joined(separator: ", ")

        return """
        Plan an imaging session with these parameters:

        Observer: \(String(format: "%.4f", observerLat))°N, \(String(format: "%.4f", observerLon))°E
        Current time: \(now)
        Session duration: \(Int(sessionDurationHours)) hours
        Focal length: \(Int(focalLengthMM))mm
        Available filters: \(filters)

        Connected devices:
        \(devices)

        \(notes.isEmpty ? "" : "Additional notes: \(notes)")

        Generate a complete .polarseq JSON sequence.
        """
    }

    // MARK: - Response Parsing

    private func parseResponse(_ response: String) throws -> SequenceDocument {
        // Strip markdown fences if present
        var json = response
        if json.contains("```") {
            json = json.replacingOccurrences(of: "```json", with: "")
            json = json.replacingOccurrences(of: "```", with: "")
        }
        json = json.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = json.data(using: .utf8) else {
            throw PlannerError.invalidJSON("Response is not valid UTF-8")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(SequenceDocument.self, from: data)
        } catch {
            throw PlannerError.invalidJSON("Failed to parse sequence: \(error.localizedDescription)")
        }
    }

    // MARK: - Rule-Based Fallback

    /// Simple rule-based planner for when LLM is unavailable.
    func generateFallbackSequence(
        observerLat: Double,
        observerLon: Double,
        sessionDurationHours: Double,
        filterNames: [String]
    ) -> SequenceDocument {
        // Pick a few well-known targets based on rough season
        let month = Calendar.current.component(.month, from: Date())
        let targets = targetsForMonth(month, latitude: observerLat)

        var rootItems: [SequenceItem] = []

        // Unpark
        rootItems.append(.instruction(
            SequenceInstruction(type: SequenceInstruction.unparkMount, deviceRole: "mount", params: [:])
        ))

        // For each target, create a DSO container
        let timePerTarget = sessionDurationHours / Double(max(targets.count, 1))
        let framesPerTarget = Int(timePerTarget * 3600 / 120) // assuming 120s exposures

        for target in targets {
            var dsoItems: [SequenceItem] = []

            dsoItems.append(.instruction(
                SequenceInstruction(type: SequenceInstruction.slewToTarget, deviceRole: "mount", params: [:])
            ))
            dsoItems.append(.instruction(
                SequenceInstruction(type: SequenceInstruction.centerTarget, deviceRole: "mount", params: ["attempts": .int(3)])
            ))
            dsoItems.append(.instruction(
                SequenceInstruction(type: SequenceInstruction.startGuiding, deviceRole: "guide_camera", params: [:])
            ))

            if filterNames.isEmpty {
                // No filter wheel — just capture
                dsoItems.append(.instruction(
                    SequenceInstruction(type: SequenceInstruction.captureFrames, deviceRole: "imaging_camera",
                                       params: ["exposure_sec": .double(120), "count": .int(framesPerTarget), "dither_every_n": .int(3)])
                ))
            } else {
                // LRGB or narrowband per filter
                let framesPerFilter = max(framesPerTarget / filterNames.count, 5)
                for filter in filterNames {
                    dsoItems.append(.instruction(
                        SequenceInstruction(type: SequenceInstruction.switchFilter, deviceRole: "filter_wheel",
                                           params: ["filter_name": .string(filter)])
                    ))
                    let isNarrowband = ["Ha", "SII", "OIII", "S2", "O3"].contains(where: { filter.contains($0) })
                    dsoItems.append(.instruction(
                        SequenceInstruction(type: SequenceInstruction.captureFrames, deviceRole: "imaging_camera",
                                           params: ["exposure_sec": .double(isNarrowband ? 300 : 120),
                                                    "count": .int(framesPerFilter),
                                                    "dither_every_n": .int(isNarrowband ? 1 : 3)])
                    ))
                }
            }

            dsoItems.append(.instruction(
                SequenceInstruction(type: SequenceInstruction.stopGuiding, deviceRole: "guide_camera", params: [:])
            ))

            let dsoContainer = SequenceContainer(
                name: target.name,
                type: .deepSkyObject,
                target: target,
                items: dsoItems,
                triggers: [
                    SequenceTrigger(type: "meridian_flip", params: ["minutes_past_meridian": .int(5)]),
                    SequenceTrigger(type: "guide_deviation_pause", params: ["max_rms_arcsec": .double(2.0)])
                ]
            )
            rootItems.append(.container(dsoContainer))
        }

        // Park at end
        rootItems.append(.instruction(
            SequenceInstruction(type: SequenceInstruction.parkMount, deviceRole: "mount", params: [:])
        ))

        let root = SequenceContainer(name: "Auto-generated Session", type: .sequential, items: rootItems)
        return SequenceDocument(name: "AI Planned Session", rootContainer: root)
    }

    // MARK: - Target Selection

    private func targetsForMonth(_ month: Int, latitude: Double) -> [TargetInfo] {
        // Simple seasonal target list for Northern Hemisphere
        // Each entry: (startMonth, endMonth, target) — wraps around Dec→Jan
        let allTargets: [(start: Int, end: Int, target: TargetInfo)] = [
            (1, 4, TargetInfo(name: "M42 - Orion Nebula", ra: 5.59, dec: -5.39)),
            (1, 3, TargetInfo(name: "M1 - Crab Nebula", ra: 5.575, dec: 22.01)),
            (3, 7, TargetInfo(name: "M81 - Bode's Galaxy", ra: 9.926, dec: 69.07)),
            (3, 7, TargetInfo(name: "M51 - Whirlpool Galaxy", ra: 13.498, dec: 47.20)),
            (4, 9, TargetInfo(name: "M13 - Hercules Cluster", ra: 16.695, dec: 36.46)),
            (5, 10, TargetInfo(name: "M57 - Ring Nebula", ra: 18.892, dec: 33.03)),
            (6, 11, TargetInfo(name: "M31 - Andromeda Galaxy", ra: 0.712, dec: 41.27)),
            (6, 10, TargetInfo(name: "NGC 7000 - North America Nebula", ra: 20.98, dec: 44.33)),
            (7, 11, TargetInfo(name: "M27 - Dumbbell Nebula", ra: 19.994, dec: 22.72)),
            (8, 12, TargetInfo(name: "NGC 7635 - Bubble Nebula", ra: 23.337, dec: 61.21)),
            (10, 12, TargetInfo(name: "IC 1805 - Heart Nebula", ra: 2.543, dec: 61.47)),
            (11, 2, TargetInfo(name: "NGC 2244 - Rosette Nebula", ra: 6.535, dec: 4.95)),
        ]

        let visible = allTargets.filter { entry in
            if entry.start <= entry.end {
                return month >= entry.start && month <= entry.end
            } else {
                // Wraps around year boundary (e.g. Nov–Feb)
                return month >= entry.start || month <= entry.end
            }
        }

        // Return up to 3 targets
        return Array(visible.prefix(3).map(\.target))
    }
}

enum PlannerError: LocalizedError {
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let msg): return msg
        }
    }
}
