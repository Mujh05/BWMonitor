import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("cpuRefreshInterval") private var cpuRefreshInterval = 2.0
    @AppStorage("kiwiRefreshInterval") private var kiwiRefreshInterval = 180.0
    @AppStorage("autoStartMonitoring") private var autoStartMonitoring = true
    @AppStorage("historyRetentionDays") private var historyRetentionDays = 30
    @AppStorage("trafficWarning") private var trafficWarning = 0.8
    @AppStorage("cpuWarning") private var cpuWarning = 0.9
    @AppStorage("memoryWarning") private var memoryWarning = 0.9
    @AppStorage("diskWarning") private var diskWarning = 0.85
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var section = SettingsSection.general
    @State private var appKey: SSHKeyInfo?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Settings Section", selection: $section) {
                ForEach(SettingsSection.allCases) { item in
                    Label(item.localizedTitle, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Form {
                switch section {
                case .general: general
                case .monitoring: monitoring
                case .notifications: notificationSettings
                case .appearance: appearanceSettings
                case .security: security
                case .about: about
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle("Settings")
    }

    @ViewBuilder private var general: some View {
        Section("Startup") {
            Toggle("Launch BWMonitor at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                        state.lastError = String(
                            format: NSLocalizedString(
                                "Launch at login could not be changed: %@",
                                comment: "Login item error"
                            ),
                            error.localizedDescription
                        )
                    }
                }
            Text("macOS may ask you to confirm this in Login Items.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Start monitoring when BWMonitor opens", isOn: $autoStartMonitoring)
        }
        Section("Menu Bar") {
            LabeledContent("Status item", value: "CPU · RAM")
            Text("The menu bar keeps the latest collected snapshot; it does not increase the refresh rate.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var monitoring: some View {
        Section {
            intervalRow("Server metrics", value: $cpuRefreshInterval, range: 2...30)
            intervalRow("KiwiVM", value: $kiwiRefreshInterval, range: 120...900)
        } header: {
            Text("Refresh Intervals")
        } footer: {
            Text("CPU, memory, disk and network are read together over one SSH connection that stays open while monitoring.")
        }
        Section("History") {
            Stepper(value: $historyRetentionDays, in: 1...90) {
                Text(
                    String(
                        format: NSLocalizedString("Keep %lld days", comment: "History retention period"),
                        Int64(historyRetentionDays)
                    )
                )
            }
        }
    }

    @ViewBuilder private var notificationSettings: some View {
        Section {
            thresholdRow("Monthly traffic", value: $trafficWarning)
            thresholdRow("CPU", value: $cpuWarning)
            thresholdRow("Memory", value: $memoryWarning)
            thresholdRow("Disk", value: $diskWarning)
        } header: {
            Text("Warning Thresholds")
        } footer: {
            Text("CPU alerts require sustained samples before a notification is sent.")
        }
        Section {
            Button("Allow Notifications") {
                Task {
                    do { _ = try await state.notifications.requestAuthorization() }
                    catch { state.lastError = error.localizedDescription }
                }
            }
        }
    }

    @ViewBuilder private var appearanceSettings: some View {
        Section("Appearance") {
            Picker("Color scheme", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder private var security: some View {
        Section("Credentials") {
            Label("API keys, passwords and key passphrases are stored in macOS Keychain.", systemImage: "key.fill")
            Label("Server identities are pinned in a private known_hosts file.", systemImage: "lock.shield.fill")
            Label("A changed SSH host key blocks the connection.", systemImage: "hand.raised.fill")
            Label("Saved secrets go straight to ssh and are never typed into a terminal.", systemImage: "eye.slash.fill")
        }
        Section {
            if let appKey {
                LabeledContent("Fingerprint") {
                    Text("\(appKey.displayAlgorithm)  \(appKey.fingerprint ?? "—")")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Copy Public Key") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(appKey.publicKey ?? "", forType: .string)
                    }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appKey.path)])
                    }
                }
            } else {
                Text("Not created yet. Choose “BWMonitor Key” when editing a server to create it.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("BWMonitor Key")
        } footer: {
            Text("A key BWMonitor created for itself. Like the keys in ~/.ssh, only your user account can read it.")
        }
        .onAppear { appKey = state.keyStore.appKey() }
    }

    @ViewBuilder private var about: some View {
        Section {
            LabeledContent("Application", value: "BWMonitor")
            LabeledContent("Version", value: state.appVersion)
            LabeledContent {
                Text("Native macOS · SwiftUI")
            } label: {
                Text("Architecture")
            }
        }
        SoftwareUpdateSection()
    }

    private func intervalRow(
        _ title: LocalizedStringKey,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Stepper(value: value, in: range, step: 1) {
                Text(
                    String(
                        format: NSLocalizedString("%lld seconds", comment: "Refresh interval"),
                        Int64(value.wrappedValue)
                    )
                )
                    .monospacedDigit()
                    .frame(width: 100, alignment: .trailing)
            }
        }
    }

    private func thresholdRow(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: 0.5...0.99, step: 0.05)
            Text(value.wrappedValue, format: BWFormat.percentage)
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
    }
}

private struct SoftwareUpdateSection: View {
    @EnvironmentObject private var updater: SoftwareUpdater

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $updater.automaticChecks)
            status
            if let message = updater.message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Software Update")
        } footer: {
            Text("New versions come from GitHub Releases. BWMonitor checks the download, replaces itself, and reopens; your servers and settings stay as they are.")
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.status {
        case .idle:
            checkButton
        case .upToDate:
            HStack {
                Label(
                    String(format: NSLocalizedString("Up to date (%@)", comment: "Update status"), updater.currentVersion),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                Spacer()
                checkButton
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…")
            }
        case let .available(release):
            HStack {
                Label(
                    String(format: NSLocalizedString("New version available: %@", comment: "Update status"), release.version),
                    systemImage: "arrow.down.circle.fill"
                )
                .foregroundStyle(.orange)
                Spacer()
                Link("Release Notes", destination: release.pageURL)
                Button("Update Now") { updater.install() }
                    .buttonStyle(.borderedProminent)
            }
        case let .downloading(release):
            progress(String(format: NSLocalizedString("Downloading %@…", comment: "Update status"), release.version))
        case let .installing(release):
            progress(String(format: NSLocalizedString("Installing %@…", comment: "Update status"), release.version))
        }
    }

    private var checkButton: some View {
        Button("Check for Updates") {
            Task { await updater.check(userInitiated: true) }
        }
    }

    private func progress(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(title)
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case monitoring = "Monitoring"
    case notifications = "Alerts"
    case appearance = "Appearance"
    case security = "Security"
    case about = "About"

    var id: String { rawValue }
    var localizedTitle: LocalizedStringKey { LocalizedStringKey(rawValue) }
    var symbol: String {
        switch self {
        case .general: "gear"
        case .monitoring: "waveform.path.ecg"
        case .notifications: "bell"
        case .appearance: "circle.lefthalf.filled"
        case .security: "lock.shield"
        case .about: "info.circle"
        }
    }
}
