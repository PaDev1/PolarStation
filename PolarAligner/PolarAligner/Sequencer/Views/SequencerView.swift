import SwiftUI
import UniformTypeIdentifiers

struct SequencerView: View {
    @ObservedObject var engine: SequenceEngine
    @ObservedObject var filterWheelViewModel: FilterWheelViewModel
    @Binding var document: SequenceDocument
    @Binding var selectedItemId: UUID?
    @StateObject private var planner = AISequencePlanner()

    @State private var showImporter = false
    @State private var showAIPlanner = false
    @State private var showContainerPicker = false
    @State private var showInstructionPicker = false
    @State private var draggedItemId: UUID?
    @State private var dropTargetId: UUID?
    @State private var dropInsideContainer: Bool = false
    @State private var expandedContainers: Set<UUID> = []
    @State private var expandedInitialized = false

    // AI planner inputs
    @AppStorage("observerLat") private var observerLat: Double = 60.17
    @AppStorage("observerLon") private var observerLon: Double = 24.94
    @AppStorage("llmProvider") private var llmProviderRaw: String = LLMProvider.claude.rawValue
    @AppStorage("llmApiEndpoint") private var llmApiEndpoint: String = ""
    @AppStorage("llmApiKey") private var llmApiKey: String = ""
    @AppStorage("llmModel") private var llmModel: String = ""
    @State private var aiSessionHours: Double = 6
    @State private var aiNotes: String = ""

    var body: some View {
        HSplitView {
            // Left: Sequence tree
            VStack(spacing: 0) {
                toolbar
                Divider()
                sequenceTree
            }
            .frame(minWidth: 300, idealWidth: 400)

            // Right: Execution status + inspector
            VStack(spacing: 0) {
                executionStatus
                Divider()
                inspector
            }
            .frame(minWidth: 320)
        }
        .sheet(isPresented: $showAIPlanner) { aiPlannerSheet }
        .sheet(isPresented: $showContainerPicker) { containerPickerSheet }
        .sheet(isPresented: $showInstructionPicker) { instructionPickerSheet }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .xml],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                importFile(url)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(document.name)
                .font(.headline)

            Spacer()

            Button(action: { showAIPlanner = true }) {
                Label("AI Plan", systemImage: "wand.and.stars")
            }
            .help("Generate sequence with AI")

            Menu {
                Button("New Sequence") {
                    document = SequenceDocument(name: "New Sequence")
                    selectedItemId = nil
                    expandedContainers = [document.rootContainer.id]
                }
                Divider()
                Button("Open...") { openFile() }
                Button("Save...") { saveFile() }
                Divider()
                Button("Import NINA/Ekos...") { showImporter = true }
                Button("Export NINA...") { exportNINA() }
            } label: {
                Label("File", systemImage: "doc")
            }

            Button(action: { showContainerPicker = true }) {
                Label("Container", systemImage: "folder.badge.plus")
            }
            .help("Add container")

            Button(action: { showInstructionPicker = true }) {
                Label("Instruction", systemImage: "plus.circle")
            }
            .help("Add instruction")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Container Picker Sheet

