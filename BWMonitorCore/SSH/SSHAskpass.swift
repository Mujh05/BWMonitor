import Darwin
import Foundation

/// Supplies saved passwords and key passphrases to OpenSSH.
///
/// OpenSSH runs the program named in `SSH_ASKPASS` whenever it needs a secret.
/// BWMonitor names its own executable, which starts in helper mode and asks
/// the running app for the secret over a private Unix socket
/// (``AskpassServer``). Only the app itself reads the Keychain, so any
/// Keychain permission prompt comes from BWMonitor while it runs, never from
/// a background process. Secrets never pass through command lines,
/// environment variables, files, or a terminal stream.
public enum SSHAskpass {
    static let enabledKey = "BWMONITOR_ASKPASS"
    static let socketKey = "BWMONITOR_ASKPASS_SOCKET"
    static let passwordAccountKey = "BWMONITOR_ASKPASS_PASSWORD"
    static let passphraseAccountKey = "BWMONITOR_ASKPASS_PASSPHRASE"

    public enum Prompt: Equatable, Sendable {
        case password
        case passphrase
        case unsupported
    }

    /// Recognizes the prompts OpenSSH shows for passwords and key passphrases.
    /// Anything else, such as a one-time code, is refused.
    public static func classify(_ prompt: String) -> Prompt {
        let text = prompt.lowercased()
        if text.contains("passphrase") { return .passphrase }
        if text.contains("password") { return .password }
        return .unsupported
    }

    /// Environment that makes OpenSSH ask BWMonitor for the given Keychain items.
    public static func environment(
        helperPath: String,
        socketPath: String,
        password: (UUID, SecretKind)?,
        passphrase: (UUID, SecretKind)?
    ) -> [String: String] {
        var environment = [
            "SSH_ASKPASS": helperPath,
            "SSH_ASKPASS_REQUIRE": "force",
            enabledKey: "1",
            socketKey: socketPath
        ]
        if let password {
            environment[passwordAccountKey] = KeychainStore.account(password.0, password.1)
        }
        if let passphrase {
            environment[passphraseAccountKey] = KeychainStore.account(passphrase.0, passphrase.1)
        }
        return environment
    }

    /// Runs helper mode when OpenSSH started this process as its askpass
    /// program. Returns the exit status, or nil for a normal app launch.
    public static func runIfRequested(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32? {
        guard environment[enabledKey] == "1" else { return nil }
        guard let parent = ProcessInspector.executablePath(of: getppid()),
              AskpassServer.trustedParents.contains(parent),
              let socketPath = environment[socketKey] else {
            return 1
        }
        let accountKey: String
        switch classify(arguments.dropFirst().first ?? "") {
        case .password: accountKey = passwordAccountKey
        case .passphrase: accountKey = passphraseAccountKey
        case .unsupported: return 1
        }
        guard let account = environment[accountKey],
              let secret = AskpassServer.request(account: account, socketPath: socketPath),
              !secret.isEmpty else {
            return 1
        }
        FileHandle.standardOutput.write(Data((secret + "\n").utf8))
        return 0
    }
}

/// Answers askpass helpers on behalf of the running app.
///
/// A request is served only when the connecting process is BWMonitor's own
/// executable, its parent is the system `ssh` or `ssh-keygen`, and that tool
/// was started by this app process. Other programs cannot use the socket to
/// read the Keychain.
public final class AskpassServer: @unchecked Sendable {
    static let trustedParents: Set<String> = ["/usr/bin/ssh", "/usr/bin/ssh-keygen"]

    public let socketPath: String
    private let keychain: KeychainStore
    private let queue = DispatchQueue(label: "BWMonitor.askpass", attributes: .concurrent)
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    public init(socketPath: String, keychain: KeychainStore) throws {
        self.socketPath = socketPath
        self.keychain = keychain
        // Only the owner may connect (0600 below); a new folder is private too.
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: socketPath).deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        unlink(socketPath)
        guard Self.withAddress(socketPath, { bind(fd, $0, $1) }) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(socketPath)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.resume()
        self.source = source
    }

    deinit {
        stop()
    }

    public func stop() {
        source?.cancel()
        source = nil
        if listener >= 0 {
            close(listener)
            listener = -1
            unlink(socketPath)
        }
    }

    private func acceptConnections() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            queue.async { [weak self] in
                self?.serve(client)
                close(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        var enabled: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(client, F_SETFL, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var peer: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) == 0,
              isTrustedHelper(peer),
              let account = Self.readLine(from: client),
              let parsed = KeychainStore.parse(account: account),
              parsed.kind.isAskpassSecret,
              let secret = try? keychain.read(account: account) else {
            return
        }
        _ = Self.write(secret + "\n", to: client)
    }

    /// The helper runs this app's executable, its parent is the system ssh
    /// or ssh-keygen, and that tool is a child of this process.
    private func isTrustedHelper(_ pid: pid_t) -> Bool {
        guard let path = ProcessInspector.executablePath(of: pid),
              path == ProcessInspector.executablePath(of: getpid()),
              let tool = ProcessInspector.parentPID(of: pid),
              let toolPath = ProcessInspector.executablePath(of: tool),
              Self.trustedParents.contains(toolPath) else {
            return false
        }
        return ProcessInspector.parentPID(of: tool) == getpid()
    }

    /// Helper side: asks the app for one secret.
    static func request(account: String, socketPath: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        // Leave time for the user to answer a Keychain prompt in the app.
        var timeout = timeval(tv_sec: 90, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard withAddress(socketPath, { connect(fd, $0, $1) }) == 0,
              write(account + "\n", to: fd) else {
            return nil
        }
        return readLine(from: fd)
    }

    private static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            errno = ENAMETOOLONG
            return -1
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private static func readLine(from fd: Int32) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 4_096 {
            guard read(fd, &byte, 1) == 1 else { break }
            if byte == 0x0A { return String(data: data, encoding: .utf8) }
            data.append(byte)
        }
        return nil
    }

    private static func write(_ text: String, to fd: Int32) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }
}

enum ProcessInspector {
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
