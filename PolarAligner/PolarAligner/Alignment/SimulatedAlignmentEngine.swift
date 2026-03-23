import AppKit
import Foundation
import Metal
import PolarCore

/// Simulated polar alignment engine for end-to-end testing of the three-point
/// plate-solving alignment workflow without real hardware.
///
/// Generates synthetic star field images from the real tetra3 star catalog,
/// simulates a mount with known polar alignment error, and feeds frames through
/// the real detection → plate solve → polar error pipeline.
///
/// Also supports manual alt/az adjustment simulation for practicing the
/// correction workflow.
@MainActor
final class SimulatedAlignmentEngine: ObservableObject {

    // MARK: - Published state

    @Published var isRunning = false
    @Published var currentStep: Int = 0  // 0=idle, 1-3=solving, 4=complete
    @Published var statusMessage = "Ready"

    /// Injected polar alignment error (arcminutes).
    @Published var injectedAltError: Double = 10.0
    @Published var injectedAzError: Double = 5.0

    /// Manual adjustment offsets (arcminutes) — simulates turning mount knobs.
    @Published var adjustmentAlt: Double = 0
    @Published var adjustmentAz: Double = 0

    /// Computed error from the plate solve pipeline.
    @Published var computedError: PolarError?

    /// Live correction error — updated in real-time as user adjusts mount screws.
    @Published var correctionError: PolarError?

    /// Solved positions for display.
    @Published var solvedPositions: [SolveResult?] = [nil, nil, nil]

    /// Camera model parameters.
    @Published var seeingFWHM: Double = 2.5      // arcseconds
    @Published var cameraRollDeg: Double = 15.0   // degrees
    @Published var initialDec: Double = 60.0      // degrees
    @Published var initialRA: Double? = nil        // nil = auto from LST

    /// Star detector toggle.
    @Published var useClassicalDetector: Bool = true

    /// Detected star count from last frame.
    @Published var lastDetectedCount: Int = 0

    /// Star count from preview render (before alignment run).
    @Published var previewStarCount: Int = 0

    /// Rendered preview image for display (no Metal display dependency).
    @Published var previewImage: NSImage?

    /// Current camera pointing — updated during alignment run and correction loop
    /// so the sky map FOV overlay can track the camera position.
    @Published var currentCameraRA: Double?
    @Published var currentCameraDec: Double?

    // Camera model — synced from PlateSolveService settings
    var imageWidth: Int = 1920
    var imageHeight: Int = 1080
    var fovDeg: Double = 3.2
    let slewDeg: Double = 30.0
    /// Number of detection frames for consensus (mirrors AlignmentCoordinator).
    var detectionFrames: Int = 3

    // Observer location (matches AlignmentCoordinator defaults)
    var observerLatDeg: Double = 60.17
    var observerLonDeg: Double = 24.94

    // MARK: - Correction Loop Reference State

    /// Saved when entering correction mode (step 4) so the correction loop
    /// can compute how the camera pointing shifts as the user adjusts screws.
    private var referenceJD: Double = 0
    private var referenceCameraRA: Double = 0
    private var referenceCameraDec: Double = 0
    private var referencePole: (raDeg: Double, decDeg: Double) = (0, 0)

    // MARK: - Metal resources

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var starFieldTexture: MTLTexture?
    private var pixelBuffer: [UInt16] = []

    // MARK: - Detection

    private let classicalDetector = ClassicalDetector()
    private var coremlDetector: CoreMLDetector?

    // MARK: - Catalog cache

    private var catalog: [CatalogStar] = []

    // MARK: - Public API

