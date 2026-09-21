import Foundation

/// Storage locations shared by the app and its helpers.
///
/// The release build keeps the paths used since 1.0. A copy with a different
/// bundle identifier (used for local end-to-end testing) gets its own folder
/// and Keychain service, so it never touches the real data.
public enum AppEnvironment {
    public static let releaseBundleIdentifier = "com.mujh.BWMonitor"

    public static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? releaseBundleIdentifier
    }

    public static var isReleaseIdentity: Bool {
        bundleIdentifier == releaseBundleIdentifier
    }

    /// `~/Library/Application Support/BWMonitor`
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(isReleaseIdentity ? "BWMonitor" : bundleIdentifier, isDirectory: true)
    }

    public static var keychainService: String {
        "\(bundleIdentifier).credentials"
    }

    /// Short, per-user directory for SSH control sockets. Unix socket paths
    /// are limited to 104 bytes, so this avoids the long Application Support
    /// path.
    public static var controlSocketDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bwm-ssh", isDirectory: true)
    }

    /// Creates `url` (and parents) readable only by the current user.
    public static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
