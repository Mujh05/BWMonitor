import Foundation

/// Update channel backed by public GitHub Releases. No third-party SDK is
/// required: the app compares its bundle version against the latest release
/// tag and points the user at the release page when a newer build exists.
public enum AppUpdate {
    public static let githubOwner = "Mujh05"
    public static let githubRepo = "BWMonitor"

    public static var releasesAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(githubOwner)/\(githubRepo)/releases/latest")!
    }

    public static var releasesPageURL: URL {
        URL(string: "https://github.com/\(githubOwner)/\(githubRepo)/releases/latest")!
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

    static func normalized(_ version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let separator = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            text = String(text[..<separator])
        }
        return text.split(separator: ".").map { Int($0) ?? 0 }
    }
}

public struct GitHubRelease: Decodable, Sendable {
    public var tagName: String
    public var name: String?
    public var htmlURL: URL?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
    }
}

public enum UpdateCheckError: Error {
    case badResponse
}

public final class AppUpdateChecker: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: AppUpdate.releasesAPIURL, timeoutInterval: 20)
        request.setValue("BWMonitor", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateCheckError.badResponse
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}
