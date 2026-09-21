import CryptoKit
import Foundation

public struct SSHHostKey: Equatable, Hashable, Sendable {
    public var type: String
    public var keyData: String
    public var fingerprint: String
    /// The line as stored in the pinned `known_hosts` file.
    public var line: String

    /// `host`, or `[host]:port` for other ports, as written by ssh-keyscan.
    public var hostPattern: String {
        String(line.split(separator: " ", maxSplits: 1).first ?? "")
    }

    public var displayType: String {
        switch type {
        case "ssh-ed25519": "ED25519"
        case "ssh-rsa": "RSA"
        case let value where value.hasPrefix("ecdsa-"): "ECDSA"
        default: type
        }
    }

    /// OpenSSH prefers ED25519, then ECDSA, then RSA host keys.
    var preference: Int {
        switch type {
        case "ssh-ed25519": 0
        case let value where value.hasPrefix("ecdsa-"): 1
        case "ssh-rsa": 2
        default: 3
        }
    }
}

public struct SSHHostIdentity: Equatable, Sendable {
    public var host: String
    /// All host keys the server offered, most preferred first.
    public var keys: [SSHHostKey]

    public init(host: String, keys: [SSHHostKey]) {
        self.host = host
        self.keys = keys.sorted { $0.preference < $1.preference }
    }

    public var primary: SSHHostKey? { keys.first }
    public var fingerprint: String { primary?.fingerprint ?? "" }
    public var keyType: String { primary?.displayType ?? "" }
}

public enum SSHHostKeyStatus: Equatable, Sendable {
    case unknown(SSHHostIdentity)
    case trusted(SSHHostIdentity)
    case changed(saved: [SSHHostKey], received: SSHHostIdentity)
}

public enum KnownHosts {
    /// How ssh names a host in `known_hosts`.
    public static func pattern(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    /// Parses lines in `known_hosts` format, as printed by `ssh-keyscan`.
    public static func parse(_ text: String) -> [SSHHostKey] {
        text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3, let blob = Data(base64Encoded: String(fields[2])) else { return nil }
            return SSHHostKey(
                type: String(fields[1]),
                keyData: String(fields[2]),
                fingerprint: SSHKeyInspector.fingerprint(ofPublicBlob: blob),
                line: trimmed
            )
        }
    }

    /// The server is trusted when every key type it shares with the saved
    /// keys matches exactly. A different key of a saved type, or no common
    /// type at all, means the identity changed.
    public static func matches(saved: [SSHHostKey], received: [SSHHostKey]) -> Bool {
        let savedByType = Dictionary(saved.map { ($0.type, $0.keyData) }, uniquingKeysWith: { first, _ in first })
        var overlap = 0
        for key in received {
            guard let savedData = savedByType[key.type] else { continue }
            guard savedData == key.keyData else { return false }
            overlap += 1
        }
        return overlap > 0
    }
}

public enum SSHError: LocalizedError, Equatable {
    case invalidServer
    case hostNotTrusted
    case hostKeyChanged
    case missingPassword
    case authenticationFailed(methods: String)
    case keyNotFound(String)
    case keyPermissionsTooOpen(String)
    case connectionRefused
    case hostNotFound
    case hostUnreachable(String)
    case connectionClosed
    case timedOut
    case commandFailed(String)
    case noHostKey