    private var containerPickerSheet: some View {
        VStack(spacing: 16) {
            Text("Add Container")
                .font(.title3)

            VStack(spacing: 8) {
                containerPickerButton(
                    type: .sequential,
                    title: "Sequential",
                    description: "Runs items one after another",
                    icon: "list.number"
                )
                containerPickerButton(
                    type: .parallel,
                    title: "Parallel",
                    description: "Runs items concurrently (e.g. guide + capture)",
                    icon: "arrow.triangle.branch"
                )
                containerPickerButton(
                    type: .deepSkyObject,
                    title: "Deep Sky Object",
                    description: "Target with RA/Dec coordinates",
                    icon: "star.circle"
                )
            }

            Button("Cancel") { showContainerPicker = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 360)
    }

    private func containerPickerButton(type: ContainerType, title: String, description: String, icon: String) -> some View {
        Button {
            let name = type == .deepSkyObject ? "New Target" : "New \(title)"
            let target = type == .deepSkyObject ? TargetInfo(name: "Target", ra: 0, dec: 0) : nil
            let container = SequenceContainer(name: name, type: type, target: target)
            expandedContainers.insert(container.id)
            addItemToSelectedOrRoot(.container(container))
            showContainerPicker = false
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 30)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(.quaternary.opacity(0.5))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Instruction Picker Sheet

    private var instructionPickerSheet: some View {
        VStack(spacing: 12) {
            Text("Add Instruction")
                .font(.title3)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    instructionCategory("Mount", items: [
                        (SequenceInstruction.slewToTarget, "Slew to Target", "scope", "mount"),
                        (SequenceInstruction.centerTarget, "Center Target", "scope", "mount"),
                        (SequenceInstruction.unparkMount, "Unpark Mount", "sunrise", "mount"),
                        (SequenceInstruction.parkMount, "Park Mount", "moon.zzz", "mount"),
                        (SequenceInstruction.goHome, "Go Home", "house", "mount"),
                        (SequenceInstruction.startTracking, "Start Tracking", "rotate.right", "mount"),
                    ])

                    instructionCategory("Camera", items: [
                        (SequenceInstruction.captureFrames, "Capture Frames", "camera", "imaging_camera"),
                        (SequenceInstruction.setCooler, "Set Cooler", "thermometer.snowflake", "imaging_camera"),
                        (SequenceInstruction.warmup, "Warm Up Camera", "thermometer.sun", "imaging_camera"),
                        (SequenceInstruction.plateSolve, "Plate Solve", "sparkle.magnifyingglass", "imaging_camera"),
                    ])

                    instructionCategory("Guiding", items: [
                        (SequenceInstruction.startGuiding, "Start Guiding", "target", "guide_camera"),
                        (SequenceInstruction.stopGuiding, "Stop Guiding", "xmark.circle", "guide_camera"),
                        (SequenceInstruction.dither, "Dither", "arrow.up.and.down.and.arrow.left.and.right", "guide_camera"),
                    ])

                    instructionCategory("Filter Wheel", items: [
                        (SequenceInstruction.switchFilter, "Switch Filter", "circle.grid.cross", "filter_wheel"),
                    ])

                    instructionCategory("Focuser", items: [
                        (SequenceInstruction.moveFocuser, "Move Focuser", "arrow.up.arrow.down", "focuser"),
                        (SequenceInstruction.haltFocuser, "Halt Focuser", "stop.circle", "focuser"),
                        (SequenceInstruction.autofocus, "Autofocus", "scope", "focuser"),
                    ])

                    instructionCategory("Dome", items: [
                        (SequenceInstruction.slewDome, "Slew Dome", "circle.dashed", "dome"),
                        (SequenceInstruction.openShutter, "Open Shutter", "rectangle.portrait.arrowtriangle.2.outward", "dome"),
                        (SequenceInstruction.closeShutter, "Close Shutter", "rectangle.portrait.arrowtriangle.2.inward", "dome"),
                        (SequenceInstruction.parkDome, "Park Dome", "moon.zzz", "dome"),
                        (SequenceInstruction.homeDome, "Home Dome", "house", "dome"),
                    ])

                    instructionCategory("Rotator", items: [
                        (SequenceInstruction.moveRotator, "Move Rotator", "arrow.triangle.2.circlepath", "rotator"),
                    ])

                    instructionCategory("Switch", items: [
                        (SequenceInstruction.setSwitch, "Set Switch", "switch.2", "switch"),
                    ])

                    instructionCategory("Cover/Calibrator", items: [
                        (SequenceInstruction.openCover, "Open Cover", "rectangle.portrait.arrowtriangle.2.outward", "cover_calibrator"),
                        (SequenceInstruction.closeCover, "Close Cover", "rectangle.portrait.arrowtriangle.2.inward", "cover_calibrator"),
                        (SequenceInstruction.calibratorOn, "Calibrator On", "lightbulb.max", "cover_calibrator"),
                        (SequenceInstruction.calibratorOff, "Calibrator Off", "lightbulb.slash", "cover_calibrator"),
                    ])

                    instructionCategory("Safety / Conditions", items: [
                        (SequenceInstruction.waitForSafe, "Wait for Safe", "shield.checkered", "safety_monitor"),
                        (SequenceInstruction.logWeather, "Log Weather", "cloud.sun", "observing_conditions"),
                    ])

                    instructionCategory("Timing", items: [
                        (SequenceInstruction.waitTime, "Wait (Duration)", "clock", nil),
                        (SequenceInstruction.waitUntilTime, "Wait Until Time (UTC)", "clock.badge.checkmark", nil),
                        (SequenceInstruction.waitUntilLocalTime, "Wait Until Local Time", "clock.badge.checkmark", nil),
                        (SequenceInstruction.waitForAltitude, "Wait for Altitude", "mountain.2", nil),
                    ])

                    instructionCategory("Utility", items: [
                        (SequenceInstruction.annotation, "Annotation", "text.bubble", nil),
                        (SequenceInstruction.runScript, "Run Script", "terminal", nil),
                    ])
                }
            }
            .frame(maxHeight: 400)

            Button("Cancel") { showInstructionPicker = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(width: 360)
    }

    private func instructionCategory(_ title: String, items: [(String, String, String, String?)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 2) {
                ForEach(items, id: \.0) { type, label, icon, role in
                    Button {
                        let defaults = defaultParams(for: type)
                        let instruction = SequenceInstruction(type: type, deviceRole: role, params: defaults)
                        addItemToSelectedOrRoot(.instruction(instruction))
                        selectedItemId = instruction.id
                        showInstructionPicker = false
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon)
                                .frame(width: 24)
                                .foregroundStyle(.blue)
                            Text(label)
                            Spacer()
                            if let role {
                                Text(role.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(.quaternary.opacity(0.3))
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Sequence Tree

    private var sequenceTree: some View {
        List(selection: $selectedItemId) {
            containerRow(document.rootContainer, path: [])
        }
        .listStyle(.sidebar)
        .onAppear {
            if !expandedInitialized {
                // Expand root by default
                expandedContainers.insert(document.rootContainer.id)
                expandedInitialized = true
            }
        }
    }

    private func isExpanded(_ containerId: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedContainers.contains(containerId) },
            set: { isExpanded in
                if isExpanded {
                    expandedContainers.insert(containerId)
                } else {
                    expandedContainers.remove(containerId)
                }
            }
        )
    }

    @ViewBuilder
    private func containerRow(_ container: SequenceContainer, path: [Int]) -> some View {
        DisclosureGroup(isExpanded: isExpanded(container.id)) {
            ForEach(Array(container.items.enumerated()), id: \.element.id) { index, item in
                let childPath = path + [index]
                switch item {
                case .container(let child):
                    containerRow(child, path: childPath)
                case .instruction(let instruction):
                    instructionRow(instruction, path: childPath)
                }
            }
        } label: {
            containerLabel(container, path: path)
        }
        // Drop onto container — inserts into it
        .onDrop(of: [.utf8PlainText], delegate: ContainerDropDelegate(
            containerId: container.id,
            draggedItemId: $draggedItemId,
            dropTargetId: $dropTargetId,
            dropInsideContainer: $dropInsideContainer,
            document: $document
        ))
    }

    @ViewBuilder
    private func containerLabel(_ container: SequenceContainer, path: [Int]) -> some View {
        let isRoot = path.isEmpty
        HStack(spacing: 6) {
            // Drag handle (non-root only)
            if !isRoot {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.quaternary)
                    .font(.caption)
                    .onDrag {
                        draggedItemId = container.id
                        return NSItemProvider(object: container.id.uuidString as NSString)
                    }
            }
            Image(systemName: containerIcon(container.type))
                .foregroundStyle(container.enabled ? containerColor(container.type) : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.name)
                    .font(.body)
                    .foregroundStyle(container.enabled ? .primary : .secondary)
                if let target = container.target {
                    let trackingLabel = target.effectiveTrackingRate == .sidereal ? "" : "  [\(target.effectiveTrackingRate.label)]"
                    Text("\(target.name)  RA \(String(format: "%.2f", target.ra))h  Dec \(String(format: "%.1f", target.dec))°\(trackingLabel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !container.conditions.isEmpty || !container.triggers.isEmpty {
                    HStack(spacing: 4) {
                        if !container.conditions.isEmpty {
                            Label("\(container.conditions.count)", systemImage: "repeat")
                        }
                        if !container.triggers.isEmpty {
                            Label("\(container.triggers.count)", systemImage: "bolt")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            executionBadge(for: container.id)
        }
        .overlay(alignment: .bottom) {
            if dropTargetId == container.id && dropInsideContainer {
                // Green border when dropping INTO a container
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.green, lineWidth: 2)
                    .padding(-2)
            } else if !isRoot && dropTargetId == container.id && !dropInsideContainer {
                // Green line below when reordering
                dropIndicatorLine
                    .offset(y: 4)
            }
        }
        .tag(container.id)
        .contextMenu { itemContextMenu(id: container.id, path: path) }
    }

    private var dropIndicatorLine: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Rectangle()
                .fill(Color.green)
                .frame(height: 2)
        }
        .padding(.leading, 4)
        .transition(.opacity)
    }

    private func instructionRow(_ instruction: SequenceInstruction, path: [Int]) -> some View {
        HStack(spacing: 6) {
            // Drag handle
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.quaternary)
                .font(.caption)
                .onDrag {
                    draggedItemId = instruction.id
                    return NSItemProvider(object: instruction.id.uuidString as NSString)
                }
            Image(systemName: instructionIcon(instruction.type))
                .foregroundStyle(instruction.enabled ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(instructionDisplayName(instruction.type))
                    .font(.body)
                    .foregroundStyle(instruction.enabled ? .primary : .secondary)
                if let summary = instructionSummary(instruction) {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            executionBadge(for: instruction.id)
        }
        .overlay(alignment: .bottom) {
            // Green drop indicator line below this row — shows where item will be placed
            if dropTargetId == instruction.id && !dropInsideContainer {
                dropIndicatorLine
                    .offset(y: 4)
            }
        }
        .tag(instruction.id)
        .contextMenu { itemContextMenu(id: instruction.id, path: path) }
        .onDrop(of: [.utf8PlainText], delegate: ReorderDropDelegate(
            targetId: instruction.id,
            draggedItemId: $draggedItemId,
            dropTargetId: $dropTargetId,
            dropInsideContainer: $dropInsideContainer,
            document: $document
        ))
    }

    @ViewBuilder
    private func executionBadge(for id: UUID) -> some View {
        if engine.isRunning {
            if engine.currentInstructionId == id {
                Circle().fill(.green).frame(width: 8, height: 8)
            } else if engine.completedIds.contains(id) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private func itemContextMenu(id: UUID, path: [Int]) -> some View {
        Button(toggleEnabledLabel(for: id)) {
            toggleEnabled(id: id)
        }
        Divider()
        Button("Duplicate") {
            duplicateItem(at: path)
        }
        Button("Delete", role: .destructive) {
            deleteItem(at: path)
            if selectedItemId == id { selectedItemId = nil }
        }
    }

    // MARK: - Inspector (Right Panel)

    @ViewBuilder
    private var inspector: some View {
        if let id = selectedItemId {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let container = findContainer(id: id, in: document.rootContainer) {
                        containerInspector(container)
                    } else if let instruction = findInstruction(id: id, in: document.rootContainer) {
                        instructionInspector(instruction)
                    } else {
                        noSelectionView
                    }
                }
                .padding()
            }
        } else {
            gettingStartedView
        }
    }

    // MARK: Container Inspector

    private func containerInspector(_ container: SequenceContainer) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            Label("Container", systemImage: containerIcon(container.type))
                .font(.headline)

            GroupBox("Properties") {
                VStack(alignment: .leading, spacing: 8) {
                    inspectorField("Name") {
                        TextField("Name", text: bindContainerName(container.id))
                            .textFieldStyle(.roundedBorder)
                    }
                    inspectorField("Type") {
                        Picker("", selection: bindContainerType(container.id)) {
                            Text("Sequential").tag(ContainerType.sequential)
                            Text("Parallel").tag(ContainerType.parallel)
                            Text("Deep Sky Object").tag(ContainerType.deepSkyObject)
                        }
                        .labelsHidden()
                    }
                    inspectorField("Enabled") {
                        Toggle("", isOn: bindContainerEnabled(container.id))
                            .labelsHidden()
                    }
                }
                .padding(.vertical, 4)
            }

            if container.type == .deepSkyObject {
                GroupBox("Target") {
                    VStack(alignment: .leading, spacing: 8) {
                        inspectorField("Name") {
                            TextField("Target name", text: bindTargetName(container.id))
                                .textFieldStyle(.roundedBorder)
                        }
                        inspectorField("RA (hours)") {
                            DoubleField(value: bindTargetRA(container.id), fractionDigits: 4)
                                .frame(width: 100)
                        }
                        inspectorField("Dec (deg)") {
                            DoubleField(value: bindTargetDec(container.id), fractionDigits: 4)
                                .frame(width: 100)
                        }
                        inspectorField("Tracking") {
                            Picker("", selection: bindTrackingRate(container.id)) {
                                ForEach(TrackingRate.allCases, id: \.self) { rate in
                                    Text(rate.label).tag(rate)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 120)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // Conditions
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Conditions (loop control)")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Menu {
                            ForEach(SequenceCondition.allTypes, id: \.type) { item in
                                Button(item.label) {
                                    addCondition(to: container.id, type: item.type, params: item.defaultParams)
                                }
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                    if container.conditions.isEmpty {
                        Text("No conditions — runs once")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(container.conditions.enumerated()), id: \.element.id) { idx, condition in
                            conditionRow(condition, containerId: container.id, index: idx)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // Triggers
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Triggers (reactive)")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Menu {
                            Button("Meridian Flip") { addTrigger(to: container.id, type: "meridian_flip", params: ["minutes_past_meridian": .int(5)]) }
                            Button("Autofocus Interval") { addTrigger(to: container.id, type: "autofocus_interval", params: ["every_n_frames": .int(30)]) }
                            Button("Autofocus on Filter Change") { addTrigger(to: container.id, type: "autofocus_on_filter_change", params: [:]) }
                            Button("Guide Deviation Pause") { addTrigger(to: container.id, type: "guide_deviation_pause", params: ["max_rms_arcsec": .double(2.0)]) }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                    if container.triggers.isEmpty {
                        Text("No triggers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(container.triggers.enumerated()), id: \.element.id) { idx, trigger in
                            triggerRow(trigger, containerId: container.id, index: idx)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func conditionRow(_ condition: SequenceCondition, containerId: UUID, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "repeat")
                    .foregroundStyle(.orange)
                Text(conditionDisplayName(condition.type))
                    .font(.callout.weight(.medium))
                Spacer()
                Toggle("", isOn: bindConditionEnabled(containerId, index: index))
                    .labelsHidden()
                    .controlSize(.small)
                Button(role: .destructive) {
                    removeCondition(from: containerId, at: index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
            conditionParamEditor(condition, containerId: containerId, index: index)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func conditionParamEditor(_ condition: SequenceCondition, containerId: UUID, index: Int) -> some View {
        switch condition.type {
        case SequenceCondition.loopCount:
            conditionIntParam(containerId, index: index, key: "count", label: "Iterations")
        case SequenceCondition.frameCount:
            conditionIntParam(containerId, index: index, key: "count", label: "Total frames")
        case SequenceCondition.timeElapsed:
            conditionIntParam(containerId, index: index, key: "minutes", label: "Minutes")
        case SequenceCondition.loopUntilTime:
            conditionStringParam(containerId, index: index, key: "utc_time", label: "UTC time (ISO 8601)")
        case SequenceCondition.loopUntilLocalTime:
            HStack(spacing: 4) {
                conditionIntParam(containerId, index: index, key: "hour", label: "Hour")
                conditionIntParam(containerId, index: index, key: "minute", label: "Min")
            }
        case SequenceCondition.targetAltitudeBelow:
            conditionIntParam(containerId, index: index, key: "min_altitude_deg", label: "Altitude (°)")
        case SequenceCondition.targetAltitudeAbove:
            conditionIntParam(containerId, index: index, key: "min_altitude_deg", label: "Altitude (°)")
        case SequenceCondition.sunAltitudeAbove:
            conditionIntParam(containerId, index: index, key: "altitude_deg", label: "Sun alt (°)")
        default:
            Text("No editable parameters")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func conditionIntParam(_ containerId: UUID, index: Int, key: String, label: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            IntField(label: "", value: bindConditionParam(containerId, index: index, key: key, default: .int(1)).intBinding)
                .frame(width: 80)
        }
    }

    private func conditionStringParam(_ containerId: UUID, index: Int, key: String, label: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            TextField("", text: bindConditionParam(containerId, index: index, key: key, default: .string("")).stringBinding)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func triggerRow(_ trigger: SequenceTrigger, containerId: UUID, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "bolt")
                    .foregroundStyle(.purple)
                Text(triggerDisplayName(trigger.type))
                    .font(.callout.weight(.medium))
                Spacer()
                Toggle("", isOn: bindTriggerEnabled(containerId, index: index))
                    .labelsHidden()
                    .controlSize(.small)
                Button(role: .destructive) {
                    removeTrigger(from: containerId, at: index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
            triggerParamEditor(trigger, containerId: containerId, index: index)
        }
        .padding(8)
        .background(.quaternary.opacity(0.3))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func triggerParamEditor(_ trigger: SequenceTrigger, containerId: UUID, index: Int) -> some View {
        switch trigger.type {
        case "meridian_flip":
            triggerIntParam(containerId, index: index, key: "minutes_past_meridian", label: "Minutes past meridian")
            triggerIntParam(containerId, index: index, key: "settle_time_sec", label: "Settle time (sec)")
        case "autofocus_interval":
            triggerIntParam(containerId, index: index, key: "every_n_frames", label: "Every N frames")
            triggerDoubleParam(containerId, index: index, key: "temp_change_c", label: "Temp change (°C)")
        case "autofocus_on_filter_change":
            Text("Triggers autofocus when filter changes")
                .font(.caption)
                .foregroundStyle(.secondary)
        case "guide_deviation_pause":
            triggerDoubleParam(containerId, index: index, key: "max_rms_arcsec", label: "Max RMS (arcsec)")
            triggerIntParam(containerId, index: index, key: "settle_time_sec", label: "Settle time (sec)")
        case "hfr_refocus":
            triggerDoubleParam(containerId, index: index, key: "hfr_threshold", label: "HFR threshold")
        case "error_recovery":
            triggerStringParam(containerId, index: index, key: "strategy", label: "Strategy (retry/skip/abort)")
            triggerIntParam(containerId, index: index, key: "max_retries", label: "Max retries")
        default:
            Text("No editable parameters")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func triggerIntParam(_ containerId: UUID, index: Int, key: String, label: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            IntField(label: "", value: bindTriggerParam(containerId, index: index, key: key, default: .int(0)).intBinding)
                .frame(width: 80)
        }
    }

    private func triggerDoubleParam(_ containerId: UUID, index: Int, key: String, label: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            DoubleField(value: bindTriggerParam(containerId, index: index, key: key, default: .double(0)).doubleBinding, fractionDigits: 1)
                .frame(width: 80)
        }
    }

    private func triggerStringParam(_ containerId: UUID, index: Int, key: String, label: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            TextField("", text: bindTriggerParam(containerId, index: index, key: key, default: .string("")).stringBinding)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: Instruction Inspector

    private func instructionInspector(_ instruction: SequenceInstruction) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(instructionDisplayName(instruction.type), systemImage: instructionIcon(instruction.type))
                .font(.headline)

            GroupBox("Properties") {
                VStack(alignment: .leading, spacing: 8) {
                    inspectorField("Type") {
                        Text(instruction.type)
                            .foregroundStyle(.secondary)
                    }
                    if let role = instruction.deviceRole {
                        inspectorField("Device") {
                            Text(role.replacingOccurrences(of: "_", with: " "))
                                .foregroundStyle(.secondary)
                        }
                    }
                    inspectorField("Enabled") {
                        Toggle("", isOn: bindInstructionEnabled(instruction.id))
                            .labelsHidden()
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Parameters") {
                VStack(alignment: .leading, spacing: 8) {
                    instructionParamEditor(instruction)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func instructionParamEditor(_ instruction: SequenceInstruction) -> some View {
        switch instruction.type {
        case SequenceInstruction.captureFrames:
            paramDouble(instruction.id, key: "exposure_sec", label: "Exposure (sec)", defaultVal: 60)
            paramInt(instruction.id, key: "count", label: "Frame Count", defaultVal: 10)
            paramInt(instruction.id, key: "gain", label: "Gain", defaultVal: 100)
            paramInt(instruction.id, key: "binning", label: "Binning", defaultVal: 1)
            paramString(instruction.id, key: "frame_type", label: "Frame Type", defaultVal: "light")
            paramFolderPicker(instruction.id, key: "save_folder", label: "Save Folder")

            Divider()
            paramBool(instruction.id, key: "dither_enabled", label: "Dither")
            if instruction.params["dither_enabled"]?.boolValue == true {
                paramDouble(instruction.id, key: "dither_pixels", label: "Dither Amount (px)", defaultVal: 5.0)
                paramInt(instruction.id, key: "dither_every_n", label: "Dither Every N Frames", defaultVal: 1)
                paramDouble(instruction.id, key: "dither_settle_sec", label: "Settle Time (sec)", defaultVal: 10.0)
            }

        case SequenceInstruction.switchFilter:
            filterPicker(instruction.id)

        case SequenceInstruction.centerTarget:
            paramInt(instruction.id, key: "attempts", label: "Max Attempts", defaultVal: 3)

        case SequenceInstruction.setCooler:
            paramBool(instruction.id, key: "enabled", label: "Cooler On")
            paramInt(instruction.id, key: "target_celsius", label: "Target (°C)", defaultVal: -10)
            paramDouble(instruction.id, key: "tolerance_c", label: "Tolerance (°C)", defaultVal: 1.0)
            paramInt(instruction.id, key: "timeout_sec", label: "Timeout (sec)", defaultVal: 600)

        case SequenceInstruction.waitTime:
            paramDouble(instruction.id, key: "seconds", label: "Wait (seconds)", defaultVal: 30)

        case SequenceInstruction.waitUntilTime:
            paramString(instruction.id, key: "utc_time", label: "UTC Time (ISO 8601)", defaultVal: "")

        case SequenceInstruction.waitUntilLocalTime:
            paramInt(instruction.id, key: "hour", label: "Hour (0-23)", defaultVal: 21)
            paramInt(instruction.id, key: "minute", label: "Minute (0-59)", defaultVal: 0)

        case SequenceInstruction.waitForAltitude:
            paramDouble(instruction.id, key: "min_altitude_deg", label: "Min Altitude (°)", defaultVal: 30)

        case SequenceInstruction.dither:
            paramDouble(instruction.id, key: "pixels", label: "Pixels", defaultVal: 5)
            paramDouble(instruction.id, key: "settle_time_sec", label: "Settle Time (sec)", defaultVal: 10)

        case SequenceInstruction.startTracking:
            paramInt(instruction.id, key: "rate", label: "Rate (0=sidereal)", defaultVal: 0)

        case SequenceInstruction.annotation:
            paramString(instruction.id, key: "message", label: "Message", defaultVal: "")

        case SequenceInstruction.runScript:
            paramString(instruction.id, key: "script_path", label: "Script Path", defaultVal: "")
            paramString(instruction.id, key: "args", label: "Arguments", defaultVal: "")

        case SequenceInstruction.moveFocuser:
            paramInt(instruction.id, key: "position", label: "Position", defaultVal: 0)

        case SequenceInstruction.autofocus:
            paramInt(instruction.id, key: "step_size", label: "Step Size", defaultVal: 100)
            paramInt(instruction.id, key: "num_steps", label: "Sample Points", defaultVal: 9)
            paramDouble(instruction.id, key: "exposure_sec", label: "Exposure (sec)", defaultVal: 3)
            paramInt(instruction.id, key: "backlash_steps", label: "Backlash Steps", defaultVal: 200)
            paramDouble(instruction.id, key: "settle_sec", label: "Settle Time (sec)", defaultVal: 2)
            paramInt(instruction.id, key: "min_stars", label: "Min Stars", defaultVal: 4)

        case SequenceInstruction.slewDome:
            paramDouble(instruction.id, key: "azimuth_deg", label: "Azimuth (°)", defaultVal: 0)

        case SequenceInstruction.moveRotator:
            paramDouble(instruction.id, key: "position_deg", label: "Position (°)", defaultVal: 0)
            paramBool(instruction.id, key: "relative", label: "Relative Move")

        case SequenceInstruction.setSwitch:
            paramInt(instruction.id, key: "switch_id", label: "Switch ID", defaultVal: 0)
            paramBool(instruction.id, key: "state", label: "State (On/Off)")
            paramDouble(instruction.id, key: "value", label: "Value (optional)", defaultVal: 0)

        case SequenceInstruction.calibratorOn:
            paramInt(instruction.id, key: "brightness", label: "Brightness", defaultVal: 100)

        case SequenceInstruction.waitForSafe:
            paramInt(instruction.id, key: "timeout_sec", label: "Timeout (sec)", defaultVal: 3600)

        default:
            // Generic key-value display for unknown types
            ForEach(Array(instruction.params.keys.sorted()), id: \.self) { key in
                inspectorField(key) {
                    Text(instruction.params[key]?.stringValue ?? "—")
                        .foregroundStyle(.secondary)
                }
            }
            if instruction.params.isEmpty {
                Text("No parameters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Param Editors

    private func paramDouble(_ instructionId: UUID, key: String, label: String, defaultVal: Double) -> some View {
        inspectorField(label) {
            DoubleField(value: bindInstructionParam(instructionId, key: key, default: .double(defaultVal)).doubleBinding)
                .frame(width: 100)
        }
    }

    private func paramInt(_ instructionId: UUID, key: String, label: String, defaultVal: Int) -> some View {
        inspectorField(label) {
            IntField(label: "", value: bindInstructionParam(instructionId, key: key, default: .int(defaultVal)).intBinding)
                .frame(width: 80)
        }
    }

    private func paramString(_ instructionId: UUID, key: String, label: String, defaultVal: String) -> some View {
        inspectorField(label) {
            TextField("", text: bindInstructionParam(instructionId, key: key, default: .string(defaultVal)).stringBinding)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func filterPicker(_ instructionId: UUID) -> some View {
        let posBinding = bindInstructionParam(instructionId, key: "filter_position", default: .int(0))
        let nameBinding = bindInstructionParam(instructionId, key: "filter_name", default: .string(""))
        let names = filterWheelViewModel.filterNames
        let savedName = nameBinding.stringBinding.wrappedValue
        let currentPos = posBinding.intBinding.wrappedValue

        // Check if saved filter name matches what's at the stored position
        let mismatch: Bool = {
            guard !names.isEmpty, !savedName.isEmpty else { return false }
            if currentPos < names.count {
                return names[currentPos] != savedName
            }
            return true  // position out of range
        }()

        return VStack(alignment: .leading, spacing: 4) {
            inspectorField("Filter") {
                if names.isEmpty {
                    // No filter wheel connected — show saved name + position stepper
                    HStack {
                        Text(savedName.isEmpty ? "Pos \(currentPos)" : savedName)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                        Spacer()
                        Stepper(
                            value: Binding(
                                get: { currentPos },
                                set: { newVal in
                                    posBinding.setValue(.int(newVal))
                                    mutateInstruction(id: instructionId) { $0.params["filter_name"] = .string("Filter \(newVal)") }
                                }
                            ),
                            in: 0...12
                        ) {
                            Text("\(currentPos)")
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                } else {
                    Picker("", selection: Binding(
                        get: { currentPos },
                        set: { newVal in
                            posBinding.setValue(.int(newVal))
                            let name = newVal < names.count ? names[newVal] : "Filter \(newVal)"
                            mutateInstruction(id: instructionId) { $0.params["filter_name"] = .string(name) }
                        }
                    )) {
                        ForEach(Array(names.enumerated()), id: \.offset) { idx, name in
                            Text("\(idx): \(name)").tag(idx)
                        }
                    }
                    .labelsHidden()
                }
            }
            if mismatch {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 10))
                    Text("Saved: \"\(savedName)\" — wheel has \"\(currentPos < names.count ? names[currentPos] : "?")\" at position \(currentPos)")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                }
            }
        }
    }

    private func paramBool(_ instructionId: UUID, key: String, label: String) -> some View {
        inspectorField(label) {
            Toggle("", isOn: bindInstructionParam(instructionId, key: key, default: .bool(false)).boolBinding)
                .labelsHidden()
        }
    }

    private func paramFolderPicker(_ instructionId: UUID, key: String, label: String) -> some View {
        let binding = bindInstructionParam(instructionId, key: key, default: .string(""))
        let currentPath = binding.stringBinding.wrappedValue
        return inspectorField(label) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("Use default from Settings", text: binding.stringBinding)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.prompt = "Select Folder"
                        if panel.runModal() == .OK, let url = panel.url {
                            binding.setValue(.string(url.path))
                        }
                    }
                    if !currentPath.isEmpty {
                        Button {
                            binding.setValue(.string(""))
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear — use default from Settings")
                    }
                }
                if currentPath.isEmpty {
                    Text("Using default folder from Settings")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: No Selection / Getting Started

    private var noSelectionView: some View {
        Text("No item selected")
            .foregroundStyle(.secondary)
    }

    private var gettingStartedView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Sequencer")
                .font(.title2)
            VStack(alignment: .leading, spacing: 8) {
                gettingStartedStep(number: 1, text: "Add a Deep Sky Object container with your target coordinates")
                gettingStartedStep(number: 2, text: "Add instructions: Slew, Start Guiding, Capture Frames")
                gettingStartedStep(number: 3, text: "Set conditions (loop count) and triggers (meridian flip)")
                gettingStartedStep(number: 4, text: "Press Run to execute the sequence")
            }
            .padding()
            Text("Or use AI Plan to auto-generate a sequence")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func gettingStartedStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.blue))
            Text(text)
                .font(.callout)
        }
    }

    // MARK: - Inspector Helpers

    private func inspectorField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.callout)
                .frame(width: 120, alignment: .trailing)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Execution Status

    private var executionStatus: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(engine.isRunning ? (engine.isPaused ? .yellow : .green) : .gray)
                    .frame(width: 10, height: 10)
                Text(engine.statusMessage)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()

                if engine.isRunning {
                    if engine.isPaused {
                        Button("Resume") { engine.resume() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Pause") { engine.pause() }
                            .buttonStyle(.bordered)
                    }
                    Button("Stop") { engine.stop() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                } else {
                    Button("Run") { engine.start(document: document) }
                        .buttonStyle(.borderedProminent)
                }
            }

            if engine.isRunning {
                HStack {
                    Text("Current: \(engine.currentInstruction)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Frames: \(engine.totalFramesCaptured)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.bar)
    }

    // MARK: - AI Planner Sheet

    private var aiPlannerSheet: some View {
        VStack(spacing: 16) {
            Text("AI Sequence Planner")
                .font(.title2)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Session duration:")
                        TextField("Hours", value: $aiSessionHours, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("hours")
                    }
                    HStack {
                        Text("Location:")
                        Text(String(format: "%.2f°N, %.2f°E", observerLat, observerLon))
                            .foregroundStyle(.secondary)
                    }
                    TextField("Additional notes (targets, constraints...)", text: $aiNotes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3)
                }
            }

            if planner.isPlanning {
                ProgressView(planner.statusMessage)
            }
            if let error = planner.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Button("Cancel") { showAIPlanner = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Generate") {
                    Task {
                        let llm = LLMService()
                        let provider = LLMProvider(rawValue: llmProviderRaw) ?? .claude
                        let doc = try? await planner.generateSequence(
                            llmService: llm,
                            provider: provider,
                            endpoint: llmApiEndpoint,
                            apiKey: llmApiKey,
                            model: llmModel,
                            deviceRoles: document.deviceRoles,
                            observerLat: observerLat,
                            observerLon: observerLon,
                            sessionDurationHours: aiSessionHours,
                            notes: aiNotes
                        )
                        if let doc {
                            document = doc
                            expandAllContainers(in: doc.rootContainer)
                        }
                        showAIPlanner = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(planner.isPlanning)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 450)
    }

    // MARK: - Data Model Mutation

    /// Add an item into the currently selected container, or root if nothing is selected.
    private func addItemToSelectedOrRoot(_ item: SequenceItem) {
        if let selectedId = selectedItemId,
           findContainer(id: selectedId, in: document.rootContainer) != nil {
            mutateContainer(id: selectedId) { $0.items.append(item) }
        } else {
            document.rootContainer.items.append(item)
        }
    }

    private func deleteItem(at path: [Int]) {
        guard !path.isEmpty else { return }
        mutateContainerAtParentPath(Array(path.dropLast())) { container in
            let idx = path.last!
            if idx < container.items.count {
                container.items.remove(at: idx)
            }
        }
    }

    private func duplicateItem(at path: [Int]) {
        guard !path.isEmpty else { return }
        mutateContainerAtParentPath(Array(path.dropLast())) { container in
            let idx = path.last!
            if idx < container.items.count {
                var copy = container.items[idx]
                copy = reassignIds(copy)
                container.items.insert(copy, at: idx + 1)
            }
        }
    }

    private func toggleEnabled(id: UUID) {
        if var container = findContainer(id: id, in: document.rootContainer) {
            container.enabled.toggle()
            mutateContainer(id: id) { $0.enabled = container.enabled }
        } else {
            mutateInstruction(id: id) { $0.enabled.toggle() }
        }
    }

    private func toggleEnabledLabel(for id: UUID) -> String {
        if let container = findContainer(id: id, in: document.rootContainer) {
            return container.enabled ? "Disable" : "Enable"
        } else if let instruction = findInstruction(id: id, in: document.rootContainer) {
            return instruction.enabled ? "Disable" : "Enable"
        }
        return "Toggle"
    }

    /// Recursively expand all containers in the tree.
    private func expandAllContainers(in container: SequenceContainer) {
        expandedContainers.insert(container.id)
        for item in container.items {
            if case .container(let child) = item {
                expandAllContainers(in: child)
            }
        }
    }

    private func addCondition(to containerId: UUID, type: String, params: [String: AnyCodableValue]) {
        let condition = SequenceCondition(type: type, params: params)
        mutateContainer(id: containerId) { $0.conditions.append(condition) }
    }

    private func removeCondition(from containerId: UUID, at index: Int) {
        mutateContainer(id: containerId) { $0.conditions.remove(at: index) }
    }

    private func addTrigger(to containerId: UUID, type: String, params: [String: AnyCodableValue]) {
        let trigger = SequenceTrigger(type: type, params: params)
        mutateContainer(id: containerId) { $0.triggers.append(trigger) }
    }

    private func removeTrigger(from containerId: UUID, at index: Int) {
        mutateContainer(id: containerId) { $0.triggers.remove(at: index) }
    }

    // MARK: Tree Traversal & Mutation

    private func findContainer(id: UUID, in container: SequenceContainer) -> SequenceContainer? {
        if container.id == id { return container }
        for item in container.items {
            if case .container(let child) = item,
               let found = findContainer(id: id, in: child) {
                return found
            }
        }
        return nil
    }

    private func findInstruction(id: UUID, in container: SequenceContainer) -> SequenceInstruction? {
        for item in container.items {
            switch item {
            case .instruction(let instr):
                if instr.id == id { return instr }
            case .container(let child):
                if let found = findInstruction(id: id, in: child) { return found }
            }
        }
        return nil
    }

    private func mutateContainer(id: UUID, _ transform: (inout SequenceContainer) -> Void) {
        mutateContainerRecursive(id: id, in: &document.rootContainer, transform)
    }

    @discardableResult
    private func mutateContainerRecursive(id: UUID, in container: inout SequenceContainer, _ transform: (inout SequenceContainer) -> Void) -> Bool {
        if container.id == id {
            transform(&container)
            return true
        }
        for i in container.items.indices {
            if case .container(var child) = container.items[i] {
                if mutateContainerRecursive(id: id, in: &child, transform) {
                    container.items[i] = .container(child)
                    return true
                }
            }
        }
        return false
    }

    private func mutateInstruction(id: UUID, _ transform: (inout SequenceInstruction) -> Void) {
        mutateInstructionRecursive(id: id, in: &document.rootContainer, transform)
    }

    @discardableResult
    private func mutateInstructionRecursive(id: UUID, in container: inout SequenceContainer, _ transform: (inout SequenceInstruction) -> Void) -> Bool {
        for i in container.items.indices {
            switch container.items[i] {
            case .instruction(var instr):
                if instr.id == id {
                    transform(&instr)
                    container.items[i] = .instruction(instr)
                    return true
                }
            case .container(var child):
                if mutateInstructionRecursive(id: id, in: &child, transform) {
                    container.items[i] = .container(child)
                    return true
                }
            }
        }
        return false
    }

    private func mutateContainerAtParentPath(_ parentPath: [Int], _ transform: (inout SequenceContainer) -> Void) {
        if parentPath.isEmpty {
            transform(&document.rootContainer)
        } else {
            func walk(_ container: inout SequenceContainer, path: ArraySlice<Int>) {
                guard let first = path.first else {
                    transform(&container)
                    return
                }
                if case .container(var child) = container.items[first] {
                    walk(&child, path: path.dropFirst())
                    container.items[first] = .container(child)
                }
            }
            walk(&document.rootContainer, path: parentPath[...])
        }
    }

    private func reassignIds(_ item: SequenceItem) -> SequenceItem {
        switch item {
        case .instruction(var instr):
            instr = SequenceInstruction(type: instr.type, deviceRole: instr.deviceRole, params: instr.params)
            return .instruction(instr)
        case .container(let cont):
            var newCont = SequenceContainer(name: cont.name, type: cont.type, target: cont.target,
                                           items: cont.items.map { reassignIds($0) },
                                           conditions: cont.conditions, triggers: cont.triggers)
            newCont.enabled = cont.enabled
            return .container(newCont)
        }
    }

    // MARK: - Bindings

    private func bindContainerName(_ id: UUID) -> Binding<String> {
        Binding(
            get: { findContainer(id: id, in: document.rootContainer)?.name ?? "" },
            set: { newVal in mutateContainer(id: id) { $0.name = newVal } }
        )
    }

    private func bindContainerType(_ id: UUID) -> Binding<ContainerType> {
        Binding(
            get: { findContainer(id: id, in: document.rootContainer)?.type ?? .sequential },
            set: { newVal in mutateContainer(id: id) { $0.type = newVal } }
        )
    }

    private func bindContainerEnabled(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { findContainer(id: id, in: document.rootContainer)?.enabled ?? true },
            set: { newVal in mutateContainer(id: id) { $0.enabled = newVal } }
        )
    }

    private func bindTargetName(_ id: UUID) -> Binding<String> {
        Binding(
            get: { findContainer(id: id, in: document.rootContainer)?.target?.name ?? "" },
            set: { newVal in mutateContainer(id: id) { c in
                if c.target == nil { c.target = TargetInfo(name: newVal, ra: 0, dec: 0) }
                else { c.target?.name = newVal }
            }}
        )
    }

    private func bindTargetRA(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { findContainer(id: id, in: document.rootContainer)?.target?.ra ?? 0 },
            set: { newVal in mutateContainer(id: id) { c in
                if c.target == nil { c.target = TargetInfo(name: "Target", ra: newVal, dec: 0) }
                else { c.target?.ra = newVal }
            }}
        )
    }

    private func bindTargetDec(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { findContainer(id: id, in: document.rootContainer)?.target?.dec ?? 0 },
            set: { newVal in mutateContainer(id: id) { c in
                if c.target == nil { c.target = TargetInfo(name: "Target", ra: 0, dec: newVal) }
                else { c.target?.dec = newVal }
            }}
        )
    }

    private func bindTrackingRate(_ id: UUID) -> Binding<TrackingRate> {
        Binding(
            get: { findContainer(id: id, in: document.rootContainer)?.target?.effectiveTrackingRate ?? .sidereal },
            set: { newVal in mutateContainer(id: id) { c in
                if c.target == nil { c.target = TargetInfo(name: "Target", ra: 0, dec: 0, trackingRate: newVal) }
                else { c.target?.trackingRate = newVal }
            }}
        )
    }

    private func bindInstructionEnabled(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { findInstruction(id: id, in: document.rootContainer)?.enabled ?? true },
            set: { newVal in mutateInstruction(id: id) { $0.enabled = newVal } }
        )
    }

    private func bindInstructionParam(_ id: UUID, key: String, default defaultVal: AnyCodableValue) -> ParamBinding {
        ParamBinding(
            getValue: { findInstruction(id: id, in: document.rootContainer)?.params[key] ?? defaultVal },
            setValue: { newVal in mutateInstruction(id: id) { $0.params[key] = newVal } }
        )
    }

    // Condition bindings

    private func bindConditionEnabled(_ containerId: UUID, index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let c = findContainer(id: containerId, in: document.rootContainer),
                      index < c.conditions.count else { return true }
                return c.conditions[index].enabled
            },
            set: { newVal in
                mutateContainer(id: containerId) { c in
                    if index < c.conditions.count { c.conditions[index].enabled = newVal }
                }
            }
        )
    }

    private func bindConditionParam(_ containerId: UUID, index: Int, key: String, default defaultVal: AnyCodableValue) -> ParamBinding {
        ParamBinding(
            getValue: {
                guard let c = findContainer(id: containerId, in: document.rootContainer),
                      index < c.conditions.count else { return defaultVal }
                return c.conditions[index].params[key] ?? defaultVal
            },
            setValue: { newVal in
                mutateContainer(id: containerId) { c in
                    if index < c.conditions.count { c.conditions[index].params[key] = newVal }
                }
            }
        )
    }

    // Trigger bindings

    private func bindTriggerEnabled(_ containerId: UUID, index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let c = findContainer(id: containerId, in: document.rootContainer),
                      index < c.triggers.count else { return true }
                return c.triggers[index].enabled
            },
            set: { newVal in
                mutateContainer(id: containerId) { c in
                    if index < c.triggers.count { c.triggers[index].enabled = newVal }
                }
            }
        )
    }

    private func bindTriggerParam(_ containerId: UUID, index: Int, key: String, default defaultVal: AnyCodableValue) -> ParamBinding {
        ParamBinding(
            getValue: {
                guard let c = findContainer(id: containerId, in: document.rootContainer),
                      index < c.triggers.count else { return defaultVal }
                return c.triggers[index].params[key] ?? defaultVal
            },
            setValue: { newVal in
                mutateContainer(id: containerId) { c in
                    if index < c.triggers.count { c.triggers[index].params[key] = newVal }
                }
            }
        )
    }

    // MARK: - File Actions

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "polarseq") ?? .json]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            if let doc = try? SequenceDocument.load(from: url) {
                document = doc
                selectedItemId = nil
                expandAllContainers(in: doc.rootContainer)
            }
        }
    }

    private func saveFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "polarseq") ?? .json]
        panel.nameFieldStringValue = "\(document.name).polarseq"
        if panel.runModal() == .OK, let url = panel.url {
            try? document.save(to: url)
        }
    }

    private func importFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        do {
            if ext == "esq" || ext == "xml" {
                document = try EkosImporter.importFile(from: url)
            } else {
                document = try NINAImporter.importFile(from: url)
            }
            selectedItemId = nil
            expandAllContainers(in: document.rootContainer)
        } catch {
            print("Import failed: \(error)")
        }
    }

    private func exportNINA() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(document.name).json"
        if panel.runModal() == .OK, let url = panel.url {
            try? NINAExporter.export(document: document, to: url)
        }
    }

    // MARK: - Default Params

    private func defaultParams(for type: String) -> [String: AnyCodableValue] {
        switch type {
        case SequenceInstruction.captureFrames:
            return ["exposure_sec": .double(120), "count": .int(10), "dither_enabled": .bool(false)]
        case SequenceInstruction.switchFilter:
            let name = filterWheelViewModel.filterNames.first ?? "Filter 0"
            return ["filter_position": .int(0), "filter_name": .string(name)]
        case SequenceInstruction.centerTarget:
            return ["attempts": .int(3)]
        case SequenceInstruction.setCooler:
            return ["enabled": .bool(true), "target_celsius": .int(-10)]
        case SequenceInstruction.waitTime:
            return ["seconds": .double(30)]
        case SequenceInstruction.dither:
            return ["pixels": .double(5), "settle_time_sec": .double(10)]
        case SequenceInstruction.startTracking:
            return ["rate": .int(0)]
        case SequenceInstruction.annotation:
            return ["message": .string("")]
        case SequenceInstruction.moveFocuser:
            return ["position": .int(5000)]
        case SequenceInstruction.autofocus:
            return ["step_size": .int(100), "num_steps": .int(9), "exposure_sec": .double(3), "backlash_steps": .int(200), "settle_sec": .double(2), "min_stars": .int(4)]
        case SequenceInstruction.slewDome:
            return ["azimuth_deg": .double(0)]
        case SequenceInstruction.moveRotator:
            return ["position_deg": .double(0), "relative": .bool(false)]
        case SequenceInstruction.setSwitch:
            return ["switch_id": .int(0), "state": .bool(false)]
        case SequenceInstruction.calibratorOn:
            return ["brightness": .int(100)]
        case SequenceInstruction.waitForSafe:
            return ["timeout_sec": .int(3600)]
        default:
            return [:]
        }
    }

    // MARK: - Display Names

    private func instructionDisplayName(_ type: String) -> String {
        let names: [String: String] = [
            SequenceInstruction.slewToTarget: "Slew to Target",
            SequenceInstruction.centerTarget: "Center Target",
            SequenceInstruction.parkMount: "Park Mount",
            SequenceInstruction.unparkMount: "Unpark Mount",
            SequenceInstruction.goHome: "Go Home",
            SequenceInstruction.startTracking: "Start Tracking",
            SequenceInstruction.captureFrames: "Capture Frames",
            SequenceInstruction.setCooler: "Set Cooler",
            SequenceInstruction.warmup: "Warm Up Camera",
            SequenceInstruction.switchFilter: "Switch Filter",
            SequenceInstruction.startGuiding: "Start Guiding",
            SequenceInstruction.stopGuiding: "Stop Guiding",
            SequenceInstruction.dither: "Dither",
            SequenceInstruction.plateSolve: "Plate Solve",
            SequenceInstruction.waitTime: "Wait (Duration)",
            SequenceInstruction.waitUntilTime: "Wait Until Time (UTC)",
            SequenceInstruction.waitUntilLocalTime: "Wait Until Local Time",
            SequenceInstruction.waitForAltitude: "Wait for Altitude",
            SequenceInstruction.annotation: "Annotation",
            SequenceInstruction.runScript: "Run Script",
            SequenceInstruction.moveFocuser: "Move Focuser",
            SequenceInstruction.haltFocuser: "Halt Focuser",
            SequenceInstruction.autofocus: "Autofocus",
            SequenceInstruction.slewDome: "Slew Dome",
            SequenceInstruction.openShutter: "Open Shutter",
            SequenceInstruction.closeShutter: "Close Shutter",
            SequenceInstruction.parkDome: "Park Dome",
            SequenceInstruction.homeDome: "Home Dome",
            SequenceInstruction.moveRotator: "Move Rotator",
            SequenceInstruction.setSwitch: "Set Switch",
            SequenceInstruction.openCover: "Open Cover",
            SequenceInstruction.closeCover: "Close Cover",
            SequenceInstruction.calibratorOn: "Calibrator On",
            SequenceInstruction.calibratorOff: "Calibrator Off",
            SequenceInstruction.waitForSafe: "Wait for Safe",
            SequenceInstruction.logWeather: "Log Weather",
        ]
        return names[type] ?? type.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func conditionDisplayName(_ type: String) -> String {
        if let entry = SequenceCondition.allTypes.first(where: { $0.type == type }) {
            return entry.label
        }
        return type
    }

    private func conditionSummary(_ condition: SequenceCondition) -> String {
        switch condition.type {
        case SequenceCondition.loopCount:
            return "Stop after \(condition.params["count"]?.intValue ?? 0) iterations"
        case SequenceCondition.frameCount:
            return "Stop after \(condition.params["count"]?.intValue ?? 0) frames"
        case SequenceCondition.timeElapsed:
            let min = condition.params["minutes"]?.intValue ?? condition.params["seconds"]?.intValue ?? 0
            return "Stop after \(min) min"
        case SequenceCondition.loopUntilTime:
            return condition.params["utc_time"]?.stringValue ?? "Set time..."
        case SequenceCondition.loopUntilLocalTime:
            let h = condition.params["hour"]?.intValue ?? 0
            let m = condition.params["minute"]?.intValue ?? 0
            return String(format: "Until %02d:%02d", h, m)
        case SequenceCondition.targetAltitudeBelow:
            return "Target below \(condition.params["min_altitude_deg"]?.intValue ?? 30)°"
        case SequenceCondition.targetAltitudeAbove:
            return "Target above \(condition.params["min_altitude_deg"]?.intValue ?? 30)°"
        case SequenceCondition.sunAltitudeAbove:
            return "Sun above \(condition.params["altitude_deg"]?.intValue ?? -12)°"
        default: return ""
        }
    }

    private func triggerDisplayName(_ type: String) -> String {
        let names: [String: String] = [
            "meridian_flip": "Meridian Flip",
            "autofocus_interval": "Autofocus Interval",
            "autofocus_on_filter_change": "Autofocus on Filter Change",
            "guide_deviation_pause": "Guide Deviation Pause",
            "hfr_refocus": "HFR Refocus",
            "error_recovery": "Error Recovery",
        ]
        return names[type] ?? type
    }

    private func triggerSummary(_ trigger: SequenceTrigger) -> String {
        switch trigger.type {
        case "meridian_flip": return "\(trigger.params["minutes_past_meridian"]?.intValue ?? 5) min past meridian"
        case "autofocus_interval": return "Every \(trigger.params["every_n_frames"]?.intValue ?? 30) frames"
        case "autofocus_on_filter_change": return "On filter change"
        case "guide_deviation_pause": return "RMS > \(trigger.params["max_rms_arcsec"]?.doubleValue ?? 2.0)\""
        default: return ""
        }
    }

    // MARK: - Icons & Colors

    private func containerIcon(_ type: ContainerType) -> String {
        switch type {
        case .sequential: return "list.number"
        case .parallel: return "arrow.triangle.branch"
        case .deepSkyObject: return "star.circle"
        }
    }

    private func containerColor(_ type: ContainerType) -> Color {
        switch type {
        case .sequential: return .primary
        case .parallel: return .orange
        case .deepSkyObject: return .yellow
        }
    }

    private func instructionIcon(_ type: String) -> String {
        switch type {
        case SequenceInstruction.captureFrames: return "camera"
        case SequenceInstruction.slewToTarget, SequenceInstruction.centerTarget: return "scope"
        case SequenceInstruction.startGuiding, SequenceInstruction.stopGuiding: return "target"
        case SequenceInstruction.switchFilter: return "circle.grid.cross"
        case SequenceInstruction.parkMount: return "moon.zzz"
        case SequenceInstruction.unparkMount: return "sunrise"
        case SequenceInstruction.goHome: return "house"
        case SequenceInstruction.waitTime, SequenceInstruction.waitUntilTime, SequenceInstruction.waitUntilLocalTime: return "clock"
        case SequenceInstruction.waitForAltitude: return "mountain.2"
        case SequenceInstruction.dither: return "arrow.up.and.down.and.arrow.left.and.right"
        case SequenceInstruction.plateSolve: return "sparkle.magnifyingglass"
        case SequenceInstruction.setCooler: return "thermometer.snowflake"
        case SequenceInstruction.warmup: return "thermometer.sun"
        case SequenceInstruction.startTracking: return "rotate.right"
        case SequenceInstruction.annotation: return "text.bubble"
        case SequenceInstruction.runScript: return "terminal"
        case SequenceInstruction.moveFocuser: return "arrow.up.arrow.down"
        case SequenceInstruction.haltFocuser: return "stop.circle"
        case SequenceInstruction.autofocus: return "scope"
        case SequenceInstruction.slewDome: return "circle.dashed"
        case SequenceInstruction.openShutter: return "rectangle.portrait.arrowtriangle.2.outward"
        case SequenceInstruction.closeShutter: return "rectangle.portrait.arrowtriangle.2.inward"
        case SequenceInstruction.parkDome: return "moon.zzz"
        case SequenceInstruction.homeDome: return "house"
        case SequenceInstruction.moveRotator: return "arrow.triangle.2.circlepath"
        case SequenceInstruction.setSwitch: return "switch.2"
        case SequenceInstruction.openCover: return "rectangle.portrait.arrowtriangle.2.outward"
        case SequenceInstruction.closeCover: return "rectangle.portrait.arrowtriangle.2.inward"
        case SequenceInstruction.calibratorOn: return "lightbulb.max"
        case SequenceInstruction.calibratorOff: return "lightbulb.slash"
        case SequenceInstruction.waitForSafe: return "shield.checkered"
        case SequenceInstruction.logWeather: return "cloud.sun"
        default: return "gearshape"
        }
    }

    private func instructionSummary(_ instruction: SequenceInstruction) -> String? {
        switch instruction.type {
        case SequenceInstruction.captureFrames:
            let exp = instruction.params["exposure_sec"]?.doubleValue ?? 0
            let count = instruction.params["count"]?.intValue ?? 0
            let ditherOn = instruction.params["dither_enabled"]?.boolValue ?? false
            var s = "\(count)x \(Int(exp))s"
            if ditherOn {
                let px = instruction.params["dither_pixels"]?.doubleValue ?? 5.0
                s += ", dither \(Int(px))px"
            }
            return s
        case SequenceInstruction.switchFilter:
            return instruction.params["filter_name"]?.stringValue
        case SequenceInstruction.waitTime:
            let sec = instruction.params["seconds"]?.doubleValue ?? 0
            return "\(Int(sec))s"
        case SequenceInstruction.dither:
            let px = instruction.params["pixels"]?.doubleValue ?? 5
            return "\(Int(px))px"
        case SequenceInstruction.setCooler:
            let temp = instruction.params["target_celsius"]?.intValue ?? 0
            return "\(temp)°C"
        case SequenceInstruction.annotation:
            return instruction.params["message"]?.stringValue
        case SequenceInstruction.centerTarget:
            let attempts = instruction.params["attempts"]?.intValue ?? 3
            return "\(attempts) attempts"
        case SequenceInstruction.moveFocuser:
            let pos = instruction.params["position"]?.intValue ?? 0
            return "Position \(pos)"
        case SequenceInstruction.autofocus:
            let steps = instruction.params["num_steps"]?.intValue ?? 9
            let stepSize = instruction.params["step_size"]?.intValue ?? 100
            return "\(steps)pts x\(stepSize)"
        case SequenceInstruction.slewDome:
            let az = instruction.params["azimuth_deg"]?.doubleValue ?? 0
            return "\(Int(az))°"
        case SequenceInstruction.moveRotator:
            let pos = instruction.params["position_deg"]?.doubleValue ?? 0
            let rel = instruction.params["relative"]?.boolValue ?? false
            return "\(Int(pos))°\(rel ? " relative" : "")"
        case SequenceInstruction.setSwitch:
            let id = instruction.params["switch_id"]?.intValue ?? 0
            return "Switch #\(id)"
        case SequenceInstruction.calibratorOn:
            let b = instruction.params["brightness"]?.intValue ?? 0
            return "Brightness \(b)"
        case SequenceInstruction.waitForSafe:
            let t = instruction.params["timeout_sec"]?.intValue ?? 3600
            return "Timeout \(t)s"
        default:
            return nil
        }
    }
}

// MARK: - ParamBinding Helper

/// Helper to create typed bindings from AnyCodableValue for inspector param editors.
struct ParamBinding {
    let getValue: () -> AnyCodableValue
    let setValue: (AnyCodableValue) -> Void

    var doubleBinding: Binding<Double> {
        Binding(
            get: { getValue().doubleValue ?? 0 },
            set: { setValue(.double($0)) }
        )
    }

    var intBinding: Binding<Int> {
        Binding(
            get: { getValue().intValue ?? 0 },
            set: { setValue(.int($0)) }
        )
    }

    var stringBinding: Binding<String> {
        Binding(
            get: { getValue().stringValue ?? "" },
            set: { setValue(.string($0)) }
        )
    }

    var boolBinding: Binding<Bool> {
        Binding(
            get: { getValue().boolValue ?? false },
            set: { setValue(.bool($0)) }
        )
    }
}

// MARK: - Commit-on-Enter Number Fields

/// Integer text field that keeps a local editing string and only commits
/// the parsed value on Enter / focus loss — so you can freely clear and
/// retype without the value snapping back.
struct IntField: View {
    let label: String
    @Binding var value: Int
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(label, text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onAppear { text = "\(value)" }
            .onChange(of: value) { _, newVal in
                if !isFocused { text = "\(newVal)" }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onSubmit { commit() }
    }

    private func commit() {
        if let parsed = Int(text) {
            value = parsed
        } else {
            text = "\(value)"
        }
    }
}

/// Double text field with the same commit-on-finish behaviour.
struct DoubleField: View {
    let label: String
    let fractionDigits: Int
    @Binding var value: Double
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    init(label: String = "", value: Binding<Double>, fractionDigits: Int = 2) {
        self.label = label
        self._value = value
        self.fractionDigits = fractionDigits
    }

    var body: some View {
        TextField(label, text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onAppear { text = formatted(value) }
            .onChange(of: value) { _, newVal in
                if !isFocused { text = formatted(newVal) }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onSubmit { commit() }
    }

    private func commit() {
        // Accept both dot and comma as decimal separator
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        if let parsed = Double(normalized) {
            value = parsed
        } else {
            text = formatted(value)
        }
    }

    private func formatted(_ v: Double) -> String {
        String(format: "%.\(fractionDigits)f", v)
    }
}

// MARK: - Drag & Drop Delegates

/// Drop delegate for reordering: dropping ON an instruction/container reorders relative to it
/// (inserts before the target item in the same parent).
struct ReorderDropDelegate: DropDelegate {
    let targetId: UUID
    @Binding var draggedItemId: UUID?
    @Binding var dropTargetId: UUID?
    @Binding var dropInsideContainer: Bool
    @Binding var document: SequenceDocument

    func dropEntered(info: DropInfo) {
        guard let dragId = draggedItemId, dragId != targetId else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            dropTargetId = targetId
            dropInsideContainer = false
        }
    }

    func dropExited(info: DropInfo) {
        if dropTargetId == targetId {
            withAnimation(.easeInOut(duration: 0.15)) {
                dropTargetId = nil
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let dragId = draggedItemId, dragId != targetId else { return false }
        // Don't allow dropping a container onto its own descendant
        if let item = SequenceTreeHelper.findItem(id: dragId, in: document.rootContainer),
           case .container(let dragContainer) = item,
           SequenceTreeHelper.isDescendant(targetId, of: dragContainer) {
            return false
        }
        return true
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragId = draggedItemId, dragId != targetId else { return false }
        // Find where the target lives
        guard let (parentPath, targetIndex) = SequenceTreeHelper.findItemLocation(id: targetId, in: document.rootContainer) else {
            return false
        }
        // Remove the dragged item from the tree
        guard let draggedItem = SequenceTreeHelper.removeItem(id: dragId, from: &document.rootContainer) else {
            return false
        }
        // Insert before the target in the same parent
        SequenceTreeHelper.insertItem(draggedItem, inContainerAt: parentPath, at: targetIndex, in: &document.rootContainer)
        draggedItemId = nil
        dropTargetId = nil
        return true
    }
}

/// Drop delegate for containers: dropping onto a container inserts the item at the end of that container.
struct ContainerDropDelegate: DropDelegate {
    let containerId: UUID
    @Binding var draggedItemId: UUID?
    @Binding var dropTargetId: UUID?
    @Binding var dropInsideContainer: Bool
    @Binding var document: SequenceDocument

    func dropEntered(info: DropInfo) {
        guard let dragId = draggedItemId, dragId != containerId else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            dropTargetId = containerId
            dropInsideContainer = true
        }
    }

    func dropExited(info: DropInfo) {
        if dropTargetId == containerId {
            withAnimation(.easeInOut(duration: 0.15)) {
                dropTargetId = nil
                dropInsideContainer = false
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        guard let dragId = draggedItemId, dragId != containerId else { return false }
        // Don't allow dropping a container into itself or its descendants
        if let item = SequenceTreeHelper.findItem(id: dragId, in: document.rootContainer),
           case .container(let dragContainer) = item,
           (dragContainer.id == containerId || SequenceTreeHelper.isDescendant(containerId, of: dragContainer)) {
            return false
        }
        return true
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let dragId = draggedItemId, dragId != containerId else { return false }
        // Remove the dragged item from the tree
        guard let draggedItem = SequenceTreeHelper.removeItem(id: dragId, from: &document.rootContainer) else {
            return false
        }
        // Insert at end of target container
        SequenceTreeHelper.appendItem(draggedItem, toContainerId: containerId, in: &document.rootContainer)
        draggedItemId = nil
        dropTargetId = nil
        dropInsideContainer = false
        return true
    }
}

// MARK: - Tree Manipulation Helpers

enum SequenceTreeHelper {
    /// Find an item by ID in the tree.
    static func findItem(id: UUID, in container: SequenceContainer) -> SequenceItem? {
        if container.id == id { return .container(container) }
        for item in container.items {
            switch item {
            case .container(let child):
                if child.id == id { return item }
                if let found = findItem(id: id, in: child) { return found }
            case .instruction(let instr):
                if instr.id == id { return item }
            }
        }
        return nil
    }

    /// Check if `targetId` is a descendant of `container`.
    static func isDescendant(_ targetId: UUID, of container: SequenceContainer) -> Bool {
        for item in container.items {
            switch item {
            case .container(let child):
                if child.id == targetId { return true }
                if isDescendant(targetId, of: child) { return true }
            case .instruction(let instr):
                if instr.id == targetId { return true }
            }
        }
        return false
    }

    /// Find the parent path (indices from root) and index of an item by its ID.
    /// Returns (parentPath, indexInParent).
    static func findItemLocation(id: UUID, in root: SequenceContainer, currentPath: [Int] = []) -> ([Int], Int)? {
        for (index, item) in root.items.enumerated() {
            if item.id == id {
                return (currentPath, index)
            }
            if case .container(let child) = item {
                if let result = findItemLocation(id: id, in: child, currentPath: currentPath + [index]) {
                    return result
                }
            }
        }
        return nil
    }

    /// Remove an item by ID from the tree. Returns the removed item.
    @discardableResult
    static func removeItem(id: UUID, from container: inout SequenceContainer) -> SequenceItem? {
        for i in container.items.indices {
            if container.items[i].id == id {
                return container.items.remove(at: i)
            }
            if case .container(var child) = container.items[i] {
                if let removed = removeItem(id: id, from: &child) {
                    container.items[i] = .container(child)
                    return removed
                }
            }
        }
        return nil
    }

    /// Insert an item into the container found by walking the path, at the given index.
    static func insertItem(_ item: SequenceItem, inContainerAt path: [Int], at index: Int, in root: inout SequenceContainer) {
        if path.isEmpty {
            let safeIndex = min(index, root.items.count)
            root.items.insert(item, at: safeIndex)
            return
        }
        let first = path[0]
        guard first < root.items.count, case .container(var child) = root.items[first] else { return }
        insertItem(item, inContainerAt: Array(path.dropFirst()), at: index, in: &child)
        root.items[first] = .container(child)
    }

    /// Append an item to a container found by ID.
    static func appendItem(_ item: SequenceItem, toContainerId id: UUID, in container: inout SequenceContainer) {
        if container.id == id {
            container.items.append(item)
            return
        }
        for i in container.items.indices {
            if case .container(var child) = container.items[i] {
                appendItem(item, toContainerId: id, in: &child)
                container.items[i] = .container(child)
            }
        }
    }
}
