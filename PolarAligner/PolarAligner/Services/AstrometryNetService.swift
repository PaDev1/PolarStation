import Foundation
import PolarCore

/// Client for the Astrometry.net REST plate solving API.
///
/// Works with both nova.astrometry.net (remote, free account required) and any
/// local server that implements the same API — e.g. Watney (https://github.com/Jusas/WatneyAstrometry),
/// which runs on macOS and serves the same endpoints on localhost.
///
/// Flow:
///   1. login(apiKey:)  → session token
///   2. upload(jpeg:session:hints:) → submission ID
///   3. waitForCalibration(subid:session:) polls until solved
///   4. Returns SolveResult compatible with local tetra3 results
@MainActor
final class AstrometryNetService: ObservableObject {

    static let remoteBaseURL = "https://nova.astrometry.net/api"
    static let localDefaultBaseURL = "http://localhost:8080/api"

    /// Base URL for the API. Override to point at a local Watney server.
    var baseURL: String

    @Published var isSolving = false
    @Published var statusMessage = ""

    /// Optional callback — called on MainActor whenever statusMessage changes.
    /// Use this to forward progress messages to another service or view.
    var onStatusUpdate: ((String) -> Void)?

    init(baseURL: String = AstrometryNetService.remoteBaseURL) {
        self.baseURL = baseURL
    }

    // MARK: - Helpers

    private func setStatus(_ msg: String) {
        statusMessage = msg
        onStatusUpdate?(msg)
    }

    // MARK: - Public entry point

    /// Verify the API key by logging in. Throws on failure.
    func testLogin(apiKey: String) async throws {
        let _ = try await login(apiKey: apiKey)
    }

    /// Solve an image uploaded as JPEG data. Provide optional hints to speed up the solve.
    func solve(
        jpegData: Data,
        apiKey: String,
        hintRA: Double? = nil,
        hintDec: Double? = nil,
        hintRadiusDeg: Double? = nil,
        hintFovDeg: Double? = nil
    ) async throws -> SolveResult {
        isSolving = true
        defer { isSolving = false }

        setStatus("Logging in...")
        let session = try await login(apiKey: apiKey)

        setStatus("Uploading image...")
        let subid = try await upload(jpegData: jpegData, session: session,
                                     hintRA: hintRA, hintDec: hintDec,
                                     hintRadiusDeg: hintRadiusDeg, hintFovDeg: hintFovDeg)

        setStatus("Queued — waiting for solver (job \(subid))...")
        let calibration = try await waitForCalibration(subid: subid, session: session)

        setStatus(String(format: "Solved: RA %.4f° Dec %.3f°", calibration.ra, calibration.dec))
        return calibration.toSolveResult()
    }

    // MARK: - API steps

    private func login(apiKey: String) async throws -> String {
        let url = URL(string: "\(baseURL)/login")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = try jsonFormField(["apikey": apiKey])
        req.httpBody = "request-json=\(body)".data(using: .utf8)

        let data = try await URLSession.shared.data(for: req).0
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let status = json?["status"] as? String, status == "success",
              let sessionKey = json?["session"] as? String else {
            let msg = json?["errormessage"] as? String ?? "Login failed"
            throw AstrometryError.loginFailed(msg)
        }
        return sessionKey
    }