    public var errorDescription: String? {
        switch self {
        case .invalidServer:
            NSLocalizedString("The SSH server configuration is invalid.", comment: "SSH validation error")
        case .hostNotTrusted:
            NSLocalizedString(
                "Verify and trust this server's host key before connecting.",
                comment: "SSH trust error"
            )
        case .hostKeyChanged:
            NSLocalizedString("The SSH host key changed. The connection was blocked.", comment: "SSH security error")
        case .missingPassword:
            NSLocalizedString("No SSH password is saved for this server.", comment: "SSH authentication error")
        case let .authenticationFailed(methods):
            methods.isEmpty
                ? NSLocalizedString("The server rejected the login.", comment: "SSH authentication error")
                : String(
                    format: NSLocalizedString(
                        "The server rejected the login. It accepts: %@.",
                        comment: "SSH authentication error with accepted methods"
                    ),
                    methods
                )
        case let .keyNotFound(path):
            String(
                format: NSLocalizedString("The private key file %@ was not found.", comment: "SSH key error"),
                NSString(string: path).abbreviatingWithTildeInPath
            )
        case let .keyPermissionsTooOpen(path):
            String(
                format: NSLocalizedString(
                    "Other users can read %@, so SSH refuses to use it.",
                    comment: "SSH key permission error"
                ),
                NSString(string: path).abbreviatingWithTildeInPath
            )
        case .connectionRefused:
            NSLocalizedString(
                "The server refused the connection. Check the SSH port.",
                comment: "SSH connection error"
            )
        case .hostNotFound:
            NSLocalizedString("The host name could not be found.", comment: "SSH connection error")
        case let .hostUnreachable(detail):
            String(
                format: NSLocalizedString("The server could not be reached: %@", comment: "SSH connection error"),
                detail
            )
        case .connectionClosed:
            NSLocalizedString(
                "The server closed the connection. It may be temporarily blocking this Mac after failed logins.",
                comment: "SSH connection error"
            )
        case .timedOut:
            NSLocalizedString("SSH operation timed out.", comment: "SSH timeout error")
        case let .commandFailed(message):
            message.isEmpty
                ? NSLocalizedString("The SSH command failed.", comment: "SSH command error")
                : message
        case .noHostKey:
            NSLocalizedString("The server did not provide an SSH host key.", comment: "SSH scan error")
        }
    }

    /// Errors that retrying cannot fix. Retrying failed logins can also get
    /// this Mac blocked by the server, so monitoring pauses on these.
    public var needsUserAction: Bool {
        switch self {
        case .invalidServer, .hostNotTrusted, .hostKeyChanged, .missingPassword, .authenticationFailed,
             .keyNotFound, .keyPermissionsTooOpen, .hostNotFound:
            true
        case .connectionRefused, .hostUnreachable, .connectionClosed, .timedOut, .commandFailed, .noHostKey:
            false
        }
    }

    /// The network connection broke, as opposed to a login or command error.
    public var isConnectionLoss: Bool {
        switch self {
        case .timedOut, .connectionClosed, .hostUnreachable: true
        default: false
        }
    }

    /// Maps the output of a failed `ssh` run (exit status 255) to an error.
    public static func classify(stderr: String) -> SSHError {
        let lines = stderr
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("@") }
        let text = lines.joined(separator: "\n")

        if text.contains("Host key verification failed") {
            if text.contains("host key is known for") { return .hostNotTrusted }
            return .hostKeyChanged
        }
        if let line = lines.first(where: { $0.contains("bad permissions") || $0.contains("are too open") }) {
            return .keyPermissionsTooOpen(quotedPath(in: line) ?? "")
        }
        if let line = lines.first(where: { $0.contains("Identity file") && $0.contains("not accessible") }) {
            let path = line
                .replacingOccurrences(of: "Warning: Identity file ", with: "")
                .components(separatedBy: " not accessible")[0]
            return .keyNotFound(path)
        }
        if let line = lines.first(where: { $0.contains("Permission denied (") }),
           let start = line.range(of: "Permission denied ("),
           let end = line.range(of: ")", range: start.upperBound..<line.endIndex) {
            let methods = line[start.upperBound..<end.lowerBound]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return .authenticationFailed(methods: methods.joined(separator: ", "))
        }
        if text.contains("Too many authentication failures") { return .authenticationFailed(methods: "") }
        if text.contains("Connection refused") { return .connectionRefused }
        if text.contains("Could not resolve hostname") || text.contains("nodename nor servname") {
            return .hostNotFound
        }
        for reason in ["Operation timed out", "Connection timed out", "No route to host", "Network is unreachable", "Host is down"]
        where text.contains(reason) {
            return .hostUnreachable(reason)
        }
        if text.contains("Connection closed by") || text.contains("Connection reset by")
            || text.contains("kex_exchange_identification") {
            return .connectionClosed
        }
        return .commandFailed(lines.suffix(3).joined(separator: "\n"))
    }

    private static func quotedPath(in line: String) -> String? {
        for quote in ["\"", "'"] {
            let parts = line.components(separatedBy: quote)
            if parts.count >= 3 { return parts[1] }
        }
        return nil
    }
}

