import Foundation

public enum ServerProvider: String, Codable, CaseIterable, Sendable {
    case bandwagonHost = "BandwagonHost"
    case genericLinux = "Generic Linux"
}

public enum SSHAuthentication: String, Codable, CaseIterable, Sendable {
    case key = "Private Key / SSH Agent"
    case password = "Password"
}

public struct Server: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var provider: ServerProvider
    public var veid: String
    public var operatingSystem: String
    public var authentication: SSHAuthentication
    public var privateKeyPath: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String = "root",
        provider: ServerProvider = .genericLinux,
        veid: String = "",
        operatingSystem: String = "Linux",
        authentication: SSHAuthentication = .key,
        privateKeyPath: String = "",
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.provider = provider
        self.veid = veid
        self.operatingSystem = operatingSystem
        self.authentication = authentication
        self.privateKeyPath = privateKeyPath
        self.createdAt = createdAt
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (1...65_535).contains(port) &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static let demo = Server(
        id: UUID(uuidString: "B6B3C9D0-6FB8-4F5C-A0D6-2DC6F6357B62")!,
        name: "CCM",
        host: "104.194.82.27",
        provider: .bandwagonHost,
        veid: "2178331",
        operatingSystem: "Ubuntu 24.04"
    )
}

public struct ServerMetrics: Codable, Equatable, Sendable {
    public var timestamp: Date
    public var cpuUsage: Double
    public var cpuUser: Double
    public var cpuSystem: Double
    public var cpuIOWait: Double
    public var cpuCores: Int
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    public var memoryAvailable: UInt64
    public var memoryCache: UInt64
    public var memoryBuffers: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var diskUsed: UInt64
    public var diskTotal: UInt64
    public var networkDownloadRate: Double
    public var networkUploadRate: Double
    public var networkReceivedTotal: UInt64
    public var networkSentTotal: UInt64
    public var networkInterface: String
    public var load1: Double
    public var load5: Double
    public var load15: Double
    public var uptime: TimeInterval

    public init(
        timestamp: Date = .now,
        cpuUsage: Double,
        cpuUser: Double = 0,
        cpuSystem: Double = 0,
        cpuIOWait: Double = 0,
        cpuCores: Int,
        memoryUsed: UInt64,
        memoryTotal: UInt64,
        memoryAvailable: UInt64 = 0,
        memoryCache: UInt64 = 0,
        memoryBuffers: UInt64 = 0,
        swapUsed: UInt64,
        swapTotal: UInt64,
        diskUsed: UInt64,
        diskTotal: UInt64,
        networkDownloadRate: Double,
        networkUploadRate: Double,
        networkReceivedTotal: UInt64 = 0,
        networkSentTotal: UInt64 = 0,
        networkInterface: String = "",
        load1: Double,
        load5: Double,
        load15: Double,
        uptime: TimeInterval
    ) {
        self.timestamp = timestamp
        self.cpuUsage = cpuUsage
        self.cpuUser = cpuUser
        self.cpuSystem = cpuSystem
        self.cpuIOWait = cpuIOWait
        self.cpuCores = cpuCores
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.memoryAvailable = memoryAvailable
        self.memoryCache = memoryCache
        self.memoryBuffers = memoryBuffers
        self.swapUsed = swapUsed
        self.swapTotal = swapTotal
        self.diskUsed = diskUsed
        self.diskTotal = diskTotal
        self.networkDownloadRate = networkDownloadRate
        self.networkUploadRate = networkUploadRate
        self.networkReceivedTotal = networkReceivedTotal
        self.networkSentTotal = networkSentTotal
        self.networkInterface = networkInterface
        self.load1 = load1
        self.load5 = load5
        self.load15 = load15
        self.uptime = uptime
    }

    public var memoryPercentage: Double { percentage(memoryUsed, memoryTotal) }
    public var swapPercentage: Double { percentage(swapUsed, swapTotal) }
    public var diskPercentage: Double { percentage(diskUsed, diskTotal) }

    private func percentage(_ used: UInt64, _ total: UInt64) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(used) / Double(total), 0), 1)
    }

    public static let demo = ServerMetrics(
        cpuUsage: 0.12,
        cpuUser: 0.08,
        cpuSystem: 0.03,
        cpuIOWait: 0.01,
        cpuCores: 2,
        memoryUsed: 327 * 1_048_576,
        memoryTotal: 1_024 * 1_048_576,
        memoryAvailable: 697 * 1_048_576,
        memoryCache: 218 * 1_048_576,
        memoryBuffers: 34 * 1_048_576,
        swapUsed: 13 * 1_048_576,
        swapTotal: 545 * 1_048_576,
        diskUsed: 6_300_000_000,
        diskTotal: 20_000_000_000,
        networkDownloadRate: 3_800_000,
        networkUploadRate: 420_000,
        networkReceivedTotal: 18_200_000_000,
        networkSentTotal: 4_100_000_000,
        networkInterface: "eth0",
        load1: 0.03,
        load5: 0.08,
        load15: 0.12,
        uptime: 17 * 86_400 + 4 * 3_600
    )
}

public struct BandwagonTraffic: Codable, Equatable, Sendable {
    public var used: UInt64
    public var limit: UInt64
    public var nextReset: Date
    public var serverOnline: Bool
    public var lastUpdated: Date

    public init(
        used: UInt64,
        limit: UInt64,
        nextReset: Date,
        serverOnline: Bool,
        lastUpdated: Date = .now
    ) {
        self.used = used
        self.limit = limit
        self.nextReset = nextReset
        self.serverOnline = serverOnline
        self.lastUpdated = lastUpdated
    }

    public var remaining: UInt64 { limit > used ? limit - used : 0 }
    public var usagePercentage: Double {
        guard limit > 0 else { return 0 }
        return min(max(Double(used) / Double(limit), 0), 1)
    }

    public static let demo = BandwagonTraffic(
        used: 422_480_000_000,
        limit: 1_000_000_000_000,
        nextReset: Calendar.current.date(byAdding: .day, value: 13, to: .now)!,
        serverOnline: true
    )
}

public struct TrafficForecast: Equatable, Sendable {
    public var dailyAverage: Double
    public var projectedUsage: Double
    public var exhaustionDate: Date?
    public var isAtRisk: Bool
}

public enum TrafficForecaster {
    public static func forecast(
        current: BandwagonTraffic,
        recentDailyUsage: [UInt64],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> TrafficForecast {
        let average = recentDailyUsage.isEmpty
            ? 0
            : recentDailyUsage.map { Double($0) }.reduce(0, +) / Double(recentDailyUsage.count)
        let days = max(calendar.dateComponents([.day], from: now, to: current.nextReset).day ?? 0, 0)
        let projected = Double(current.used) + average * Double(days)
        let bytesRemaining = max(Double(current.limit) - Double(current.used), 0)
        let daysToExhaustion = average > 0 ? bytesRemaining / average : .infinity
        let exhaustionDate = daysToExhaustion.isFinite
            ? calendar.date(byAdding: .second, value: Int(daysToExhaustion * 86_400), to: now)
            : nil
        return TrafficForecast(
            dailyAverage: average,
            projectedUsage: projected,
            exhaustionDate: exhaustionDate,
            isAtRisk: projected > Double(current.limit)
        )
    }
}

public extension UInt64 {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: self), countStyle: .decimal)
    }
}

public extension Double {
    var rateString: String {
        ByteCountFormatter.string(fromByteCount: Int64(max(self, 0)), countStyle: .decimal) + "/s"
    }
}
