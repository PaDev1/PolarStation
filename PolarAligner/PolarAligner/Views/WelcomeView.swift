import SwiftUI
import PolarCore

struct WelcomeView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("starCatalogPath") private var starCatalogPath: String = ""
    @Binding var showWelcome: Bool

    @State private var selectedDensity: Double = 9.0
    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var statusMessage: String = ""
    @State private var errorMessage: String?

    private static var dataDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PolarStation")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var body: some View {
        ZStack {
            // Background — replace with an image later:
            // Image("welcome_bg").resizable().scaledToFill().ignoresSafeArea()
            Color.black.ignoresSafeArea()

            welcomeContent
        }
    }

    private var welcomeContent: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("PolarStation")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(.white)

            Text("To get started, PolarStation needs to download a star catalog from ESA's Gaia archive.\nThis is used for plate solving, sky map display, and simulated alignment.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 500)

            Divider().frame(maxWidth: 400)

            VStack(spacing: 12) {
                HStack {
                    Text("Star density")
                    Picker("", selection: $selectedDensity) {
                        Text("Low — mag\u{2264}7 (15K stars, ~50 MB, fast)").tag(7.0)
                        Text("Medium — mag\u{2264}8 (63K stars, ~480 MB)").tag(8.0)
                        Text("High — mag\u{2264}9 (177K stars, ~1.5 GB, recommended)").tag(9.0)
                    }
                    .frame(maxWidth: 380)
                }

                if isWorking {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress)
                            .tint(progress > 0.4 ? .green : .blue)
                            .frame(maxWidth: 400)
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 400)
                }

                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: 400)
                }
            }

            HStack(spacing: 16) {
                Button("Download & Setup") {
                    downloadAndGenerate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking)

                Button("Load Existing...") {
                    loadExisting()
                }
                .disabled(isWorking)
            }

            Text("You can change the catalog later in Settings.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(40)
        .frame(minWidth: 600, minHeight: 450)
    }

    private func loadExisting() {
        let panel = NSOpenPanel()
        panel.title = "Select Star Catalog Database"
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.dataDir
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await appState.plateSolveService.loadDatabase(from: url.path)
                    starCatalogPath = url.path
                    showWelcome = false
                } catch {
                    errorMessage = "Failed to load: \(error.localizedDescription)"
                }
            }
        }
    }

    private func downloadAndGenerate() {
        isWorking = true
        progress = 0
        statusMessage = "Querying Gaia DR3 archive..."
        errorMessage = nil

        let mag = selectedDensity
        let destDir = Self.dataDir
        let csvPath = destDir.appendingPathComponent("gaia_dr3_mag\(String(format: "%.1f", mag)).csv")
        let hipPath = destDir.appendingPathComponent("gaia_as_hip2.dat")
        let dbPath = destDir.appendingPathComponent("star_catalog.rkyv")

        Task.detached {
            do {
                // Check if CSV already downloaded
                let csvExists = FileManager.default.fileExists(atPath: csvPath.path)
                if csvExists {
                    await MainActor.run {
                        progress = 0.35
                        statusMessage = "Using cached Gaia catalog..."
                    }
                } else {
                    // Download from Gaia TAP
                    let query = "SELECT source_id,ra,dec,pmra,pmdec,phot_g_mean_mag FROM gaiadr3.gaia_source WHERE phot_g_mean_mag < \(mag) ORDER BY phot_g_mean_mag"
                    var components = URLComponents(string: "https://gea.esac.esa.int/tap-server/tap/sync")!
                    components.queryItems = [
                        URLQueryItem(name: "REQUEST", value: "doQuery"),
                        URLQueryItem(name: "LANG", value: "ADQL"),
                        URLQueryItem(name: "FORMAT", value: "csv"),
                        URLQueryItem(name: "MAXREC", value: "5000000"),
                        URLQueryItem(name: "QUERY", value: query),
                    ]
                    guard let url = components.url else { throw NSError(domain: "PolarStation", code: -1, userInfo: [NSLocalizedDescriptionKey: "Bad URL"]) }

                    await MainActor.run { statusMessage = "Downloading Gaia DR3 mag\u{2264}\(String(format: "%.0f", mag))..." }

                    let (bytes, response) = try await URLSession.shared.bytes(from: url)
                    let totalSize = (response as? HTTPURLResponse)
                        .flatMap { Int($0.value(forHTTPHeaderField: "Content-Length") ?? "") } ?? 0

                    try? FileManager.default.removeItem(at: csvPath)
                    FileManager.default.createFile(atPath: csvPath.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: csvPath)

                    var downloaded = 0
                    var buffer = Data()
                    var lineCount = 0
                    let expectedStars: Double = mag <= 7 ? 15000 : mag <= 8 ? 63000 : 177000

                    for try await byte in bytes {
                        buffer.append(byte)
                        downloaded += 1
                        if byte == 0x0A { lineCount += 1 }

                        if buffer.count >= 64 * 1024 {
                            handle.write(buffer)
                            buffer.removeAll(keepingCapacity: true)
                            let stars = max(0, lineCount - 1)
                            let pct: Double
                            if totalSize > 0 {
                                pct = Double(downloaded) / Double(totalSize) * 0.35
                            } else {
                                pct = min(0.34, Double(stars) / expectedStars * 0.35)
                            }
                            await MainActor.run {
                                progress = pct
                                statusMessage = String(format: "Downloading... %.1f MB (%d stars)", Double(downloaded) / 1_048_576, stars)
                            }
                        }
                    }
                    if !buffer.isEmpty { handle.write(buffer) }
                    handle.closeFile()

                    await MainActor.run {
                        progress = 0.35
                        statusMessage = "Downloaded \(lineCount - 1) stars."
                    }
                }

                // Convert CSV to hip2.dat
                await MainActor.run {
                    progress = 0.4
                    statusMessage = "Converting to solver format..."
                }
                try SettingsView.gaiaCSVToHip2(csvPath: csvPath, hipPath: hipPath)

                // Generate database
                await MainActor.run {
                    progress = 0.5
                    statusMessage = "Generating pattern database (this takes a few minutes)..."
                }

                let solver = PlateSolver()
                let info = try solver.generateDatabase(
                    catalogPath: hipPath.path,
                    catalogType: "hipparcos",
                    outputPath: dbPath.path,
                    maxMagnitude: Double(mag),
                    minFovDeg: 0.5,
                    maxFovDeg: 5.0
                )

                // Load the database
                await MainActor.run {
                    progress = 0.9
                    statusMessage = "Loading database..."
                }

                try await appState.plateSolveService.loadDatabase(from: dbPath.path)

                await MainActor.run {
                    progress = 1.0
                    statusMessage = "Complete! \(info)"
                    starCatalogPath = dbPath.path
                    isWorking = false
                    // Dismiss welcome after short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        showWelcome = false
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed: \(error.localizedDescription)"
                    isWorking = false
                }
            }
        }
    }
}
