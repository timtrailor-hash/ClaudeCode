import SwiftUI
import Charts

// MARK: - Graph Data Models

struct SpeedGraphEntry: Decodable, Identifiable {
    var id: Int { layer }
    let alpha: Double
    let layer: Int
    let optimal_pct: Int
    let status: String
}

struct EtaHistoryEntry: Decodable, Identifiable {
    var id: Double { elapsed_h }
    let elapsed_h: Double
    let finish_str: String
    let finish_ts: Double
    let progress: Double
    let remaining_h: Double
}

// MARK: - Speed Profile Graph

struct SpeedProfileChart: View {
    let data: [SpeedGraphEntry]
    let currentLayer: Int?
    let currentSpeedPct: Int?

    private let accent = Color(hex: "#C9A96E")
    private let chartBg = Color(hex: "#0D1520")

    private var yDomain: ClosedRange<Int> {
        let values = data.map { min($0.optimal_pct, 500) }
        let maxVal = values.max() ?? 200
        let minVal = values.min() ?? 0
        let lo = max(0, minVal - 20)
        let hi = maxVal + 20
        return lo...hi
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Speed Profile")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(hex: "#AAAAAA"))
                Spacer()
                Text("Speed %")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "#666666"))
            }

            Chart {
                ForEach(data.filter { $0.status == "past" }) { entry in
                    LineMark(
                        x: .value("Layer", entry.layer),
                        y: .value("Speed %", min(entry.optimal_pct, 500))
                    )
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }

                ForEach(data.filter { $0.status == "future" }) { entry in
                    LineMark(
                        x: .value("Layer", entry.layer),
                        y: .value("Speed %", min(entry.optimal_pct, 500))
                    )
                    .foregroundStyle(.green.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }

                if let current = data.first(where: { $0.status == "current" }) {
                    PointMark(
                        x: .value("Layer", current.layer),
                        y: .value("Speed %", min(current.optimal_pct, 500))
                    )
                    .foregroundStyle(.blue)
                    .symbolSize(40)

                    RuleMark(x: .value("Current", current.layer))
                        .foregroundStyle(.blue.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }

                RuleMark(y: .value("100%", 100))
                    .foregroundStyle(.white.opacity(0.2))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
            }
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                        .foregroundStyle(.white.opacity(0.1))
                    AxisValueLabel()
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: "#888888"))
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                        .foregroundStyle(.white.opacity(0.1))
                    if let pct = value.as(Int.self) {
                        AxisValueLabel {
                            Text("\(pct)%")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(Color(hex: "#888888"))
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.padding(.leading, 4)
            }
            .frame(height: 210)
            .padding(.top, 4)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .background(chartBg)
            .cornerRadius(10)

            // Legend
            HStack(spacing: 12) {
                legendDot(color: .green, label: "Optimal %")
                legendDot(color: .blue, label: "Current")
                if let pct = currentSpeedPct {
                    Text("Set: \(pct)%")
                        .font(.system(size: 12))
                        .foregroundColor(accent)
                }
            }
            .padding(.leading, 4)
        }
    }
}

// MARK: - ETA History Graph (Y-axis = predicted finish time)

struct EtaHistoryChart: View {
    let data: [EtaHistoryEntry]

    private let accent = Color(hex: "#C9A96E")
    private let chartBg = Color(hex: "#0D1520")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ETA History")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(hex: "#AAAAAA"))

                Spacer()

