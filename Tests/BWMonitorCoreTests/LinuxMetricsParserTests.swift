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
        XCTAssertEqual(metrics.diskUsed, 6_300_000 * 1_024)
        XCTAssertEqual(metrics.diskTotal, (6_300_000 + 12_700_000) * 1_024)
        XCTAssertEqual(metrics.networkDownloadRate, 1_500)
        XCTAssertEqual(metrics.networkUploadRate, 500)
        XCTAssertEqual(metrics.networkInterface, "eth0")
        XCTAssertEqual(metrics.load5, 0.08)
    }

    /// Real /proc/net/dev right-aligns interface names, so lines start with
    /// spaces. Version 1.0 failed on exactly this and never produced metrics.
    func testParsesIndentedNetDevAndPrefersDefaultRoute() {
        let devices = LinuxMetricsParser.parseNetworkDevices(Self.netDev(received: 98_765_432, sent: 12_345_678))
        XCTAssertEqual(devices.map(\.name), ["lo", "docker0", "eth0"])
        XCTAssertEqual(devices.last?.received, 98_765_432)
        XCTAssertEqual(devices.last?.sent, 12_345_678)

        XCTAssertEqual(LinuxMetricsParser.primaryInterface(devices, defaultRoute: "eth0")?.name, "eth0")
        XCTAssertEqual(LinuxMetricsParser.primaryInterface(devices, defaultRoute: "docker0")?.name, "docker0")
        // Without a default route, pick the busiest interface that is not loopback.
        XCTAssertEqual(LinuxMetricsParser.primaryInterface(devices, defaultRoute: "")?.name, "eth0")
    }

    func testFallsBackWhenMemAvailableIsMissing() throws {
        let output = Self.sample(cpuUser: 1, cpuIdle: 1, received: 1, sent: 1)
            .replacingOccurrences(of: "MemAvailable:    704000 kB\n", with: "MemFree:         400000 kB\n")
        let sample = try LinuxMetricsParser.parse(output)
        XCTAssertEqual(sample.memoryAvailable, (400_000 + 34_000 + 218_000) * 1_024)
    }

    func testIOWaitCountsAsIdle() throws {
        let first = try LinuxMetricsParser.parse(Self.sample(cpuUser: 100, cpuIdle: 800, ioWait: 10, received: 0, sent: 0))
        let second = try LinuxMetricsParser.parse(Self.sample(cpuUser: 100, cpuIdle: 800, ioWait: 110, received: 0, sent: 0))
        XCTAssertEqual(LinuxMetricsParser.metrics(current: second, previous: first).cpuUsage, 0, accuracy: 0.001)
    }

    func testRatesUseServerUptimeInterval() throws {
        // Local timestamps are 10 s apart because of network delay, but the
        // server read its counters 2 s apart.
        let first = try LinuxMetricsParser.parse(
            Self.sample(cpuUser: 0, cpuIdle: 0, received: 0, sent: 0, uptime: 100),
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let second = try LinuxMetricsParser.parse(
            Self.sample(cpuUser: 0, cpuIdle: 0, received: 2_000, sent: 0, uptime: 102),
            timestamp: Date(timeIntervalSince1970: 10)
        )
        XCTAssertEqual(LinuxMetricsParser.metrics(current: second, previous: first).networkDownloadRate, 1_000, accuracy: 0.001)
    }

    private static func sample(
        cpuUser: UInt64,
        cpuIdle: UInt64,
        ioWait: UInt64 = 10,
        received: UInt64,
        sent: UInt64,
        uptime: Double = 1_483_200
    ) -> String {
        """
        __CPU__
        cpu  \(cpuUser) 0 40 \(cpuIdle) \(ioWait) 0 0 0 0 0
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
        /dev/vda1 20480000 6300000 12700000 34% /
        __LOAD__
        0.03 0.08 0.12 1/100 123
        __UPTIME__
        \(String(format: "%.2f", uptime)) 0.00
        __ROUTE__
        eth0
        __NET__
        \(netDev(received: received, sent: sent))
        __OS__
        Ubuntu 24.04 LTS
        """
    }

    private static func netDev(received: UInt64, sent: UInt64) -> String {
        """
        Inter-|   Receive                                                |  Transmit
         face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
            lo:  123456    1234    0    0    0     0          0         0   123456    1234    0    0    0     0       0          0
        docker0:    5000      50    0    0    0     0          0         0     6000      60    0    0    0     0       0          0
          eth0: \(received)  87654    0    0    0     0          0         0 \(sent)  54321    0    0    0     0       0          0
        """
    }
}
