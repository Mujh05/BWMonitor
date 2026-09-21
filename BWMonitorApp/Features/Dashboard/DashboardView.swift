import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let server = state.selectedServer {
                    ServerHero(server: server, metrics: state.selectedMetrics, traffic: state.selectedTraffic)

                    if let metrics = state.selectedMetrics {
                        MetricsGrid(metrics: metrics)
                        NetworkStrip(metrics: metrics)
                    } else {
                        monitoringPlaceholder
                    }

                    if let traffic = state.selectedTraffic {
                        TrafficSection(traffic: traffic, records: state.history)
                    }

                    if !state.history.isEmpty {
                        HistoryOverview(records: state.history)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1_300, alignment: .leading)
        }
        .navigationTitle("Overview")
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var monitoringPlaceholder: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("No live SSH sample yet")
                    .font(.headline)
                Text("Verify the host key, then start monitoring or refresh once.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 16)
    }
}

private struct ServerHero: View {
    let server: Server
    let metrics: ServerMetrics?
    let traffic: BandwagonTraffic?

    var isOnline: Bool { traffic?.serverOnline ?? (metrics != nil) }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(isOnline ? Color.green : Color.secondary)
                        .frame(width: 10, height: 10)
                        .shadow(color: isOnline ? .green.opacity(0.35) : .clear, radius: 5)
                    Text(server.name)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                }
                Text("\(server.host)  ·  \(server.operatingSystem)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 18) {
                    StatusLabel(text: "SSH", active: metrics != nil)
                    StatusLabel(text: "KiwiVM", active: traffic != nil)
                }
                .padding(.top, 4)
            }
            Spacer()
            if let metrics {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Uptime")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(BWFormat.duration(metrics.uptime))
                        .font(.title.weight(.semibold))
                        .monospacedDigit()
                    Text("Load \(metrics.load1, format: .number.precision(.fractionLength(2)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

private struct MetricsGrid: View {
    let metrics: ServerMetrics

    var body: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 16) {
            GridRow {
                GaugeMetric(
                    title: "CPU",
                    value: metrics.cpuUsage,
                    detail: "\(metrics.cpuCores) cores  ·  user \(metrics.cpuUser.formatted(BWFormat.percentage))  ·  system \(metrics.cpuSystem.formatted(BWFormat.percentage))",
                    tint: .blue
                )
                GaugeMetric(
                    title: "Memory",
                    value: metrics.memoryPercentage,
                    detail: "\(metrics.memoryUsed.byteString) of \(metrics.memoryTotal.byteString)",
                    tint: .purple
                )
                GaugeMetric(
                    title: "Disk",
                    value: metrics.diskPercentage,
                    detail: "\(metrics.diskUsed.byteString) of \(metrics.diskTotal.byteString)",
                    tint: .orange
                )
            }
            GridRow {
                loadPanel
                    .gridCellColumns(2)
                GaugeMetric(
                    title: "Swap",
                    value: metrics.swapPercentage,
                    detail: "\(metrics.swapUsed.byteString) of \(metrics.swapTotal.byteString)",
                    tint: .indigo
                )
            }
        }
    }

    private var loadPanel: some View {
        HStack(spacing: 30) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Load Average")
                    .font(.headline)
                Text("Linux scheduler pressure")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            loadValue("1 min", metrics.load1)
            loadValue("5 min", metrics.load5)
            loadValue("15 min", metrics.load15)
        }
        .padding(18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func loadValue(_ label: LocalizedStringKey, _ value: Double) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(value, format: .number.precision(.fractionLength(2)))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NetworkStrip: View {
    let metrics: ServerMetrics

    var body: some View {
        HStack(spacing: 32) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metrics.networkDownloadRate.rateString)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("Download")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title)
                    .foregroundStyle(.blue)
            }
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(metrics.networkUploadRate.rateString)
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("Upload")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
                    .foregroundStyle(.mint)
            }
            Spacer()
            Text(metrics.networkInterface)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 4)
    }
}

private struct TrafficSection: View {
    let traffic: BandwagonTraffic
    let records: [MetricRecord]

    private var forecast: TrafficForecast {
        let daily: [UInt64]
        if let first = records.first, let last = records.last, last.trafficUsed >= first.trafficUsed {
            daily = [last.trafficUsed - first.trafficUsed]
        } else {
            daily = []
        }
        return TrafficForecaster.forecast(current: traffic, recentDailyUsage: daily)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Monthly Traffic")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("Resets \(traffic.nextReset, format: .dateTime.month(.abbreviated).day())")
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .lastTextBaseline, spacing: 7) {
                Text(traffic.used.byteString)
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .monospacedDigit()
                Text("of \(traffic.limit.byteString)")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(traffic.usagePercentage, format: BWFormat.percentage)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            ProgressView(value: traffic.usagePercentage)
                .tint(traffic.usagePercentage >= 0.8 ? .orange : .green)
            HStack {
                Text("\(traffic.remaining.byteString) remaining")
                Spacer()
                if forecast.isAtRisk {
                    Label("Projected to exceed plan", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Label("On track for this cycle", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .font(.callout)
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct HistoryOverview: View {
    let records: [MetricRecord]

    private var timeLabel: String { NSLocalizedString("Time", comment: "Chart axis") }
    private var cpuLabel: String { NSLocalizedString("CPU", comment: "Chart metric") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last 24 Hours")
                .font(.title2.weight(.semibold))
            Chart(records) { record in
                LineMark(
                    x: .value(timeLabel, record.timestamp),
                    y: .value(cpuLabel, record.cpuUsage)
                )
                .foregroundStyle(.blue)
                .interpolationMethod(.catmullRom)
                AreaMark(
                    x: .value(timeLabel, record.timestamp),
                    y: .value(cpuLabel, record.cpuUsage)
                )
                .foregroundStyle(.blue.opacity(0.09))
                .interpolationMethod(.catmullRom)
            }
            .chartYScale(domain: 0...1)
            .chartYAxis {
                AxisMarks(values: [0, 0.5, 1]) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(number, format: BWFormat.percentage)
                        }
                    }
                }
            }
            .frame(height: 190)
            .accessibilityLabel("CPU history for the last 24 hours")
        }
    }
}
