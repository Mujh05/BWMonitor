import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let server = state.selectedServer {
                    ServerHero(
                        server: server,
                        metrics: state.selectedMetrics,
                        traffic: state.selectedTraffic,
                        isOnline: state.isOnline(server.id),
                        sshConnected: state.selectedConnection.isConnected
                    )
                    ConnectionStatusCard(server: server)

                    if let metrics = state.selectedMetrics {
                        MetricsGrid(metrics: metrics)
                        NetworkStrip(metrics: metrics)
                    }

                    if let traffic = state.selectedTraffic {
                        TrafficSection(traffic: traffic, records: state.history)
                    }

                    if !state.history.isEmpty {
                        HistoryOverview(records: state.history, range: state.historyRange)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1_300, alignment: .leading)
        }
        .navigationTitle("Overview")
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ServerHero: View {
    let server: Server
    let metrics: ServerMetrics?
    let traffic: BandwagonTraffic?
    let isOnline: Bool?
    let sshConnected: Bool

    private var statusColor: Color {
        switch isOnline {
        case true: .green
        case false: .red
        default: .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .shadow(color: isOnline == true ? .green.opacity(0.35) : .clear, radius: 5)
                    Text(server.name)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                }
                Text("\(server.host)  ·  \(server.operatingSystem)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 18) {
                    StatusLabel(text: "SSH", active: sshConnected)
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
        TrafficForecaster.forecast(
            current: traffic,
            recentDailyUsage: TrafficForecaster.dailyUsage(samples: records.map { ($0.timestamp, $0.trafficUsed) })
        )
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
    let range: HistoryRange

    private var timeLabel: String { NSLocalizedString("Time", comment: "Chart axis") }
    private var cpuLabel: String { NSLocalizedString("CPU", comment: "Chart metric") }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("CPU History")
                    .font(.title2.weight(.semibold))
                Text(range.localizedTitle)
                    .foregroundStyle(.secondary)
            }
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
            .accessibilityLabel("CPU History")
        }
    }
}

/// Explains why no live data is shown and offers the next step.
private struct ConnectionStatusCard: View {
    @EnvironmentObject private var state: AppState
    let server: Server

    var body: some View {
        if let content {
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if content.showsProgress {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: content.symbol)
                            .foregroundStyle(content.tint)
                    }
                }
                .font(.title2)
                .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(content.title)
                        .font(.headline)
                    Text(content.message)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    ForEach(content.actions, id: \.title) { action in
                        if action.primary {
                            Button(action.title, action: action.run)
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button(action.title, action: action.run)
                        }
                    }
                }
                .fixedSize()
            }
            .padding(18)
            .background(content.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private struct Action {
        let title: String
        var primary = false
        let run: () -> Void
    }

    private struct Content {
        var symbol: String
        var tint: Color
        var title: String
        var message: String
        var showsProgress = false
        var actions: [Action] = []
    }

    private var content: Content? {
        if state.isDemoMode { return nil }
        let edit = Action(title: NSLocalizedString("Edit Server…", comment: "Dashboard action")) { state.edit(server) }
        let retry = Action(title: NSLocalizedString("Try Again", comment: "Dashboard action"), primary: true) {
            state.stopMonitoring()
            state.beginMonitoring()
        }
        guard state.ssh.isTrusted(server) else {
            return Content(
                symbol: "lock.shield",
                tint: .accentColor,
                title: NSLocalizedString("Finish setting up the connection", comment: "Dashboard status"),
                message: NSLocalizedString(
                    "Verify the server's host key and choose how BWMonitor signs in. It takes a minute and only needs to be done once.",
                    comment: "Dashboard status"
                ),
                actions: [Action(title: NSLocalizedString("Set Up Connection…", comment: "Dashboard action"), primary: true) {
                    state.edit(server)
                }]
            )
        }
        switch state.selectedConnection {
        case .connected:
            return nil
        case .connecting:
            guard state.selectedMetrics == nil else { return nil }
            return Content(
                symbol: "",
                tint: .secondary,
                title: String(format: NSLocalizedString("Connecting to %@…", comment: "Dashboard status"), server.name),
                message: NSLocalizedString("The first sample takes a few seconds.", comment: "Dashboard status"),
                showsProgress: true
            )
        case .idle:
            guard state.selectedMetrics == nil else { return nil }
            return Content(
                symbol: "pause.circle",
                tint: .secondary,
                title: NSLocalizedString("Monitoring is off", comment: "Dashboard status"),
                message: NSLocalizedString("Start monitoring to collect live CPU, memory, disk and network data.", comment: "Dashboard status"),
                actions: [Action(title: NSLocalizedString("Start Monitoring", comment: "Dashboard action"), primary: true) {
                    state.beginMonitoring()
                }]
            )
        case let .retrying(message):
            return Content(
                symbol: "arrow.clockwise.circle",
                tint: .orange,
                title: NSLocalizedString("Connection lost, retrying", comment: "Dashboard status"),
                message: message,
                actions: [retry]
            )
        case let .failed(message):
            return Content(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                title: NSLocalizedString("Could not read the server's data", comment: "Dashboard status"),
                message: message,
                actions: [retry]
            )
        case let .needsAttention(error):
            let message = state.explanation(for: error, server: server)
            var actions = [edit, retry]
            if case .keyPermissionsTooOpen = error {
                actions.insert(Action(title: NSLocalizedString("Fix Key Permissions", comment: "Dashboard action"), primary: true) {
                    try? SSHKeyInspector.restrictPermissions(path: server.privateKeyPath)
                    state.beginMonitoring()
                }, at: 0)
                actions.removeLast()
            }
            return Content(
                symbol: "exclamationmark.triangle.fill",
                tint: .red,
                title: NSLocalizedString("Monitoring paused", comment: "Dashboard status"),
                message: message,
                actions: actions
            )
        }
    }
}
