import AppKit
import Combine
import Foundation

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case available(ReleaseInfo)
    case downloading(ReleaseInfo)
    case installing(ReleaseInfo)

    /// The newer release, while one is offered or being installed.
    var release: ReleaseInfo? {
        switch self {
        case let .available(release), let .downloading(release), let .installing(release): release
        case .idle, .checking, .upToDate: nil
        }
    }

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing: true
        case .idle, .upToDate, .available: false
        }
    }
}

/// Checks GitHub Releases, then downloads the new version, replaces this copy
/// of BWMonitor, and reopens it.
@MainActor
final class SoftwareUpdater: ObservableObject {
    @Published private(set) var status = UpdateStatus.idle
    /// Why the last manual check or update did not work.
    @Published private(set) var message: String?
    /// The version whose reminder the user closed; Settings still offers it.
    @Published private(set) var dismissedVersion: String?
    @Published var automaticChecks: Bool {
        didSet {
            UserDefaults.standard.set(automaticChecks, forKey: Keys.automaticChecks)
            scheduleChecks()
        }
    }

    /// When false (in the debug run), a failed install is only reported
    /// instead of opening the installer in Finder.
    private let opensInstallerOnFailure: Bool
    private var checkTask: Task<Void, Never>?

    private enum Keys {
        static let automaticChecks = "automaticUpdateChecks"
        static let lastCheck = "lastUpdateCheck"
    }

    init(opensInstallerOnFailure: Bool = true) {
        self.opensInstallerOnFailure = opensInstallerOnFailure
        automaticChecks = UserDefaults.standard.object(forKey: Keys.automaticChecks) as? Bool ?? true
    }

    var currentVersion: String { AppUpdate.currentVersion }

    /// The release to remind the user about outside Settings.
    var reminder: ReleaseInfo? {
        guard let release = status.release, release.version != dismissedVersion else { return nil }
        return release
    }

    func dismissReminder() {
        dismissedVersion = status.release?.version
    }

