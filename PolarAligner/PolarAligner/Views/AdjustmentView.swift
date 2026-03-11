import SwiftUI
import PolarCore

/// Real-time adjustment view showing polar alignment error as a bullseye target.
///
/// The dot moves toward center as the user turns altitude/azimuth screws.
/// Color coding: green (<2'), yellow (<10'), red (>10').
struct AdjustmentView: View {
    @ObservedObject var errorTracker: ErrorTracker

    var body: some View {
        VStack(spacing: 16) {
            Text("Polar Adjustment")
                .font(.title2)

            if let error = errorTracker.currentError {
                HStack(spacing: 32) {
                    // Bullseye
                    BullseyeView(error: error)
                        .frame(width: 280, height: 280)

                    // Readout + directions
                    VStack(alignment: .leading, spacing: 16) {
                        // Total error
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Total Error")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.1f'", error.totalErrorArcmin))
                                .font(.system(size: 42, weight: .bold, design: .rounded))
                                .foregroundStyle(errorColor(error.totalErrorArcmin))
                        }

                        Divider()

                        // Altitude
                        AdjustmentRow(
                            label: "Altitude",
                            value: error.altErrorArcmin,
                            direction: error.altErrorArcmin > 0 ? "Lower mount" : "Raise mount",
                            icon: error.altErrorArcmin > 0 ? "arrow.down" : "arrow.up"
                        )

                        // Azimuth
                        AdjustmentRow(
                            label: "Azimuth",
                            value: error.azErrorArcmin,
                            direction: error.azErrorArcmin > 0 ? "Turn left" : "Turn right",
                            icon: error.azErrorArcmin > 0 ? "arrow.left" : "arrow.right"
                        )

                        Divider()

                        // Status
                        HStack(spacing: 6) {
                            Circle()
                                .fill(errorTracker.isTracking ? .green : .gray)
                                .frame(width: 8, height: 8)
                            Text(errorTracker.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 200)
                }

                // Error history graph
                if errorTracker.errorHistory.count > 1 {
                    ErrorHistoryGraph(samples: errorTracker.errorHistory)
                        .frame(height: 120)
                        .padding(.top, 8)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "scope")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Complete 3-point alignment first")
                        .foregroundStyle(.secondary)
                    Text("The alignment error will appear here for real-time adjustment")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, 40)
            }
        }
        .padding()
        .frame(minWidth: 550)
    }
}

// MARK: - Bullseye

struct BullseyeView: View {
    let error: PolarError

    /// Scale: 1 arcminute = this many points in the view.
    private let scale: Double = 12.0
    /// Max displayable error in arcminutes (dot clamps beyond this).
    private let maxRange: Double = 15.0

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = min(geo.size.width, geo.size.height) / 2

            ZStack {
                // Background
                Circle()
                    .fill(Color.black.opacity(0.3))

                // Zone rings
                ForEach([10.0, 5.0, 2.0, 1.0], id: \.self) { arcmin in
                    let r = arcmin * scale
                    if r < radius {
                        Circle()
                            .stroke(ringColor(arcmin), lineWidth: 1)
                            .frame(width: r * 2, height: r * 2)
                    }
                }

                // Crosshairs
                Path { path in
                    path.move(to: CGPoint(x: center.x, y: center.y - radius))
                    path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                    path.move(to: CGPoint(x: center.x - radius, y: center.y))
                    path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                }
                .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)

                // Error dot
                let clampedAz = max(-maxRange, min(maxRange, error.azErrorArcmin))
                let clampedAlt = max(-maxRange, min(maxRange, error.altErrorArcmin))
                let dotX = center.x + clampedAz * scale
                let dotY = center.y + clampedAlt * scale  // positive alt = down (lower)

                Circle()
                    .fill(errorColor(error.totalErrorArcmin))
                    .frame(width: 14, height: 14)
                    .shadow(color: errorColor(error.totalErrorArcmin).opacity(0.6), radius: 4)
                    .position(x: dotX, y: dotY)

                // Ring labels
                VStack {
                    Spacer()
                    HStack {
                        Text("2'").font(.system(size: 9)).foregroundStyle(.green.opacity(0.6))
                        Spacer()
                    }
                    .padding(.leading, center.x - 2.0 * scale - 10)
                }

                // Axis labels
                VStack {
                    Text("Alt-").font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer()
                    Text("Alt+").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                HStack {
                    Text("Az-").font(.system(size: 9)).foregroundStyle(.secondary)
                    Spacer()
                    Text("Az+").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func ringColor(_ arcmin: Double) -> Color {
        if arcmin <= 2 { return .green.opacity(0.4) }
        if arcmin <= 5 { return .yellow.opacity(0.3) }
        return .red.opacity(0.2)
    }
}

// MARK: - Adjustment Row

struct AdjustmentRow: View {
    let label: String
    let value: Double
    let direction: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(String(format: "%+.1f'", value))
                    .font(.system(.title3, design: .monospaced))
                Image(systemName: icon)
                    .foregroundStyle(.orange)
                Text(direction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Error History Graph

struct ErrorHistoryGraph: View {
    let samples: [ErrorTracker.ErrorSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Error History")
                .font(.caption)
                .foregroundStyle(.secondary)

            Canvas { context, size in
                let w = size.width
                let h = size.height
                guard let first = samples.first, let last = samples.last else { return }
                let timeRange = max(last.timestamp.timeIntervalSince(first.timestamp), 1.0)
                let maxError = max(samples.map(\.totalArcmin).max() ?? 10, 2.0)

                // Error curve
                var linePath = Path()
                for (i, sample) in samples.enumerated() {
                    let x = (sample.timestamp.timeIntervalSince(first.timestamp) / timeRange) * w
                    let y = h - (sample.totalArcmin / maxError) * h
                    if i == 0 { linePath.move(to: CGPoint(x: x, y: y)) }
                    else { linePath.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(linePath, with: .color(.green), lineWidth: 1.5)

                // 2' target line
                let targetY = h - (2.0 / maxError) * h
                var dashPath = Path()
                dashPath.move(to: CGPoint(x: 0, y: targetY))
                dashPath.addLine(to: CGPoint(x: w, y: targetY))
                context.stroke(dashPath, with: .color(.green.opacity(0.3)),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .background(Color.black.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

// MARK: - Helpers

private func errorColor(_ arcmin: Double) -> Color {
    if arcmin < 2 { return .green }
    if arcmin < 10 { return .yellow }
    return .red
}
