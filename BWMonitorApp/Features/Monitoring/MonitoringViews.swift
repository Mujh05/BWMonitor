import Charts
import SwiftUI

struct PerformanceView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let metrics = state.selectedMetrics {
                    HStack(spacing: 18) {
                        GaugeMetric(title: "CPU", value: metrics.cpuUsage, detail: "\(metrics.cpuCores) logical cores", tint: .blue)
                        GaugeMetric(title: "Memory", value: metrics.memoryPercentage, detail: "\(metrics.memoryUsed.byteString) used", tint: .purple)
                        GaugeMetric(title: "Swap", value: metrics.swapPercentage, detail: "\(metrics.swapUsed.byteString) used", tint: .indigo)
                    }
                    HStack {
                        Text("History")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        RangePicker(range: $state.historyRange)
                    }
                    PerformanceChart(records: state.history)
                    memoryDetails(metrics)
                } else {
                    ContentUnavailableView("No performance sample", systemImage: "waveform.path.ecg", description: Text("Start monitoring to collect live Linux metrics."))
                }
            }
            .padding(28)
        }
        .navigationTitle("Performance")
    }

    private func memoryDetails(_ metrics: ServerMetrics) -> some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 36, verticalSpacing: 10) {
                GridRow { Text("Total").foregroundStyle(.secondary); Text(metrics.memoryTotal.byteString).monospacedDigit() }
                GridRow { Text("Available").foregroundStyle(.secondary); Text(metrics.memoryAvailable.byteString).monospacedDigit() }
                GridRow { Text("Cache").foregroundStyle(.secondary); Text(metrics.memoryCache.byteString).monospacedDigit() }
                GridRow { Text("Buffers").foregroundStyle(.secondary); Text(metrics.memoryBuffers.byteString).monospacedDigit() }
                GridRow { Text("I/O wait").foregroundStyle(.secondary); Text(metrics.cpuIOWait, format: BWFormat.percentage).monospacedDigit() }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Memory Details")
        }
    }
}

private struct PerformanceChart: View {
    let records: [MetricRecord]

    private var cpuLabel: String { NSLocalizedString("CPU", comment: "Chart metric") }
    private var memoryLabel: String { NSLocalizedString("Memory", comment: "Chart metric") }
    private var metricLabel: String { NSLocalizedString("Metric", comment: "Chart dimension") }
    private var timeLabel: String { NSLocalizedString("Time", comment: "Chart axis") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Chart {
                ForEach(records) { record in
                    LineMark(x: .value(timeLabel, record.timestamp), y: .value(cpuLabel, record.cpuUsage), series: .value(metricLabel, cpuLabel))
                        .foregroundStyle(by: .value(metricLabel, cpuLabel))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value(timeLabel, record.timestamp), y: .value(memoryLabel, record.memoryUsage), series: .value(metricLabel, memoryLabel))
                        .foregroundStyle(by: .value(metricLabel, memoryLabel))
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: 0...1)
            .chartForegroundStyleScale([cpuLabel: Color.blue, memoryLabel: Color.purple])
            .frame(height: 300)
        }
    }
}

struct NetworkView: View {
    @EnvironmentObject private var state: AppState

    private var downloadLabel: String { NSLocalizedString("Download", comment: "Chart direction") }
    private var uploadLabel: String { NSLocalizedString("Upload", comment: "Chart direction") }
    private var directionLabel: String { NSLocalizedString("Direction", comment: "Chart dimension") }
    private var timeLabel: String { NSLocalizedString("Time", comment: "Chart axis") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let metrics = state.selectedMetrics {
                    HStack(spacing: 40) {
                        rate("Download", symbol: "arrow.down", value: metrics.networkDownloadRate, color: .blue)
                        rate("Upload", symbol: "arrow.up", value: metrics.networkUploadRate, color: .mint)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(metrics.networkInterface)
                                .font(.title3.monospaced().weight(.semibold))
                            Text("Active interface")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(22)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    HStack {
                        Text("Transfer Rate")
                            .font(.title2.weight(.semibold))
                        Spacer()
                        RangePicker(range: $state.historyRange)
                    }
                    TransferSummary(records: state.history)
                    Chart {
                        ForEach(state.history) { record in
                            LineMark(x: .value(timeLabel, record.timestamp), y: .value(downloadLabel, record.networkRX), series: .value(directionLabel, downloadLabel))
                                .foregroundStyle(by: .value(directionLabel, downloadLabel))
                            LineMark(x: .value(timeLabel, record.timestamp), y: .value(uploadLabel, record.networkTX), series: .value(directionLabel, uploadLabel))
                                .foregroundStyle(by: .value(directionLabel, uploadLabel))
                        }
                    }
                    .chartForegroundStyleScale([downloadLabel: Color.blue, uploadLabel: Color.mint])
                    .frame(height: 320)
                } else {
                    ContentUnavailableView("No network sample", systemImage: "arrow.up.arrow.down", description: Text("Start monitoring to calculate transfer rates."))
                }
            }
            .padding(28)
        }
        .navigationTitle("Network")
    }

    private func rate(_ title: LocalizedStringKey, symbol: String, value: Double, color: Color) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(value.rateString)
                    .font(.title.weight(.bold))
                    .monospacedDigit()
                Text(title)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "\(symbol).circle.fill")
                .font(.largeTitle)
                .foregroundStyle(color)
        }
    }
}