                // Drift indicator
                if data.count >= 2 {
                    let firstTs = data.first!.finish_ts
                    let lastTs = data.last!.finish_ts
                    let driftSec = lastTs - firstTs
                    let driftMin = Int(abs(driftSec) / 60)
                    HStack(spacing: 3) {
                        Image(systemName: driftSec > 900 ? "arrow.up.right" : driftSec < -900 ? "arrow.down.right" : "equal")
                            .font(.system(size: 10))
                        Text(driftMin < 2 ? "stable" : driftMin < 60 ? "\(driftMin)m \(driftSec > 0 ? "late" : "early")" : "\(driftMin / 60)h\(driftMin % 60)m \(driftSec > 0 ? "late" : "early")")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(abs(driftSec) < 900 ? .green : driftSec > 0 ? .red : .green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((abs(driftSec) < 900 ? Color.green : driftSec > 0 ? Color.red : Color.green).opacity(0.15))
                    .cornerRadius(4)
                }
            }

            Chart(data) { entry in
                LineMark(
                    x: .value("Elapsed", entry.elapsed_h),
                    y: .value("Finish", entry.finish_ts)
                )
                .foregroundStyle(accent)
                .lineStyle(StrokeStyle(lineWidth: 1.5))

                PointMark(
                    x: .value("Elapsed", entry.elapsed_h),
                    y: .value("Finish", entry.finish_ts)
                )
                .foregroundStyle(accent.opacity(0.4))
                .symbolSize(8)
            }
            .chartYScale(domain: yDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                        .foregroundStyle(.white.opacity(0.1))
                    if let h = value.as(Double.self) {
                        AxisValueLabel {
                            Text(String(format: "%.0fh", h))
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(Color(hex: "#888888"))
                    }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                        .foregroundStyle(.white.opacity(0.1))
                    if let ts = value.as(Double.self) {
                        AxisValueLabel {
                            Text(formatAxisDate(Date(timeIntervalSince1970: ts)))
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(Color(hex: "#888888"))
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.padding(.leading, 4)
            }
            .frame(height: 210)
            .padding(.top, 4)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .background(chartBg)
            .cornerRadius(10)

            // Current ETA label
            if let last = data.last {
                HStack {
                    Spacer()
                    Text("Current ETA: \(last.finish_str)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(accent)
                }
                .padding(.trailing, 4)
            }
        }
    }

    /// Tight Y-axis domain based on actual data range + 10% padding (min 30 min)
    private var yDomain: ClosedRange<Double> {
        let timestamps = data.map(\.finish_ts)
        guard let minTs = timestamps.min(), let maxTs = timestamps.max() else {
            return 0...1
        }
        let range = maxTs - minTs
        let padding = max(range * 0.1, 1800) // At least 30 min padding
        return (minTs - padding)...(maxTs + padding)
    }

    private func formatAxisDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE HH:mm"
        return fmt.string(from: date)
    }
}

// MARK: - Complexity (Alpha) Graph

struct ComplexityChart: View {
    let data: [SpeedGraphEntry]
    let currentLayer: Int?

    private let accent = Color(hex: "#C9A96E")
    private let chartBg = Color(hex: "#0D1520")

    private var yMax: Double {
        let maxAlpha = data.map { min($0.alpha, 2.0) }.max() ?? 1.0
        // Round up to next 0.5 step for clean ticks
        return max(0.5, (maxAlpha * 2.0).rounded(.up) / 2.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Layer Complexity")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(hex: "#AAAAAA"))
                Spacer()
                Text("\u{03B1}")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "#666666"))
            }

            Chart {
                ForEach(data) { entry in
                    AreaMark(
                        x: .value("Layer", entry.layer),
                        y: .value("Alpha", min(entry.alpha, 2.0))
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.red.opacity(0.3), .red.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }

                ForEach(data.filter { $0.status == "past" }) { entry in
                    LineMark(
                        x: .value("Layer", entry.layer),
                        y: .value("Alpha", min(entry.alpha, 2.0))
                    )
                    .foregroundStyle(.red)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.catmullRom)
                }

                ForEach(data.filter { $0.status == "future" }) { entry in
                    LineMark(
                        x: .value("Layer", entry.layer),
                        y: .value("Alpha", min(entry.alpha, 2.0))
                    )
                    .foregroundStyle(.red.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .interpolationMethod(.catmullRom)
                }

                if let current = data.first(where: { $0.status == "current" }) {
                    PointMark(
                        x: .value("Layer", current.layer),
                        y: .value("Alpha", min(current.alpha, 2.0))
                    )
                    .foregroundStyle(.blue)
                    .symbolSize(40)

                    RuleMark(x: .value("Current", current.layer))
                        .foregroundStyle(.blue.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: 0...yMax)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                        .foregroundStyle(.white.opacity(0.1))
                    AxisValueLabel()
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: "#888888"))
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                        .foregroundStyle(.white.opacity(0.1))
                    if let v = value.as(Double.self) {
                        AxisValueLabel {
                            Text(String(format: "%.1f", v))
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(Color(hex: "#888888"))
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.padding(.leading, 4)
            }
            .frame(height: 210)
            .padding(.top, 4)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .background(chartBg)
            .cornerRadius(10)

            // Legend
            HStack(spacing: 12) {
                Text("Low \u{03B1} = simple")
                    .font(.system(size: 12))
                    .foregroundColor(.green)
                Text("High \u{03B1} = complex")
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }
            .padding(.leading, 4)
        }
    }
}

// MARK: - Helper

private func legendDot(color: Color, label: String) -> some View {
    HStack(spacing: 4) {
        Circle().fill(color).frame(width: 7, height: 7)
        Text(label)
            .font(.system(size: 12))
            .foregroundColor(Color(hex: "#999999"))
    }
}
