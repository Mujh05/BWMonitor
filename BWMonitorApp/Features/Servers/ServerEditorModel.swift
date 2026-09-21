import AppKit
import Combine
import Foundation

/// State and actions of the server editor.
///
/// Everything the editor does live (checking the host key, testing the
/// connection, installing a key) runs against a temporary copy of the server
/// with its own ID. The saved server, its pinned host key and its Keychain
/// items change only when the user clicks Save.
@MainActor
final class ServerEditorModel: ObservableObject {
    enum HostKeyState: Equatable {
        case notChecked
        case checking
        case trusted([SSHHostKey])
        case awaitingTrust(SSHHostIdentity)
        case changed(saved: [SSHHostKey], received: SSHHostIdentity)
        case failed(String)
    }

    enum TestState: Equatable {
        case idle
        case running(String)
        case succeeded(String)
        case failed(String, EditorAction?)
    }

    /// Follow-up actions offered next to an error.
    enum EditorAction: Equatable {
        case checkHostKey
        case installKey
        case fixPermissions
        case chooseKey
    }

    @Published var draft: Server {
        didSet { draftChanged(from: oldValue) }
    }
    @Published var apiKey = ""
    @Published var password = ""
    @Published var passphrase = ""
    @Published private(set) var hostKey: HostKeyState = .notChecked
    @Published private(set) var test: TestState = .idle
    @Published private(set) var keyInfo: SSHKeyInfo?
    @Published private(set) var keyProblem: String?
    @Published private(set) var keyHasLoosePermissions = false
    @Published private(set) var discoveredKeys: [SSHKeyInfo] = []
    @Published private(set) var appKey: SSHKeyInfo?
    @Published private(set) var isWorking = false
    @Published var saveError: String?

    let original: Server?
    let hasSavedPassword: Bool
    let hasSavedPassphrase: Bool
    let hasSavedAPIKey: Bool

    private let state: AppState
    private let probeID = UUID()
    private var ssh: SSHManager { state.ssh }
    private var keychain: KeychainStore { state.keychain }

    init(server: Server?, state: AppState) {
        self.state = state
        original = server
        hasSavedPassword = server.map { state.keychain.contains($0.id, kind: .sshPassword) } ?? false
        hasSavedPassphrase = server.map { state.keychain.contains($0.id, kind: .privateKeyPassphrase) } ?? false
        hasSavedAPIKey = server.map { state.keychain.contains($0.id, kind: .kiwiAPIKey) } ?? false
        let appKey = state.keyStore.appKey()
        let discovered = SSHKeyInspector.discoverKeys()

        var initial = server ?? Server(name: "", host: "")
        if server == nil {
            // Prefer a key that is probably installed already; otherwise
            // BWMonitor's own key, created when first needed.
            initial.privateKeyPath = appKey?.path ?? discovered.first?.path ?? state.keyStore.appKeyPath
        }
        draft = initial
        self.appKey = appKey
        discoveredKeys = discovered

        if let server {
            var probe = server
            probe.id = probeID
            try? ssh.copyHostKeys(from: server, to: probe)
        }
        refreshHostKeyState()
        inspectKey()
    }

    // MARK: Derived state

    var isNew: Bool { original == nil }

    /// The draft as used for live checks.
    var probe: Server {
        var server = draft.normalized
        server.id = probeID
        return server
    }

    var canConnect: Bool {
        let server = draft.normalized
        return Server.isValidHost(server.host) && Server.isValidUsername(server.username) && (1...65_535).contains(server.port)
    }

    var isHostTrusted: Bool {
        if case .trusted = hostKey { return true }
        return false
    }

