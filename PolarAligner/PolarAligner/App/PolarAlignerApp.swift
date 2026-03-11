import SwiftUI

@main
struct PolarAlignerApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("starCatalogPath") private var starCatalogPath: String = ""

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .task {
                    await autoLoadCatalog()
                }
        }
        .defaultSize(width: 1200, height: 800)
    }

    private func autoLoadCatalog() async {
        // Load from saved path if set
        if !starCatalogPath.isEmpty {
            do {
                try await appState.plateSolveService.loadDatabase(from: starCatalogPath)
                return
            } catch {
                print("Failed to load star catalog from \(starCatalogPath): \(error)")
            }
        }
        // Try bundled database as fallback
        do {
            try await appState.plateSolveService.loadBundledDatabase()
        } catch {
            print("No star catalog loaded — set path in Settings")
        }
    }
}
