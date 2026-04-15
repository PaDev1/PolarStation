import Foundation
import Metal
import SwiftUI

/// Simulated mount + camera engine for testing guide calibration and guiding
/// without real hardware. Generates synthetic rgba16Float star field textures
/// that feed directly into the real star detection pipeline (CoreML + classical).
///
/// Mount simulation includes: commanded rates, RA drift, periodic error,
/// Dec drift, and Dec backlash.
@MainActor
final class SimulatedGuideEngine: ObservableObject {

    // MARK: - Published state

    @Published var isRunning = false
    @Published var statusMessage = "Stopped"

    // MARK: - Configurable parameters

    /// Seeing FWHM in arcseconds (determines star profile width + jitter).
    @Published var seeingFWHM: Double = 2.0

    /// RA tracking drift in arcseconds per second.
    @Published var raDriftArcsecPerSec: Double = 0.5

    /// Dec drift in arcseconds per second.
    @Published var decDriftArcsecPerSec: Double = 0.1

    /// Periodic error amplitude in arcseconds.
    @Published var peAmplitudeArcsec: Double = 5.0

    /// Periodic error period in seconds.
    var pePeriodSec: Double = 480.0  // 8 minutes

    /// Dec backlash zone in arcseconds.
    @Published var backlashArcsec: Double = 3.0

    /// Camera rotation angle relative to sky (degrees).
    @Published var cameraAngleDeg: Double = 15.0

    /// Pixel scale in arcseconds per pixel.
    var pixelScaleArcsecPerPix: Double = 1.5

    /// Simulated image dimensions.
    var imageWidth: Int = 1920
    var imageHeight: Int = 1200

    /// Background level (normalized 0-1).
    var backgroundLevel: Float = 0.05
    /// Background noise standard deviation (normalized).
    var noiseStdDev: Float = 0.015

    // MARK: - Dependencies

    private weak var cameraViewModel: CameraViewModel?
    private weak var calibrator: GuideCalibrator?

    // MARK: - Internal mount state

    private var raOffsetArcsec: Double = 0
    private var decOffsetArcsec: Double = 0
    private var raCommandRateDegPerSec: Double = 0
    private var decCommandRateDegPerSec: Double = 0
    private var startTime: Date = .now
    private var decBacklashAccum: Double = 0
    private var lastDecDirection: Double = 0

    /// Fixed star field in sky coordinates (RA offset arcsec, Dec offset arcsec, peak brightness 0-1).
    private var starField: [(raArcsec: Double, decArcsec: Double, peak: Float)] = []

    /// Frame counter for detection cadence.
    private var frameNumber: UInt64 = 0

    /// Simulation timer.
    private var timer: Timer?
    private let tickInterval: TimeInterval = 0.1  // 10 Hz

    // MARK: - Metal resources

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var stretchPipeline: MTLComputePipelineState?
    /// Reusable rgba16Float star field texture for star detection.
    private var starFieldTexture: MTLTexture?
    /// Reusable bgra8Unorm display texture.
    private var displayTexture: MTLTexture?
    /// CPU-side half-float pixel buffer.
    private var pixelBuffer: [UInt16] = []

    // MARK: - Init

    init() {
        generateStarField()
    }

    // MARK: - Public API

    func start(cameraViewModel: CameraViewModel, calibrator: GuideCalibrator, viewSize: CGSize = .zero) {
        guard !isRunning else { return }

        self.cameraViewModel = cameraViewModel
        self.calibrator = calibrator

        // Match image size to the view (use integer points — backing scale handled by MTKView)
        if viewSize.width > 0 && viewSize.height > 0 {
            imageWidth = Int(viewSize.width)
            imageHeight = Int(viewSize.height)
            generateStarField()
        }

        // Reset mount state
        raOffsetArcsec = 0
        decOffsetArcsec = 0
        raCommandRateDegPerSec = 0
        decCommandRateDegPerSec = 0
        decBacklashAccum = 0
        lastDecDirection = 0
        startTime = .now
        frameNumber = 0

        // Set up Metal resources from the preview view model
        guard let dev = cameraViewModel.previewViewModel.device,
              let queue = cameraViewModel.previewViewModel.commandQueue else {
            statusMessage = "No Metal device"
            cameraViewModel.appendDebug("[Sim] FAIL: No Metal device from previewViewModel")
            return
        }
        self.device = dev
        self.commandQueue = queue
        setupMetalResources(device: dev)

        cameraViewModel.appendDebug("[Sim] Metal device=\(dev.name)")
        cameraViewModel.appendDebug("[Sim] sfTex=\(starFieldTexture != nil) dispTex=\(displayTexture != nil) stretchPipe=\(stretchPipeline != nil)")
        cameraViewModel.appendDebug("[Sim] detector=classical")
        cameraViewModel.appendDebug("[Sim] image=\(imageWidth)x\(imageHeight) viewSize=\(Int(viewSize.width))x\(Int(viewSize.height)) stars=\(starField.count)")

        // Set up camera view model for simulated mode
        cameraViewModel.isConnected = true
        cameraViewModel.isCapturing = true
        cameraViewModel.captureWidth = imageWidth
        cameraViewModel.captureHeight = imageHeight
        cameraViewModel.statusMessage = "Simulated"
        cameraViewModel.starDetectionEnabled = true

        // Install moveAxis handler on calibrator
        calibrator.moveAxisHandler = { [weak self] axis, rate in
            await self?.handleMoveAxis(axis: axis, rateDegPerSec: rate)
        }

        // Start timer
        isRunning = true
        statusMessage = "Running"
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        statusMessage = "Stopped"

        if let cvm = cameraViewModel {
            cvm.isConnected = false
            cvm.isCapturing = false
            cvm.detectedStars = []
            cvm.previewViewModel.displayTexture = nil
            cvm.statusMessage = "Disconnected"
        }

        calibrator?.moveAxisHandler = nil
        cameraViewModel = nil
        calibrator = nil
    }

