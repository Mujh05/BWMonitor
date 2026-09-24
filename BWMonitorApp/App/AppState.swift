import AppKit
import Combine
import Foundation
import SwiftUI
import WidgetKit

enum SidebarDestination: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case performance = "Performance"
    case network = "Network"
    case traffic = "Traffic"
    case terminal = "Terminal"
    case services = "Services"
    case processes = "Processes"
    case servers = "Servers"
    case settings = "Settings"

    var id: String { rawValue }

    var localizedTitle: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }

    var symbol: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .performance: "gauge.with.dots.needle.50percent"
        case .network: "arrow.up.arrow.down"
        case .traffic: "chart.xyaxis.line"
        case .terminal: "terminal"
        case .services: "gearshape.2"
        case .processes: "list.bullet.rectangle"
        case .servers: "server.rack"
        case .settings: "gear"
        }
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case hour = "1H"
    case sixHours = "6H"
    case day = "24H"
    case week = "7D"
    case month = "30D"

    var id: String { rawValue }
    var localizedTitle: LocalizedStringKey {
        switch self {
        case .hour: "1 hour"
        case .sixHours: "6 hours"
        case .day: "24 hours"
        case .week: "7 days"
        case .month: "30 days"
        }
    }
    var interval: TimeInterval {
        switch self {
        case .hour: 3_600
        case .sixHours: 6 * 3_600
        case .day: 24 * 3_600
        case .week: 7 * 24 * 3_600
        case .month: 30 * 24 * 3_600
        }
    }
}

struct ServiceInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let state: String
}

struct RemoteProcessInfo: Identifiable, Equatable {
    let id: Int
    let name: String
    let cpu: Double
    let memory: Double
}

/// SSH state of one server, shown on the dashboard and in the server list.
enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected
    /// A network problem; monitoring retries with increasing delays.
    case retrying(message: String)
    /// Retrying cannot help (for example a rejected login), so monitoring
    /// paused until the settings are fixed.
    case needsAttention(SSHError)
    /// The server answered, but its output could not be read.
    case failed(message: String)

    var isConnected: Bool { self == .connected }
}

/// Opens the server editor from anywhere in the app.
struct ServerEditorRequest: Identifiable {
    let id = UUID()
    let server: Server?
}

@MainActor
final class AppState: ObservableObject {
    @Published var servers: [Server] = []
    @Published var selectedServerID: UUID? {
        didSet {
            if oldValue != selectedServerID { selectedServerChanged() }
        }
    }
    @Published var selection: SidebarDestination = .overview
    @Published var metricsByServer: [UUID: ServerMetrics] = [:]
    @Published var trafficByServer: [UUID: BandwagonTraffic] = [:]
    @Published var connectionByServer: [UUID: ConnectionState] = [:]
    @Published var history: [MetricRecord] = []
    @Published var historyRange: HistoryRange = .day {
        didSet { reloadHistory() }
    }
    @Published var services: [ServiceInfo] = []
    @Published var processes: [RemoteProcessInfo] = []
    @Published var isRefreshing = false
    @Published private(set) var monitoredServerIDs: Set<UUID> = []
    @Published var lastError: String?
    @Published var lastRefresh: Date?
    @Published var editorRequest: ServerEditorRequest?
    @Published var terminalSessions: [TerminalSession] = []
    @Published var selectedTerminalID: UUID?

    let updater = SoftwareUpdater()
    let keychain = KeychainStore()
    let ssh: SSHManager
    private let askpassServer: AskpassServer?
    let keyStore = SSHKeyStore()
    let repository = ServerRepository()
    let kiwi = KiwiVMClient()
    let notifications = NotificationManager()
    let historyStore: HistoryStore?

    private let monitoring: MonitoringService
    private var monitoringTasks: [UUID: Task<Void, Never>] = [:]
    private var kiwiTasks: [UUID: Task<Void, Never>] = [:]
    private var deliveredAlerts = Set<String>()
    private var lastHistoryWrite: [UUID: Date] = [:]
    private var cpuHighSince: [UUID: Date] = [:]
    private var lastWidgetReload = Date.distantPast
    private var lastWidgetOnline: Bool?
    private var terminationObserver: NSObjectProtocol?
    let isDemoMode: Bool