/// Which Keychain items OpenSSH may ask for during one operation.
///
/// The server editor tests settings under a temporary server ID. It points
/// these at values typed but not saved yet, or at the saved server's items.
public struct SSHSecretSource: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        /// The server the Keychain item belongs to; nil means the server
        /// being connected.
        public var owner: UUID?
        public var kind: SecretKind

        public init(owner: UUID? = nil, kind: SecretKind) {
            self.owner = owner
            self.kind = kind
        }
    }

    public var password: Item
    public var passphrase: Item

    public init(
        password: Item = Item(kind: .sshPassword),
        passphrase: Item = Item(kind: .privateKeyPassphrase)
    ) {
        self.password = password
        self.passphrase = passphrase
    }

    public static let saved = SSHSecretSource()
}

public struct SSHConnectionReport: Equatable, Sendable {
    public var system: String
    public var operatingSystem: String
    public var duration: TimeInterval
}

/// Runs OpenSSH for BWMonitor.
///
/// - Host keys are pinned in a per-server `known_hosts` file and checked by
///   ssh itself (`StrictHostKeyChecking=yes`), so no extra scan is needed per
///   command.
/// - Monitoring reuses one authenticated connection per server through an SSH
///   control socket, instead of logging in again every few seconds.
/// - Saved passwords and key passphrases reach ssh only through
///   ``SSHAskpass``.
public final class SSHManager: @unchecked Sendable {
    /// How ssh reaches BWMonitor's askpass helper; see ``SSHAskpass``.
    public struct Askpass: Sendable {
        public var helperPath: String
        public var socketPath: String

        public init(helperPath: String, socketPath: String) {
            self.helperPath = helperPath
            self.socketPath = socketPath
        }
    }

    public let knownHostsDirectory: URL
    public let controlDirectory: URL
    private let keychain: KeychainStore
    private let askpass: Askpass?

    public init(
        knownHostsDirectory: URL? = nil,
        controlDirectory: URL? = nil,
        keychain: KeychainStore = KeychainStore(),
        askpass: Askpass? = nil
    ) {
        self.knownHostsDirectory = knownHostsDirectory
            ?? AppEnvironment.supportDirectory.appendingPathComponent("KnownHosts", isDirectory: true)
        self.controlDirectory = controlDirectory ?? AppEnvironment.controlSocketDirectory
        self.keychain = keychain
        self.askpass = askpass
    }

    // MARK: Host keys

    public func knownHostsFile(for server: Server) -> URL {
        knownHostsDirectory.appendingPathComponent("\(server.id.uuidString).known_hosts")
    }

    public func savedHostKeys(for server: Server) -> [SSHHostKey] {
        guard let text = try? String(contentsOf: knownHostsFile(for: server), encoding: .utf8) else { return [] }
        return KnownHosts.parse(text)
    }

    /// Whether a host key is pinned for the server's current host and port.
    /// Needs no network access.
    public func isTrusted(_ server: Server) -> Bool {
        let pattern = KnownHosts.pattern(host: server.host, port: server.port)
        return savedHostKeys(for: server).contains { $0.hostPattern == pattern }
    }

    /// Replaces the pinned keys of `target` with those of `source` (or
    /// removes them when `source` has none).
    public func copyHostKeys(from source: Server, to target: Server) throws {
        let sourceFile = knownHostsFile(for: source)
        let targetFile = knownHostsFile(for: target)
        guard sourceFile != targetFile else { return }
        try? FileManager.default.removeItem(at: targetFile)
        if FileManager.default.fileExists(atPath: sourceFile.path) {
            try AppEnvironment.makePrivateDirectory(knownHostsDirectory)
            try FileManager.default.copyItem(at: sourceFile, to: targetFile)
        }
    }

    public func scanHostKeys(for server: Server) async throws -> SSHHostIdentity {
        try validate(server)
        let output = try await runTool(
            "/usr/bin/ssh-keyscan",
            arguments: ["-T", "8", "-p", String(server.port), "-t", "ed25519,ecdsa,rsa", "--", server.host],
            timeout: 30
        )
        let keys = KnownHosts.parse(output.stdout)
        guard !keys.isEmpty else { throw await diagnoseUnreachable(server) }
        return SSHHostIdentity(host: server.host, keys: keys)
    }

