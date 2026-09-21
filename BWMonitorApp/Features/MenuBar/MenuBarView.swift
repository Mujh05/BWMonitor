import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.selectedServer?.name ?? "BWMonitor")
                        .font(.headline)
                    Group {
                        if let host = state.selectedServer?.host {
                            Text(host)
                        } else {
                            Text("No server selected")
                        }
                    }
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let server = state.selectedServer {
                    ConnectionBadge(connection: state.selectedConnection, trusted: state.ssh.isTrusted(server))
                        .font(.caption)
                }
            }

            if let metrics = state.selectedMetrics, state.selectedConnection.isConnected {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow { Text("CPU").foregroundStyle(.secondary); Text(metrics.cpuUsage, format: BWFormat.percentage).monospacedDigit() }
                    GridRow { Text("RAM").foregroundStyle(.secondary); Text(metrics.memoryPercentage, format: BWFormat.percentage).monospacedDigit() }
                    GridRow { Text("Disk").foregroundStyle(.secondary); Text(metrics.diskPercentage, format: BWFormat.percentage).monospacedDigit() }
                    GridRow { Text("Down").foregroundStyle(.secondary); Text(metrics.networkDownloadRate.rateString).monospacedDigit() }
                    GridRow { Text("Up").foregroundStyle(.secondary); Text(metrics.networkUploadRate.rateString).monospacedDigit() }
                }
            }

            if let traffic = state.selectedTraffic {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Traffic")
                        Spacer()
                        Text(traffic.usagePercentage, format: BWFormat.percentage).monospacedDigit()
                    }
                    ProgressView(value: traffic.usagePercentage)
                    Text("\(traffic.used.byteString) / \(traffic.limit.byteString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack {
                Button("Dashboard") {
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Terminal") {
                    state.selection = .terminal
                    openWindow(id: "dashboard")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                if state.monitoringActive {
                    Button {
                        state.stopMonitoring()
                    } label: {
                        Image(systemName: "pause.fill")
                    }
                    .help("Stop Monitoring")
                } else {
                    Button {
                        state.beginMonitoring()
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .disabled(state.selectedServer == nil || state.isDemoMode)
                    .help("Start Monitoring")
                }
                Button {
                    Task { await state.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(state.isDemoMode)
                .help("Refresh")
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 310)
    }
}