    // MARK: - Mount Command Handler

    private func handleMoveAxis(axis: UInt8, rateDegPerSec: Double) {
        if axis == 0 {
            raCommandRateDegPerSec = rateDegPerSec
        } else {
            decCommandRateDegPerSec = rateDegPerSec
        }
    }

    // MARK: - Simulation Tick

    private func tick() {
        guard isRunning, let cvm = cameraViewModel else { return }
        guard let dev = device, let queue = commandQueue,
              let sfTex = starFieldTexture, let dispTex = displayTexture else {
            cvm.appendDebug("[Sim] tick: missing resource dev=\(device != nil) queue=\(commandQueue != nil) sfTex=\(starFieldTexture != nil) dispTex=\(displayTexture != nil)")
            return
        }

        let dt = tickInterval
        let elapsed = Date.now.timeIntervalSince(startTime)

        // --- Mount model ---
        raOffsetArcsec += raCommandRateDegPerSec * 3600.0 * dt
        raOffsetArcsec += raDriftArcsecPerSec * dt

        let peRate = peAmplitudeArcsec * (2.0 * .pi / pePeriodSec) * cos(2.0 * .pi * elapsed / pePeriodSec)
        raOffsetArcsec += peRate * dt

        let decCommandArcsec = decCommandRateDegPerSec * 3600.0 * dt
        if decCommandArcsec != 0 {
            let newDir = decCommandArcsec > 0 ? 1.0 : -1.0
            if newDir != lastDecDirection && lastDecDirection != 0 {
                decBacklashAccum = backlashArcsec
            }
            lastDecDirection = newDir

            if decBacklashAccum > 0 {
                decBacklashAccum -= abs(decCommandArcsec)
                if decBacklashAccum < 0 {
                    decOffsetArcsec += newDir * (-decBacklashAccum)
                    decBacklashAccum = 0
                }
            } else {
                decOffsetArcsec += decCommandArcsec
            }
        }
        decOffsetArcsec += decDriftArcsecPerSec * dt

        // --- Render star field into rgba16Float texture ---
        renderStarField()

        let w = imageWidth
        let h = imageHeight
        let bytesPerRow = w * 4 * MemoryLayout<UInt16>.size
        let region = MTLRegion(origin: MTLOrigin(), size: MTLSize(width: w, height: h, depth: 1))
        sfTex.replace(region: region, mipmapLevel: 0, withBytes: pixelBuffer, bytesPerRow: bytesPerRow)

        // --- Auto-stretch for display ---
        if let stretchPipe = stretchPipeline,
           let cmdBuf = queue.makeCommandBuffer(),
           let encoder = cmdBuf.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(stretchPipe)
            encoder.setTexture(sfTex, index: 0)
            encoder.setTexture(dispTex, index: 1)
            var params = StretchParams(blackPoint: 0.0, whitePoint: 1.0, midtones: 0.5, useSTF: 0)
            encoder.setBytes(&params, length: MemoryLayout<StretchParams>.size, index: 0)
            let threads = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
            let groups = MTLSize(width: 16, height: 16, depth: 1)
            encoder.dispatchThreadgroups(threads, threadsPerThreadgroup: groups)
            encoder.endEncoding()
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
        }

        // --- Update display ---
        cvm.previewViewModel.displayTexture = dispTex
        cvm.previewViewModel.frameCount += 1