    /// `ssh-keyscan` reports failures poorly, so ask ssh itself why the
    /// server cannot be reached.
    private func diagnoseUnreachable(_ server: Server) async -> SSHError {
        let arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ControlPath=none",
            "-p", String(server.port),
            "-l", server.username,
            "-T", "--", server.host, "true"
        ]
        guard let output = try? await runTool("/usr/bin/ssh", arguments: arguments, timeout: 20) else {
            return .timedOut
        }
        let error = SSHError.classify(stderr: output.stderr)
        // Reaching host key verification means the server answered.
        return error == .hostNotTrusted ? .noHostKey : error
    }

    public func hostKeyStatus(for server: Server) async throws -> SSHHostKeyStatus {
        let received = try await scanHostKeys(for: server)
        // Keys pinned for another address (the host or port was edited) say
        // nothing about this one.
        let pattern = KnownHosts.pattern(host: server.host, port: server.port)
        let saved = savedHostKeys(for: server).filter { $0.hostPattern == pattern }
        guard !saved.isEmpty else { return .unknown(received) }
        return KnownHosts.matches(saved: saved, received: received.keys)
            ? .trusted(received)
            : .changed(saved: saved, received: received)
    }

    public func trust(_ identity: SSHHostIdentity, for server: Server) throws {
        try AppEnvironment.makePrivateDirectory(knownHostsDirectory)
        let text = identity.keys.map(\.line).joined(separator: "\n") + "\n"
        try text.write(to: knownHostsFile(for: server), atomically: true, encoding: .utf8)
        closeSharedConnection(for: server)
    }

    public func forgetHostKey(for server: Server) {
        closeSharedConnection(for: server)
        try? FileManager.default.removeItem(at: knownHostsFile(for: server))
    }

    // MARK: Commands

    /// Runs a shell script on the server over the shared connection. The
    /// script is sent on standard input to `sh`, so it works whatever the
    /// login shell is and needs no quoting.
    public func execute(_ script: String, on server: Server, timeout: TimeInterval = 20) async throws -> String {
        let invocation = try makeInvocation(for: server, channel: .shared, remoteCommand: ["sh", "-s"])
        do {
            return try await run(invocation, input: script, timeout: timeout)
        } catch let error as SSHError where error.isConnectionLoss {
            // A stale shared connection keeps failing; start fresh next time.
            closeSharedConnection(for: server)
            throw error
        }
    }

    /// Logs in on a new connection, so the saved credentials are really used.
    public func testConnection(
        _ server: Server,
        secrets: SSHSecretSource = .saved
    ) async throws -> SSHConnectionReport {
        let started = Date.now
        let invocation = try makeInvocation(
            for: server,
            channel: .isolated,
            secrets: secrets,
            remoteCommand: ["sh", "-s"]
        )
        let script = """
        echo BWMONITOR_OK
        uname -srm 2>/dev/null || echo
        ( if [ -r /etc/os-release ]; then . /etc/os-release; fi; printf '%s\\n' "${PRETTY_NAME:-}" )
        """
        let output = try await run(invocation, input: script, timeout: 30)
        let lines = output.components(separatedBy: .newlines)
        guard let marker = lines.firstIndex(of: "BWMONITOR_OK") else {
            throw SSHError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let rest = Array(lines[(marker + 1)...])
        return SSHConnectionReport(
            system: rest.first ?? "",
            operatingSystem: rest.dropFirst().first ?? "",
            duration: Date.now.timeIntervalSince(started)
        )
    }

    /// Adds `publicKey` to `~/.ssh/authorized_keys` on the server, logging in
    /// once with the password. Existing keys are kept, and a key that is
    /// already present is not added twice.
    public func installPublicKey(
        _ publicKey: String,
        on server: Server,
        password: SSHSecretSource.Item
    ) async throws {
        guard let parsed = SSHKeyInspector.parsePublicKeyLine(publicKey) else {
            throw SSHKeyError.publicKeyUnavailable
        }
        let safeComment = String(parsed.comment.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "@._-".contains($0)) })
        let line = SSHKeyInspector.authorizedKeysLine(algorithm: parsed.algorithm, blob: parsed.blob, comment: safeComment)
        let keyData = parsed.blob.base64EncodedString()

        var passwordServer = server
        passwordServer.authentication = .password
        let invocation = try makeInvocation(
            for: passwordServer,
            channel: .isolated,
            secrets: SSHSecretSource(password: password),
            remoteCommand: ["sh", "-s"]
        )
        let output = try await run(invocation, input: Self.installScript(line: line, keyData: keyData), timeout: 45)
        guard output.contains("BWMONITOR_KEY_INSTALLED") else {
            throw SSHError.commandFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Appends a key to `~/.ssh/authorized_keys` unless it is already there.
    /// `line` and `keyData` contain only base64 and safe comment characters,
    /// so single quotes cannot break out.
    static func installScript(line: String, keyData: String) -> String {
        """
        set -e
        umask 077
        dir="$HOME/.ssh"
        file="$dir/authorized_keys"
        mkdir -p "$dir"
        touch "$file"
        if ! grep -qF '\(keyData)' "$file"; then
          if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then echo >> "$file"; fi
          printf '%s\\n' '\(line)' >> "$file"
        fi
        chmod 700 "$dir"
        chmod 600 "$file"
        if command -v restorecon >/dev/null 2>&1; then restorecon -R "$dir" >/dev/null 2>&1 || true; fi
        echo BWMONITOR_KEY_INSTALLED
        """
    }

    /// Checks a key passphrase locally with `ssh-keygen`, without contacting
    /// the server.
    public func verifyPassphrase(forKeyAt path: String, passphrase: (owner: UUID, kind: SecretKind)) async throws {
        var environment: [String: String] = [:]
        if let askpass {
            environment = SSHAskpass.environment(
                helperPath: askpass.helperPath,
                socketPath: askpass.socketPath,
                password: nil,
                passphrase: (passphrase.owner, passphrase.kind)
            )
        }
        let output = try await runTool(
            "/usr/bin/ssh-keygen",
            arguments: ["-y", "-f", NSString(string: path).expandingTildeInPath],
            environment: environment,
            timeout: 20
        )
        guard output.status == 0 else {
            if output.stderr.contains("incorrect passphrase") || output.stderr.contains("passphrase") {
                throw SSHKeyError.incorrectPassphrase
            }
            throw SSHError.commandFailed(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: Interactive sessions

    public struct Invocation: Sendable {
        public var arguments: [String]
        public var environment: [String: String]
    }

    /// Arguments for an interactive shell in BWMonitor's terminal. Saved
    /// secrets are supplied by askpass; without one, ssh prompts in the
    /// terminal as usual.
    public func terminalInvocation(for server: Server) throws -> Invocation {
        try makeInvocation(for: server, channel: .shared, interactive: true, remoteCommand: [])
    }

    /// A command line for Terminal.app. It reuses BWMonitor's connection when
    /// one is open; otherwise ssh asks for any password in Terminal.
    public func externalTerminalCommand(for server: Server) throws -> [String] {
        var invocation = try makeInvocation(for: server, channel: .shared, interactive: true, remoteCommand: [])
        invocation.environment = [:]
        return ["/usr/bin/ssh"] + invocation.arguments
    }

    /// A `.command` script for Terminal.app that deletes itself and runs ssh.
    public func externalTerminalScript(for server: Server) throws -> String {
        let command = try externalTerminalCommand(for: server)
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        return "#!/bin/sh\nrm -f \"$0\"\nclear\nexec \(command)\n"
    }

    /// Removes pinned keys that belong to no server, such as those of an
    /// editor that was closed by quitting the app.
    public func removeUnusedHostKeys(keeping servers: [Server]) {
        let ids = Set(servers.map(\.id.uuidString))
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: knownHostsDirectory.path) else { return }
        for file in files where file.hasSuffix(".known_hosts") && !ids.contains(String(file.dropLast(".known_hosts".count))) {
            try? FileManager.default.removeItem(at: knownHostsDirectory.appendingPathComponent(file))
        }
    }

    /// Ends the shared connection, for example after the server settings changed.
    public func closeSharedConnection(for server: Server) {
        let path = controlPath(for: server)
        guard FileManager.default.fileExists(atPath: path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "ControlPath=\(Self.quoted(path))", "-O", "exit", "--", server.host]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Ends every shared connection BWMonitor opened.
    public func closeAllSharedConnections(for servers: [Server]) {
        servers.forEach(closeSharedConnection(for:))
    }

    // MARK: Building ssh command lines

    enum Channel {
        /// Reuses one authenticated connection per server.
        case shared
        /// Always opens a new connection.
        case isolated
    }

    func makeInvocation(
        for server: Server,
        channel: Channel,
        interactive: Bool = false,
        secrets: SSHSecretSource = .saved,
        remoteCommand: [String]
    ) throws -> Invocation {
        try validate(server)
        guard isTrusted(server) else { throw SSHError.hostNotTrusted }

        var arguments = [
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=yes",
            // ssh splits this option at spaces ("Application Support"),
            // so the path must be quoted.
            "-o", "UserKnownHostsFile=\(Self.quoted(knownHostsFile(for: server).path))",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "UpdateHostKeys=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "PermitLocalCommand=no",
            "-p", String(server.port),
            "-l", server.username
        ]

        var passwordItem: (UUID, SecretKind)?
        var passphraseItem: (UUID, SecretKind)?
        switch server.authentication {
        case .key:
            arguments += [
                "-o", "PreferredAuthentications=publickey",
                "-o", "PasswordAuthentication=no",
                "-o", "KbdInteractiveAuthentication=no"
            ]
            let keyPath = server.privateKeyPath.trimmingCharacters(in: .whitespaces)
            if !keyPath.isEmpty {
                arguments += ["-o", "IdentitiesOnly=yes", "-i", NSString(string: keyPath).expandingTildeInPath]
            }
            let passphrase = (secrets.passphrase.owner ?? server.id, secrets.passphrase.kind)
            if keychain.contains(passphrase.0, kind: passphrase.1) {
                passphraseItem = passphrase
            }
        case .password:
            arguments += [
                "-o", "PreferredAuthentications=keyboard-interactive,password",
                "-o", "PubkeyAuthentication=no"
            ]
            let password = (secrets.password.owner ?? server.id, secrets.password.kind)
            if keychain.contains(password.0, kind: password.1) {
                passwordItem = password
            } else if !interactive {
                // Without a password ssh would try an empty one, which counts
                // as a failed login on the server.
                throw SSHError.missingPassword
            }
        }

        var environment: [String: String] = [:]
        if let askpass, passwordItem != nil || passphraseItem != nil {
            environment = SSHAskpass.environment(
                helperPath: askpass.helperPath,
                socketPath: askpass.socketPath,
                password: passwordItem,
                passphrase: passphraseItem
            )
            arguments += ["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=1"]
        } else {
            arguments += ["-o", "BatchMode=\(interactive ? "no" : "yes")"]
        }

        switch channel {
        case .shared:
            arguments += [
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=\(Self.quoted(controlPath(for: server)))",
                "-o", "ControlPersist=120"
            ]
        case .isolated:
            arguments += ["-o", "ControlMaster=no", "-o", "ControlPath=none"]
        }

        arguments.append(interactive ? "-tt" : "-T")
        arguments += ["--", server.host]
        arguments += remoteCommand
        return Invocation(arguments: arguments, environment: environment)
    }

    /// Control socket for the shared connection. The name covers every
    /// setting that affects the login, so an edited server gets a new
    /// connection instead of silently reusing the old one.
    func controlPath(for server: Server) -> String {
        let identity = [
            server.id.uuidString, server.host, String(server.port), server.username,
            server.authentication.rawValue, server.privateKeyPath
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(identity.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return controlDirectory.appendingPathComponent(name).path
    }

    /// Quotes a path for an ssh `-o` option value.
    static func quoted(_ path: String) -> String {
        "\"" + path + "\""
    }

    public func validate(_ server: Server) throws {
        guard server.isValid,
              Server.isValidHost(server.host),
              Server.isValidUsername(server.username) else {
            throw SSHError.invalidServer
        }
    }

    private func run(_ invocation: Invocation, input: String, timeout: TimeInterval) async throws -> String {
        if invocation.arguments.contains(where: { $0.hasPrefix("ControlPath=") && $0 != "ControlPath=none" }) {
            try AppEnvironment.makePrivateDirectory(controlDirectory)
        }
        let output = try await runTool(
            "/usr/bin/ssh",
            arguments: invocation.arguments,
            environment: invocation.environment,
            input: Data(input.utf8),
            timeout: timeout
        )
        switch output.status {
        case 0:
            return output.stdout
        case 255:
            throw SSHError.classify(stderr: output.stderr)
        default:
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHError.commandFailed(message.isEmpty ? output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : message)
        }
    }

    private func runTool(
        _ executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        input: Data? = nil,
        timeout: TimeInterval
    ) async throws -> ProcessOutput {
        do {
            return try await ProcessRunner.run(
                executable,
                arguments: arguments,
                environment: environment,
                input: input,
                timeout: timeout
            )
        } catch ProcessRunnerError.timedOut {
            throw SSHError.timedOut
        }
    }
}
