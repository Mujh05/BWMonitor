import Foundation
import Testing

@testable import BWMonitorCore

/// Runs against a real SSH server when these variables are set, for example
/// a throwaway `sshd` on localhost:
///
///     BWMONITOR_TEST_SSH_HOST=127.0.0.1 BWMONITOR_TEST_SSH_PORT=2222 \
///     BWMONITOR_TEST_SSH_USER=$USER BWMONITOR_TEST_SSH_KEY=/path/to/key swift test
///
/// Against a Linux server it also collects real metrics.
@Suite(
    "SSH against a live server",
    .enabled(if: ProcessInfo.processInfo.environment["BWMONITOR_TEST_SSH_HOST"] != nil),
    .serialized
)
struct SSHIntegrationTests {
    let manager: SSHManager
    let server: Server
    let directory: URL

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bwm-live-\(UUID().uuidString.prefix(8))")
        manager = SSHManager(
            // A space, like in "Application Support", must not break ssh options.
            knownHostsDirectory: directory.appendingPathComponent("Known Hosts"),
            controlDirectory: directory.appendingPathComponent("cm"),
            keychain: KeychainStore(service: "com.mujh.BWMonitor.tests.\(UUID().uuidString)")
        )
        server = Server(
            name: "Live",
            host: environment["BWMONITOR_TEST_SSH_HOST"] ?? "",
            port: Int(environment["BWMONITOR_TEST_SSH_PORT"] ?? "") ?? 22,
            username: environment["BWMONITOR_TEST_SSH_USER"] ?? "root",
            authentication: .key,
            privateKeyPath: environment["BWMONITOR_TEST_SSH_KEY"] ?? ""
        )
    }

    @Test("Trust, test, run commands over one shared connection")
    func endToEnd() async throws {
        defer {
            manager.closeSharedConnection(for: server)
            try? FileManager.default.removeItem(at: directory)
        }
        await #expect(throws: SSHError.hostNotTrusted) { _ = try await manager.execute("true", on: server) }

        guard case let .unknown(identity) = try await manager.hostKeyStatus(for: server) else {
            Issue.record("A new server should be unknown")
            return
        }
        try manager.trust(identity, for: server)
        guard case .trusted = try await manager.hostKeyStatus(for: server) else {
            Issue.record("The pinned key should match")
            return
        }

        let report = try await manager.testConnection(server)
        #expect(!report.system.isEmpty)

        let first = Date.now
        #expect(try await manager.execute("echo one", on: server) == "one\n")
        let firstDuration = Date.now.timeIntervalSince(first)
        let second = Date.now
        #expect(try await manager.execute("printf '%s' \"$((20 + 22))\"", on: server) == "42")
        let secondDuration = Date.now.timeIntervalSince(second)
        #expect(FileManager.default.fileExists(atPath: manager.controlPath(for: server)))
        print("first command \(firstDuration)s, shared connection \(secondDuration)s")

        // Remote failures are command errors, not connection errors.
        await #expect(throws: SSHError.commandFailed("boom")) {
            _ = try await manager.execute("echo boom >&2; exit 3", on: server)
        }

        if report.system.hasPrefix("Linux") {
            let service = MonitoringService(ssh: manager)
            let result = try await service.refresh(server: server)
            #expect(result.metrics.memoryTotal > 0)
            #expect(!result.metrics.networkInterface.isEmpty)
            print("metrics: cpu \(result.metrics.cpuUsage) iface \(result.metrics.networkInterface) os \(result.operatingSystem)")
        }
    }

    @Test("A changed host key blocks the connection")
    func changedHostKey() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let pattern = server.port == 22 ? server.host : "[\(server.host)]:\(server.port)"
        let fake = SSHHostIdentity(host: server.host, keys: KnownHosts.parse(
            "\(pattern) \(KnownHostsTests.ed25519.split(separator: " ", maxSplits: 1)[1])"
        ))
        try manager.trust(fake, for: server)
        guard case .changed = try await manager.hostKeyStatus(for: server) else {
            Issue.record("A different pinned key must be reported as changed")
            return
        }
        await #expect(throws: SSHError.hostKeyChanged) { _ = try await manager.execute("true", on: server) }
    }
}