        // --- Run star detection on the rgba16Float texture (every 5th frame) ---
        frameNumber += 1
        if frameNumber % 5 == 0 {
            cvm.runStarDetection(on: sfTex, device: dev, commandQueue: queue)
        }
        // Pipe preview debug message to the debug log
        if let msg = cvm.previewViewModel.debugMessage {
            cvm.appendDebug(msg)
            cvm.previewViewModel.debugMessage = nil
        }
        if frameNumber % 50 == 0 {
            cvm.appendDebug("[Sim] frame=\(frameNumber) detStars=\(cvm.detectedStars.count) enabled=\(cvm.starDetectionEnabled) raOff=\(String(format:"%.1f",raOffsetArcsec))\"")
        }
    }

    // MARK: - Metal Setup

    private func setupMetalResources(device: MTLDevice) {
        let w = imageWidth
        let h = imageHeight

        // Star field texture (rgba16Float) — used for star detection
        let sfDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: w, height: h, mipmapped: false
        )
        sfDesc.usage = [.shaderRead, .shaderWrite]
        sfDesc.storageMode = .shared
        starFieldTexture = device.makeTexture(descriptor: sfDesc)

        // Display texture (bgra8Unorm) — used for MTKView
        let dispDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: w, height: h, mipmapped: false
        )
        dispDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        dispDesc.storageMode = .shared
        displayTexture = device.makeTexture(descriptor: dispDesc)

        // Auto-stretch pipeline
        if let library = device.makeDefaultLibrary(),
           let stretchFunc = library.makeFunction(name: "auto_stretch") {
            stretchPipeline = try? device.makeComputePipelineState(function: stretchFunc)
        }

        // Allocate CPU pixel buffer (4 half-float channels per pixel)
        pixelBuffer = [UInt16](repeating: 0, count: w * h * 4)
    }

    // MARK: - Star Field Rendering

    /// Render star field into the CPU pixel buffer as rgba16Float.
    private func renderStarField() {
        let w = imageWidth
        let h = imageHeight
        let bgHalf = floatToHalf(backgroundLevel)
        let oneHalf = floatToHalf(1.0)

        // Fill with background + noise
        for y in 0..<h {
            for x in 0..<w {
                let noise = Float(gaussianRandom()) * noiseStdDev
                let val = max(0, backgroundLevel + noise)
                let hval = floatToHalf(val)
                let idx = (y * w + x) * 4
                pixelBuffer[idx] = hval     // R
                pixelBuffer[idx + 1] = hval // G
                pixelBuffer[idx + 2] = hval // B
                pixelBuffer[idx + 3] = oneHalf // A
            }
        }

        // Project and render each star
        let cameraAngleRad = cameraAngleDeg * .pi / 180.0
        let cosAngle = cos(cameraAngleRad)
        let sinAngle = sin(cameraAngleRad)
        let centerX = Double(w) / 2.0
        let centerY = Double(h) / 2.0
        let seeingSigmaArcsec = seeingFWHM / 2.35
        let starSigmaPix = (seeingFWHM / pixelScaleArcsecPerPix) / 2.35

        for star in starField {
            let dRA = star.raArcsec - raOffsetArcsec
            let dDec = star.decArcsec - decOffsetArcsec

            let jitterRA = gaussianRandom() * seeingSigmaArcsec
            let jitterDec = gaussianRandom() * seeingSigmaArcsec

            let raPixels = (dRA + jitterRA) / pixelScaleArcsecPerPix
            let decPixels = (dDec + jitterDec) / pixelScaleArcsecPerPix

            let px = centerX + raPixels * cosAngle - decPixels * sinAngle
            let py = centerY + raPixels * sinAngle + decPixels * cosAngle

            let margin = starSigmaPix * 5
            guard px >= -margin && px < Double(w) + margin &&
                  py >= -margin && py < Double(h) + margin else {
                continue
            }

            renderGaussianStar(
                width: w, height: h,
                cx: px, cy: py,
                sigma: starSigmaPix,
                peak: Float(star.peak)
            )
        }
    }

    /// Render a single Gaussian star into the half-float pixel buffer.
    private func renderGaussianStar(
        width: Int, height: Int,
        cx: Double, cy: Double,
        sigma: Double,
        peak: Float
    ) {
        let radius = Int(ceil(sigma * 4))
        let x0 = max(0, Int(cx) - radius)
        let x1 = min(width - 1, Int(cx) + radius)
        let y0 = max(0, Int(cy) - radius)
        let y1 = min(height - 1, Int(cy) + radius)
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
                    let idx = (y * width + x) * 4
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

    // MARK: - Star Field Generation

    private func generateStarField() {
        let fieldRadiusArcsec = Double(min(imageWidth, imageHeight)) / 2.0 * pixelScaleArcsecPerPix * 0.7

        var rng = SystemRandomNumberGenerator()
        starField = (0..<25).map { _ in
            let ra = Double.random(in: -fieldRadiusArcsec...fieldRadiusArcsec, using: &rng)
            let dec = Double.random(in: -fieldRadiusArcsec...fieldRadiusArcsec, using: &rng)
            let peak = Float.random(in: 0.15...0.7, using: &rng)
            return (raArcsec: ra, decArcsec: dec, peak: peak)
        }

        // Ensure one very bright guide star near center
        starField[0] = (raArcsec: 15.0, decArcsec: -10.0, peak: 0.85)
        // A second moderately bright star
        starField[1] = (raArcsec: -80.0, decArcsec: 50.0, peak: 0.6)
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

        let f = Float(sign == 0 ? 1 : -1) * pow(2.0, Float(Int(exponent) - 15)) * (1.0 + Float(mantissa) / 1024.0)
        return f
    }

    // MARK: - Utilities

    private func gaussianRandom() -> Double {
        let u1 = Double.random(in: 0.0001...1.0)
        let u2 = Double.random(in: 0.0...1.0)
        return sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
    }
}
