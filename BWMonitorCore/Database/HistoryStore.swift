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
        let configuration = ModelConfiguration("BWMonitorHistory", schema: schema, isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: schema, configurations: [configuration])
    }

    public func append(serverID: UUID, metrics: ServerMetrics, trafficUsed: UInt64 = 0) throws {
        context.insert(MetricRecord(serverID: serverID, metrics: metrics, trafficUsed: trafficUsed))
        try context.save()
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
