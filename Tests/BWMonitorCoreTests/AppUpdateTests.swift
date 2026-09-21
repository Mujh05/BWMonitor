import CryptoKit
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

@Suite("Release installer lookup")
struct ReleaseInfoTests {
    private static let digest = String(repeating: "ab", count: 32)

    @Test("Picks this Mac's installer and the checksum from the notes")
    func releaseInfo() throws {
        let json = """
        {
          "tag_name": "v1.2.0",
          "html_url": "https://github.com/Mujh05/BWMonitor/releases/tag/v1.2.0",
          "body": "安装说明\\n\\nSHA-256: `\(Self.digest.uppercased())`\\n",
          "assets": [
            {"name": "BWMonitor-Source.zip", "browser_download_url": "https://example.com/source.zip"},
            {"name": "BWMonitor-1.2-x86_64.dmg", "browser_download_url": "https://example.com/x86_64.dmg"},
            {"name": "BWMonitor-1.2-arm64.dmg", "browser_download_url": "https://example.com/arm64.dmg"}
          ]
        }
        """.data(using: .utf8)!
        let info = try JSONDecoder().decode(GitHubRelease.self, from: json).info
        #expect(info.version == "1.2.0")
        #if arch(arm64)
            #expect(info.dmgName == "BWMonitor-1.2-arm64.dmg")
        #else
            #expect(info.dmgName == "BWMonitor-1.2-x86_64.dmg")
        #endif
        #expect(info.sha256 == Self.digest)
    }

    @Test("A release without an installer still decodes")
    func releaseWithoutInstaller() throws {
        let json = #"{"tag_name": "v1.2"}"#.data(using: .utf8)!
        let info = try JSONDecoder().decode(GitHubRelease.self, from: json).info
        #expect(info.dmgURL == nil)
        #expect(info.sha256 == nil)
        #expect(info.pageURL == AppUpdate.releasesPageURL)
    }

    @Test("Same version with different spellings")
    func sameVersion() {
        #expect(AppUpdate.isSameVersion("1.2", "v1.2.0"))
        #expect(!AppUpdate.isSameVersion("1.2", "1.2.1"))
    }
}

@Suite("Update download and install steps")
struct UpdateInstallerTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BWMonitorUpdateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func source(_ contents: String) throws -> (URL, String) {
        let file = folder.appendingPathComponent("source.dmg")
        let data = Data(contents.utf8)
        try data.write(to: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (file, digest)
    }

    @Test("Download keeps the file when the checksum matches")
    func downloadMatches() async throws {
        defer { cleanUp() }
        let (file, digest) = try source("installer")
        let release = ReleaseInfo(
            version: "1.2", pageURL: AppUpdate.releasesPageURL,
            dmgURL: file, dmgName: "BWMonitor-1.2-arm64.dmg", sha256: digest.uppercased()
        )
        let target = folder.appendingPathComponent("download", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let downloaded = try await AppUpdateChecker().download(release, to: target)
        #expect(downloaded.lastPathComponent == "BWMonitor-1.2-arm64.dmg")
        #expect(try String(contentsOf: downloaded, encoding: .utf8) == "installer")
    }

    @Test("Download is rejected when the checksum differs")
    func downloadMismatch() async throws {
        defer { cleanUp() }
        let (file, _) = try source("tampered")
        let release = ReleaseInfo(
            version: "1.2", pageURL: AppUpdate.releasesPageURL,
            dmgURL: file, dmgName: "BWMonitor.dmg", sha256: String(repeating: "0", count: 64)
        )
        await #expect(throws: UpdateCheckError.checksumMismatch) {
            _ = try await AppUpdateChecker().download(release, to: folder)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("BWMonitor.dmg").path))
    }

    private func makeApp(_ name: String, identifier: String, version: String) throws -> URL {
        let app = folder.appendingPathComponent(name)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundlePackageType": "APPL"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    @Test("Finds the app with the same identifier and the released version")
    func findsNewApp() throws {
        defer { cleanUp() }
        _ = try makeApp("Other.app", identifier: "com.example.other", version: "1.2")
        let app = try makeApp("BWMonitor.app", identifier: "com.mujh.BWMonitor", version: "1.2")
        let found = try UpdateInstaller.newApp(in: folder, version: "v1.2.0", bundleIdentifier: "com.mujh.BWMonitor")
        #expect(found.resolvingSymlinksInPath().path == app.resolvingSymlinksInPath().path)
        #expect(throws: UpdateInstallError.self) {
            try UpdateInstaller.newApp(in: folder, version: "1.3", bundleIdentifier: "com.mujh.BWMonitor")
        }
        #expect(throws: UpdateInstallError.self) {
            try UpdateInstaller.newApp(in: folder, version: "1.2", bundleIdentifier: "com.mujh.BWMonitor.devtest")
        }
    }

    @Test("Swaps the staged app with the installed one")
    func swapsApps() throws {
        defer { cleanUp() }
        let installed = try makeApp("BWMonitor.app", identifier: "com.mujh.BWMonitor", version: "1.1")
        let stagingFolder = folder.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingFolder, withIntermediateDirectories: true)
        let staged = try makeApp("staging/BWMonitor.app", identifier: "com.mujh.BWMonitor", version: "1.2")
        try UpdateInstaller.swapItems(staged, installed)
        #expect(Bundle(url: installed)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "1.2")
        #expect(Bundle(url: staged)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "1.1")
    }

    @Test("Only app bundles in writable folders can be replaced")
    func replaceable() throws {
        defer { cleanUp() }
        let app = try makeApp("BWMonitor.app", identifier: "com.mujh.BWMonitor", version: "1.1")
        #expect(try UpdateInstaller.replaceableApp(app) == app.resolvingSymlinksInPath())
        #expect(throws: UpdateInstallError.self) {
            try UpdateInstaller.replaceableApp(folder)
        }
    }

    @Test("Existing downloads are not overwritten")
    func uniqueNames() throws {
        defer { cleanUp() }
        try Data().write(to: folder.appendingPathComponent("BWMonitor.dmg"))
        try Data().write(to: folder.appendingPathComponent("BWMonitor 2.dmg"))
        #expect(AppUpdate.uniqueURL(in: folder, name: "BWMonitor.dmg").lastPathComponent == "BWMonitor 3.dmg")
    }
}
