import Foundation
import Testing

@testable import BWMonitorCore

@Suite("SSH error classification")
struct SSHErrorTests {
    @Test("Host key problems")
    func hostKeys() {
        #expect(SSHError.classify(stderr: """
        No ED25519 host key is known for [127.0.0.1]:2222 and you have requested strict checking.
        Host key verification failed.
        """) == .hostNotTrusted)
        #expect(SSHError.classify(stderr: """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        Host key for [127.0.0.1]:2222 has changed and you have requested strict checking.
        Host key verification failed.
        """) == .hostKeyChanged)
    }

    @Test("Login problems pause monitoring")
    func logins() {
        let denied = SSHError.classify(stderr: "root@203.0.113.10: Permission denied (publickey,password).")
        #expect(denied == .authenticationFailed(methods: "publickey, password"))
        #expect(denied.needsUserAction)

        #expect(SSHError.classify(stderr: """
        Permissions 0644 for 'loosekey' are too open.
        It is required that your private key files are NOT accessible by others.
        This private key will be ignored.
        Load key "loosekey": bad permissions
        mujh@127.0.0.1: Permission denied (publickey).
        """) == .keyPermissionsTooOpen("loosekey"))

        #expect(SSHError.classify(stderr: """
        Warning: Identity file /nonexistent/key not accessible: No such file or directory.
        mujh@127.0.0.1: Permission denied (publickey).
        """) == .keyNotFound("/nonexistent/key"))
    }

    @Test("Network problems are retried")
    func network() {
        let refused = SSHError.classify(stderr: "ssh: connect to host 127.0.0.1 port 2299: Connection refused")
        #expect(refused == .connectionRefused)
        #expect(!refused.needsUserAction)
        #expect(SSHError.classify(
            stderr: "ssh: Could not resolve hostname nosuchhost.invalid: nodename nor servname provided, or not known"
        ) == .hostNotFound)
        #expect(SSHError.classify(
            stderr: "ssh: connect to host 10.255.255.1 port 22: Operation timed out"
        ) == .hostUnreachable("Operation timed out"))
        let reset = SSHError.classify(stderr: """
        kex_exchange_identification: read: Connection reset by peer
        Connection reset by 127.0.0.1 port 2222
        """)
        #expect(reset == .connectionClosed)
        #expect(reset.isConnectionLoss)
    }
}

@Suite("Pinned host keys")
struct KnownHostsTests {
    static let ed25519 = "[203.0.113.10]:27015 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINliH/woXD9l1QBxyFKmHHmLAmqLdYE6jqCK5mGhTTz8"
    static let rsa = "[203.0.113.10]:27015 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAAgQC263Wa+lV0h9ETkRZ0KKGEOx4QzbOu30nZ7qlO3pBbachqpm9NPIH0XH52MpGSwn2n9BhIkjE3aiBG8s1zPbrbCujTBIrlM2YqTRT5Vm9DkmkdxOgWugUqeuPKo/Jm7lmJB9DQze2WE/q7waCp2jgXjBYrPH8Lq8+HvXpe379fCQ=="
    static let otherEd25519 = "[203.0.113.10]:27015 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKGwfQUmnz2lHMmM2DF1XI1cuPKh4g4gwg6qayyL759a"

    @Test("Scan output order does not matter")
    func orderIndependent() {
        let saved = KnownHosts.parse("# 203.0.113.10:27015 SSH-2.0-OpenSSH_9.6\n\(Self.ed25519)\n\(Self.rsa)\n")
        let received = KnownHosts.parse("\(Self.rsa)\n\(Self.ed25519)\n")
        #expect(saved.count == 2)
        #expect(KnownHosts.matches(saved: saved, received: received))
        #expect(SSHHostIdentity(host: "h", keys: received).primary?.type == "ssh-ed25519")
    }

    @Test("A 1.0 file with a single key still matches")
    func singleSavedKey() {
        let saved = KnownHosts.parse(Self.rsa)
        #expect(KnownHosts.matches(saved: saved, received: KnownHosts.parse("\(Self.ed25519)\n\(Self.rsa)")))
    }

    @Test("A different key of a saved type is a change")
    func changedKey() {
        let saved = KnownHosts.parse("\(Self.ed25519)\n\(Self.rsa)")
        #expect(!KnownHosts.matches(saved: saved, received: KnownHosts.parse("\(Self.otherEd25519)\n\(Self.rsa)")))
        #expect(!KnownHosts.matches(saved: KnownHosts.parse(Self.rsa), received: KnownHosts.parse(Self.otherEd25519)))
    }
}

@Suite("Askpass")
struct AskpassTests {
    @Test("OpenSSH prompts are recognized")
    func prompts() {
        #expect(SSHAskpass.classify("Enter passphrase for key '/Users/me/.ssh/id_ed25519': ") == .passphrase)
        #expect(SSHAskpass.classify("Enter passphrase for \"/Users/me/key\": ") == .passphrase)
        #expect(SSHAskpass.classify("root@203.0.113.10's password: ") == .password)
        #expect(SSHAskpass.classify("(root@203.0.113.10) Password: ") == .password)
        #expect(SSHAskpass.classify("Verification code: ") == .unsupported)
        #expect(SSHAskpass.classify("Are you sure you want to continue connecting (yes/no/[fingerprint])? ") == .unsupported)
    }

    @Test("A normal launch is not helper mode")
    func normalLaunch() {
        #expect(SSHAskpass.runIfRequested(arguments: ["BWMonitor"], environment: [:]) == nil)
    }

    @Test("Helper mode refuses callers that are not BWMonitor's ssh")
    func refusesOtherParents() {
        let environment = SSHAskpass.environment(
            helperPath: "/Applications/BWMonitor.app/Contents/MacOS/BWMonitor",
            socketPath: "/tmp/bwm-test.sock",
            password: (UUID(), .sshPassword),
            passphrase: nil
        )
        // The test runner is not started by /usr/bin/ssh.
        #expect(SSHAskpass.runIfRequested(arguments: ["helper", "root@host's password: "], environment: environment) == 1)
    }

    @Test("The askpass socket answers only BWMonitor's own helpers")
    func serverRefusesOtherProcesses() throws {
        let service = "com.mujh.BWMonitor.tests.\(UUID().uuidString)"
        let keychain = KeychainStore(service: service)
        let id = UUID()
        try keychain.save("secret", for: id, kind: .pendingPassword)
        defer { try? keychain.delete(id, kind: .pendingPassword) }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bwm-askpass-\(UUID().uuidString.prefix(6))").path
        let server = try AskpassServer(socketPath: path, keychain: keychain)
        defer { server.stop() }
        // This process is not a helper started by ssh, so nothing is revealed.
        #expect(AskpassServer.request(account: KeychainStore.account(id, .pendingPassword), socketPath: path) == nil)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("Keychain account names round-trip")
    func accounts() {
        let id = UUID()
        let account = KeychainStore.account(id, .pendingPassphrase)
        #expect(KeychainStore.parse(account: account)?.serverID == id)
        #expect(KeychainStore.parse(account: account)?.kind == .pendingPassphrase)
        #expect(KeychainStore.parse(account: "not-a-uuid.sshPassword") == nil)
    }
}

@Suite("SSH command lines")
final class SSHInvocationTests {
    let directory: URL
    let manager: SSHManager

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bwm-tests-\(UUID().uuidString)")
        manager = SSHManager(
            knownHostsDirectory: directory.appendingPathComponent("KnownHosts"),
            controlDirectory: directory.appendingPathComponent("cm"),
            keychain: KeychainStore(service: "com.mujh.BWMonitor.tests.\(UUID().uuidString)"),
            askpass: .init(helperPath: "/Applications/BWMonitor.app/Contents/MacOS/BWMonitor", socketPath: "/tmp/bwm-test.sock")
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func trustedServer(_ configure: (inout Server) -> Void = { _ in }) throws -> Server {
        var server = Server(name: "Test", host: "203.0.113.10", port: 27_015, username: "root")
        configure(&server)
        let identity = SSHHostIdentity(host: server.host, keys: KnownHosts.parse(KnownHostsTests.ed25519))
        try manager.trust(identity, for: server)
        return server
    }

    @Test("Untrusted hosts are refused before connecting")
    func untrusted() {
        let server = Server(name: "Test", host: "203.0.113.10")
        #expect(throws: SSHError.hostNotTrusted) {
            try manager.makeInvocation(for: server, channel: .shared, remoteCommand: ["true"])
        }
    }

    @Test("Hosts that look like options are rejected")
    func optionInjection() {
        let server = Server(name: "Test", host: "-oProxyCommand=evil")
        #expect(throws: SSHError.invalidServer) {
            try manager.makeInvocation(for: server, channel: .shared, remoteCommand: ["true"])
        }
    }

    @Test("A selected key is the only identity offered")
    func keyAuthentication() throws {
        let server = try trustedServer { $0.privateKeyPath = "~/.ssh/id_ed25519" }
        let invocation = try manager.makeInvocation(for: server, channel: .shared, remoteCommand: ["sh", "-s"])
        let arguments = invocation.arguments
        #expect(arguments.contains("IdentitiesOnly=yes"))
        #expect(arguments.contains(NSString(string: "~/.ssh/id_ed25519").expandingTildeInPath))
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("StrictHostKeyChecking=yes"))
        #expect(arguments.contains("ControlMaster=auto"))
        let knownHosts = arguments.first { $0.hasPrefix("UserKnownHostsFile=") } ?? ""
        #expect(knownHosts.hasSuffix(".known_hosts\""), "paths with spaces must be quoted: \(knownHosts)")
        #expect(Array(arguments.suffix(4)) == ["--", "203.0.113.10", "sh", "-s"])
        #expect(invocation.environment.isEmpty)
    }

    @Test("Password logins without a saved password do not connect")
    func missingPassword() throws {
        let server = try trustedServer { $0.authentication = .password }
        #expect(throws: SSHError.missingPassword) {
            try manager.makeInvocation(for: server, channel: .shared, remoteCommand: ["true"])
        }
        // The interactive terminal lets ssh prompt instead.
        let terminal = try manager.makeInvocation(for: server, channel: .shared, interactive: true, remoteCommand: [])
        #expect(terminal.arguments.contains("BatchMode=no"))
        #expect(terminal.arguments.contains("-tt"))
    }

    @Test("Control socket paths fit the Unix socket limit")
    func controlPathLength() throws {
        let server = try trustedServer()
        let real = SSHManager(knownHostsDirectory: directory)
        // ssh appends a 17-character suffix while creating the socket.
        #expect(real.controlPath(for: server).utf8.count + 17 < 104)
        var edited = server
        edited.port = 22
        #expect(manager.controlPath(for: server) != manager.controlPath(for: edited))
    }

    @Test("The Terminal.app script is valid shell and carries no secrets")
    func externalTerminalScript() async throws {
        let server = try trustedServer { $0.name = "it's" }
        let script = try manager.externalTerminalScript(for: server)
        #expect(!script.contains("BWMONITOR"))
        #expect(script.contains("'-tt'"))
        let file = directory.appendingPathComponent("open.command")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let check = try await ProcessRunner.run("/bin/sh", arguments: ["-n", file.path], timeout: 10)
        #expect(check.status == 0, "\(check.stderr)")
    }

    @Test("Installing a key keeps existing keys and never duplicates")
    func installScript() async throws {
        let home = directory.appendingPathComponent("home")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let authorized = ssh.appendingPathComponent("authorized_keys")
        // An existing key without a trailing newline.
        try "ssh-ed25519 AAAAexisting old@laptop".write(to: authorized, atomically: true, encoding: .utf8)
        let parsed = try #require(SSHKeyInspector.parsePublicKeyLine(String(KnownHostsTests.otherEd25519.split(separator: " ", maxSplits: 1)[1]) + " BWMonitor@Mac"))
        let line = SSHKeyInspector.authorizedKeysLine(algorithm: parsed.algorithm, blob: parsed.blob, comment: parsed.comment)
        let script = SSHManager.installScript(line: line, keyData: parsed.blob.base64EncodedString())
        for _ in 0..<2 {
            let output = try await ProcessRunner.run(
                "/bin/sh", arguments: ["-s"], environment: ["HOME": home.path], input: Data(script.utf8), timeout: 10
            )
            #expect(output.stdout.contains("BWMONITOR_KEY_INSTALLED"), "\(output.stderr)")
        }
        let content = try String(contentsOf: authorized, encoding: .utf8)
        #expect(content == "ssh-ed25519 AAAAexisting old@laptop\n\(line)\n")
        let mode = try FileManager.default.attributesOfItem(atPath: authorized.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("Unused pinned keys are removed")
    func unusedHostKeys() throws {
        let kept = try trustedServer()
        let orphan = Server(name: "Orphan", host: "203.0.113.10", port: 27_015)
        try manager.trust(SSHHostIdentity(host: orphan.host, keys: KnownHosts.parse(KnownHostsTests.ed25519)), for: orphan)
        manager.removeUnusedHostKeys(keeping: [kept])
        #expect(manager.isTrusted(kept))
        #expect(!manager.isTrusted(orphan))
    }

    @Test("Trusting writes every offered key")
    func trustWritesAllKeys() throws {
        let server = Server(name: "Test", host: "203.0.113.10", port: 27_015)
        let identity = SSHHostIdentity(host: server.host, keys: KnownHosts.parse("\(KnownHostsTests.rsa)\n\(KnownHostsTests.ed25519)"))
        try manager.trust(identity, for: server)
        #expect(manager.savedHostKeys(for: server).count == 2)
        #expect(manager.isTrusted(server))
        manager.forgetHostKey(for: server)
        #expect(!manager.isTrusted(server))
    }
}
