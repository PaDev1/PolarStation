import Foundation

/// Writes SER v3 video files — the standard format for planetary/lunar imaging.
/// Raw uncompressed frames with per-frame timestamps, compatible with
/// AutoStakkert, RegiStax, PIPP, Siril, and other stacking software.
final class SERWriter {

    /// SER color ID values.
    enum ColorID: Int32 {
        case mono       = 0
        case bayerRGGB  = 8
        case bayerGRBG  = 9
        case bayerGBRG  = 10
        case bayerBGGR  = 11
        case bayerCYYM  = 16
        case bayerYCMY  = 17
        case bayerYMCY  = 18
        case bayerMYYC  = 19
        case rgb        = 100
        case bgr        = 101
    }

    private let fileHandle: FileHandle
    private let fileURL: URL
    private let imageWidth: Int32
    private let imageHeight: Int32
    private let pixelDepth: Int32       // bits per pixel per plane
    private let colorID: ColorID
    private let bytesPerFrame: Int
    private(set) var frameCount: Int32 = 0
    private var frameTimestamps: [Int64] = []
    private let lock = NSLock()
    private var isClosed = false

    /// Create a new SER file.
    /// - Parameters:
    ///   - url: File path for the .ser file.
    ///   - width: Image width in pixels.
    ///   - height: Image height in pixels.
    ///   - bitsPerPixel: Bits per pixel per plane (8 or 16).
    ///   - colorID: Bayer pattern or mono.
    ///   - observer: Observer name (max 40 chars).
    ///   - instrument: Camera name (max 40 chars).
    ///   - telescope: Telescope name (max 40 chars).
    init(url: URL,
         width: Int,
         height: Int,
         bitsPerPixel: Int,
         colorID: ColorID = .mono,
         observer: String = "",
         instrument: String = "",
         telescope: String = "") throws {

        self.fileURL = url
        self.imageWidth = Int32(width)
        self.imageHeight = Int32(height)
        self.pixelDepth = Int32(bitsPerPixel)
        self.colorID = colorID

        let bytesPerPixel = bitsPerPixel <= 8 ? 1 : 2
        let planesMultiplier = (colorID == .rgb || colorID == .bgr) ? 3 : 1
        self.bytesPerFrame = width * height * bytesPerPixel * planesMultiplier

        // Create file and write initial header
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        self.fileHandle = handle

        try writeHeader(observer: observer, instrument: instrument, telescope: telescope)
    }

    /// Append a raw frame. Buffer must contain exactly `bytesPerFrame` bytes.
    /// Thread-safe and a no-op after `finalize()`.
    func addFrame(_ buffer: UnsafeBufferPointer<UInt8>) {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { return }
        let data = Data(bytes: buffer.baseAddress!, count: min(buffer.count, bytesPerFrame))
        fileHandle.write(data)
        frameCount += 1

        // Record timestamp as .NET DateTime ticks (100ns intervals since 0001-01-01)
        let utcNow = Date()
        let ticks = Self.dateToTicks(utcNow)
        frameTimestamps.append(ticks)
    }

    /// Finalize the file: update frame count in header and write timestamp trailer.
    /// Thread-safe and idempotent.
    func finalize() {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true

        // Write per-frame timestamp trailer
        var ticksData = Data(capacity: frameTimestamps.count * 8)
        for ticks in frameTimestamps {
            var t = ticks
            ticksData.append(Data(bytes: &t, count: 8))
        }
        fileHandle.write(ticksData)

        // Seek back and update frame count in header (offset 38, 4 bytes LE)
        fileHandle.seek(toFileOffset: 38)
        var count = frameCount
        fileHandle.write(Data(bytes: &count, count: 4))

        fileHandle.closeFile()
    }

    // MARK: - Private

    private func writeHeader(observer: String, instrument: String, telescope: String) throws {
        var header = Data(count: 178)

        // Bytes 0-13: File ID "LUCAM-RECORDER"
        let fileID = "LUCAM-RECORDER"
        header.replaceSubrange(0..<14, with: fileID.utf8.prefix(14))

        // Bytes 14-17: LuID (unused, set to 0)
        writeInt32(&header, offset: 14, value: 0)

        // Bytes 18-21: ColorID
        writeInt32(&header, offset: 18, value: colorID.rawValue)

        // Bytes 22-25: LittleEndian (0=big-endian, non-zero=little-endian)
        writeInt32(&header, offset: 22, value: 1)  // ASI cameras output little-endian

        // Bytes 26-29: ImageWidth
        writeInt32(&header, offset: 26, value: imageWidth)

        // Bytes 30-33: ImageHeight
        writeInt32(&header, offset: 30, value: imageHeight)

        // Bytes 34-37: PixelDepthPerPlane (bits)
        writeInt32(&header, offset: 34, value: pixelDepth)

        // Bytes 38-41: FrameCount (updated on finalize)
        writeInt32(&header, offset: 38, value: 0)

        // Bytes 42-81: Observer (40 bytes, padded with zeros)
        writeString(&header, offset: 42, length: 40, value: observer)

        // Bytes 82-121: Instrument (40 bytes)
        writeString(&header, offset: 82, length: 40, value: instrument)

        // Bytes 122-161: Telescope (40 bytes)
        writeString(&header, offset: 122, length: 40, value: telescope)

        // Bytes 162-169: DateTime (local time as .NET ticks)
        let now = Date()
        var localTicks = Self.dateToTicks(now)
        header.replaceSubrange(162..<170, with: Data(bytes: &localTicks, count: 8))

        // Bytes 170-177: DateTimeUTC
        var utcTicks = Self.dateToTicks(now)
        header.replaceSubrange(170..<178, with: Data(bytes: &utcTicks, count: 8))

        fileHandle.write(header)
    }

    private func writeInt32(_ data: inout Data, offset: Int, value: Int32) {
        var v = value.littleEndian
        data.replaceSubrange(offset..<offset+4, with: Data(bytes: &v, count: 4))
    }

    private func writeString(_ data: inout Data, offset: Int, length: Int, value: String) {
        let bytes = Array(value.utf8.prefix(length))
        for (i, b) in bytes.enumerated() {
            data[offset + i] = b
        }
    }

    /// Convert a Swift Date to .NET DateTime ticks (100-nanosecond intervals since 0001-01-01).
    static func dateToTicks(_ date: Date) -> Int64 {
        // .NET epoch is 0001-01-01 00:00:00 UTC
        // Unix epoch is 1970-01-01 00:00:00 UTC
        // Difference: 621355968000000000 ticks
        let unixSeconds = date.timeIntervalSince1970
        let ticks = Int64(unixSeconds * 10_000_000) + 621_355_968_000_000_000
        return ticks
    }
}