    /// Checks shortly after launch, then whenever a day has passed since the
    /// last check. Nothing is shown unless an update is found.
    func scheduleChecks() {
        checkTask?.cancel()
        checkTask = nil
        guard automaticChecks else { return }
        checkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                guard let self else { return }
                let last = UserDefaults.standard.double(forKey: Keys.lastCheck)
                if Date.now.timeIntervalSince1970 - last >= 24 * 3_600 {
                    await check(userInitiated: false)
                }
                try? await Task.sleep(for: .seconds(3_600), tolerance: .seconds(300))
            }
        }
    }

    func check(userInitiated: Bool) async {
        guard !status.isBusy else { return }
        let previous = status
        status = .checking
        message = nil
        do {
            let release = try await AppUpdateChecker().latestRelease().info
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Keys.lastCheck)
            if AppUpdate.isNewer(latest: release.version, than: currentVersion) {
                if userInitiated { dismissedVersion = nil }
                status = .available(release)
            } else {
                status = .upToDate
            }
        } catch {
            status = previous
            // Failed automatic checks (for example while offline) stay quiet
            // and are retried an hour later.
            if userInitiated {
                message = String(
                    format: NSLocalizedString("Update check failed: %@", comment: "Update status"),
                    error.localizedDescription
                )
            }
        }
    }

    /// "Check for Updates…" in the app menu answers in a dialog.
    func checkFromMenu() async {
        await check(userInitiated: true)
        NSApp.activate()
        let alert = NSAlert()
        switch status {
        case let .available(release):
            alert.messageText = String(
                format: NSLocalizedString("BWMonitor %@ is available", comment: "Update alert"),
                release.version
            )
            alert.informativeText = String(
                format: NSLocalizedString(
                    "You have version %@. BWMonitor downloads the new version, replaces itself, and reopens.",
                    comment: "Update alert"
                ),
                currentVersion
            )
            alert.addButton(withTitle: NSLocalizedString("Update Now", comment: "Update button"))
            alert.addButton(withTitle: NSLocalizedString("Later", comment: "Update button"))
            alert.addButton(withTitle: NSLocalizedString("Release Notes", comment: "Update button"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: await perform(release)
            case .alertThirdButtonReturn: NSWorkspace.shared.open(release.pageURL)
            default: break
            }
        case .upToDate:
            alert.messageText = NSLocalizedString("BWMonitor is up to date", comment: "Update alert")
            alert.informativeText = String(
                format: NSLocalizedString("Version %@ is the newest version.", comment: "Update alert"),
                currentVersion
            )
            alert.runModal()
        default:
            guard let message else { return }
            alert.alertStyle = .warning
            alert.messageText = message
            alert.runModal()
        }
    }

    func install() {
        guard case let .available(release) = status else { return }
        Task { await perform(release) }
    }

    /// Downloads, checks, and installs `release`. On success BWMonitor quits
    /// and reopens, so this does not return. When this copy cannot be
    /// replaced, the installer opens so the user can drag it to Applications.
    func perform(_ release: ReleaseInfo) async {
        guard release.dmgURL != nil else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        status = .downloading(release)
        message = nil
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("BWMonitor-Update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let dmg: URL
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            dmg = try await AppUpdateChecker().download(release, to: work)
        } catch {
            status = .available(release)
            message = String(
                format: NSLocalizedString("Download failed: %@", comment: "Update error"),
                error.localizedDescription
            )
            return
        }

        let app: URL
        do {
            app = try UpdateInstaller.replaceableApp()
            status = .installing(release)
            try await UpdateInstaller.install(dmg, version: release.version, replacing: app)
        } catch {
            status = .available(release)
            installManually(dmg, because: error)
            return
        }

        // Clean up now; the deferred removal does not run once the app quits.
        try? FileManager.default.removeItem(at: work)
        do {
            try relaunch(app)
        } catch {
            status = .idle
            message = String(
                format: NSLocalizedString(
                    "BWMonitor %@ is installed. Quit and reopen BWMonitor to use it.",
                    comment: "Update status"
                ),
                release.version
            )
        }
    }

    /// Fallback: move the installer to Downloads and open it.
    private func installManually(_ dmg: URL, because error: Error) {
        let reason = String(
            format: NSLocalizedString("BWMonitor could not update itself: %@", comment: "Update error"),
            error.localizedDescription
        )
        // Opening from the temporary folder is pointless: it is deleted next.
        guard opensInstallerOnFailure, let file = try? AppUpdate.moveToDownloads(dmg) else {
            message = reason
            return
        }
        message = reason + " " + NSLocalizedString(
            "The installer is open: quit BWMonitor, then drag it into Applications to replace the old copy. Later updates can then install automatically.",
            comment: "Update error"
        )
        NSWorkspace.shared.open(file)
    }

    /// Waits for this process to exit, opens `app` (now the new version),
    /// and quits.
    private func relaunch(_ app: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits at most 20 seconds. The path is passed as $0, so it needs no
        // quoting.
        process.arguments = ["-c", """
            i=0; while /bin/kill -0 \(pid) 2>/dev/null && [ $i -lt 100 ]; do /bin/sleep 0.2; i=$((i+1)); done
            /usr/bin/open "$0"
            """, app.path]
        try process.run()
        NSApp.terminate(nil)
    }

    /// `--debug-self-update`: checks and installs without showing any
    /// window, printing what happened. Used to test updates end to end
    /// against a local `BWMONITOR_UPDATE_API`.
    static func runDebugSelfUpdate() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let updater = SoftwareUpdater(opensInstallerOnFailure: false)
            await updater.check(userInitiated: true)
            if let release = updater.status.release {
                print("installing \(release.version) over \(Bundle.main.bundlePath)")
                fflush(stdout)
                await updater.perform(release)
            }
            // Reaching this point means there was no update, or it failed.
            print("status: \(updater.status)")
            print("message: \(updater.message ?? "none")")
            fflush(stdout)
            exit(0)
        }
        app.run()
        exit(0)
    }
}
