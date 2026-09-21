import Foundation
import Security

/// Why an update could not be installed automatically.
public enum UpdateInstallError: LocalizedError, Equatable {
    /// The app cannot be replaced where it is; the user has to install the
    /// new version by hand.
    case notReplaceable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case let .notReplaceable(reason), let .failed(reason): reason
        }
    }
}

/// Installs a downloaded release over the running app, without the user
/// dragging anything into Applications.
///
/// The disk image is mounted hidden (`nobrowse`) in a temporary folder and the
/// new app is staged next to the old one before the two are swapped, so
/// neither shows up in Finder or gets indexed by Spotlight (which would add
/// extra copies to Launchpad).
public enum UpdateInstaller {
    /// The running app's bundle, if it can be replaced in place.
    public static func replaceableApp(_ bundle: URL = Bundle.main.bundleURL) throws -> URL {
        let app = bundle.resolvingSymlinksInPath()
        guard app.pathExtension == "app" else {
            throw UpdateInstallError.notReplaceable(
                NSLocalizedString("BWMonitor is not running from an app bundle.", comment: "Update error")
            )
        }
        // Quarantined apps opened from Downloads run from a read-only copy.
        if app.path.contains("/AppTranslocation/") {
            throw UpdateInstallError.notReplaceable(
                NSLocalizedString(
                    "macOS is running BWMonitor from a temporary location because it was opened from Downloads.",
                    comment: "Update error"
                )
            )
        }
        if (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            throw UpdateInstallError.notReplaceable(
                NSLocalizedString(
                    "BWMonitor is on a read-only disk, such as its installer.",
                    comment: "Update error"
                )
            )
        }
        let folder = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path),
              FileManager.default.isWritableFile(atPath: app.path) else {
            throw UpdateInstallError.notReplaceable(
                String(
                    format: NSLocalizedString("You don’t have permission to replace BWMonitor in “%@”.", comment: "Update error"),
                    folder.path
                )
            )
        }
        return app
    }

    /// Mounts `dmg`, checks the app inside, and swaps it with `app`. The disk
    /// image is ejected and the old version deleted afterwards.
    public static func install(
        _ dmg: URL,
        version: String,
        replacing app: URL,
        bundleIdentifier: String = AppEnvironment.bundleIdentifier
    ) async throws {
        try await Task.detached {
            try installNow(dmg, version: version, replacing: app, bundleIdentifier: bundleIdentifier)
        }.value
    }

    private static func installNow(_ dmg: URL, version: String, replacing app: URL, bundleIdentifier: String) throws {
        let fileManager = FileManager.default
        let mountPoint = dmg.deletingLastPathComponent().appendingPathComponent("mount", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try attach(dmg, at: mountPoint)
        defer { detach(mountPoint) }

        let source = try newApp(in: mountPoint, version: version, bundleIdentifier: bundleIdentifier)
        try verifySignature(of: source, replacing: app, bundleIdentifier: bundleIdentifier)
        // Staged on the same volume as the app, so the two can be swapped.
        let staging = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: app,
            create: true
        )
        defer { try? fileManager.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(app.lastPathComponent)
        try run("/usr/bin/ditto", source.path, staged.path)
        // Downloads made by BWMonitor are not quarantined, but make sure
        // Gatekeeper does not stop the relaunch.
        _ = try? run("/usr/bin/xattr", "-dr", "com.apple.quarantine", staged.path)
        // After the swap the old version sits in the staging folder, which is
        // deleted above.
        try swapItems(staged, app)
    }

    /// Mounts read-only at `mountPoint`, hidden from Finder and Spotlight.
    /// `hdiutil` is deprecated on current macOS, so `diskutil image` comes
    /// first; older systems without it fall back to `hdiutil`.
    private static func attach(_ dmg: URL, at mountPoint: URL) throws {
        do {
            try run(
                "/usr/sbin/diskutil", "image", "attach", "--readOnly", "--mountOptions", "nobrowse",
                "--mountPoint", mountPoint.path, dmg.path
            )
        } catch {
            // Report the diskutil error: later systems may not have hdiutil.
            guard (try? run(
                "/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                "-mountpoint", mountPoint.path
            )) != nil else { throw error }
        }
    }

    private static func detach(_ mountPoint: URL) {
        if (try? run("/usr/sbin/diskutil", "eject", "force", mountPoint.path)) == nil {
            _ = try? run("/usr/bin/hdiutil", "detach", mountPoint.path, "-force")
        }
    }

    /// The app in the disk image: same bundle identifier, the released version.
    static func newApp(in folder: URL, version: String, bundleIdentifier: String) throws -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let app = items.first(where: {
            $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == bundleIdentifier
        }) else {
            throw UpdateInstallError.failed(
                NSLocalizedString("The installer does not contain BWMonitor.", comment: "Update error")
            )
        }
        let found = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let found, AppUpdate.isSameVersion(found, version) else {
            throw UpdateInstallError.failed(
                String(
                    format: NSLocalizedString("The installer contains version %@ instead of %@.", comment: "Update error"),
                    found ?? "?",
                    version
                )
            )
        }
        return app
    }

    /// The new app must have an intact signature. When the running app is
    /// signed by a developer team, the new one must come from the same team,
    /// which also keeps saved Keychain passwords readable without prompts.
    static func verifySignature(of newApp: URL, replacing app: URL, bundleIdentifier: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(newApp as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateInstallError.failed(
                NSLocalizedString("The new version’s signature is not valid.", comment: "Update error")
            )
        }
        var requirement: SecRequirement?
        if let team = teamIdentifier(of: app) {
            let text = "identifier \"\(bundleIdentifier)\" and anchor apple generic "
                + "and certificate leaf[subject.OU] = \"\(team)\""
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
                throw UpdateInstallError.failed(
                    NSLocalizedString("The new version’s signature is not valid.", comment: "Update error")
                )
            }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateInstallError.failed(
                status == errSecCSReqFailed
                    ? NSLocalizedString("The new version is signed by a different developer.", comment: "Update error")
                    : NSLocalizedString("The new version’s signature is not valid.", comment: "Update error")
            )
        }
    }

    static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Swaps `staged` and `app`: one atomic step on APFS. Elsewhere the old
    /// version is moved aside first and put back if the new one cannot be
    /// moved in.
    static func swapItems(_ staged: URL, _ app: URL) throws {
        if renamex_np(staged.path, app.path, UInt32(RENAME_SWAP)) == 0 { return }
        let old = staged.deletingLastPathComponent().appendingPathComponent("Old " + app.lastPathComponent)
        guard rename(app.path, old.path) == 0 else {
            throw posixFailure(NSLocalizedString("Could not move the old version aside", comment: "Update error"))
        }
        guard rename(staged.path, app.path) == 0 else {
            let failure = posixFailure(NSLocalizedString("Could not move the new version in", comment: "Update error"))
            _ = rename(old.path, app.path)
            throw failure
        }
    }

    private static func posixFailure(_ action: String) -> UpdateInstallError {
        let code = errno
        let reason = POSIXErrorCode(rawValue: code).map { POSIXError($0).localizedDescription } ?? "errno \(code)"
        return .failed("\(action): \(reason)")
    }

    /// Runs a system tool; its output becomes part of the error on failure.
    @discardableResult
    private static func run(_ tool: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read to the end before waiting, so large output cannot block.
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateInstallError.failed("\(URL(fileURLWithPath: tool).lastPathComponent): \(output)")
        }
        return output
    }
}
