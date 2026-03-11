import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: String? = "alignment"

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                NavigationLink("Alignment", value: "alignment")
                NavigationLink("Adjustment", value: "adjustment")
                NavigationLink("Mount", value: "mount")
                NavigationLink("Camera", value: "camera")
                NavigationLink("Settings", value: "settings")
            }
            .navigationTitle("PolarAligner")
        } detail: {
            switch selectedTab {
            case "alignment":
                AlignmentView(
                    coordinator: appState.alignmentCoordinator,
                    cameraViewModel: appState.cameraViewModel,
                    selectedTab: $selectedTab
                )
            case "adjustment":
                AdjustmentView(errorTracker: appState.errorTracker)
            case "mount":
                MountTabView(
                    mountService: appState.mountService,
                    plateSolveService: appState.plateSolveService
                )
            case "camera":
                CameraTabView(viewModel: appState.cameraViewModel)
            case "settings":
                SettingsView(
                    mountService: appState.mountService,
                    plateSolveService: appState.plateSolveService,
                    coordinator: appState.alignmentCoordinator,
                    cameraViewModel: appState.cameraViewModel
                )
            default:
                Text("Select a tab")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
