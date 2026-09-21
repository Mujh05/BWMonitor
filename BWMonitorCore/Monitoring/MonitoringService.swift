import Foundation

public actor MonitoringService {
    private let ssh: SSHManager
    private var previousSamples: [UUID: LinuxSample] = [:]

    public init(ssh: SSHManager) {
        self.ssh = ssh
    }

    public func refresh(server: Server) async throws -> (metrics: ServerMetrics, operatingSystem: String) {
        let output = try await ssh.execute(LinuxMetricsParser.command, on: server)
        let sample = try LinuxMetricsParser.parse(output)
        let metrics = LinuxMetricsParser.metrics(current: sample, previous: previousSamples[server.id])
        previousSamples[server.id] = sample
        return (metrics, sample.operatingSystem)
    }

    public func reset(serverID: UUID) {
        previousSamples[serverID] = nil
    }
}
