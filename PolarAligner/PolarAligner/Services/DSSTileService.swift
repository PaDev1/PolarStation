import AppKit
import Foundation
import Metal
import MetalKit

/// Fetches and caches DSS2 sky imagery tiles from STScI.
///
/// Tiles are decoded to CGImage eagerly on the background fetch thread so the
/// main thread never stalls on image decompression. MTLTexture objects are
/// created immediately after decoding and kept in a GPU-side cache.
/// When the zoom level changes the old-zoom tiles are evicted from memory
/// (they remain on disk and will be reloaded if the user zooms back out).
@MainActor
final class DSSTileService: ObservableObject {
    @Published var isEnabled = false
    @Published var cacheSizeMB: Double = 0
    /// Increments when new tiles finish loading — triggers Canvas / Metal redraws.
    @Published var tileLoadCount: Int = 0

    // MARK: - Metal

    /// Shared Metal device. Exposed so DSSMetalTileLayer can use the same device.
    let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var textureLoader: MTKTextureLoader?
    /// GPU-resident textures, keyed by tile key.
    private var textureCache: [String: MTLTexture] = [:]

    // MARK: - Memory cache (CGImage, decoded)

    private struct CachedTile {
        let image: CGImage
        var accessTime: Date
    }
    private var imageCache: [String: CachedTile] = [:]
    private let maxMemoryCacheCount = 80

    // MARK: - Fetch management

    private var inFlightTasks: [String: Task<Void, Never>] = [:]
    private let maxConcurrentFetches = 4
    private var fetchDebounceTask: Task<Void, Never>?
    private var lastRequestedKeys: Set<String> = []

    // MARK: - Disk cache