    var isUsingAgent: Bool {
        draft.privateKeyPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var isUsingAppKey: Bool {
        draft.privateKeyPath == state.keyStore.appKeyPath
    }

    var appKeyMissing: Bool {
        isUsingAppKey && appKey == nil
    }

    var validationMessage: String? {
        let server = draft.normalized
        if server.name.isEmpty { return NSLocalizedString("Enter a display name.", comment: "Server form validation") }
        if !Server.isValidHost(server.host) {
            return NSLocalizedString("Enter a valid host name or IP address.", comment: "Server form validation")
        }
        if !(1...65_535).contains(server.port) {
            return NSLocalizedString("Enter a port between 1 and 65535.", comment: "Server form validation")
        }
        if !Server.isValidUsername(server.username) {
            return NSLocalizedString("Enter a valid user name.", comment: "Server form validation")
        }
        return nil
    }

    // MARK: Host key

    func checkHostKey() async {
        guard canConnect else { return }
        hostKey = .checking
        do {
            switch try await ssh.hostKeyStatus(for: probe) {
            case let .unknown(identity):
                hostKey = .awaitingTrust(identity)
            case let .trusted(identity):
                hostKey = .trusted(identity.keys)
            case let .changed(saved, received):
                hostKey = .changed(saved: saved, received: received)
            }
        } catch {
            hostKey = .failed(error.localizedDescription)
        }
    }

    func trust(_ identity: SSHHostIdentity) {
        do {
            try ssh.trust(identity, for: probe)
            hostKey = .trusted(identity.keys)
            if case .failed(_, .checkHostKey) = test { test = .idle }
        } catch {
            hostKey = .failed(error.localizedDescription)
        }
    }

    func forgetHostKey() {
        ssh.forgetHostKey(for: probe)
        hostKey = .notChecked
    }

    private func refreshHostKeyState() {
        let pinned = ssh.savedHostKeys(for: probe)
        hostKey = ssh.isTrusted(probe) ? .trusted(pinned) : .notChecked
    }

    // MARK: Keys

    func useKey(at path: String) {
        draft.privateKeyPath = path
    }

    func useAgent() {
        draft.privateKeyPath = ""
    }

    func useAppKey() async {
        draft.privateKeyPath = state.keyStore.appKeyPath
        if appKey == nil { await createAppKey() }
    }

    func createAppKey() async {
        isWorking = true
        defer { isWorking = false }
        do {
            appKey = try await state.keyStore.generateAppKey()
            draft.privateKeyPath = state.keyStore.appKeyPath
            inspectKey()
        } catch {
            keyProblem = error.localizedDescription
        }
    }

    func importPastedKey(_ text: String) throws {
        let info = try state.keyStore.importPrivateKey(text)
        draft.privateKeyPath = info.path
    }

    func fixKeyPermissions() {
        do {
            try SSHKeyInspector.restrictPermissions(path: draft.privateKeyPath)
            inspectKey()
            if case .failed(_, .fixPermissions) = test { test = .idle }
        } catch {
            keyProblem = error.localizedDescription
        }
    }

    func copyPublicKey() {
        guard let key = keyInfo?.publicKey else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
    }

    func revealKeyInFinder() {
        guard let path = keyInfo?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func inspectKey() {
        keyProblem = nil
        keyInfo = nil
        keyHasLoosePermissions = false
        let path = draft.privateKeyPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }
        if path == state.keyStore.appKeyPath, appKey == nil { return }
        do {
            keyInfo = try SSHKeyInspector.inspect(path: path)
            keyHasLoosePermissions = SSHKeyInspector.hasLoosePermissions(path: path)
            if keyInfo?.publicKey == nil {
                keyProblem = NSLocalizedString(
                    "The public key is unknown because there is no .pub file next to this key.",
                    comment: "SSH key warning"
                )
            }
        } catch {
            keyProblem = error.localizedDescription
        }
    }

    // MARK: Connection test and key installation

    func testConnection() async {
        guard canConnect else { return }
        if draft.authentication == .key, appKeyMissing { await createAppKey() }
        guard isHostTrusted else {
            test = .failed(SSHError.hostNotTrusted.localizedDescription, .checkHostKey)
            return
        }
        isWorking = true
        defer { isWorking = false }
        test = .running(NSLocalizedString("Signing in…", comment: "Connection test progress"))
        do {
            let report = try await withPendingSecrets { source in
                if let problem = try await self.passphraseProblem(source: source) { throw problem }
                return try await self.ssh.testConnection(self.probe, secrets: source)
            }
            test = .succeeded(Self.describe(report))
        } catch {
            test = failure(for: error)
        }
    }

    /// Adds the selected key to the server, then signs in with it to confirm.
    func installKey(password typedPassword: String) async -> Bool {
        if appKeyMissing { await createAppKey() }
        guard let publicKey = keyInfo?.publicKey else {
            test = .failed(SSHKeyError.publicKeyUnavailable.localizedDescription, nil)
            return false
        }
        isWorking = true
        defer { isWorking = false }
        test = .running(NSLocalizedString("Installing the public key…", comment: "Key installation progress"))
        do {
            try await withPendingSecrets(password: typedPassword) { source in
                try await self.ssh.installPublicKey(publicKey, on: self.probe, password: source.password)
            }
        } catch {
            test = failure(for: error, installing: true)
            return false
        }
        var keyServer = probe
        keyServer.authentication = .key
        test = .running(NSLocalizedString("Signing in with the key…", comment: "Connection test progress"))
        do {
            let report = try await withPendingSecrets { source in
                try await self.ssh.testConnection(keyServer, secrets: source)
            }
            draft.authentication = .key
            test = .succeeded(
                NSLocalizedString("The key is installed and works.", comment: "Key installation result")
                    + " " + Self.describe(report)
            )
            return true
        } catch {
            test = failure(for: error)
            return false
        }
    }

    /// Password mode: creates BWMonitor's key if needed, installs it with the
    /// password, and switches the server to key login.
    func setUpKeyLogin(password typedPassword: String) async -> Bool {
        let previousPath = draft.privateKeyPath
        if appKey == nil { await createAppKey() }
        guard appKey != nil else { return false }
        draft.privateKeyPath = state.keyStore.appKeyPath
        let installed = await installKey(password: typedPassword)
        if !installed { draft.privateKeyPath = previousPath }
        return installed
    }

    // MARK: Saving

    func save() async -> Bool {
        saveError = nil
        if let validationMessage {
            saveError = validationMessage
            return false
        }
        var server = draft.normalized
        if server.authentication == .key {
            if appKeyMissing { await createAppKey() }
            inspectKey()
            if !isUsingAgent, keyInfo == nil {
                saveError = keyProblem ?? SSHKeyError.notAPrivateKey.localizedDescription
                return false
            }
            if let keyInfo, keyInfo.isEncrypted {
                if passphrase.isEmpty, !hasSavedPassphrase, await !SSHKeyInspector.isLoadedInAgent(keyInfo) {
                    saveError = NSLocalizedString("This key is protected by a passphrase. Enter it.", comment: "Server form validation")
                    return false
                }
                if !passphrase.isEmpty {
                    do {
                        if let problem = try await withPendingSecrets(passphraseProblem) {
                            saveError = problem.localizedDescription
                            return false
                        }
                    } catch {
                        saveError = error.localizedDescription
                        return false
                    }
                }
            }
        }

        do {
            if server.provider == .bandwagonHost {
                if !apiKey.isEmpty { try keychain.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: server.id, kind: .kiwiAPIKey) }
            } else {
                try keychain.delete(server.id, kind: .kiwiAPIKey)
                server.veid = ""
            }
            // Keep only the secrets the chosen sign-in method needs.
            switch server.authentication {
            case .password:
                if !password.isEmpty { try keychain.save(password, for: server.id, kind: .sshPassword) }
                try keychain.delete(server.id, kind: .privateKeyPassphrase)
            case .key:
                try keychain.delete(server.id, kind: .sshPassword)
                if keyInfo?.isEncrypted == true {
                    if !passphrase.isEmpty { try keychain.save(passphrase, for: server.id, kind: .privateKeyPassphrase) }
                } else {
                    try keychain.delete(server.id, kind: .privateKeyPassphrase)
                }
            }
            try ssh.copyHostKeys(from: probe, to: server)
            try await state.commit(server, replacing: original)
            discard()
            return true
        } catch {
            saveError = String(
                format: NSLocalizedString("Could not save server: %@", comment: "Server save error"),
                error.localizedDescription
            )
            return false
        }
    }

