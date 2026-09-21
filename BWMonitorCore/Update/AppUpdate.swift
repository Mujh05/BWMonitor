import CryptoKit
import Foundation

/// A published version on GitHub Releases.
public struct ReleaseInfo: Equatable, Sendable {
    public var version: String
    public var pageURL: URL
    public var dmgURL: URL?
    public var dmgName: String?
    /// The installer's SHA-256 as written in the release notes.
    public var sha256: String?

    public init(version: String, pageURL: URL, dmgURL: URL? = nil, dmgName: String? = nil, sha256: String? = nil) {
        self.version = version
        self.pageURL = pageURL
        self.dmgURL = dmgURL
        self.dmgName = dmgName
        self.sha256 = sha256
    }
}

/// Update channel backed by public GitHub Releases. No third-party SDK is
/// required: the app compares its bundle version against the latest release,
/// downloads the installer, and replaces itself (see ``UpdateInstaller``).
public enum AppUpdate {
    public static let githubOwner = "Mujh05"
    public static let githubRepo = "BWMonitor"

    public static var releasesAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest")!
    }

    public static var releasesPageURL: URL {
        URL(string: "https://github.com/\(githubOwner)/\(githubRepo)/releases/latest")!
    }

    /// For testing, `BWMONITOR_UPDATE_API` can point to local release data.
    static var latestReleaseAPI: URL {
        ProcessInfo.processInfo.environment["BWMONITOR_UPDATE_API"].flatMap(URL.init(string:)) ?? releasesAPIURL
    }

    /// The running version. For testing, `BWMONITOR_PRETEND_VERSION`
    /// replaces it so an update is offered.
    public static var currentVersion: String {
        ProcessInfo.processInfo.environment["BWMONITOR_PRETEND_VERSION"]
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
    }

    /// Moves a downloaded installer into the Downloads folder, next to any
    /// earlier copies.
    public static func moveToDownloads(_ file: URL) throws -> URL {
        let folder = try FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let destination = uniqueURL(in: folder, name: file.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    /// Adds " 2", " 3", … when a file with the name already exists.
    static func uniqueURL(in directory: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = "\(base) \(number)"
            candidate = directory.appendingPathComponent(
                pathExtension.isEmpty ? numbered : "\(numbered).\(pathExtension)"
            )
            number += 1
        }
        return candidate
    }

    /// Returns true when `latest` is a newer dotted version than `current`.
    /// A leading `v` (as in Git tags like `v1.0.1`) is ignored, missing
    /// components count as zero, and non-numeric suffixes stop parsing.
    public static func isNewer(latest: String, than current: String) -> Bool {
        let lhs = normalized(latest)
        let rhs = normalized(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// "1.2" and "v1.2.0" are the same version.
    public static func isSameVersion(_ a: String, _ b: String) -> Bool {
        !isNewer(latest: a, than: b) && !isNewer(latest: b, than: a)
    }

    static func normalized(_ version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let separator = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            text = String(text[..<separator])
        }
        return text.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// The `SHA-256: ...` line of the release notes.
    static func checksum(in notes: String) -> String? {
        guard let range = notes.range(of: #"SHA-256:\s*`?([0-9a-fA-F]{64})"#, options: .regularExpression) else {
            return nil
        }
        return String(notes[range].suffix(64)).lowercased()
    }
}

public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public var name: String
        public var downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }

    public var tagName: String
    public var name: String?
    public var htmlURL: URL?
    public var body: String?
    public var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case body
        case assets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        htmlURL = try container.decodeIfPresent(URL.self, forKey: .htmlURL)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }

    /// The release with the installer for this Mac's architecture.
    public var info: ReleaseInfo {
        #if arch(arm64)
            let architecture = "arm64"
        #else
            let architecture = "x86_64"
        #endif
        let dmg = assets.first { $0.name.hasSuffix(".dmg") && $0.name.contains(architecture) }
            ?? assets.first { $0.name.hasSuffix(".dmg") }
        return ReleaseInfo(
            version: tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
            pageURL: htmlURL ?? AppUpdate.releasesPageURL,
            dmgURL: dmg?.downloadURL,
            dmgName: dmg?.name,
            sha256: body.flatMap(AppUpdate.checksum(in:))
        )
    }
}

public enum UpdateCheckError: LocalizedError, Equatable {
    case badResponse(Int)
    case noInstaller
    case checksumMismatch

    public var errorDescription: String? {
        switch self {
        case let .badResponse(status):
            String(format: NSLocalizedString("GitHub returned an error (%d).", comment: "Update error"), status)
        case .noInstaller:
            NSLocalizedString("This release has no installer to download.", comment: "Update error")
        case .checksumMismatch:
            NSLocalizedString(
                "The download does not match the SHA-256 in the release notes and was deleted.",
                comment: "Update error"
            )
        }
    }
}

/// Reads public release information only; no personal data is sent.
public final class AppUpdateChecker: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: AppUpdate.latestReleaseAPI, timeoutInterval: 20)
        request.setValue("BWMonitor", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    /// Downloads the installer into `directory`, checking it against the
    /// SHA-256 from the release notes when they have one.
    public func download(_ release: ReleaseInfo, to directory: URL) async throws -> URL {
        guard let source = release.dmgURL else { throw UpdateCheckError.noInstaller }
        let (temporary, response) = try await session.download(from: source)
        do {
            try Self.check(response)
            if let expected = release.sha256 {
                let digest = try SHA256.hash(data: Data(contentsOf: temporary, options: .mappedIfSafe))
                    .map { String(format: "%02x", $0) }
                    .joined()
                guard digest == expected.lowercased() else { throw UpdateCheckError.checksumMismatch }
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        let destination = directory.appendingPathComponent(release.dmgName ?? source.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// HTTP responses must be 200; local files (used in tests) have no status.
    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateCheckError.badResponse(http.statusCode)
        }
    }
}