    var selectedServer: Server? {
        guard let selectedServerID else { return nil }
        return servers.first(where: { $0.id == selectedServerID })
    }

    var selectedMetrics: ServerMetrics? {
        selectedServerID.flatMap { metricsByServer[$0] }
    }

    var selectedTraffic: BandwagonTraffic? {
        selectedServerID.flatMap { trafficByServer[$0] }
    }

    var selectedConnection: ConnectionState {
        selectedServerID.flatMap { connectionByServer[$0] } ?? .idle
    }

    var monitoringActive: Bool {
        selectedServerID.map(monitoredServerIDs.contains) ?? false
    }

    init(demo: Bool = Foundation.ProcessInfo.processInfo.arguments.contains("--demo")) {
        isDemoMode = demo
        let socketPath = AppEnvironment.controlSocketDirectory.appendingPathComponent("askpass-\(getpid())").path
        askpassServer = demo ? nil : try? AskpassServer(socketPath: socketPath, keychain: keychain)
        var askpass: SSHManager.Askpass?
        if let helperPath = Bundle.main.executablePath, let server = askpassServer {
            askpass = SSHManager.Askpass(helperPath: helperPath, socketPath: server.socketPath)
        }
        ssh = SSHManager(keychain: keychain, askpass: askpass)
        if let store = try? HistoryStore() {
            historyStore = store
        } else {
            historyStore = try? HistoryStore(inMemory: true)
            if historyStore == nil {
                lastError = NSLocalizedString("Could not open the local history database.", comment: "History store failure")
            }
        }
        monitoring = MonitoringService(ssh: ssh)

        if demo {
            installDemoData()
        } else {
            pruneHistory()
            Task { await loadServers() }
            updater.scheduleChecks()
            terminationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.shutDown() }
            }
        }
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    // MARK: Servers

    func loadServers() async {
        do {
            servers = try await repository.load()
            // Leftovers of a server editor that was open when the app quit.
            ssh.removeUnusedHostKeys(keeping: servers)
            keychain.deleteAll(of: [.pendingPassword, .pendingPassphrase])
            if selectedServerID == nil { selectedServerID = servers.first?.id }
            if UserDefaults.standard.object(forKey: "autoStartMonitoring") as? Bool ?? true {
                for server in servers where ssh.isTrusted(server) {
                    beginMonitoring(for: server)
                }
            }
        } catch {
            lastError = String(
                format: NSLocalizedString("Could not load servers: %@", comment: "Server loading error"),
                error.localizedDescription
            )
        }
    }

    func addServer() {
        editorRequest = ServerEditorRequest(server: nil)
    }

    func edit(_ server: Server) {
        editorRequest = ServerEditorRequest(server: server)
    }

    /// Stores an edited server. Called by the server editor after its own
    /// checks; `previous` is the saved version, if any.
    func commit(_ server: Server, replacing previous: Server?) async throws {
        if let previous, ssh.controlPath(for: previous) != ssh.controlPath(for: server) {
            ssh.closeSharedConnection(for: previous)
            await monitoring.reset(serverID: server.id)
        }
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == server.id }) {
            updated[index] = server
        } else {
            updated.append(server)
        }
        try await repository.save(updated)
        servers = updated
        if case .needsAttention = connectionByServer[server.id] {
            connectionByServer[server.id] = .idle
        }
        selectedServerID = server.id
        // Restart only this server. Other servers keep collecting in parallel.
        if monitoredServerIDs.contains(server.id) {
            stopMonitoring(serverID: server.id)
            beginMonitoring(for: server)
        } else if UserDefaults.standard.object(forKey: "autoStartMonitoring") as? Bool ?? true, ssh.isTrusted(server) {
            beginMonitoring(for: server)
        }
    }

    func deleteServer(_ server: Server) async {
        do {
            stopMonitoring(serverID: server.id)
            for session in terminalSessions where session.server.id == server.id { closeTerminal(session) }
            try keychain.deleteSecrets(for: server.id)
            ssh.forgetHostKey(for: server)
            var updated = servers
            updated.removeAll { $0.id == server.id }
            try await repository.save(updated)
            servers = updated
            metricsByServer[server.id] = nil
            trafficByServer[server.id] = nil
            connectionByServer[server.id] = nil
            if selectedServerID == server.id { selectedServerID = servers.first?.id }
        } catch {
            lastError = String(
                format: NSLocalizedString("Could not delete server: %@", comment: "Server deletion error"),
                error.localizedDescription
            )
        }
    }

    private func selectedServerChanged() {
        services = []
        processes = []
        reloadHistory()
    }

    // MARK: Monitoring

    func refreshAll() async {
        guard let server = selectedServer, !isDemoMode else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        _ = await collectMetrics(serverID: server.id)
        await refreshTraffic(server)
        if selection == .services { await loadServices() }
        if selection == .processes { await loadProcesses() }
    }

    func beginMonitoring() {
        guard let server = selectedServer else { return }
        beginMonitoring(for: server)
    }

    private func beginMonitoring(for server: Server) {
        guard !monitoredServerIDs.contains(server.id), !isDemoMode else { return }
        let serverID = server.id
        monitoredServerIDs.insert(serverID)
        monitoringTasks[serverID] = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                let outcome = await self.collectMetrics(serverID: serverID)
                guard !Task.isCancelled else { return }
                let interval = max(UserDefaults.standard.object(forKey: "cpuRefreshInterval") as? Double ?? 2, 2)
                switch outcome {
                case .success:
                    failures = 0
                    try? await Task.sleep(for: .seconds(interval))
                case .retry:
                    // Back off so an unreachable server is not hammered.
                    failures += 1
                    try? await Task.sleep(for: .seconds(min(interval * pow(2, Double(failures)), 300)))
                case .stop:
                    self.stopMonitoring(serverID: serverID)
                    return
                }
            }
        }
        if server.provider == .bandwagonHost {
            kiwiTasks[serverID] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let server = self.servers.first(where: { $0.id == serverID }) else { return }
                    await self.refreshTraffic(server)
                    let configured = UserDefaults.standard.object(forKey: "kiwiRefreshInterval") as? Double ?? 180
                    try? await Task.sleep(for: .seconds(max(configured, 120)))
                }
            }
        }
    }

    func stopMonitoring() {
        guard let selectedServerID else { return }
        stopMonitoring(serverID: selectedServerID)
    }

    private func stopMonitoring(serverID: UUID) {
        monitoringTasks.removeValue(forKey: serverID)?.cancel()
        kiwiTasks.removeValue(forKey: serverID)?.cancel()
        monitoredServerIDs.remove(serverID)
        switch connectionByServer[serverID] {
        case .connecting, .retrying, .connected: connectionByServer[serverID] = .idle
        default: break
        }
    }

    private func stopAllMonitoring() {
        for serverID in monitoredServerIDs {
            monitoringTasks[serverID]?.cancel()
            kiwiTasks[serverID]?.cancel()
        }
        monitoringTasks.removeAll()
        kiwiTasks.removeAll()
        monitoredServerIDs.removeAll()
    }

    private enum CollectionOutcome {
        case success
        case retry
        case stop
    }

    private func collectMetrics(serverID: UUID) async -> CollectionOutcome {
        guard let server = servers.first(where: { $0.id == serverID }) else { return .stop }
        guard ssh.isTrusted(server) else {
            connectionByServer[serverID] = .needsAttention(.hostNotTrusted)
            return .stop
        }
        if connectionByServer[serverID] != .connected { connectionByServer[serverID] = .connecting }
        do {
            let result = try await monitoring.refresh(server: server)
            connectionByServer[serverID] = .connected
            await apply(result, to: server)
            return .success
        } catch {
            if Task.isCancelled || error is CancellationError { return .stop }
            metricsByServer[serverID] = nil
            if let error = error as? SSHError {
                if error.needsUserAction {
                    connectionByServer[serverID] = .needsAttention(error)
                    return .stop
                }
                connectionByServer[serverID] = .retrying(message: error.localizedDescription)
            } else {
                connectionByServer[serverID] = .failed(message: error.localizedDescription)
            }
            saveWidgetSnapshot(server)
            return .retry
        }
    }

    private func apply(_ result: (metrics: ServerMetrics, operatingSystem: String), to server: Server) async {
        metricsByServer[server.id] = result.metrics
        if let index = servers.firstIndex(where: { $0.id == server.id }),
           !result.operatingSystem.isEmpty,
           servers[index].operatingSystem != result.operatingSystem {
            servers[index].operatingSystem = result.operatingSystem
            try? await repository.save(servers)
        }
        if Date.now.timeIntervalSince(lastHistoryWrite[server.id] ?? .distantPast) >= 60 {
            do {
                let record = try historyStore?.append(
                    serverID: server.id,
                    metrics: result.metrics,
                    trafficUsed: trafficByServer[server.id]?.used ?? 0
                )
                lastHistoryWrite[server.id] = .now
                if let record, server.id == selectedServerID { history.append(record) }
            } catch {
                lastError = String(
                    format: NSLocalizedString("Could not save history: %@", comment: "History saving error"),
                    error.localizedDescription
                )
            }
        }
        lastRefresh = .now
        saveWidgetSnapshot(server)
        await evaluateAlerts(server)
    }

    private func refreshTraffic(_ server: Server) async {
        guard server.provider == .bandwagonHost else { return }
        do {
            guard let apiKey = try keychain.read(for: server.id, kind: .kiwiAPIKey), !apiKey.isEmpty else { return }
            trafficByServer[server.id] = try await kiwi.serviceInfo(veid: server.veid, apiKey: apiKey)
            lastRefresh = .now
            saveWidgetSnapshot(server)
            await evaluateAlerts(server)
        } catch {
            if !(error is CancellationError) {
                lastError = String(
                    format: NSLocalizedString("Could not refresh traffic for %@: %@", comment: "Traffic refresh error"),
                    server.name,
                    error.localizedDescription
                )
            }
        }
    }

    /// Explains why monitoring paused, with the most likely fix.
    func explanation(for error: SSHError, server: Server) -> String {
        guard case let .authenticationFailed(methods) = error else { return error.localizedDescription }
        let reason: String
        switch server.authentication {
        case .password:
            reason = NSLocalizedString("The password or user name is wrong.", comment: "Connection test hint")
        case .key:
            if let key = try? SSHKeyInspector.inspect(path: server.privateKeyPath), key.isEncrypted,
               !keychain.contains(server.id, kind: .privateKeyPassphrase) {
                reason = NSLocalizedString(
                    "This key is protected by a passphrase that is not saved. Enter it in the server settings.",
                    comment: "Dashboard status"
                )
            } else if methods.contains("password") || methods.contains("keyboard-interactive") {
                reason = NSLocalizedString(
                    "The server did not accept this key. Install the public key on the server with its password.",
                    comment: "Connection test hint"
                )
            } else {
                reason = error.localizedDescription
            }
        }
        return String(
            format: NSLocalizedString(
                "%@ BWMonitor stopped retrying so the server does not block this Mac for repeated failed logins.",
                comment: "Dashboard status"
            ),
            reason
        )
    }

    /// True when SSH works, false when the server cannot be reached, nil
    /// when unknown.
    func isOnline(_ serverID: UUID) -> Bool? {
        switch connectionByServer[serverID] {
        case .connected:
            return true
        case let .needsAttention(error) where error.isConnectionLoss:
            return false
        case .retrying:
            return false
        default:
            return trafficByServer[serverID]?.serverOnline
        }
    }

    // MARK: Services and processes

    func loadServices() async {
        guard let server = selectedServer, !isDemoMode else { return }
        do {
            let output = try await ssh.execute(
                "systemctl list-units --type=service --state=running --no-legend --no-pager | head -100",
                on: server
            )
            services = output.components(separatedBy: .newlines).compactMap { line in
                let fields = line.split(maxSplits: 4, whereSeparator: { $0.isWhitespace })
                guard fields.count >= 4 else { return nil }
                return ServiceInfo(
                    id: String(fields[0]),
                    name: String(fields[0]).replacingOccurrences(of: ".service", with: ""),
                    description: fields.count > 4 ? String(fields[4]) : "",
                    state: String(fields[3])
                )
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadProcesses() async {
        guard let server = selectedServer, !isDemoMode else { return }
        do {
            let output = try await ssh.execute(
                "ps -eo pid,comm,%cpu,%mem --sort=-%cpu --no-headers | head -50",
                on: server
            )
            processes = output.components(separatedBy: .newlines).compactMap { line in
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                guard fields.count >= 4,
                      let pid = Int(fields[0]),
                      let cpu = Double(fields[2]),
                      let memory = Double(fields[3]) else { return nil }
                return RemoteProcessInfo(id: pid, name: String(fields[1]), cpu: cpu, memory: memory)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: History

    func reloadHistory() {
        if isDemoMode { return }
        guard let serverID = selectedServerID else {
            history = []
            return
        }
        do {
            history = try historyStore?.fetch(serverID: serverID, since: .now.addingTimeInterval(-historyRange.interval)) ?? []
        } catch {
            lastError = String(
                format: NSLocalizedString("Could not load history: %@", comment: "History loading error"),
                error.localizedDescription
            )
        }
    }

    private func pruneHistory() {
        let days = UserDefaults.standard.object(forKey: "historyRetentionDays") as? Int ?? 30
        try? historyStore?.prune(olderThan: .now.addingTimeInterval(-Double(max(days, 1)) * 86_400))
    }

    // MARK: Terminal

    func openTerminal(for target: Server? = nil) {
        guard let server = target ?? selectedServer, !isDemoMode else { return }
        let session = TerminalSession(server: server, ssh: ssh)
        terminalSessions.append(session)
        selectedTerminalID = session.id
        session.connect()
    }

    func closeTerminal(_ session: TerminalSession) {
        session.disconnect()
        terminalSessions.removeAll { $0.id == session.id }
        if selectedTerminalID == session.id { selectedTerminalID = terminalSessions.last?.id }
    }

    /// Opens an SSH session in Terminal.app. It reuses BWMonitor's connection
    /// when one is open.
    func openInExternalTerminal(_ server: Server) {
        do {
            let script = try ssh.externalTerminalScript(for: server)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BWMonitor-terminal", isDirectory: true)
            try AppEnvironment.makePrivateDirectory(directory)
            let url = directory.appendingPathComponent("\(server.name.filter { $0.isLetter || $0.isNumber }.prefix(20))-\(UUID().uuidString.prefix(6)).command")
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-b", "com.apple.Terminal", url.path]
            process.standardError = errors
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw SSHError.commandFailed(detail.isEmpty
                    ? NSLocalizedString("Terminal could not open the session file.", comment: "External terminal error")
                    : detail)
            }
        } catch {
            lastError = String(
                format: NSLocalizedString("Could not open Terminal for %@: %@", comment: "External terminal error"),
                server.name,
                error.localizedDescription
            )
        }
    }

    private func shutDown() {
        stopAllMonitoring()
        terminalSessions.forEach { $0.disconnect() }
        ssh.closeAllSharedConnections(for: servers)
        askpassServer?.stop()
    }

    // MARK: Widget and alerts

    private func saveWidgetSnapshot(_ server: Server) {
        guard server.id == selectedServerID else { return }
        let online = isOnline(server.id)
        let snapshot = WidgetSnapshot(
            server: server,
            metrics: metricsByServer[server.id],
            traffic: trafficByServer[server.id],
            isOnline: online
        )
        try? WidgetSnapshotStore.save(snapshot)
        // WidgetKit budgets reloads; refresh at most once a minute unless the
        // online state changed.
        if Date.now.timeIntervalSince(lastWidgetReload) >= 60 || online != lastWidgetOnline {
            WidgetCenter.shared.reloadAllTimelines()
            lastWidgetReload = .now
            lastWidgetOnline = online
        }
    }

    private func evaluateAlerts(_ server: Server) async {
        let thresholds = AlertThresholds(
            traffic: UserDefaults.standard.object(forKey: "trafficWarning") as? Double ?? 0.8,
            cpu: UserDefaults.standard.object(forKey: "cpuWarning") as? Double ?? 0.9,
            memory: UserDefaults.standard.object(forKey: "memoryWarning") as? Double ?? 0.9,
            disk: UserDefaults.standard.object(forKey: "diskWarning") as? Double ?? 0.85
        )
        let metrics = metricsByServer[server.id]
        if let cpu = metrics?.cpuUsage, cpu >= thresholds.cpu {
            cpuHighSince[server.id] = cpuHighSince[server.id] ?? .now
        } else {
            cpuHighSince[server.id] = nil
            deliveredAlerts.remove("\(server.id).cpu")
        }
        // Allow an alert again once the value has clearly dropped, so a value
        // hovering at the threshold does not notify repeatedly.
        if let metrics {
            if metrics.memoryPercentage < thresholds.memory - 0.05 { deliveredAlerts.remove("\(server.id).memory") }
            if metrics.diskPercentage < thresholds.disk - 0.05 { deliveredAlerts.remove("\(server.id).disk") }
        }
        let cpuSustained = Date.now.timeIntervalSince(cpuHighSince[server.id] ?? .now) >= 5 * 60
        for alert in AlertEvaluator.evaluate(
            server: server,
            metrics: metrics,
            traffic: trafficByServer[server.id],
            thresholds: thresholds,
            cpuSustained: cpuSustained
        ) where !deliveredAlerts.contains(alert.key) {
            try? await notifications.deliver(alert)
            deliveredAlerts.insert(alert.key)
        }
    }

    // MARK: Demo

    private func installDemoData() {
        let server = Server.demo
        servers = [server]
        selectedServerID = server.id
        metricsByServer[server.id] = .demo
        trafficByServer[server.id] = .demo
        connectionByServer[server.id] = .connected
        lastRefresh = .now

        let start = Date.now.addingTimeInterval(-24 * 3_600)
        history = (0..<49).map { index in
            let phase = Double(index) / 4
            var metrics = ServerMetrics.demo
            metrics.timestamp = start.addingTimeInterval(Double(index) * 1_800)
            metrics.cpuUsage = 0.16 + sin(phase) * 0.07 + (index % 9 == 0 ? 0.16 : 0)
            metrics.memoryUsed = UInt64(Double(metrics.memoryTotal) * (0.29 + sin(phase / 3) * 0.035))
            metrics.networkDownloadRate = 800_000 + max(0, sin(phase * 1.3)) * 4_500_000
            metrics.networkUploadRate = 160_000 + max(0, cos(phase)) * 780_000
            return MetricRecord(serverID: server.id, metrics: metrics, trafficUsed: BandwagonTraffic.demo.used)
        }
        services = [
            ServiceInfo(
                id: "ssh.service",
                name: "ssh",
                description: NSLocalizedString("OpenBSD Secure Shell server", comment: "Demo service description"),
                state: NSLocalizedString("running", comment: "Service state")
            ),
            ServiceInfo(
                id: "nginx.service",
                name: "nginx",
                description: NSLocalizedString("High performance web server", comment: "Demo service description"),
                state: NSLocalizedString("running", comment: "Service state")
            ),
            ServiceInfo(
                id: "xray.service",
                name: "xray",
                description: NSLocalizedString("Xray service", comment: "Demo service description"),
                state: NSLocalizedString("running", comment: "Service state")
            )
        ]
        processes = [
            RemoteProcessInfo(id: 1213, name: "xray", cpu: 2.1, memory: 4.2),
            RemoteProcessInfo(id: 1082, name: "nginx", cpu: 0.2, memory: 1.8),
            RemoteProcessInfo(id: 998, name: "sshd", cpu: 0.1, memory: 1.2)
        ]
    }
}