    /// Removes everything the editor created for its live checks.
    func discard() {
        ssh.forgetHostKey(for: probe)
        try? keychain.delete(probeID, kind: .pendingPassword)
        try? keychain.delete(probeID, kind: .pendingPassphrase)
    }

    // MARK: Helpers

    private func draftChanged(from old: Server) {
        if old.host != draft.host || old.port != draft.port {
            refreshHostKeyState()
        }
        if old.privateKeyPath != draft.privateKeyPath {
            passphrase = ""
            inspectKey()
        }
        let connectionChanged = old.host != draft.host || old.port != draft.port || old.username != draft.username
            || old.authentication != draft.authentication || old.privateKeyPath != draft.privateKeyPath
        if connectionChanged, !isWorking { test = .idle }
    }

    /// Stores typed-but-unsaved secrets in the Keychain for the duration of
    /// `body`, so ssh can ask for them through askpass. Values left blank
    /// fall back to the ones saved for this server.
    private func withPendingSecrets<T>(
        password overridePassword: String? = nil,
        _ body: (SSHSecretSource) async throws -> T
    ) async throws -> T {
        var source = SSHSecretSource(
            password: .init(owner: draft.id, kind: .sshPassword),
            passphrase: .init(owner: draft.id, kind: .privateKeyPassphrase)
        )
        defer {
            try? keychain.delete(probeID, kind: .pendingPassword)
            try? keychain.delete(probeID, kind: .pendingPassphrase)
        }
        let typedPassword = overridePassword.flatMap { $0.isEmpty ? nil : $0 } ?? password
        if !typedPassword.isEmpty {
            try keychain.save(typedPassword, for: probeID, kind: .pendingPassword)
            source.password = .init(owner: probeID, kind: .pendingPassword)
        }
        if !passphrase.isEmpty {
            try keychain.save(passphrase, for: probeID, kind: .pendingPassphrase)
            source.passphrase = .init(owner: probeID, kind: .pendingPassphrase)
        }
        return try await body(source)
    }