    private func upload(
        jpegData: Data,
        session: String,
        hintRA: Double?,
        hintDec: Double?,
        hintRadiusDeg: Double?,
        hintFovDeg: Double?
    ) async throws -> Int {
        let url = URL(string: "\(baseURL)/upload")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Build JSON options
        var opts: [String: Any] = ["session": session, "publicly_visible": "n"]
        if let ra = hintRA, let dec = hintDec, let r = hintRadiusDeg {
            opts["center_ra"] = ra
            opts["center_dec"] = dec
            opts["radius"] = r
        }
        if let fov = hintFovDeg {
            // Provide ±20% bounds around the expected FOV (in degrees)
            opts["scale_units"] = "degwidth"
            opts["scale_lower"] = fov * 0.8
            opts["scale_upper"] = fov * 1.2
            opts["scale_est"] = fov
            opts["scale_err"] = 20.0
        }

        // Multipart fields use raw JSON — NOT URL-encoded (that's only for x-www-form-urlencoded)
        let optsJSON = try jsonString(opts)

        var body = Data()
        // JSON options field
        body.appendMultipart(boundary: boundary, name: "request-json", value: optsJSON)
        // Image file field
        body.appendMultipartFile(boundary: boundary, name: "file", filename: "frame.jpg",
                                  mimeType: "image/jpeg", data: jpegData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let data = try await URLSession.shared.data(for: req).0
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let status = json?["status"] as? String, status == "success",
              let subid = json?["subid"] as? Int else {
            let msg = json?["errormessage"] as? String ?? "Upload failed"
            throw AstrometryError.uploadFailed(msg)
        }
        return subid
    }

    private func waitForCalibration(subid: Int, session: String) async throws -> AstrometryCalibration {
        // Poll submission until we have job IDs (up to 3 min)
        let jobID = try await pollUntilJob(subid: subid)
        setStatus("Solving (job \(jobID))...")

        // Poll job until success/failure
        try await pollUntilJobDone(jobID: jobID)

        // Fetch calibration
        return try await fetchCalibration(jobID: jobID)
    }

    private func pollUntilJob(subid: Int) async throws -> Int {
        let url = URL(string: "\(baseURL)/submissions/\(subid)")!
        let deadline = Date.now.addingTimeInterval(180)

        while Date.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(5))

            let data = try await URLSession.shared.data(from: url).0
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            if let jobs = json?["jobs"] as? [Int], let jobID = jobs.first(where: { $0 > 0 }) {
                return jobID
            }
            if let jobs = json?["jobs"] as? [Any], let first = jobs.first(where: { ($0 as? Int ?? 0) > 0 }) as? Int {
                return first
            }
        }
        throw AstrometryError.timeout("No job assigned after 3 minutes")
    }

    private func pollUntilJobDone(jobID: Int) async throws {
        let url = URL(string: "\(baseURL)/jobs/\(jobID)")!
        let deadline = Date.now.addingTimeInterval(180)

        while Date.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(5))

            let data = try await URLSession.shared.data(from: url).0
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let status = json?["status"] as? String ?? ""

            if status == "success" { return }
            if status == "failure" { throw AstrometryError.solveFailed("Job \(jobID) failed") }
        }
        throw AstrometryError.timeout("Job did not complete within 3 minutes")
    }

    private func fetchCalibration(jobID: Int) async throws -> AstrometryCalibration {
        let url = URL(string: "\(baseURL)/jobs/\(jobID)/calibration/")!
        let data = try await URLSession.shared.data(from: url).0
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let ra = json?["ra"] as? Double,
              let dec = json?["dec"] as? Double else {
            throw AstrometryError.badResponse("Missing ra/dec in calibration response")
        }
        let orientation = json?["orientation"] as? Double ?? 0.0
        let pixscale = json?["pixscale"] as? Double ?? 0.0
        let parity = json?["parity"] as? Double ?? 1.0

        return AstrometryCalibration(ra: ra, dec: dec,
                                     orientation: orientation,
                                     pixscale: pixscale,
                                     parity: parity)
    }

    // MARK: - Helpers

    /// Raw JSON string — used as the value of a multipart `request-json` field (no URL-encoding).
    private func jsonString(_ dict: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// URL-encoded JSON — used for `application/x-www-form-urlencoded` bodies (login).
    private func jsonFormField(_ dict: [String: Any]) throws -> String {
        let str = try jsonString(dict)
        return str.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? str
    }
}

// MARK: - Supporting types

struct AstrometryCalibration {
    let ra: Double          // degrees
    let dec: Double         // degrees
    let orientation: Double // degrees CCW from north
    let pixscale: Double    // arcsec/pixel
    let parity: Double      // 1 = normal, -1 = mirrored

    func toSolveResult() -> SolveResult {
        SolveResult(
            success: true,
            raDeg: ra,
            decDeg: dec,
            rollDeg: orientation,
            fovDeg: 0.0,        // not returned by Astrometry.net directly
            matchedStars: 0,
            solveTimeMs: 0.0,
            rmseArcsec: 0.0
        )
    }
}

enum AstrometryError: Error, LocalizedError {
    case loginFailed(String)
    case uploadFailed(String)
    case solveFailed(String)
    case timeout(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .loginFailed(let m): return "Astrometry.net login failed: \(m)"
        case .uploadFailed(let m): return "Image upload failed: \(m)"
        case .solveFailed(let m): return "Plate solve failed: \(m)"
        case .timeout(let m): return "Astrometry.net timeout: \(m)"
        case .badResponse(let m): return "Bad response: \(m)"
        }
    }
}

// MARK: - Data multipart helpers

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipartFile(boundary: String, name: String, filename: String,
                                       mimeType: String, data fileData: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(fileData)
        append("\r\n".data(using: .utf8)!)
    }
}
