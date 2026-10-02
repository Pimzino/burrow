import Charts
import SwiftUI

/// A metric over time from `StatusMonitor.samples`.
struct StatusSeriesPoint: Identifiable, Equatable {
    let id: String
    let date: Date
    let value: Double
    let series: String
}

/// Tiny filled line chart for tiles.
struct StatusSparkline: View {
    let values: [(Date, Double)]
    var tint: Color
    var domain: ClosedRange<Double>? = nil

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value("Time", point.0), y: .value("Value", point.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.0), y: .value("Value", point.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartYScale(domain: domain ?? 0...max(0.0001, (values.map(\.1).max() ?? 1) * 1.15))
        .animation(.smooth(duration: 0.6), value: values.count)
        .accessibilityHidden(true)
    }
}

/// Glass card wrapping a titled history chart.
struct StatusChartCard<ChartContent: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    var legend: [(String, Color)] = []
    @ViewBuilder var chart: ChartContent

    var body: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    StatusIconBadge(symbol: symbol, tint: tint, size: 24)
                    Text(title).font(.headline)
                    Spacer()
                    ForEach(legend, id: \.0) { item in
                        HStack(spacing: 4) {
                            Circle().fill(item.1).frame(width: 7, height: 7)
                            Text(item.0).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(value)
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                chart.frame(height: 130)
            }
        }
    }
}

/// CPU / memory percentage history as a soft gradient area.
struct StatusPercentChart: View {
    let points: [(Date, Double)]
    let tint: Color
    let label: String

    var body: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("Time", p.0), y: .value(label, p.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0.03)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", p.0), y: .value(label, p.1))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let last = points.last {
                PointMark(x: .value("Time", last.0), y: .value(label, last.1))
                    .foregroundStyle(tint)
                    .symbolSize(40)
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])).foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v))%").font(.caption2) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute().second(), centered: false).font(.caption2)
            }
        }
        .accessibilityLabel("\(label) history")
        .accessibilityValue(points.last.map { String(format: "%.0f percent now", $0.1) } ?? "No data")
    }
}

/// Two overlapping rate series (download/upload, read/write).
struct StatusRateChart: View {
    let points: [StatusSeriesPoint]
    let colors: [String: Color]

    var body: some View {
        let maxValue = max(0.01, (points.map(\.value).max() ?? 0) * 1.2)
        Chart(points) { p in
            AreaMark(x: .value("Time", p.date), y: .value("Rate", p.value),
                     series: .value("Series", p.series), stacking: .unstacked)
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [(colors[p.series] ?? .accentColor).opacity(0.30),
                                                         (colors[p.series] ?? .accentColor).opacity(0.02)],
                                                startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", p.date), y: .value("Rate", p.value), series: .value("Series", p.series))
                .interpolationMethod(.monotone)
                .foregroundStyle(colors[p.series] ?? .accentColor)
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .chartLegend(.hidden)
        .chartYScale(domain: 0...maxValue)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3])).foregroundStyle(.quaternary)
                AxisValueLabel { if let v = value.as(Double.self) { Text(StatusFormat.rate(v)).font(.caption2) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute().second(), centered: false).font(.caption2)
            }
        }
    }
}

/// Placeholder while the first couple of samples arrive.
struct StatusChartWarmup: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Collecting samples…").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