private struct RangePicker: View {
    @Binding var range: HistoryRange

    var body: some View {
        Picker("History Range", selection: $range) {
            ForEach(HistoryRange.allCases) { Text($0.localizedTitle).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 280)
    }
}

private struct TransferSummary: View {
    let records: [MetricRecord]

    var body: some View {
        HStack(spacing: 18) {
            summary("Last hour", records: filtered(since: 3_600))
            summary("24 hours", records: filtered(since: 24 * 3_600))
            summary("Loaded range", records: records)
        }
    }

    private func filtered(since interval: TimeInterval) -> [MetricRecord] {
        records.filter { $0.timestamp >= Date.now.addingTimeInterval(-interval) }
    }

    private func summary(_ title: LocalizedStringKey, records: [MetricRecord]) -> some View {
        let totals = integrated(records)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Label(UInt64(totals.download).byteString, systemImage: "arrow.down")
                .foregroundStyle(.blue)
            Label(UInt64(totals.upload).byteString, systemImage: "arrow.up")
                .foregroundStyle(.mint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func integrated(_ records: [MetricRecord]) -> (download: Double, upload: Double) {
        guard records.count > 1 else { return (0, 0) }
        var download = 0.0
        var upload = 0.0
        for index in 1..<records.count {
            let interval = min(max(records[index].timestamp.timeIntervalSince(records[index - 1].timestamp), 0), 300)
            download += ((records[index - 1].networkRX + records[index].networkRX) / 2) * interval
            upload += ((records[index - 1].networkTX + records[index].networkTX) / 2) * interval
        }
        return (download, upload)
    }
}

struct TrafficView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let traffic = state.selectedTraffic {
                    HStack(alignment: .lastTextBaseline) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(traffic.used.byteString)
                                .font(.system(size: 46, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("used of \(traffic.limit.byteString)")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(traffic.usagePercentage, format: BWFormat.percentage)
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    ProgressView(value: traffic.usagePercentage)
                        .controlSize(.large)
                        .tint(traffic.usagePercentage >= 0.8 ? .orange : .green)
                    HStack {
                        Label("\(traffic.remaining.byteString) remaining", systemImage: "gauge.with.dots.needle.33percent")
                        Spacer()
                        Label(traffic.nextReset.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    }
                    .font(.headline)

                    Divider().padding(.vertical, 8)
                    forecastPanel(traffic)
                } else {
                    ContentUnavailableView("KiwiVM data unavailable", systemImage: "chart.xyaxis.line", description: Text("Add a BandwagonHost VEID and API key, then refresh."))
                }
            }
            .padding(32)
            .frame(maxWidth: 1_000, alignment: .leading)
        }
        .navigationTitle("Traffic")
    }

    private func forecastPanel(_ traffic: BandwagonTraffic) -> some View {
        let daily = TrafficForecaster.dailyUsage(samples: state.history.map { ($0.timestamp, $0.trafficUsed) })
        let forecast = TrafficForecaster.forecast(current: traffic, recentDailyUsage: daily)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Forecast")
                .font(.title2.weight(.semibold))
            LabeledContent("Recent daily average", value: UInt64(max(forecast.dailyAverage, 0)).byteString)
            LabeledContent("Projected at reset", value: UInt64(max(forecast.projectedUsage, 0)).byteString)
            if forecast.isAtRisk, let date = forecast.exhaustionDate {
                Label("At the current rate, traffic may run out on \(date.formatted(date: .abbreviated, time: .omitted)).", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Label("Current usage is projected to remain within the plan.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}

struct ServicesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Table(state.services) {
            TableColumn("Service") { service in
                Label(service.name, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.primary, .green)
            }
            TableColumn("State", value: \.state)
                .width(100)
            TableColumn("Description", value: \.description)
        }
        .navigationTitle("Services")
        .task { if state.services.isEmpty { await state.loadServices() } }
        .overlay {
            if state.services.isEmpty {
                ContentUnavailableView("No running services loaded", systemImage: "gearshape.2", description: Text("Refresh after SSH is connected."))
            }
        }
    }
}

struct ProcessesView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Table(state.processes) {
            TableColumn("PID") { process in Text(String(process.id)).monospacedDigit() }
                .width(70)
            TableColumn("Process", value: \.name)
            TableColumn("CPU") { process in Text(process.cpu / 100, format: BWFormat.percentage).monospacedDigit() }
                .width(90)
            TableColumn("RAM") { process in Text(process.memory / 100, format: BWFormat.percentage).monospacedDigit() }
                .width(90)
        }
        .navigationTitle("Processes")
        .task { if state.processes.isEmpty { await state.loadProcesses() } }
        .overlay {
            if state.processes.isEmpty {
                ContentUnavailableView("No processes loaded", systemImage: "list.bullet.rectangle", description: Text("Refresh after SSH is connected."))
            }
        }
    }
}
