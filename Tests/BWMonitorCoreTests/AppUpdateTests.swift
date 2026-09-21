import Foundation
import Testing

@testable import BWMonitorCore

@Suite("App update version comparison")
struct AppUpdateTests {
    @Test("Newer patch is detected")
    func newerPatch() {
        #expect(AppUpdate.isNewer(latest: "v1.0.1", than: "1.0") == true)
    }

    @Test("Equal versions are not newer")
    func equalVersions() {
        #expect(AppUpdate.isNewer(latest: "1.0", than: "1.0") == false)
        #expect(AppUpdate.isNewer(latest: "v1.0", than: "1.0") == false)
    }

    @Test("Older versions are not newer")
    func olderVersions() {
        #expect(AppUpdate.isNewer(latest: "1.0", than: "1.0.1") == false)
        #expect(AppUpdate.isNewer(latest: "1.9.9", than: "2.0") == false)
    }

    @Test("Multi-digit components compare numerically")
    func numericComparison() {
        #expect(AppUpdate.isNewer(latest: "1.10", than: "1.9") == true)
        #expect(AppUpdate.isNewer(latest: "1.9", than: "1.10") == false)
    }

    @Test("Missing components count as zero")
    func missingComponents() {
        #expect(AppUpdate.isNewer(latest: "1.0.1", than: "1.0") == true)
        #expect(AppUpdate.isNewer(latest: "1.0", than: "1.0.0") == false)
    }

    @Test("Release payload decodes")
    func releaseDecoding() throws {
        let json = """
        {"tag_name": "v1.0.1", "name": "BWMonitor 1.0.1", "html_url": "https://github.com/Mujh05/BWMonitor/releases/tag/v1.0.1"}
        """.data(using: .utf8)!
        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        #expect(release.tagName == "v1.0.1")
        #expect(release.htmlURL?.absoluteString.hasSuffix("/releases/tag/v1.0.1") == true)
    }
}