    let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PolarStation/DSSTiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        if let dev = device {
            textureLoader = MTKTextureLoader(device: dev)
        }
    }

    // MARK: - Tile Grid

    static let tileSizeDeg: Double = 1.0
    static let maxTileCount: Int   = 49   // 7×7 cap — prevents excessive requests at wide FOV

    static let minFOV: Double = 20.0

    func visibleTiles(centerRA: Double, centerDec: Double, fov: Double)
        -> [(key: String, raDeg: Double, decDeg: Double, sizeDeg: Double)]
    {
        guard fov <= Self.minFOV else { return [] }

        let tileSz   = Self.tileSizeDeg
        let halfFOV  = fov / 2.0 * 1.2
        let decMin   = max(-90, centerDec - halfFOV)
        let decMax   = min( 90, centerDec + halfFOV)
        let cosDec   = max(cos(centerDec * .pi / 180), 0.1)
        let raHalf   = halfFOV / cosDec
        let raMin    = centerRA - raHalf
        let raMax    = centerRA + raHalf
        let decStart = floor(decMin / tileSz) * tileSz
        let raStart  = floor(raMin  / tileSz) * tileSz

        var tiles: [(String, Double, Double, Double)] = []
        var dec = decStart + tileSz / 2.0
        while dec <= decMax {
            var ra = raStart + tileSz / 2.0
            while ra <= raMax {
                let normRA = ((ra.truncatingRemainder(dividingBy: 360)) + 360)
                    .truncatingRemainder(dividingBy: 360)
                let key = "\(String(format: "%.2f", tileSz))_\(String(format: "%.4f", normRA))_\(String(format: "%+.4f", dec))"
                tiles.append((key, normRA, dec, tileSz))
                ra += tileSz
            }
            dec += tileSz
        }

        // Sort center-out (spiral fetch order)
        let cRA = centerRA
        let cDec = centerDec
        let cosCenterDec = max(cos(cDec * .pi / 180), 0.1)
        tiles.sort { a, b in
            var dA = a.1 - cRA
            if dA > 180 { dA -= 360 } else if dA < -180 { dA += 360 }
            var dB = b.1 - cRA
            if dB > 180 { dB -= 360 } else if dB < -180 { dB += 360 }
            let distA = (dA * cosCenterDec) * (dA * cosCenterDec) + (a.2 - cDec) * (a.2 - cDec)
            let distB = (dB * cosCenterDec) * (dB * cosCenterDec) + (b.2 - cDec) * (b.2 - cDec)
            return distA < distB
        }
        return Array(tiles.prefix(Self.maxTileCount))
    }

    // MARK: - Tile Access

    /// Returns the decoded CGImage for canvas rendering. Loads from disk if needed.
    func cachedCGImage(key: String) -> CGImage? {
        if var entry = imageCache[key] {
            entry.accessTime = Date()
            imageCache[key] = entry
            return entry.image
        }
        guard let cg = loadFromDisk(key: key) else { return nil }
        imageCache[key] = CachedTile(image: cg, accessTime: Date())
        trimImageCache()
        return cg
    }

    /// Returns a GPU texture (used by the Metal layer when available).
    /// Automatically promotes a cached CGImage to MTLTexture on first access.
    func metalTexture(key: String) -> MTLTexture? {
        if let tex = textureCache[key] { return tex }
        guard let cg = cachedCGImage(key: key) else { return nil }
        if let tex = makeTexture(from: cg) {
            textureCache[key] = tex
            return tex
        }
        return nil
    }

    private func loadFromDisk(key: String) -> CGImage? {
        let jpg = cacheDir.appendingPathComponent("\(key).jpg")
        if FileManager.default.fileExists(atPath: jpg.path) { return loadCGImage(from: jpg) }
        let gif = cacheDir.appendingPathComponent("\(key).gif")
        if FileManager.default.fileExists(atPath: gif.path) { return loadCGImage(from: gif) }
        return nil
    }

    // MARK: - Request / Fetch

    func requestTiles(_ tiles: [(key: String, raDeg: Double, decDeg: Double, sizeDeg: Double)]) {
        let newKeys = Set(tiles.map(\.key))

        // Cancel fetches for tiles no longer in view
        for (key, task) in inFlightTasks where !newKeys.contains(key) {
            task.cancel()
            inFlightTasks.removeValue(forKey: key)
        }
        lastRequestedKeys = newKeys

        // Skip if everything is already in memory or on disk
        let needsFetch = tiles.contains { tile in
            if textureCache[tile.key] != nil { return false }
            if imageCache[tile.key]   != nil { return false }
            let jpg = cacheDir.appendingPathComponent("\(tile.key).jpg").path
            let gif = cacheDir.appendingPathComponent("\(tile.key).gif").path
            return !FileManager.default.fileExists(atPath: jpg)
                && !FileManager.default.fileExists(atPath: gif)
        }
        guard needsFetch else { return }

        fetchDebounceTask?.cancel()
        fetchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await self?.fetchMissingTiles(tiles)
        }
    }

    private func fetchMissingTiles(
        _ tiles: [(key: String, raDeg: Double, decDeg: Double, sizeDeg: Double)]
    ) async {
        for tile in tiles {
            guard lastRequestedKeys.contains(tile.key) else { continue }
            if textureCache[tile.key] != nil { continue }
            if imageCache[tile.key]   != nil { continue }
            if inFlightTasks[tile.key] != nil { continue }

            // Check disk — prefer .jpg, fall back to legacy .gif
            let jpgPath = cacheDir.appendingPathComponent("\(tile.key).jpg")
            let gifPath = cacheDir.appendingPathComponent("\(tile.key).gif")
            let diskPath: URL? = FileManager.default.fileExists(atPath: jpgPath.path) ? jpgPath
                               : FileManager.default.fileExists(atPath: gifPath.path) ? gifPath
                               : nil
            if let diskPath {
                let key = tile.key
                inFlightTasks[key] = Task { [weak self] in
                    await self?.loadTileFromDisk(key: key, path: diskPath)
                    await MainActor.run { self?.inFlightTasks.removeValue(forKey: key) }
                }
                continue
            }

            while inFlightTasks.count >= maxConcurrentFetches {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }
            }

            let key = tile.key
            inFlightTasks[key] = Task { [weak self] in
                await self?.fetchTile(key: key,
                                      raDeg: tile.raDeg,
                                      decDeg: tile.decDeg,
                                      sizeDeg: tile.sizeDeg)
                await MainActor.run { self?.inFlightTasks.removeValue(forKey: key) }
            }
        }
    }

    private func fetchTile(key: String, raDeg: Double, decDeg: Double, sizeDeg: Double) async {
        let sizeArcmin = sizeDeg * 60.0
        let urlStr = "https://archive.stsci.edu/cgi-bin/dss_search?r=\(raDeg)&d=\(decDeg)&h=\(sizeArcmin)&w=\(sizeArcmin)&e=J2000&f=gif&v=poss2ukstu_red&s=on"
        guard let url = URL(string: urlStr) else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  data.count > 500 else { return }

            // Decode the fetched GIF to CGImage on this background thread
            guard let cgImage = decodeCGImage(from: data) else { return }

            // Re-encode as JPEG for disk cache — ~5-10× smaller than GIF
            let diskPath = cacheDir.appendingPathComponent("\(key).jpg")
            saveJPEG(cgImage, to: diskPath)

            let tex = makeTexture(from: cgImage)

            await MainActor.run { [weak self] in
                self?.imageCache[key] = CachedTile(image: cgImage, accessTime: Date())
                if let tex { self?.textureCache[key] = tex }
                self?.trimImageCache()
                self?.tileLoadCount += 1
            }
        } catch {
            // Silently fail — retried on next viewport update
        }
    }

    private func loadTileFromDisk(key: String, path: URL) async {
        guard let cgImage = loadCGImage(from: path) else { return }
        let tex = makeTexture(from: cgImage)
        await MainActor.run { [weak self] in
            self?.imageCache[key] = CachedTile(image: cgImage, accessTime: Date())
            if let tex { self?.textureCache[key] = tex }
            self?.trimImageCache()
            self?.tileLoadCount += 1
        }
    }

    // MARK: - Helpers

    /// Decode raw image data (GIF, JPEG, etc.) to a force-decoded CGImage on the calling thread.
    private func decodeCGImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return forceDecoded(cg)
    }

    /// Load and force-decode a CGImage from a file URL.
    private func loadCGImage(from url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return forceDecoded(cg)
    }

    /// Force full pixel decode into a fresh bitmap context so no lazy decode happens later.
    private func forceDecoded(_ cg: CGImage) -> CGImage? {
        let w = cg.width; let h = cg.height
        guard w > 0, h > 0 else { return nil }
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx?.makeImage()
    }

    /// Save a CGImage as JPEG to disk (quality 0.85 — good balance of size vs. quality for sky imagery).
    private func saveJPEG(_ cg: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// Upload a CGImage to GPU as an MTLTexture.
    private func makeTexture(from cgImage: CGImage) -> MTLTexture? {
        guard let loader = textureLoader else { return nil }
        return try? loader.newTexture(cgImage: cgImage, options: [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue as NSObject,
            .generateMipmaps: false as NSObject,
            .SRGB: false as NSObject
        ])
    }

    private func trimImageCache() {
        guard imageCache.count > maxMemoryCacheCount else { return }
        let sorted = imageCache.sorted { $0.value.accessTime < $1.value.accessTime }
        let removeCount = imageCache.count - maxMemoryCacheCount / 2
        for (key, _) in sorted.prefix(removeCount) {
            imageCache.removeValue(forKey: key)
            textureCache.removeValue(forKey: key)
        }
    }

    // MARK: - Control

    func cancelAllFetches() {
        fetchDebounceTask?.cancel()
        for (_, task) in inFlightTasks { task.cancel() }
        inFlightTasks.removeAll()
    }

    // MARK: - Disk Cache Management

    func updateCacheSize() {
        Task.detached { [cacheDir] in
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            var total: Int64 = 0
            for file in files {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            let mb = Double(total) / (1024 * 1024)
            await MainActor.run { self.cacheSizeMB = mb }
        }
    }

    func purgeCache() {
        cancelAllFetches()
        imageCache.removeAll()
        textureCache.removeAll()
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for file in files { try? fm.removeItem(at: file) }
        }
        cacheSizeMB = 0
    }
}