    /// Checks the passphrase of an encrypted key locally, so a wrong
    /// passphrase is reported as such instead of as a rejected login.
    private func passphraseProblem(source: SSHSecretSource) async throws -> Error? {
        guard draft.authentication == .key, let keyInfo, keyInfo.isEncrypted else { return nil }
        guard keychain.contains(source.passphrase.owner ?? draft.id, kind: source.passphrase.kind) else {
            return nil // ssh may still find the key in the SSH agent
        }
        do {
            try await ssh.verifyPassphrase(
                forKeyAt: keyInfo.path,
                passphrase: (source.passphrase.owner ?? draft.id, source.passphrase.kind)
            )
            return nil
        } catch let error as SSHKeyError {
            return error
        }
    }

    private func failure(for error: Error, installing: Bool = false) -> TestState {
        guard let sshError = error as? SSHError else {
            return .failed(error.localizedDescription, nil)
        }
        let methods: String
        switch sshError {
        case .hostNotTrusted, .hostKeyChanged:
            return .failed(sshError.localizedDescription, .checkHostKey)
        case .keyPermissionsTooOpen:
            return .failed(sshError.localizedDescription, .fixPermissions)
        case .keyNotFound:
            return .failed(sshError.localizedDescription, .chooseKey)
        case .missingPassword:
            return .failed(NSLocalizedString("Enter the password for this server.", comment: "Connection test hint"), nil)
        case let .authenticationFailed(value):
            methods = value
        default:
            return .failed(sshError.localizedDescription, nil)
        }
        let acceptsPasswords = methods.isEmpty || methods.contains("password") || methods.contains("keyboard-interactive")
        if !installing, draft.authentication == .key, keyInfo?.isEncrypted == true, passphrase.isEmpty, !hasSavedPassphrase {
            // ssh could not unlock the key (it was not in the SSH agent either).
            return .failed(
                NSLocalizedString("This key is protected by a passphrase. Enter it.", comment: "Server form validation"),
                nil
            )
        }
        if installing || draft.authentication == .password {
            return acceptsPasswords
                ? .failed(NSLocalizedString("The password or user name is wrong.", comment: "Connection test hint"), nil)
                : .failed(
                    NSLocalizedString(
                        "This server does not accept passwords. Add the public key through your provider's web console instead.",
                        comment: "Connection test hint"
                    ),
                    nil
                )
        }
        return acceptsPasswords
            ? .failed(
                NSLocalizedString(
                    "The server did not accept this key. Install the public key on the server with its password.",
                    comment: "Connection test hint"
                ),
                .installKey
            )
            : .failed(
                NSLocalizedString(
                    "The server did not accept this key and does not allow passwords. Add the public key through your provider's web console, or choose a key that is already installed.",
                    comment: "Connection test hint"
                ),
                nil
            )
    }

    private static func describe(_ report: SSHConnectionReport) -> String {
        let system = report.operatingSystem.isEmpty ? report.system : report.operatingSystem
        return String(
            format: NSLocalizedString("Connected to %1$@ in %2$@ s.", comment: "Connection test result"),
            system.isEmpty ? "Linux" : system,
            report.duration.formatted(.number.precision(.fractionLength(1)))
        )
    }
}
