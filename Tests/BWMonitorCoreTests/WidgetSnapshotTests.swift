import XCTest
@testable import BWMonitorCore

final class WidgetSnapshotTests: XCTestCase {
    func testLiveSSHMetricsKeepSnapshotOnlineWhenProviderStatusIsUnavailable() {
        let traffic = BandwagonTraffic(
            used: 500,
            limit: 1_000,
            nextReset: .now,
            serverOnline: false
        )

        let snapshot = WidgetSnapshot(server: .demo, metrics: .demo, traffic: traffic)

        XCTAssertTrue(snapshot.isOnline)
    }
}
