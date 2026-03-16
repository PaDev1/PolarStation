import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: String? = "alignment"

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                NavigationLink("Polar Alignment", value: "alignment")
                NavigationLink("Framing", value: "mount")
                NavigationLink("Camera", value: "camera")
                NavigationLink("Guide Camera", value: "guide")
                NavigationLink("Sequencer", value: "sequencer")
                NavigationLink("Settings", value: "settings")
            }
            .navigationTitle("PolarStation")
        } detail: {
            Group {
                switch selectedTab {
                case "alignment":
                    PolarAlignmentView(
                        coordinator: appState.alignmentCoordinator,
                        cameraViewModel: appState.cameraViewModel,
                        engine: appState.simulatedAlignmentEngine,
                        plateSolveService: appState.plateSolveService,
                        errorTracker: appState.errorTracker
                    )
                case "mount":
                    MountTabView(
                        mountService: appState.mountService,
                        plateSolveService: appState.plateSolveService,
                        sequenceDocument: $appState.sequenceDocument,
                        onSwitchToSequencer: { selectedTab = "sequencer" },
                        skyMapVM: appState.skyMapViewModel,
                        vm: appState.mountTabViewModel,
                        centeringSolveService: appState.centeringSolveService,
                        cameraViewModel: appState.cameraViewModel,
                        assistantVM: appState.assistantViewModel,
                        assistantWindowController: appState.assistantWindowController
                    )
                case "camera":
                    CameraTabView(mainCamera: appState.cameraViewModel, guideCamera: appState.guideCameraViewModel)
                case "guide":
                    GuideTabView(
                        cameraViewModel: appState.guideCameraViewModel,
                        calibrator: appState.guideCalibrator,
                        session: appState.guideSession,
                        mountService: appState.mountService,
                        simulatedGuideEngine: appState.simulatedGuideEngine
                    )
                case "sequencer":
                    SequencerView(
                        engine: appState.sequenceEngine,
                        filterWheelViewModel: appState.filterWheelViewModel,
                        document: $appState.sequenceDocument,
                        selectedItemId: $appState.sequenceSelectedItemId
                    )
                case "settings":
                    SettingsView(
                        mountService: appState.mountService,
                        plateSolveService: appState.plateSolveService,
                        coordinator: appState.alignmentCoordinator,
                        cameraViewModel: appState.cameraViewModel,
                        guideCameraViewModel: appState.guideCameraViewModel,
                        filterWheelViewModel: appState.filterWheelViewModel,
                        focuserViewModel: appState.focuserViewModel,
                        domeViewModel: appState.domeViewModel,
                        rotatorViewModel: appState.rotatorViewModel,
                        switchViewModel: appState.switchViewModel,
                        safetyMonitorViewModel: appState.safetyMonitorViewModel,
                        observingConditionsViewModel: appState.observingConditionsViewModel,
                        coverCalibratorViewModel: appState.coverCalibratorViewModel
                    )
                default:
                    Text("Select a tab")
                        .foregroundStyle(.secondary)
                }
            }
            // Force complete attribute graph teardown on tab switch.
            // Without this, SwiftUI accumulates internal graph nodes across
            // tab transitions, causing exponential layout cost over time.
            .id(selectedTab)
        }
    }

}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
