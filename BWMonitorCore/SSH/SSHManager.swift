import CryptoKit
import Foundation

public struct SSHHostIdentity: Equatable, Sendable {
    public var host: String
    public var keyType: String
    public var keyData: String
    public var fingerprint: String
    public var knownHostsLine: String
}

public enum SSHHostKeyStatus: Equatable, Sendable {
    case unknown(SSHHostIdentity)
    case trusted(SSHHostIdentity)
    case changed(expectedFingerprint: String, received: SSHHostIdentity)
}

public enum SSHError: LocalizedError, Equatable {
    case invalidServer
    case hostNotTrusted
    case hostKeyChanged
    case passwordRequiresTerminal
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
        case .passwordRequiresTerminal:
            NSLocalizedString(
                "Background monitoring requires a private key or SSH agent. Password login remains available in Terminal.",
                comment: "SSH authentication limitation"
            )
        case let .commandFailed(message):
            message.isEmpty
                ? NSLocalizedString("The SSH command failed.", comment: "SSH command error")
                : message
        case .noHostKey:
            NSLocalizedString("The server did not provide an SSH host key.", comment: "SSH scan error")
        }
    }
}

public final class SSHManager: @unchecked Sendable {
    public let knownHostsDirectory: URL

    public init(knownHostsDirectory: URL? = nil) {
        if let knownHostsDirectory {
            self.knownHostsDirectory = knownHostsDirectory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.knownHostsDirectory = support
                .appendingPathComponent("BWMonitor", isDirectory: true)
                .appendingPathComponent("KnownHosts", isDirectory: true)
        }
    }

    public func hostKeyStatus(for server: Server) async throws -> SSHHostKeyStatus {
        let received = try await probeHostKey(for: server)
        let file = knownHostsFile(for: server)
        guard FileManager.default.fileExists(atPath: file.path) else { return .unknown(received) }
        let saved = try String(contentsOf: file, encoding: .utf8)
        let fields = saved.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 3 else {
            return .changed(
                expectedFingerprint: NSLocalizedString("Invalid saved key", comment: "Corrupt known host entry"),
                received: received
            )
        }
        let savedFingerprint = Self.fingerprint(forBase64Key: String(fields[2]))
        if fields[1] == Substring(received.keyType), fields[2] == Substring(received.keyData) {
            return .trusted(received)
        }
        return .changed(expectedFingerprint: savedFingerprint, received: received)
    }

    public func trust(_ identity: SSHHostIdentity, for server: Server) throws {
        try FileManager.default.createDirectory(at: knownHostsDirectory, withIntermediateDirectories: true)
        try (identity.knownHostsLine + "\n").write(
            to: knownHostsFile(for: server),
            atomically: true,
            encoding: .utf8
        )
    }

    public func execute(_ command: String, on server: Server, timeout: TimeInterval = 15) async throws -> String {
        guard server.isValid, !server.host.hasPrefix("-"), !server.username.hasPrefix("-") else {
            throw SSHError.invalidServer
        }
        if server.authentication == .password { throw SSHError.passwordRequiresTerminal }
        let status = try await hostKeyStatus(for: server)
        switch status {
        case .unknown: throw SSHError.hostNotTrusted
        case .changed: throw SSHError.hostKeyChanged
        case .trusted: break
        }

        var arguments = connectionArguments(for: server, batchMode: true)
        arguments.append("\(server.username)@\(server.host)")
        arguments.append(command)
        let result = try await Self.run("/usr/bin/ssh", arguments: arguments, timeout: timeout)
        guard result.status == 0 else {
            throw SSHError.commandFailed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.output
    }

    public func connectionArguments(for server: Server, batchMode: Bool) -> [String] {
        var arguments = [
            "-p", String(server.port),
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHostsFile(for: server).path)",
            "-o", "BatchMode=\(batchMode ? "yes" : "no")"
        ]
        if !server.privateKeyPath.isEmpty {
            arguments += ["-i", NSString(string: server.privateKeyPath).expandingTildeInPath]
        }
        return arguments
    }

    public func knownHostsFile(for server: Server) -> URL {
        knownHostsDirectory.appendingPathComponent("\(server.id.uuidString).known_hosts")
    }

    private func probeHostKey(for server: Server) async throws -> SSHHostIdentity {
        guard server.isValid, !server.host.hasPrefix("-") else { throw SSHError.invalidServer }
        let result = try await Self.run(
            "/usr/bin/ssh-keyscan",
            arguments: ["-T", "5", "-p", String(server.port), server.host],
            timeout: 8
        )
        guard result.status == 0 || !result.output.isEmpty else {
            throw SSHError.commandFailed(result.error)
        }
        guard let line = result.output.components(separatedBy: .newlines).first(where: { !$0.hasPrefix("#") && !$0.isEmpty }) else {
            throw SSHError.noHostKey
        }
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 3 else { throw SSHError.noHostKey }
        let keyData = String(fields[2])
        return SSHHostIdentity(
            host: server.host,
            keyType: String(fields[1]),
            keyData: keyData,
            fingerprint: Self.fingerprint(forBase64Key: keyData),
            knownHostsLine: line
        )
    }

    private static func fingerprint(forBase64Key key: String) -> String {
        guard let data = Data(base64Encoded: key) else { return "SHA256:invalid" }
        let digest = SHA256.hash(data: data)
        return "SHA256:" + Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    private struct CommandResult: @unchecked Sendable {
        var status: Int32
        var output: String
        var error: String
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = error

            let state = CommandState()
            process.terminationHandler = { process in
                state.finish {
                    continuation.resume(returning: CommandResult(
                        status: process.terminationStatus,
                        output: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                        error: String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                state.finish { continuation.resume(throwing: error) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                state.finish {
                    process.terminate()
                    continuation.resume(throwing: SSHError.commandFailed(
                        NSLocalizedString("SSH operation timed out.", comment: "SSH timeout error")
                    ))
                }
            }
        }
    }
}

private final class CommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func finish(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        action()
    }
}
