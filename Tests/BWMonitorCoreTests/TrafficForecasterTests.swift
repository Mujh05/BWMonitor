import XCTest
@testable import BWMonitorCore

final class TrafficForecasterTests: XCTestCase {
    func testForecastMarksProjectedOverage() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let traffic = BandwagonTraffic(
            used: 800,
            limit: 1_000,
            nextReset: now.addingTimeInterval(5 * 86_400),
            serverOnline: true,
            lastUpdated: now
        )
        let forecast = TrafficForecaster.forecast(
            current: traffic,
            recentDailyUsage: [50, 50, 50],
            now: now,
            calendar: Calendar(identifier: .gregorian)
        )

        XCTAssertTrue(forecast.isAtRisk)
        XCTAssertEqual(forecast.projectedUsage, 1_050, accuracy: 0.001)
        XCTAssertNotNil(forecast.exhaustionDate)
    }

    func testDailyUsageScalesToTheSampledSpan() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // 12 GB over two days is 6 GB a day, not 12.
        let daily = TrafficForecaster.dailyUsage(samples: [
            (start, 10_000_000_000),
            (start.addingTimeInterval(86_400), 0),
            (start.addingTimeInterval(2 * 86_400), 22_000_000_000)
        ])
        XCTAssertEqual(daily, [6_000_000_000])
        XCTAssertEqual(TrafficForecaster.dailyUsage(samples: [(start, 1), (start.addingTimeInterval(60), 5)]), [])
    }

    func testForecastHandlesNoHistory() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let traffic = BandwagonTraffic(used: 400, limit: 1_000, nextReset: now.addingTimeInterval(86_400), serverOnline: true)
        let forecast = TrafficForecaster.forecast(current: traffic, recentDailyUsage: [], now: now)

        XCTAssertFalse(forecast.isAtRisk)
        XCTAssertEqual(forecast.dailyAverage, 0)
        XCTAssertNil(forecast.exhaustionDate)
    }
}
