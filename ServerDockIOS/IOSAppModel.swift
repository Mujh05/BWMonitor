import Foundation
import SwiftUI

struct MobileTraffic: Sendable {
    var used: UInt64
    var inbound: UInt64?
    var outbound: UInt64?
    var limit: UInt64?
    var nextReset: Date
    var updated: Date
    var source: String
    var proportion: Double? { limit.flatMap { $0 > 0 ? min(Double(used) / Double($0), 1) : nil } }
}

@MainActor final class IOSAppModel: ObservableObject {
    @Published var servers: [Server] = []
    @Published var selectedID: UUID?
    @Published var metrics: [UUID: ServerMetrics] = [:]
    @Published var traffic: [UUID: MobileTraffic] = [:]
    @Published var issues: [UUID: String] = [:]
    @Published var refreshing: Set<UUID> = []
    @Published var hostApproval: HostKeyApproval?
    @Published var globalIssue: String?
    @Published var isDemo = false
    let ssh = IOSSSHService()
    let keychain = KeychainStore()
    private let repository = ServerRepository()
    private var samples: [UUID: LinuxSample] = [:]
    private var generations: [UUID: Int] = [:]
    private var savingIDs: Set<UUID> = []

    var selected: Server? { servers.first { $0.id == selectedID } }
    var selectedMetrics: ServerMetrics? { selectedID.flatMap { metrics[$0] } }
    var selectedTraffic: MobileTraffic? { selectedID.flatMap { traffic[$0] } }

