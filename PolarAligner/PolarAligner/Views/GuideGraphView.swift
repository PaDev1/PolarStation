import SwiftUI

/// Scrolling timeline graph showing RA and Dec guiding error.
///
/// Similar to PHD2's guide graph: two lines (RA blue, Dec red) over time,
/// with a zero reference line and RMS readout.
struct GuideGraphView: View {
    @ObservedObject var session: GuideSession

    /// Time window to display (seconds).
    var timeWindowSec: Double = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header with RMS readout
            HStack(spacing: 16) {
                Text("Guide Graph")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if !session.samples.isEmpty {
                    HStack(spacing: 8) {
                        HStack(spacing: 3) {
                            Circle().fill(.blue).frame(width: 6, height: 6)
                            Text(String(format: "RA %.2f\"", session.raRMSArcsec))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.blue)
                            Text(String(format: "pk %.1f\"", session.raPeakArcsec))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.blue.opacity(0.5))
                        }

                        HStack(spacing: 3) {
                            Circle().fill(.red).frame(width: 6, height: 6)
                            Text(String(format: "Dec %.2f\"", session.decRMSArcsec))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.red)
                            Text(String(format: "pk %.1f\"", session.decPeakArcsec))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.red.opacity(0.5))
                        }

                        Text(String(format: "Total %.2f\"", session.totalRMSArcsec))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Graph canvas
            Canvas { context, size in
                drawGraph(context: context, size: size)
            }
            .background(Color.black.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    // MARK: - Drawing

    private func drawGraph(context: GraphicsContext, size: CGSize) {
        let w = size.width
        let h = size.height
        let samples = session.samples

        guard samples.count >= 2 else {
            // Placeholder text
            let text = Text("No guide data")
                .font(.caption)
                .foregroundColor(.secondary)
            context.draw(text, at: CGPoint(x: w / 2, y: h / 2), anchor: .center)
            return
        }

        // Time range: last N seconds from the most recent sample
        let now = samples.last!.timestamp
        let windowStart = now.addingTimeInterval(-timeWindowSec)

        // Auto-scale Y axis based on max error in the visible window
        let visibleSamples = samples.filter { $0.timestamp >= windowStart }
        let maxAbsError = visibleSamples.reduce(2.0) { maxVal, s in
            max(maxVal, abs(s.raErrorArcsec), abs(s.decErrorArcsec))
        }
        let yScale = maxAbsError * 1.2  // 20% headroom

        // Zero line (dashed)
        let midY = h / 2
        var zeroPath = Path()
        zeroPath.move(to: CGPoint(x: 0, y: midY))
        zeroPath.addLine(to: CGPoint(x: w, y: midY))
        context.stroke(zeroPath, with: .color(.gray.opacity(0.4)),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

        // Y grid lines at ±1", ±2", etc.
        let gridStep = gridStepForScale(yScale)
        var gridVal = gridStep
        while gridVal < yScale {
            let yUp = midY - CGFloat(gridVal / yScale) * midY
            let yDown = midY + CGFloat(gridVal / yScale) * midY

            var gridPath = Path()
            gridPath.move(to: CGPoint(x: 0, y: yUp))
            gridPath.addLine(to: CGPoint(x: w, y: yUp))
            gridPath.move(to: CGPoint(x: 0, y: yDown))
            gridPath.addLine(to: CGPoint(x: w, y: yDown))
            context.stroke(gridPath, with: .color(.gray.opacity(0.15)),
                            style: StrokeStyle(lineWidth: 0.5))

            // Label
            let label = Text(String(format: "%.0f\"", gridVal))
                .font(.system(size: 8))
                .foregroundColor(.gray.opacity(0.5))
            context.draw(label, at: CGPoint(x: w - 2, y: yUp), anchor: .bottomTrailing)

            gridVal += gridStep
        }

        // Correction bars: drawn on OPPOSITE side of error to show compensation
        // Drawn BEFORE error lines so they appear behind
        let maxCorrMs = visibleSamples.reduce(100.0) { maxVal, s in
            max(maxVal, abs(s.raCorrectionMs), abs(s.decCorrectionMs))
        }
        let corrScale = maxCorrMs * 1.2
        let barWidth: CGFloat = max(1, w / CGFloat(max(visibleSamples.count, 1)) * 0.3)

        for sample in visibleSamples {
            let t = sample.timestamp.timeIntervalSince(windowStart) / timeWindowSec
            let x = CGFloat(t) * w

            // RA correction bar (blue) — flipped: positive correction draws DOWN (opposing positive error)
            if abs(sample.raCorrectionMs) > 1 {
                let barH = CGFloat(abs(sample.raCorrectionMs) / corrScale) * midY
                let barY = sample.raCorrectionMs > 0 ? midY : midY - barH
                var bar = Path()
                bar.addRect(CGRect(x: x - barWidth, y: barY, width: barWidth, height: barH))
                context.fill(bar, with: .color(.blue.opacity(0.3)))
            }

            // Dec correction bar (red) — flipped, offset right
            if abs(sample.decCorrectionMs) > 1 {
                let barH = CGFloat(abs(sample.decCorrectionMs) / corrScale) * midY
                let barY = sample.decCorrectionMs > 0 ? midY : midY - barH
                var bar = Path()
                bar.addRect(CGRect(x: x, y: barY, width: barWidth, height: barH))
                context.fill(bar, with: .color(.red.opacity(0.3)))
            }
        }

        // RA error line (blue) — drawn on top of correction bars
        drawLine(context: context, samples: visibleSamples, size: size,
                 yScale: yScale, windowStart: windowStart, timeWindow: timeWindowSec,
                 value: { $0.raErrorArcsec }, color: .blue)

        // Dec error line (red)
        drawLine(context: context, samples: visibleSamples, size: size,
                 yScale: yScale, windowStart: windowStart, timeWindow: timeWindowSec,
                 value: { $0.decErrorArcsec }, color: .red)

        // Y axis label
        let scaleLabel = Text(String(format: "±%.1f\"", yScale))
            .font(.system(size: 8))
            .foregroundColor(.gray.opacity(0.4))
        context.draw(scaleLabel, at: CGPoint(x: 2, y: 2), anchor: .topLeading)
    }

    private func drawLine(
        context: GraphicsContext,
        samples: [GuideSample],
        size: CGSize,
        yScale: Double,
        windowStart: Date,
        timeWindow: Double,
        value: (GuideSample) -> Double,
        color: Color
    ) {
        let w = size.width
        let h = size.height
        let midY = h / 2

        var path = Path()
        for (i, sample) in samples.enumerated() {
            let t = sample.timestamp.timeIntervalSince(windowStart) / timeWindow
            let x = CGFloat(t) * w
            let y = midY - CGFloat(value(sample) / yScale) * midY

            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }

    /// Choose a nice grid step for the given Y scale.
    private func gridStepForScale(_ scale: Double) -> Double {
        if scale <= 1 { return 0.5 }
        if scale <= 2 { return 1.0 }
        if scale <= 5 { return 2.0 }
        if scale <= 10 { return 5.0 }
        return 10.0
    }
}