    /// Sync camera model from PlateSolveService settings.
    /// Must be called before projection/detection to ensure consistency.
    private func syncSettings(from service: PlateSolveService) {
        let newW = Int(service.imageWidth)
        let newH = Int(service.imageHeight)
        let needsResize = newW != imageWidth || newH != imageHeight

        fovDeg = service.fovDeg
        imageWidth = newW
        imageHeight = newH

        if needsResize {
            pixelBuffer = [UInt16](repeating: 0, count: newW * newH * 4)
            if let dev = device {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .rgba16Float, width: newW, height: newH, mipmapped: false
                )
                desc.usage = [.shaderRead, .shaderWrite]
                desc.storageMode = .shared
                starFieldTexture = dev.makeTexture(descriptor: desc)
            }
        }
    }

    /// Set initial position from mount if connected.
    func syncFromMount(_ mountService: MountService) {
        if let status = mountService.status, status.connected {
            initialRA = status.raHours * 15.0
            initialDec = status.decDeg
        }
    }

    /// Run the full 3-point alignment simulation.
    func run(plateSolveService: PlateSolveService) async {
        guard !isRunning else { return }
        guard plateSolveService.isLoaded else {
            statusMessage = "Load solver database first"
            return
        }

        isRunning = true
        currentStep = 0
        computedError = nil
        solvedPositions = [nil, nil, nil]

        // Sync FOV and image dimensions from Settings
        syncSettings(from: plateSolveService)

        // Set up Metal for star detection (engine owns its own device)
        if device == nil {
            guard let dev = MTLCreateSystemDefaultDevice() else {
                statusMessage = "No Metal device"
                isRunning = false
                return
            }
            self.device = dev
            self.commandQueue = dev.makeCommandQueue()
            setupMetalResources(device: dev)
        }

        // Load CoreML detector if needed
        if !useClassicalDetector && coremlDetector == nil {
            let detector = CoreMLDetector()
            do {
                try detector.loadModel(named: "StarDetector")
                coremlDetector = detector
            } catch {
                statusMessage = "CoreML model not available, using classical"
            }
        }

        // Load catalog
        statusMessage = "Loading star catalog..."
        if catalog.isEmpty {
            catalog = await plateSolveService.getStarCatalog()
        }
        guard !catalog.isEmpty else {
            statusMessage = "Star catalog is empty"
            isRunning = false
            return
        }

        // Compute current Julian Date
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        var comps = cal.dateComponents(in: utc, from: now)
        let jd = julianDate(
            year: Int32(comps.year ?? 2026),
            month: UInt32(comps.month ?? 3),
            day: UInt32(comps.day ?? 15),
            hour: UInt32(comps.hour ?? 22),
            min: UInt32(comps.minute ?? 0),
            sec: Double(comps.second ?? 0)
        )

        // Effective error = injected - adjustment
        let effectiveAlt = injectedAltError - adjustmentAlt
        let effectiveAz = injectedAzError - adjustmentAz

        // Compute where the misaligned pole points
        let pole = GnomonicProjection.computeMisalignedPole(
            altErrorArcmin: effectiveAlt,
            azErrorArcmin: effectiveAz,
            observerLatDeg: observerLatDeg,
            observerLonDeg: observerLonDeg,
            jd: jd
        )

        // Choose initial camera pointing
        var cameraRA = computeInitialCameraRA()
        var cameraDec = initialDec

        print("[SimAlign] Pole: RA=\(String(format: "%.4f", pole.raDeg)) Dec=\(String(format: "%.4f", pole.decDeg))")
        print("[SimAlign] Initial: RA=\(String(format: "%.4f", cameraRA)) Dec=\(String(format: "%.4f", cameraDec))")
        print("[SimAlign] JD=\(jd) effectiveAlt=\(effectiveAlt)' effectiveAz=\(effectiveAz)'")

        var solvedCoords: [CelestialCoord] = []

        var solvedFOV: Double? = plateSolveService.lastResult?.fovDeg

        for step in 1...3 {
            currentStep = step

            // Iterative solve: render → detect → solve → if fail, nudge and retry
            let maxAttempts = 3
            let nudgeDeg = 3.0
            var solved = false

            for attempt in 1...maxAttempts {
                if attempt > 1 {
                    // Nudge: rotate camera slightly for a different star field
                    statusMessage = "Step \(step)/3: Nudging \(String(format: "%.0f", nudgeDeg))° (attempt \(attempt)/\(maxAttempts))..."
                    let nudged = GnomonicProjection.rotateAroundAxis(
                        pointingRA: cameraRA, pointingDec: cameraDec,
                        axisRA: pole.raDeg, axisDec: pole.decDeg,
                        angleDeg: nudgeDeg
                    )
                    cameraRA = nudged.raDeg
                    cameraDec = nudged.decDeg
                }

                statusMessage = "Step \(step)/3: Generating star field..."
                self.currentCameraRA = cameraRA
                self.currentCameraDec = cameraDec

                // 1. Project catalog stars onto virtual sensor
                let visibleStars = projectCatalogStars(
                    cameraRA: cameraRA, cameraDec: cameraDec,
                    rollDeg: cameraRollDeg
                )
                previewStarCount = visibleStars.count
                guard visibleStars.count >= 4 else { continue }

                // 2. Render and detect with consensus
                lastRenderedStars = visibleStars
                renderStarField(stars: visibleStars)
                uploadTexture()
                generatePreviewImage()

                // Use locked FOV if available
                if let knownFOV = solvedFOV {
                    plateSolveService.fovDeg = knownFOV
                    plateSolveService.fovToleranceDeg = 0.5
                }

                // 3. Multi-frame consensus detect + solve
                if let result = await detectAndSolve(step: step, plateSolveService: plateSolveService) {
                    solvedPositions[step - 1] = result
                    solvedCoords.append(CelestialCoord(raDeg: result.raDeg, decDeg: result.decDeg))
                    if solvedFOV == nil { solvedFOV = result.fovDeg }
                    print("[SimAlign] Step \(step): Solved RA=\(String(format: "%.4f", result.raDeg)) Dec=\(String(format: "%.4f", result.decDeg)) matched=\(result.matchedStars)")
                    statusMessage = "Step \(step)/3: Solved — RA \(String(format: "%.2f", result.raDeg))° Dec \(String(format: "%.2f", result.decDeg))°"
                    solved = true
                    break
                }
            }

            guard solved else {
                plateSolveService.fovToleranceDeg = 1.0
                statusMessage = "Step \(step): Solve failed after \(maxAttempts) attempts (\(lastDetectedCount) stars, FOV \(String(format: "%.1f", fovDeg))°)"
                isRunning = false
                return
            }

            // 5. Rotate camera around the MISALIGNED axis for next step
            if step < 3 {
                let newPointing = GnomonicProjection.rotateAroundAxis(
                    pointingRA: cameraRA, pointingDec: cameraDec,
                    axisRA: pole.raDeg, axisDec: pole.decDeg,
                    angleDeg: slewDeg
                )
                print("[SimAlign] Step \(step): Rotated to RA=\(String(format: "%.4f", newPointing.raDeg)) Dec=\(String(format: "%.4f", newPointing.decDeg))")
                cameraRA = newPointing.raDeg
                cameraDec = newPointing.decDeg
            }

            // Brief pause so UI updates
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        // Restore default tolerance
        plateSolveService.fovToleranceDeg = 1.0

        // 6. Compute polar error
        statusMessage = "Computing polar error..."
        guard solvedCoords.count == 3 else {
            statusMessage = "Not enough solved positions"
            isRunning = false
            return
        }

        do {
            let error = try computePolarError(
                pos1: solvedCoords[0],
                pos2: solvedCoords[1],
                pos3: solvedCoords[2],
                observerLatDeg: observerLatDeg,
                observerLonDeg: observerLonDeg,
                timestampJd: jd
            )
            computedError = error
            correctionError = error
            currentStep = 4

            // Save reference state for the correction loop
            referenceJD = jd
            referenceCameraRA = cameraRA
            referenceCameraDec = cameraDec
            referencePole = pole

            statusMessage = String(format: "Done! Error: %.1f' (Alt %.1f' Az %.1f')",
                                   error.totalErrorArcmin, error.altErrorArcmin, error.azErrorArcmin)
        } catch {
            statusMessage = "Polar error computation failed: \(error.localizedDescription)"
        }

        isRunning = false
    }

    func reset() {
        isRunning = false
        currentStep = 0
        computedError = nil
        correctionError = nil
        currentCameraRA = nil
        currentCameraDec = nil
        solvedPositions = [nil, nil, nil]
        adjustmentAlt = 0
        adjustmentAz = 0
        statusMessage = "Ready"
    }

    /// Render a preview star field at the current RA/Dec without running detection or plate solving.
    /// Call this when the user selects a sky position or on first appear.
    func renderPreview(plateSolveService: PlateSolveService) async {
        // Sync FOV and image dimensions from Settings
        syncSettings(from: plateSolveService)

        // Ensure pixel buffer is allocated
        if pixelBuffer.isEmpty {
            pixelBuffer = [UInt16](repeating: 0, count: imageWidth * imageHeight * 4)
        }

        // Load catalog if needed
        if catalog.isEmpty {
            if plateSolveService.isLoaded {
                catalog = await plateSolveService.getStarCatalog()
            }
        }
        guard !catalog.isEmpty else {
            statusMessage = "Load solver database in Settings"
            return
        }

        // Compute camera pointing
        let cameraRA = computeInitialCameraRA()
        let cameraDec = initialDec

        // Project and render
        let visibleStars = projectCatalogStars(
            cameraRA: cameraRA, cameraDec: cameraDec,
            rollDeg: cameraRollDeg
        )
        previewStarCount = visibleStars.count
        renderStarField(stars: visibleStars)
        generatePreviewImage()

        if currentStep == 0 {
            statusMessage = "\(visibleStars.count) catalog stars at RA \(String(format: "%.1f", cameraRA))° Dec \(String(format: "%+.1f", cameraDec))°"
        }
    }

    /// Fast correction loop: re-render the star field at the shifted camera position
    /// and compute remaining error geometrically. Called when the user moves the
    /// adjustment sliders in correction mode (step 4).
    ///
    /// The star field visibly moves because the camera is mounted on the telescope:
    /// when the mount axis shifts (screw adjustment), the camera pointing shifts by
    /// the same rotation.
    func updateCorrectionPreview(plateSolveService: PlateSolveService) {
        guard currentStep == 4 else { return }

        // Sync settings
        syncSettings(from: plateSolveService)

        // Effective error = injected - adjustment
        let effectiveAlt = injectedAltError - adjustmentAlt
        let effectiveAz = injectedAzError - adjustmentAz

        // Compute new pole position with the adjusted error
        let newPole = GnomonicProjection.computeMisalignedPole(
            altErrorArcmin: effectiveAlt,
            azErrorArcmin: effectiveAz,
            observerLatDeg: observerLatDeg,
            observerLonDeg: observerLonDeg,
            jd: referenceJD
        )

        // Compute how camera pointing shifts: rotate reference camera by the
        // rotation that takes old pole → new pole
        let newCamera = computeShiftedCamera(
            oldPole: referencePole,
            newPole: newPole,
            cameraRA: referenceCameraRA,
            cameraDec: referenceCameraDec
        )

        // Publish shifted camera position for sky map FOV overlay
        self.currentCameraRA = newCamera.raDeg
        self.currentCameraDec = newCamera.decDeg

        // Render star field at the shifted camera position
        if pixelBuffer.isEmpty {
            pixelBuffer = [UInt16](repeating: 0, count: imageWidth * imageHeight * 4)
        }

        let visibleStars = projectCatalogStars(
            cameraRA: newCamera.raDeg, cameraDec: newCamera.decDeg,
            rollDeg: cameraRollDeg
        )
        previewStarCount = visibleStars.count
        renderStarField(stars: visibleStars)
        generatePreviewImage()

        // Compute geometric remaining error
        let totalError = sqrt(effectiveAlt * effectiveAlt + effectiveAz * effectiveAz)
        correctionError = PolarError(
            altErrorArcmin: effectiveAlt,
            azErrorArcmin: effectiveAz,
            totalErrorArcmin: totalError,
            mountAxis: CelestialCoord(raDeg: newPole.raDeg, decDeg: newPole.decDeg)
        )

        statusMessage = String(format: "Correction: %.1f' remaining (Alt %+.1f' Az %+.1f')",
                               totalError, effectiveAlt, effectiveAz)
    }

    /// Compute the shifted camera position when the mount pole moves from oldPole to newPole.
    /// Uses Rodrigues' rotation: the camera rotates by the same rotation as the pole.
    private func computeShiftedCamera(
        oldPole: (raDeg: Double, decDeg: Double),
        newPole: (raDeg: Double, decDeg: Double),
        cameraRA: Double, cameraDec: Double
    ) -> (raDeg: Double, decDeg: Double) {
        let oldP = GnomonicProjection.celestialToCartesian(raDeg: oldPole.raDeg, decDeg: oldPole.decDeg)
        let newP = GnomonicProjection.celestialToCartesian(raDeg: newPole.raDeg, decDeg: newPole.decDeg)

        // Rotation axis = old × new (perpendicular to both)
        let rawAxis = GnomonicProjection.cross(oldP, newP)
        let axisLen = sqrt(rawAxis.0 * rawAxis.0 + rawAxis.1 * rawAxis.1 + rawAxis.2 * rawAxis.2)

        guard axisLen > 1e-10 else {
            // Poles are coincident — no shift needed
            return (cameraRA, cameraDec)
        }
        let axis = GnomonicProjection.normalize(rawAxis)

        // Rotation angle = angle between old and new pole
        let dotVal = GnomonicProjection.dot(oldP, newP)
        let angle = acos(min(1.0, max(-1.0, dotVal)))

        // Apply Rodrigues' rotation to camera position
        let cam = GnomonicProjection.celestialToCartesian(raDeg: cameraRA, decDeg: cameraDec)
        let kxp = GnomonicProjection.cross(axis, cam)
        let kdotp = GnomonicProjection.dot(axis, cam)
        let cosA = cos(angle)
        let sinA = sin(angle)

        let rotated = GnomonicProjection.normalize((
            cam.0 * cosA + kxp.0 * sinA + axis.0 * kdotp * (1 - cosA),
            cam.1 * cosA + kxp.1 * sinA + axis.1 * kdotp * (1 - cosA),
            cam.2 * cosA + kxp.2 * sinA + axis.2 * kdotp * (1 - cosA)
        ))

        return GnomonicProjection.cartesianToCelestial(x: rotated.0, y: rotated.1, z: rotated.2)
    }

    /// Compute initial camera RA: use initialRA if set, otherwise compute from LST.
    private func computeInitialCameraRA() -> Double {
        if let ra = initialRA { return ra }
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let utc = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents(in: utc, from: now)
        let jd = julianDate(
            year: Int32(comps.year ?? 2026),
            month: UInt32(comps.month ?? 3),
            day: UInt32(comps.day ?? 15),
            hour: UInt32(comps.hour ?? 22),
            min: UInt32(comps.minute ?? 0),
            sec: Double(comps.second ?? 0)
        )
        return localSiderealTime(jd: jd, longitudeDeg: observerLonDeg) + 15.0
    }

    // MARK: - Catalog Projection

    private func projectCatalogStars(
        cameraRA: Double, cameraDec: Double, rollDeg: Double
    ) -> [(x: Double, y: Double, brightness: Float)] {
        var visible: [(x: Double, y: Double, brightness: Float)] = []

        for star in catalog {
            // Skip stars fainter than catalog limit
            guard star.magnitude <= 10.5 else { continue }

            guard let pixel = GnomonicProjection.projectToPixel(
                starRA: star.raDeg, starDec: star.decDeg,
                centerRA: cameraRA, centerDec: cameraDec,
                rollDeg: rollDeg,
                fovDeg: fovDeg,
                imageWidth: imageWidth, imageHeight: imageHeight
            ) else { continue }

            // Check if within image bounds (with margin)
            guard pixel.x >= -20 && pixel.x < Double(imageWidth) + 20 &&
                  pixel.y >= -20 && pixel.y < Double(imageHeight) + 20 else { continue }

            let brightness = GnomonicProjection.magnitudeToBrightness(star.magnitude)
            guard brightness > 0.003 else { continue }

            visible.append((x: pixel.x, y: pixel.y, brightness: brightness))
        }

        return visible
    }

    // MARK: - Star Detection

    private func detectStars(useClassical: Bool? = nil) -> [DetectedStar] {
        guard let sfTex = starFieldTexture,
              let dev = device,
              let queue = commandQueue else { return [] }

        let classical = useClassical ?? (useClassicalDetector || coremlDetector == nil)

        do {
            if classical {
                return try classicalDetector.detectStars(in: sfTex, device: dev, commandQueue: queue)
            } else {
                return try coremlDetector!.detectStars(in: sfTex, device: dev, commandQueue: queue)
            }
        } catch {
            print("[SimAlign] Detection error: \(error)")
            return []
        }
    }

    /// Detect stars and plate solve. If the primary detector fails to solve,
    /// falls back to the other detector and retries.
    private func detectAndSolve(
        step: Int,
        plateSolveService: PlateSolveService
    ) async -> SolveResult? {
        // Multi-frame consensus detection (simulated: run detection multiple times
        // with slight noise variation to mimic real multi-frame behaviour)
        let frameCount = max(1, detectionFrames)
        var allDetections: [[DetectedStar]] = []

        for i in 0..<frameCount {
            statusMessage = "Step \(step)/3: Detecting stars (frame \(i+1)/\(frameCount))..."

            // Re-render with slightly different noise for each frame
            if i > 0, let visibleStars = lastRenderedStars {
                renderStarField(stars: visibleStars)
                uploadTexture()
            }

            let detected = detectStars(useClassical: true)
            if !detected.isEmpty {
                allDetections.append(detected)
            }
        }

        // Build consensus from multiple frames
        let consensus: [DetectedStar]
        if allDetections.count >= 2 {
            consensus = buildConsensus(detections: allDetections, matchRadius: 5.0, minAppearances: 2)
            print("[SimAlign] Step \(step): Consensus \(allDetections.count) frames → \(consensus.count) stars")
        } else {
            consensus = allDetections.first ?? []
        }

        lastDetectedCount = consensus.count
        guard consensus.count >= 4 else { return nil }

        statusMessage = "Step \(step)/3: Plate solving (\(consensus.count) stars)..."
        if let result = try? await plateSolveService.solveRobust(centroids: consensus),
           result.success {
            return result
        }

        print("[SimAlign] Step \(step): Solve failed with \(consensus.count) consensus stars")
        return nil
    }

    /// Build consensus star list from multiple detection frames.
    private func buildConsensus(
        detections: [[DetectedStar]],
        matchRadius: Double,
        minAppearances: Int
    ) -> [DetectedStar] {
        guard let reference = detections.first else { return [] }

        var scores: [(star: DetectedStar, count: Int, totalBrightness: Double)] =
            reference.map { ($0, 1, $0.brightness) }

        for frameStars in detections.dropFirst() {
            for (i, entry) in scores.enumerated() {
                for star in frameStars {
                    let dx = star.x - entry.star.x
                    let dy = star.y - entry.star.y
                    if sqrt(dx * dx + dy * dy) < matchRadius {
                        scores[i].count += 1
                        scores[i].totalBrightness += star.brightness
                        break
                    }
                }
            }
        }

        return scores
            .filter { $0.count >= minAppearances }
            .sorted { $0.totalBrightness > $1.totalBrightness }
            .map { $0.star }
    }

    /// Last rendered stars for re-rendering with different noise.
    private var lastRenderedStars: [(x: Double, y: Double, brightness: Float)]?

    // MARK: - Star Field Rendering

    private func renderStarField(stars: [(x: Double, y: Double, brightness: Float)]) {
        let w = imageWidth
        let h = imageHeight

        let bgLevel: Float = 0.02
        let noiseStd: Float = 0.005
        let bgHalf = floatToHalf(bgLevel)
        let oneHalf = floatToHalf(1.0)

        // Fill background + noise
        for y in 0..<h {
            for x in 0..<w {
                let noise = Float(gaussianRandom()) * noiseStd
                let val = max(0, bgLevel + noise)
                let hval = floatToHalf(val)
                let idx = (y * w + x) * 4
                pixelBuffer[idx] = hval
                pixelBuffer[idx + 1] = hval
                pixelBuffer[idx + 2] = hval
                pixelBuffer[idx + 3] = oneHalf
            }
        }

        // Render each star as a Gaussian PSF
        // Seeing FWHM → sigma in pixels
        // Pixel scale: fovDeg spans imageWidth pixels → arcsec/pixel
        // Minimum 1.5 px sigma (represents optics + diffraction + sampling)
        let pixelScaleArcsec = (fovDeg * 3600.0) / Double(imageWidth)
        let sigmaPix = max(3.0, (seeingFWHM / pixelScaleArcsec) / 2.35)
        let jitterSigmaArcsec = seeingFWHM / 2.35

        for star in stars {
            // Add seeing jitter
            let jx = gaussianRandom() * jitterSigmaArcsec / pixelScaleArcsec
            let jy = gaussianRandom() * jitterSigmaArcsec / pixelScaleArcsec

            renderGaussianStar(
                cx: star.x + jx, cy: star.y + jy,
                sigma: sigmaPix,
                peak: star.brightness
            )
        }
    }

    private func renderGaussianStar(cx: Double, cy: Double, sigma: Double, peak: Float) {
        let w = imageWidth
        let h = imageHeight
        let radius = Int(ceil(sigma * 4))
        let x0 = max(0, Int(cx) - radius)
        let x1 = min(w - 1, Int(cx) + radius)
        let y0 = max(0, Int(cy) - radius)
        let y1 = min(h - 1, Int(cy) + radius)
        guard x0 <= x1 && y0 <= y1 else { return }
        let twoSigmaSq = 2.0 * sigma * sigma

        for y in y0...y1 {
            let dy = Double(y) - cy
            let dySq = dy * dy
            for x in x0...x1 {
                let dx = Double(x) - cx
                let distSq = dx * dx + dySq
                let intensity = Float(Double(peak) * exp(-distSq / twoSigmaSq))

                if intensity > 0.001 {
                    let idx = (y * w + x) * 4
                    let current = halfToFloat(pixelBuffer[idx])
                    let newVal = min(current + intensity, 1.0)
                    let hval = floatToHalf(newVal)
                    pixelBuffer[idx] = hval
                    pixelBuffer[idx + 1] = hval
                    pixelBuffer[idx + 2] = hval
                }
            }
        }
    }

    // MARK: - Texture Management

    private func uploadTexture() {
        guard let sfTex = starFieldTexture else { return }
        let w = imageWidth
        let h = imageHeight
        let bytesPerRow = w * 4 * MemoryLayout<UInt16>.size
        let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: w, height: h, depth: 1))
        sfTex.replace(region: region, mipmapLevel: 0, withBytes: pixelBuffer, bytesPerRow: bytesPerRow)
    }

    /// Convert the CPU pixel buffer to an NSImage for display.
    private func generatePreviewImage() {
        guard !pixelBuffer.isEmpty else { return }
        let w = imageWidth
        let h = imageHeight

        // Sqrt stretch: black just below background level, white at bright star peak
        let black: Float = 0.015
        let white: Float = 0.5
        let range = white - black

        var rgbaBytes = [UInt8](repeating: 0, count: w * h * 4)

        for i in 0..<(w * h) {
            let srcIdx = i * 4
            let val = halfToFloat(pixelBuffer[srcIdx])
            let normalized = max(val - black, 0) / range
            let stretched = sqrt(min(normalized, 1.0))
            let byte = UInt8(min(stretched * 255.0, 255.0))
            let dstIdx = i * 4
            rgbaBytes[dstIdx] = byte      // R
            rgbaBytes[dstIdx + 1] = byte  // G
            rgbaBytes[dstIdx + 2] = byte  // B
            rgbaBytes[dstIdx + 3] = 255   // A
        }

        guard let provider = CGDataProvider(data: Data(rgbaBytes) as CFData) else { return }
        guard let cgImage = CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return }

        previewImage = NSImage(cgImage: cgImage, size: NSSize(width: w, height: h))
    }

    // MARK: - Metal Setup (for star detection only)

    private func setupMetalResources(device: MTLDevice) {
        let w = imageWidth
        let h = imageHeight

        let sfDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
        )
        sfDesc.usage = [.shaderRead, .shaderWrite]
        sfDesc.storageMode = .shared
        starFieldTexture = device.makeTexture(descriptor: sfDesc)

        // Only allocate pixelBuffer if empty or wrong size — preserve preview data
        let expectedSize = w * h * 4
        if pixelBuffer.count != expectedSize {
            pixelBuffer = [UInt16](repeating: 0, count: expectedSize)
        }
    }

    // MARK: - Half-float Conversion

    private func floatToHalf(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let sign = (bits >> 31) & 1
        let exponent = Int((bits >> 23) & 0xFF) - 127
        let mantissa = bits & 0x7FFFFF

        if exponent > 15 {
            return UInt16(sign << 15 | 0x7C00)
        } else if exponent < -14 {
            return UInt16(sign << 15)
        }

        let hExp = UInt16(exponent + 15)
        let hMant = UInt16(mantissa >> 13)
        return UInt16(sign << 15) | (hExp << 10) | hMant
    }

    private func halfToFloat(_ h: UInt16) -> Float {
        let sign = (h >> 15) & 1
        let exponent = (h >> 10) & 0x1F
        let mantissa = h & 0x3FF

        if exponent == 0 {
            if mantissa == 0 { return sign == 0 ? 0.0 : -0.0 }
            var m = Float(mantissa) / 1024.0
            m *= pow(2.0, -14.0)
            return sign == 0 ? m : -m
        } else if exponent == 31 {
            return mantissa == 0 ? (sign == 0 ? .infinity : -.infinity) : .nan
        }

        return Float(sign == 0 ? 1 : -1) * pow(2.0, Float(Int(exponent) - 15)) * (1.0 + Float(mantissa) / 1024.0)
    }

    private func gaussianRandom() -> Double {
        let u1 = Double.random(in: 0.0001...1.0)
        let u2 = Double.random(in: 0.0...1.0)
        return sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
    }
}
