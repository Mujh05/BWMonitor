import Foundation

public actor MonitoringService {
    private let ssh: SSHManager
    private var previousSamples: [UUID: LinuxSample] = [:]

    public init(ssh: SSHManager) {
        self.ssh = ssh
    }

    public func refresh(server: Server) async throws -> (metrics: ServerMetrics, operatingSystem: String) {
        var previous = previousSamples[server.id]
        if previous.map({ Date.now.timeIntervalSince($0.timestamp) > 300 }) ?? true {
            // CPU usage and transfer rates need two samples. Take a baseline
            // so the first refresh does not show 0%.
            previous = try await sample(server)
            try await Task.sleep(for: .seconds(1))
        }
        let current = try await sample(server)
        previousSamples[server.id] = current
        return (LinuxMetricsParser.metrics(current: current, previous: previous), current.operatingSystem)
    }

    public func reset(serverID: UUID) {
        previousSamples[serverID] = nil
    }

    private func sample(_ server: Server) async throws -> LinuxSample {
        let output = try await ssh.execute(LinuxMetricsParser.command, on: server)
        return try LinuxMetricsParser.parse(output)
    }
}
