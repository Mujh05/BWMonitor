import Foundation

public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public var serverName: String
    public var isOnline: Bool
    public var cpuUsage: Double
    public var memoryUsage: Double
    public var diskUsage: Double
    public var trafficUsed: UInt64
    public var trafficLimit: UInt64
    public var downloadRate: Double
    public var uploadRate: Double
    public var updatedAt: Date

    public init(server: Server, metrics: ServerMetrics?, traffic: BandwagonTraffic?, isOnline: Bool? = nil) {
        serverName = server.name
        self.isOnline = isOnline ?? (metrics != nil || traffic?.serverOnline == true)
        cpuUsage = metrics?.cpuUsage ?? 0
        memoryUsage = metrics?.memoryPercentage ?? 0
        diskUsage = metrics?.diskPercentage ?? 0
        trafficUsed = traffic?.used ?? 0
        trafficLimit = traffic?.limit ?? 0
        downloadRate = metrics?.networkDownloadRate ?? 0
        uploadRate = metrics?.networkUploadRate ?? 0
        updatedAt = max(metrics?.timestamp ?? .distantPast, traffic?.lastUpdated ?? .distantPast)
    }
}

public enum WidgetSnapshotStore {
    public static let appGroup = "7V636A77V4.com.mujh.BWMonitor"
    private static let key = "latestWidgetSnapshot"

    public static func save(_ snapshot: WidgetSnapshot) throws {
        // Only the release app feeds the widget; a renamed test copy must
        // not overwrite what the real app shows.
        guard Bundle.main.bundleIdentifier == "com.mujh.BWMonitor",
              let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(try JSONEncoder().encode(snapshot), forKey: key)
    }

    public static func load() -> WidgetSnapshot? {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
