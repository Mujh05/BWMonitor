import XCTest
@testable import BWMonitorCore

final class LinuxMetricsParserTests: XCTestCase {
    func testParsesLinuxSnapshotAndComputesDeltas() throws {
        let first = try LinuxMetricsParser.parse(Self.sample(cpuUser: 100, cpuIdle: 800, received: 1_000, sent: 500), timestamp: Date(timeIntervalSince1970: 10))
        let second = try LinuxMetricsParser.parse(Self.sample(cpuUser: 150, cpuIdle: 850, received: 4_000, sent: 1_500), timestamp: Date(timeIntervalSince1970: 12))
        let metrics = LinuxMetricsParser.metrics(current: second, previous: first)

        XCTAssertEqual(metrics.cpuUsage, 0.5, accuracy: 0.001)
        XCTAssertEqual(metrics.memoryTotal, 1_048_576_000)
        XCTAssertEqual(metrics.memoryUsed, 327_680_000)
        XCTAssertEqual(metrics.swapUsed, 13_312_000)
        XCTAssertEqual(metrics.diskUsed, 6_300_000_000)
        XCTAssertEqual(metrics.networkDownloadRate, 1_500)
        XCTAssertEqual(metrics.networkUploadRate, 500)
        XCTAssertEqual(metrics.networkInterface, "eth0")
        XCTAssertEqual(metrics.load5, 0.08)
    }

    private static func sample(cpuUser: UInt64, cpuIdle: UInt64, received: UInt64, sent: UInt64) -> String {
        """
        __CPU__
        cpu  \(cpuUser) 0 40 \(cpuIdle) 10 0 0 0
        __CORES__
        2
        __MEM__
        MemTotal:       1024000 kB
        MemAvailable:    704000 kB
        Buffers:          34000 kB
        Cached:          218000 kB
        SwapTotal:       545000 kB
        SwapFree:        532000 kB
        __DISK__
        /dev/vda1 20000000000 6300000000 13700000000 32% /
        __LOAD__
        0.03 0.08 0.12 1/100 123
        __UPTIME__
        1483200.00 0.00
        __NET__
        eth0 \(received) \(sent)
        __OS__
        Ubuntu 24.04 LTS
        """
    }
}
