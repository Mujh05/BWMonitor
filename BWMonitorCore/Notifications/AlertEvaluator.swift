import Foundation
import UserNotifications

public struct AlertThresholds: Codable, Equatable, Sendable {
    public var traffic: Double = 0.8
    public var cpu: Double = 0.9
    public var memory: Double = 0.9
    public var disk: Double = 0.85

    public init(traffic: Double = 0.8, cpu: Double = 0.9, memory: Double = 0.9, disk: Double = 0.85) {
        self.traffic = traffic
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
    }
}

public struct MonitorAlert: Equatable, Sendable {
    public var key: String
    public var title: String
    public var body: String
}

public enum AlertEvaluator {
    public static func evaluate(
        server: Server,
        metrics: ServerMetrics?,
        traffic: BandwagonTraffic?,
        thresholds: AlertThresholds,
        cpuSustained: Bool = false
    ) -> [MonitorAlert] {
        var alerts: [MonitorAlert] = []
        if let traffic, traffic.usagePercentage >= thresholds.traffic {
            alerts.append(MonitorAlert(
                key: "\(server.id).traffic.\(Int(thresholds.traffic * 100))",
                title: String(
                    format: NSLocalizedString("%@ traffic warning", comment: "Traffic notification title"),
                    server.name
                ),
                body: String(
                    format: NSLocalizedString("%1$@ of %2$@ used", comment: "Traffic notification body"),
                    traffic.used.byteString,
                    traffic.limit.byteString
                )
            ))
        }
        if let metrics {
            if metrics.cpuUsage >= thresholds.cpu, cpuSustained {
                alerts.append(MonitorAlert(
                    key: "\(server.id).cpu",
                    title: String(
                        format: NSLocalizedString("%@ CPU is high", comment: "CPU notification title"),
                        server.name
                    ),
                    body: String(format: NSLocalizedString("CPU %lld%%", comment: "CPU notification body"), Int64(metrics.cpuUsage * 100))
                ))
            }
            if metrics.memoryPercentage >= thresholds.memory {
                alerts.append(MonitorAlert(
                    key: "\(server.id).memory",
                    title: String(
                        format: NSLocalizedString("%@ memory is high", comment: "Memory notification title"),
                        server.name
                    ),
                    body: String(format: NSLocalizedString("Memory %lld%%", comment: "Memory notification body"), Int64(metrics.memoryPercentage * 100))
                ))
            }
            if metrics.diskPercentage >= thresholds.disk {
                alerts.append(MonitorAlert(
                    key: "\(server.id).disk",
                    title: String(
                        format: NSLocalizedString("%@ disk is high", comment: "Disk notification title"),
                        server.name
                    ),
                    body: String(format: NSLocalizedString("Disk %lld%%", comment: "Disk notification body"), Int64(metrics.diskPercentage * 100))
                ))
            }
        }
        return alerts
    }
}

public final class NotificationManager: @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    public init() {}

    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    public func deliver(_ alert: MonitorAlert) async throws {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        let request = UNNotificationRequest(identifier: alert.key, content: content, trigger: nil)
        try await center.add(request)
    }
}
