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

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String, url: URL)
    case failed(message: String)
}

@MainActor
final class AppState: ObservableObject {
    @Published var servers: [Server] = []
    @Published var selectedServerID: UUID?
    @Published var selection: SidebarDestination = .overview
    @Published var metricsByServer: [UUID: ServerMetrics] = [:]
    @Published var trafficByServer: [UUID: BandwagonTraffic] = [:]
    @Published var history: [MetricRecord] = []
    @Published var services: [ServiceInfo] = []
    @Published var processes: [RemoteProcessInfo] = []
    @Published var isRefreshing = false
    @Published var monitoringActive = false
    @Published var lastError: String?
    @Published var lastRefresh: Date?
    @Published var updateStatus: UpdateStatus = .idle

    let keychain = KeychainStore()
    let ssh = SSHManager()
    let repository = ServerRepository()
    let kiwi = KiwiVMClient()
    let notifications = NotificationManager()
    let historyStore: HistoryStore?

    private let monitoring: MonitoringService
    private var monitoringTask: Task<Void, Never>?
    private var kiwiTask: Task<Void, Never>?
    private var deliveredAlerts = Set<String>()
    private var lastHistoryWrite: [UUID: Date] = [:]
    private var cpuHighSince: [UUID: Date] = [:]
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

    init(demo: Bool = Foundation.ProcessInfo.processInfo.arguments.contains("--demo")) {
        isDemoMode = demo
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
            Task { await loadServers() }
        }
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// Checks GitHub Releases for a newer build. Automatic checks are
    /// throttled to once a week and stay silent unless an update is found.
    func checkForUpdates(userInitiated: Bool = false) async {
        if updateStatus == .checking { return }
        if !userInitiated {
            let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
            if last > 0 && Date.now.timeIntervalSince1970 - last < 7 * 24 * 3_600 { return }
        }
        updateStatus = .checking
        do {
            let release = try await AppUpdateChecker().latestRelease()
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "lastUpdateCheck")
            if AppUpdate.isNewer(latest: release.tagName, than: appVersion) {
                updateStatus = .available(version: release.tagName, url: release.htmlURL ?? AppUpdate.releasesPageURL)
            } else {
                updateStatus = .upToDate
            }
        } catch {
            updateStatus = userInitiated ? .failed(message: error.localizedDescription) : .idle
        }
    }

    func loadServers() async {
        do {
            servers = try await repository.load()
            selectedServerID = selectedServerID ?? servers.first?.id
        } catch {
            lastError = String(
                format: NSLocalizedString("Could not load servers: %@", comment: "Server loading error"),
                error.localizedDescription
            )
        }
    }

    func saveServer(
        _ server: Server,
        apiKey: String = "",
        password: String = "",
        keyPassphrase: String = ""
    ) async -> Bool {
        guard server.isValid else {
            lastError = NSLocalizedString(
                "Enter a name, host, valid port, and username.",
                comment: "Invalid server form"
            )
            return false
        }
        do {
            if let index = servers.firstIndex(where: { $0.id == server.id }) {
                servers[index] = server
            } else {
                servers.append(server)
            }
            if !apiKey.isEmpty { try keychain.save(apiKey, for: server.id, kind: .kiwiAPIKey) }
            if !password.isEmpty { try keychain.save(password, for: server.id, kind: .sshPassword) }
            if !keyPassphrase.isEmpty { try keychain.save(keyPassphrase, for: server.id, kind: .privateKeyPassphrase) }
            try await repository.save(servers)
            selectedServerID = server.id
            return true
        } catch {
            lastError = String(
                format: NSLocalizedString("Could not save server: %@", comment: "Server save error"),
                error.localizedDescription
            )
            return false
        }
    }

    func deleteServer(_ server: Server) async {
        do {
            try keychain.deleteSecrets(for: server.id)
            servers.removeAll { $0.id == server.id }
            metricsByServer[server.id] = nil
            trafficByServer[server.id] = nil
            try await repository.save(servers)
            selectedServerID = servers.first?.id
            if servers.isEmpty { stopMonitoring() }
        } catch {
            lastError = String(
                format: NSLocalizedString("Could not delete server: %@", comment: "Server deletion error"),
                error.localizedDescription
            )
        }
    }

    func refreshAll() async {
        guard let server = selectedServer else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await refreshMetrics(server)
        await refreshTraffic(server)
        lastRefresh = .now
        loadHistory(for: server.id)
        saveWidgetSnapshot(server)
        await evaluateAlerts(server)
    }

    func beginMonitoring() {
        guard !monitoringActive, !isDemoMode else { return }
        monitoringActive = true
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let server = self.selectedServer else { break }
                await self.refreshMetrics(server)
                let configured = UserDefaults.standard.object(forKey: "cpuRefreshInterval") as? Double ?? 2
                try? await Task.sleep(for: .seconds(max(configured, 2)))
            }
        }
        kiwiTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let server = self.selectedServer else { break }
                await self.refreshTraffic(server)
                let configured = UserDefaults.standard.object(forKey: "kiwiRefreshInterval") as? Double ?? 180
                try? await Task.sleep(for: .seconds(max(configured, 120)))
            }
        }
    }

    func stopMonitoring() {
        monitoringActive = false
        monitoringTask?.cancel()
        kiwiTask?.cancel()
        monitoringTask = nil
        kiwiTask = nil
    }

    func inspectHostKey(_ server: Server) async throws -> SSHHostKeyStatus {
        try await ssh.hostKeyStatus(for: server)
    }

    func trustHostKey(_ identity: SSHHostIdentity, for server: Server) throws {
        try ssh.trust(identity, for: server)
    }

    func loadServices() async {
        guard let server = selectedServer else { return }
        do {
            let output = try await ssh.execute(
                "systemctl list-units --type=service --state=running --no-legend --no-pager | head -50",
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
        guard let server = selectedServer else { return }
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

    func loadHistory(for serverID: UUID, range: TimeInterval = 24 * 3_600) {
        if isDemoMode { return }
        do {
            history = try historyStore?.fetch(serverID: serverID, since: .now.addingTimeInterval(-range)) ?? []
        } catch {
            lastError = String(
                format: NSLocalizedString("Could not load history: %@", comment: "History loading error"),
                error.localizedDescription
            )
        }
    }

    private func refreshMetrics(_ server: Server) async {
        do {
            let result = try await monitoring.refresh(server: server)
            metricsByServer[server.id] = result.metrics
            if let index = servers.firstIndex(where: { $0.id == server.id }),
               servers[index].operatingSystem != result.operatingSystem {
                servers[index].operatingSystem = result.operatingSystem
                try? await repository.save(servers)
            }
            if Date.now.timeIntervalSince(lastHistoryWrite[server.id] ?? .distantPast) >= 60 {
                try historyStore?.append(
                    serverID: server.id,
                    metrics: result.metrics,
                    trafficUsed: trafficByServer[server.id]?.used ?? 0
                )
                lastHistoryWrite[server.id] = .now
            }
            lastRefresh = .now
            lastError = nil
            saveWidgetSnapshot(server)
            await evaluateAlerts(server)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshTraffic(_ server: Server) async {
        guard server.provider == .bandwagonHost else { return }
        do {
            guard let apiKey = try keychain.read(for: server.id, kind: .kiwiAPIKey), !apiKey.isEmpty else { return }
            trafficByServer[server.id] = try await kiwi.serviceInfo(veid: server.veid, apiKey: apiKey)
            lastRefresh = .now
            lastError = nil
            saveWidgetSnapshot(server)
            await evaluateAlerts(server)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func saveWidgetSnapshot(_ server: Server) {
        let snapshot = WidgetSnapshot(
            server: server,
            metrics: metricsByServer[server.id],
            traffic: trafficByServer[server.id]
        )
        try? WidgetSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func evaluateAlerts(_ server: Server) async {
        let thresholds = AlertThresholds(
            traffic: UserDefaults.standard.object(forKey: "trafficWarning") as? Double ?? 0.8,
            cpu: UserDefaults.standard.object(forKey: "cpuWarning") as? Double ?? 0.9,
            memory: UserDefaults.standard.object(forKey: "memoryWarning") as? Double ?? 0.9,
            disk: UserDefaults.standard.object(forKey: "diskWarning") as? Double ?? 0.85
        )
        if let cpu = metricsByServer[server.id]?.cpuUsage, cpu >= thresholds.cpu {
            cpuHighSince[server.id] = cpuHighSince[server.id] ?? .now
        } else {
            cpuHighSince[server.id] = nil
            deliveredAlerts.remove("\(server.id).cpu")
        }
        let cpuSustained = Date.now.timeIntervalSince(cpuHighSince[server.id] ?? .now) >= 5 * 60
        for alert in AlertEvaluator.evaluate(
            server: server,
            metrics: metricsByServer[server.id],
            traffic: trafficByServer[server.id],
            thresholds: thresholds,
            cpuSustained: cpuSustained
        ) where !deliveredAlerts.contains(alert.key) {
            try? await notifications.deliver(alert)
            deliveredAlerts.insert(alert.key)
        }
    }

    private func installDemoData() {
        let server = Server.demo
        servers = [server]
        selectedServerID = server.id
        metricsByServer[server.id] = .demo
        trafficByServer[server.id] = .demo
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
