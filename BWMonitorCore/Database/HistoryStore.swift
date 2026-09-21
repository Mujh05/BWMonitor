import Foundation
import SwiftData

@Model
public final class MetricRecord {
    @Attribute(.unique) public var id: UUID
    public var serverID: UUID
    public var timestamp: Date
    public var cpuUsage: Double
    public var memoryUsage: Double
    public var swapUsage: Double
    public var diskUsage: Double
    public var networkRX: Double
    public var networkTX: Double
    public var trafficUsed: UInt64
    public var load1: Double
    public var load5: Double
    public var load15: Double

    public init(serverID: UUID, metrics: ServerMetrics, trafficUsed: UInt64 = 0) {
        id = UUID()
        self.serverID = serverID
        timestamp = metrics.timestamp
        cpuUsage = metrics.cpuUsage
        memoryUsage = metrics.memoryPercentage
        swapUsage = metrics.swapPercentage
        diskUsage = metrics.diskPercentage
        networkRX = metrics.networkDownloadRate
        networkTX = metrics.networkUploadRate
        self.trafficUsed = trafficUsed
        load1 = metrics.load1
        load5 = metrics.load5
        load15 = metrics.load15
    }
}

@MainActor
public final class HistoryStore {
    public let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    public init(inMemory: Bool = false) throws {
        let schema = Schema([MetricRecord.self])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration("BWMonitorHistory", schema: schema, isStoredInMemoryOnly: true)
        } else {
            let url = AppEnvironment.supportDirectory.appendingPathComponent("History.store")
            try Self.moveLegacyStore(to: url)
            configuration = ModelConfiguration("BWMonitorHistory", schema: schema, url: url)
        }
        container = try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Version 1.0 kept its database directly in ~/Library/Application
    /// Support. Move it into the BWMonitor folder.
    private static func moveLegacyStore(to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard AppEnvironment.isReleaseIdentity, !fileManager.fileExists(atPath: url.path) else { return }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = base.appendingPathComponent("BWMonitorHistory.store").path
        guard fileManager.fileExists(atPath: legacy) else { return }
        for suffix in ["", "-wal", "-shm"] where fileManager.fileExists(atPath: legacy + suffix) {
            try fileManager.moveItem(atPath: legacy + suffix, toPath: url.path + suffix)
        }
    }

    @discardableResult
    public func append(serverID: UUID, metrics: ServerMetrics, trafficUsed: UInt64 = 0) throws -> MetricRecord {
        let record = MetricRecord(serverID: serverID, metrics: metrics, trafficUsed: trafficUsed)
        context.insert(record)
        try context.save()
        return record
    }

    public func fetch(serverID: UUID, since date: Date) throws -> [MetricRecord] {
        let predicate = #Predicate<MetricRecord> { record in
            record.serverID == serverID && record.timestamp >= date
        }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\.timestamp)]
        return try context.fetch(descriptor)
    }

    public func prune(olderThan date: Date) throws {
        try context.delete(model: MetricRecord.self, where: #Predicate { $0.timestamp < date })
        try context.save()
    }
}
