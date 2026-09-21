import Foundation

public struct CPUCounters: Equatable, Sendable {
    public var user: UInt64
    public var nice: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var ioWait: UInt64
    public var irq: UInt64
    public var softIRQ: UInt64
    public var steal: UInt64

    public var total: UInt64 { user + nice + system + idle + ioWait + irq + softIRQ + steal }
    public var active: UInt64 { total - idle - ioWait }
}

public struct LinuxSample: Equatable, Sendable {
    public var timestamp: Date
    public var cpu: CPUCounters
    public var cpuCores: Int
    public var memoryTotal: UInt64
    public var memoryAvailable: UInt64
    public var memoryCache: UInt64
    public var memoryBuffers: UInt64
    public var swapTotal: UInt64
    public var swapFree: UInt64
    public var diskTotal: UInt64
    public var diskUsed: UInt64
    public var networkInterface: String
    public var networkReceived: UInt64
    public var networkSent: UInt64
    public var load1: Double
    public var load5: Double
    public var load15: Double
    public var uptime: TimeInterval
    public var operatingSystem: String
}

public enum LinuxMetricsParserError: LocalizedError, Equatable {
    case missingSection(String)
    case malformedSection(String)

    public var errorDescription: String? {
        switch self {
        case let .missingSection(section):
            String(
                format: NSLocalizedString("Missing Linux metrics section: %@", comment: "Metrics parser error"),
                section
            )
        case let .malformedSection(section):
            String(
                format: NSLocalizedString("Malformed Linux metrics section: %@", comment: "Metrics parser error"),
                section
            )
        }
    }
}