    func load() async {
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            isDemo = true
            servers = [Server(name: "新加坡 · 演示服务器", host: "example.invalid", username: "ubuntu", provider: .awsLightsail,
                              awsInstanceName: "demo-singapore", awsRegion: "ap-southeast-1")]
            let id = servers[0].id
            selectedID = id
            metrics[id] = .demo
            traffic[id] = MobileTraffic(used: 4_100_000_000, inbound: 2_170_000_000, outbound: 1_930_000_000,
                limit: 2_048_000_000_000, nextReset: Calendar.current.date(byAdding: .month, value: 1, to: .now)!,
                updated: .now, source: "AWS Lightsail · 演示数据")
            return
        }
        do {
            servers = try await repository.load()
            selectedID = servers.first?.id
        } catch { globalIssue = error.localizedDescription }
    }

    func leaveDemo() async {
        isDemo = false; metrics = [:]; traffic = [:]; samples = [:]; servers = []; selectedID = nil
        do { servers = try await repository.load(); selectedID = servers.first?.id }
        catch { globalIssue = error.localizedDescription }
    }

    func save(_ server: Server, secrets: [SecretKind: String], privateKey: String) async throws {
        guard !isDemo else { return }
        savingIDs.insert(server.id)
        defer { savingIDs.remove(server.id) }
        let server = server.normalized
        guard server.isValid, Server.isValidHost(server.host), Server.isValidUsername(server.username) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        if !privateKey.isEmpty {
            _ = try IOSSSHService.keyAuthentication(privateKey, username: server.username,
                passphrase: secrets[.privateKeyPassphrase] ?? keychain.read(for: server.id, kind: .privateKeyPassphrase))
            try MobileKeyStore.save(RSAPEMImport.openSSH(privateKey), for: server.id)
        }
        if let existing = servers.first(where: { $0.id == server.id }), existing.provider != server.provider {
            for kind: SecretKind in [.kiwiAPIKey, .awsAccessKeyID, .awsSecretAccessKey, .awsSessionToken, .cloudAPIKey] {
                try keychain.delete(server.id, kind: kind)
            }
        }
        for (kind, value) in secrets where !value.isEmpty {
            if kind == .cloudAPIKey { try keychain.saveCloudToken(value, for: server.id, provider: server.provider) }
            else { try keychain.save(value, for: server.id, kind: kind) }
        }
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == server.id }) { updated[index] = server }
        else { updated.append(server) }
        try await repository.save(updated)
        generations[server.id, default: 0] += 1
        servers = updated; selectedID = server.id
        metrics.removeValue(forKey: server.id); samples.removeValue(forKey: server.id); traffic.removeValue(forKey: server.id)
        issues.removeValue(forKey: server.id)
    }

    func delete(_ server: Server) async {
        guard !isDemo else { return }
        do {
            let updated = servers.filter { $0.id != server.id }
            try await repository.save(updated)
            generations[server.id, default: 0] += 1
            servers = updated
            try keychain.deleteSecrets(for: server.id); try MobileKeyStore.delete(server.id)
            metrics.removeValue(forKey: server.id); traffic.removeValue(forKey: server.id)
            samples.removeValue(forKey: server.id); issues.removeValue(forKey: server.id)
            if selectedID == server.id { selectedID = servers.first?.id }
        } catch { globalIssue = error.localizedDescription }
    }

    func importServers(_ url: URL) async {
        guard !isDemo else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let imported = try decoder.decode([Server].self, from: Data(contentsOf: url))
            var updated = servers
            for var server in imported {
                server = server.normalized
                guard server.isValid, Server.isValidHost(server.host), Server.isValidUsername(server.username) else { continue }
                // Desktop paths have no meaning inside the iOS sandbox.
                server.privateKeyPath = ""
                if !updated.contains(where: { $0.id == server.id }) { updated.append(server) }
            }
            try await repository.save(updated); servers = updated
            if selectedID == nil { selectedID = servers.first?.id }
        } catch { globalIssue = "导入失败：\(error.localizedDescription)" }
    }

    func report(_ error: Error, server: Server? = nil) {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        if let approval = error as? HostKeyApproval { hostApproval = approval; return }
        if let server { issues[server.id] = error.localizedDescription }
        else { globalIssue = error.localizedDescription }
    }

    func refresh(_ server: Server) async {
        guard !isDemo, !savingIDs.contains(server.id), !refreshing.contains(server.id) else { return }
        refreshing.insert(server.id)
        defer { refreshing.remove(server.id) }
        issues.removeValue(forKey: server.id)
        // SSH and billing APIs fail independently: either successful result stays visible.
        let generation = generations[server.id, default: 0]
        async let monitor: Void = refreshMetrics(server, generation: generation)
        async let billing: Void = refreshTraffic(server, generation: generation)
        _ = await (monitor, billing)
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for server in servers { group.addTask { await self.refresh(server) } }
        }
    }

    private func stillCurrent(_ server: Server, generation: Int) -> Bool {
        guard !Task.isCancelled, !savingIDs.contains(server.id), generations[server.id, default: 0] == generation,
              var current = servers.first(where: { $0.id == server.id }) else { return false }
        current.operatingSystem = server.operatingSystem
        return current == server
    }

    private func refreshMetrics(_ server: Server, generation: Int) async {
        guard stillCurrent(server, generation: generation) else { return }
        do {
            let output = try await ssh.execute(LinuxMetricsParser.command, on: server)
            guard stillCurrent(server, generation: generation) else { return }
            let sample = try LinuxMetricsParser.parse(output)
            let previous = samples[server.id]
            samples[server.id] = sample
            metrics[server.id] = LinuxMetricsParser.metrics(current: sample, previous: previous)
            if previous == nil {
                try await Task.sleep(for: .seconds(1))
                let secondOutput = try await ssh.execute(LinuxMetricsParser.command, on: server)
                guard stillCurrent(server, generation: generation) else { return }
                let second = try LinuxMetricsParser.parse(secondOutput)
                metrics[server.id] = LinuxMetricsParser.metrics(current: second, previous: sample)
                samples[server.id] = second
            }
        } catch { if stillCurrent(server, generation: generation) { report(error, server: server) } }
    }

    private func refreshTraffic(_ server: Server, generation: Int) async {
        guard stillCurrent(server, generation: generation) else { return }
        do {
            switch server.provider {
            case .awsLightsail:
                guard let id = try keychain.read(for: server.id, kind: .awsAccessKeyID),
                      let secret = try keychain.read(for: server.id, kind: .awsSecretAccessKey) else { return }
                let value = try await AWSLightsailClient().monthlyTraffic(instanceName: server.awsInstanceName,
                    region: server.awsRegion, credentials: AWSCredentials(accessKeyID: id, secretAccessKey: secret,
                        sessionToken: keychain.read(for: server.id, kind: .awsSessionToken)), quotaOverrideGB: server.awsMonthlyTransferOverrideGB)
                guard stillCurrent(server, generation: generation) else { return }
                traffic[server.id] = MobileTraffic(used: value.used, inbound: value.inbound, outbound: value.outbound,
                    limit: value.limit, nextReset: value.nextReset, updated: value.lastUpdated, source: "AWS Lightsail · 入站 + 出站")
            case .bandwagonHost:
                guard let key = try keychain.read(for: server.id, kind: .kiwiAPIKey) else { return }
                let value = try await KiwiVMClient().serviceInfo(veid: server.veid, apiKey: key)
                guard stillCurrent(server, generation: generation) else { return }
                traffic[server.id] = MobileTraffic(used: value.used, limit: value.limit, nextReset: value.nextReset,
                    updated: value.lastUpdated, source: "KiwiVM · 服务计费流量")
            case .vultr, .hetznerCloud:
                guard let token = try keychain.readCloudToken(for: server.id, provider: server.provider) else { return }
                let value = try await CloudProviderClient().fetchTraffic(server: server, apiToken: token)
                guard stillCurrent(server, generation: generation) else { return }
                traffic[server.id] = MobileTraffic(used: value.used, inbound: value.inbound, outbound: value.outbound,
                    limit: value.limit, nextReset: value.nextReset, updated: value.lastUpdated, source: server.provider.rawValue + " · 出站计费")
            default: break
            }
        } catch {
            guard stillCurrent(server, generation: generation) else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            issues[server.id] = "平台流量：\(error.localizedDescription)"
        }
    }
}

enum MobileFormat {
    static func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .decimal) }
    static func rate(_ value: Double) -> String { bytes(UInt64(max(value, 0))) + "/s" }
}