public enum LinuxMetricsParser {
    public static let command = #"""
LC_ALL=C
echo __CPU__; head -n 1 /proc/stat
echo __CORES__; nproc
echo __MEM__; cat /proc/meminfo
echo __DISK__; df -B1 -P / | tail -n 1
echo __LOAD__; cat /proc/loadavg
echo __UPTIME__; cat /proc/uptime
echo __NET__; awk -F'[: ]+' '$1 != "lo" && $1 != "Inter-" && $1 != "face" && NF > 10 {print $1, $3, $11; exit}' /proc/net/dev
echo __OS__; . /etc/os-release 2>/dev/null; printf '%s\n' "${PRETTY_NAME:-Linux}"
"""#

    public static func parse(_ output: String, timestamp: Date = .now) throws -> LinuxSample {
        let sections = splitSections(output)
        let cpu = try parseCPU(required("CPU", from: sections))
        let cores = Int(firstLine(required("CORES", from: sections))) ?? 1
        let memory = parseKeyValue(required("MEM", from: sections))
        guard let memoryTotal = memory["MemTotal"],
              let memoryAvailable = memory["MemAvailable"],
              let swapTotal = memory["SwapTotal"],
              let swapFree = memory["SwapFree"] else {
            throw LinuxMetricsParserError.malformedSection("MEM")
        }
        let disk = required("DISK", from: sections).split(whereSeparator: { $0.isWhitespace })
        guard disk.count >= 4,
              let diskTotal = UInt64(disk[1]),
              let diskUsed = UInt64(disk[2]) else {
            throw LinuxMetricsParserError.malformedSection("DISK")
        }
        let load = required("LOAD", from: sections).split(whereSeparator: { $0.isWhitespace })
        guard load.count >= 3,
              let load1 = Double(load[0]),
              let load5 = Double(load[1]),
              let load15 = Double(load[2]) else {
            throw LinuxMetricsParserError.malformedSection("LOAD")
        }
        guard let uptime = Double(firstLine(required("UPTIME", from: sections)).split(separator: " ").first ?? "") else {
            throw LinuxMetricsParserError.malformedSection("UPTIME")
        }
        let network = required("NET", from: sections).split(whereSeparator: { $0.isWhitespace })
        guard network.count >= 3,
              let received = UInt64(network[1]),
              let sent = UInt64(network[2]) else {
            throw LinuxMetricsParserError.malformedSection("NET")
        }

        return LinuxSample(
            timestamp: timestamp,
            cpu: cpu,
            cpuCores: cores,
            memoryTotal: memoryTotal,
            memoryAvailable: memoryAvailable,
            memoryCache: memory["Cached"] ?? 0,
            memoryBuffers: memory["Buffers"] ?? 0,
            swapTotal: swapTotal,
            swapFree: swapFree,
            diskTotal: diskTotal,
            diskUsed: diskUsed,
            networkInterface: String(network[0]),
            networkReceived: received,
            networkSent: sent,
            load1: load1,
            load5: load5,
            load15: load15,
            uptime: uptime,
            operatingSystem: firstLine(required("OS", from: sections))
        )
    }

    public static func metrics(current: LinuxSample, previous: LinuxSample?) -> ServerMetrics {
        let interval = previous.map { max(current.timestamp.timeIntervalSince($0.timestamp), 0.001) } ?? 1
        let cpuValues = cpuPercentages(current: current.cpu, previous: previous?.cpu)
        let receivedDelta = delta(current.networkReceived, previous?.networkReceived)
        let sentDelta = delta(current.networkSent, previous?.networkSent)
        return ServerMetrics(
            timestamp: current.timestamp,
            cpuUsage: cpuValues.total,
            cpuUser: cpuValues.user,
            cpuSystem: cpuValues.system,
            cpuIOWait: cpuValues.ioWait,
            cpuCores: current.cpuCores,
            memoryUsed: current.memoryTotal - min(current.memoryAvailable, current.memoryTotal),
            memoryTotal: current.memoryTotal,
            memoryAvailable: current.memoryAvailable,
            memoryCache: current.memoryCache,
            memoryBuffers: current.memoryBuffers,
            swapUsed: current.swapTotal - min(current.swapFree, current.swapTotal),
            swapTotal: current.swapTotal,
            diskUsed: current.diskUsed,
            diskTotal: current.diskTotal,
            networkDownloadRate: Double(receivedDelta) / interval,
            networkUploadRate: Double(sentDelta) / interval,
            networkReceivedTotal: current.networkReceived,
            networkSentTotal: current.networkSent,
            networkInterface: current.networkInterface,
            load1: current.load1,
            load5: current.load5,
            load15: current.load15,
            uptime: current.uptime
        )
    }

    private static func splitSections(_ output: String) -> [String: String] {
        var sections: [String: [String]] = [:]
        var active: String?
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("__"), line.hasSuffix("__") {
                active = String(line.dropFirst(2).dropLast(2))
                sections[active!, default: []] = []
            } else if let active {
                sections[active, default: []].append(line)
            }
        }
        return sections.mapValues { $0.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func required(_ key: String, from sections: [String: String]) -> String {
        sections[key] ?? ""
    }

    private static func firstLine(_ value: String) -> String {
        value.components(separatedBy: .newlines).first ?? ""
    }

    private static func parseCPU(_ value: String) throws -> CPUCounters {
        let values = value.split(whereSeparator: { $0.isWhitespace }).dropFirst().compactMap { UInt64($0) }
        guard values.count >= 8 else { throw LinuxMetricsParserError.malformedSection("CPU") }
        return CPUCounters(
            user: values[0], nice: values[1], system: values[2], idle: values[3],
            ioWait: values[4], irq: values[5], softIRQ: values[6], steal: values[7]
        )
    }

    private static func parseKeyValue(_ value: String) -> [String: UInt64] {
        value.components(separatedBy: .newlines).reduce(into: [:]) { result, line in
            let fields = line.split(whereSeparator: { $0 == ":" || $0.isWhitespace })
            guard fields.count >= 2, let number = UInt64(fields[1]) else { return }
            result[String(fields[0])] = number * 1_024
        }
    }

    private static func cpuPercentages(
        current: CPUCounters,
        previous: CPUCounters?
    ) -> (total: Double, user: Double, system: Double, ioWait: Double) {
        guard let previous else { return (0, 0, 0, 0) }
        let total = delta(current.total, previous.total)
        guard total > 0 else { return (0, 0, 0, 0) }
        let divisor = Double(total)
        let idle = delta(current.idle, previous.idle)
        return (
            min(max(1 - Double(idle) / divisor, 0), 1),
            Double(delta(current.user + current.nice, previous.user + previous.nice)) / divisor,
            Double(delta(current.system, previous.system)) / divisor,
            Double(delta(current.ioWait, previous.ioWait)) / divisor
        )
    }

    private static func delta(_ current: UInt64, _ previous: UInt64?) -> UInt64 {
        guard let previous, current >= previous else { return 0 }
        return current - previous
    }
}
