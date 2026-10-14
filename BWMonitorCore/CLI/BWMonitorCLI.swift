import Foundation

public enum BWMonitorCLICommand: Equatable, Sendable {
    case servers
    case status(selector: String?)
    case traffic(selector: String?)
    case files(selector: String, path: String)
    case upload(selector: String, local: String, directory: String)
    case download(selector: String, remote: String, local: String)
    case execute(selector: String, command: [String])
    case shell(selector: String)
    case installCLI
    case version
    case help
}

public enum BWMonitorCLIParseError: LocalizedError, Equatable {
    case unknownCommand(String)
    case unexpectedArguments(String)
    case missingServer
    case missingRemoteCommand

    public var errorDescription: String? {
        switch self {
        case let .unknownCommand(command):
            "Unknown command: \(command)"
        case let .unexpectedArguments(arguments):
            "Unexpected arguments: \(arguments)"
        case .missingServer:
            "A server name or UUID is required."
        case .missingRemoteCommand:
            "A remote command is required after --."
        }
    }
}

public enum BWMonitorCLIParser {
    public static func parse(_ arguments: [String]) throws -> BWMonitorCLICommand {
        guard let name = arguments.first else { return .help }
        let rest = Array(arguments.dropFirst())
        switch name {
        case "servers", "list":
            try requireEmpty(rest)
            return .servers
        case "status":
            guard rest.count <= 1 else { throw unexpected(rest.dropFirst()) }
            return .status(selector: rest.first)
        case "traffic":
            guard rest.count <= 1 else { throw unexpected(rest.dropFirst()) }
            return .traffic(selector: rest.first)
        case "files", "ls":
            guard let selector = rest.first else { throw BWMonitorCLIParseError.missingServer }
            guard rest.count == 1 || (rest.count == 3 && rest[1] == "--path") else { throw unexpected(rest.dropFirst()) }
            return .files(selector: selector, path: rest.count == 3 ? rest[2] : "")
        case "upload", "download":
            guard let selector = rest.first else { throw BWMonitorCLIParseError.missingServer }
            guard rest.count == 4 && rest[2] == "--to" else { throw unexpected(rest.dropFirst()) }
            return name == "upload" ? .upload(selector: selector, local: rest[1], directory: rest[3])
                : .download(selector: selector, remote: rest[1], local: rest[3])
        case "exec":
            guard let selector = rest.first else { throw BWMonitorCLIParseError.missingServer }
            guard let commandStart = rest.firstIndex(of: "--") else {
                throw BWMonitorCLIParseError.missingRemoteCommand
            }
            let command = Array(rest.dropFirst(commandStart + 1))
            guard !command.isEmpty else { throw BWMonitorCLIParseError.missingRemoteCommand }
            guard commandStart == 1 else { throw unexpected(rest[1..<commandStart]) }
            return .execute(selector: selector, command: command)
        case "shell", "ssh":
            guard let selector = rest.first else { throw BWMonitorCLIParseError.missingServer }
            guard rest.count == 1 else { throw unexpected(rest.dropFirst()) }
            return .shell(selector: selector)
        case "install-cli":
            try requireEmpty(rest)
            return .installCLI
        case "version", "--version", "-v":
            try requireEmpty(rest)
            return .version
        case "help", "--help", "-h":
            try requireEmpty(rest)
            return .help
        default:
            throw BWMonitorCLIParseError.unknownCommand(name)
        }
    }

    private static func requireEmpty(_ arguments: [String]) throws {
        guard arguments.isEmpty else { throw unexpected(arguments[...]) }
    }

    private static func unexpected<S: Sequence>(_ arguments: S) -> BWMonitorCLIParseError where S.Element == String {
        .unexpectedArguments(Array(arguments).joined(separator: " "))
    }
}

public enum BWMonitorCLI {
    public static let schemaVersion = 1

    public static let help = """
    ServerDock command-line interface

    Usage:
      serverdock servers
      serverdock status [SERVER]
      serverdock traffic [SERVER]
      serverdock files SERVER [--path DIRECTORY]
      serverdock upload SERVER LOCAL_FILE --to REMOTE_DIRECTORY
      serverdock download SERVER REMOTE_FILE --to LOCAL_FILE
      serverdock exec SERVER -- COMMAND [ARG ...]
      serverdock shell SERVER
      serverdock install-cli
      serverdock version

    SERVER is an exact server name, host, or UUID. Data commands write JSON
    to stdout. Passwords, API keys, and private-key passphrases are never
    included in output.

    The legacy bwmonitor command remains an alias with the same JSON schema.
    """

    public static func run(arguments: [String]) async -> Int32 {
        let command: BWMonitorCLICommand
        do {
            command = try BWMonitorCLIParser.parse(arguments)
        } catch {
            writeError(code: "invalid_arguments", message: error.localizedDescription)
            write(help + "\n", to: .standardError)
            return 2
        }

        switch command {
        case .help:
            write(help + "\n")
            return 0
        case .version:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
            return encode(VersionResponse(schemaVersion: schemaVersion, version: version, build: build)) ? 0 : 1
        case .installCLI:
            return installLauncher()
        default:
            break
        }

        let servers: [Server]
        do {
            servers = try await ServerRepository().load()
        } catch {
            writeError(code: "configuration_unreadable", message: error.localizedDescription)
            return 1
        }

        let context = makeContext()
        switch command {
        case .servers:
            let items = servers.map { ServerOutput(server: $0, trusted: context.ssh.isTrusted($0)) }
            return encode(ServersResponse(schemaVersion: schemaVersion, servers: items)) ? 0 : 1
        case let .status(selector):
            guard let selected = select(selector, from: servers) else { return 2 }
            let results = await status(for: selected, ssh: context.ssh)
            let success = results.allSatisfy(\.ok)
            return encode(StatusResponse(schemaVersion: schemaVersion, statuses: results)) ? (success ? 0 : 1) : 1
        case let .traffic(selector):
            let trafficServers = servers.filter { $0.provider.supportsTrafficAPI }
            guard let selected = select(selector, from: selector == nil ? trafficServers : servers) else {
                return 2
            }
            let results = await traffic(for: selected, keychain: context.keychain)
            let success = results.allSatisfy(\.ok)
            return encode(TrafficResponse(schemaVersion: schemaVersion, traffic: results)) ? (success ? 0 : 1) : 1
        case let .execute(selector, command):
            guard let server = selectOne(selector, from: servers) else { return 2 }
            do {
                let script = command.map(shellQuote).joined(separator: " ") + "\n"
                let output = try await context.ssh.execute(script, on: server, timeout: 60)
                return encode(ExecuteResponse(
                    schemaVersion: schemaVersion,
                    server: ServerReference(server),
                    stdout: output
                )) ? 0 : 1
            } catch {
                writeError(code: "remote_command_failed", message: error.localizedDescription)
                return 1
            }
        case let .files(selector, path):
            guard let server = selectOne(selector, from: servers) else { return 2 }
            do {
                let listing = try await SSHFileService(ssh: context.ssh).list(path: path, on: server)
                return encode(FilesResponse(schemaVersion: schemaVersion, server: ServerReference(server),
                                            path: listing.path, entries: listing.entries)) ? 0 : 1
            } catch {
                writeError(code: "directory_failed", message: error.localizedDescription)
                return 1
            }
        case let .upload(selector, local, directory):
            guard let server = selectOne(selector, from: servers) else { return 2 }
            do {
                let source = URL(fileURLWithPath: NSString(string: local).expandingTildeInPath)
                try await SSHFileService(ssh: context.ssh).upload(source, to: directory, on: server)
                return encode(FileTransferResponse(schemaVersion: schemaVersion, server: ServerReference(server),
                                                   ok: true, path: try RemoteFileCommands.join(directory: directory, name: source.lastPathComponent))) ? 0 : 1
            } catch {
                writeError(code: "upload_failed", message: error.localizedDescription)
                return 1
            }
        case let .download(selector, remote, local):
            guard let server = selectOne(selector, from: servers) else { return 2 }
            do {
                let target = URL(fileURLWithPath: NSString(string: local).expandingTildeInPath)
                // Automation never overwrites an existing local file without consent.
                guard !FileManager.default.fileExists(atPath: target.path) else { throw RemoteFileError.destinationExists }
                let parent = (remote as NSString).deletingLastPathComponent
                let listing = try await SSHFileService(ssh: context.ssh).list(path: parent, on: server)
                guard let entry = listing.entries.first(where: { $0.path == remote }), entry.kind == .file else { throw RemoteFileError.invalidPath }
                try await SSHFileService(ssh: context.ssh).download(entry, to: target, on: server)
                return encode(FileTransferResponse(schemaVersion: schemaVersion, server: ServerReference(server),
                                                   ok: true, path: target.path)) ? 0 : 1
            } catch {
                writeError(code: "download_failed", message: error.localizedDescription)
                return 1
            }
        case let .shell(selector):
            guard let server = selectOne(selector, from: servers) else { return 2 }
            return runShell(server: server, ssh: context.ssh)
        case .help, .installCLI, .version:
            return 0
        }
    }

    private static func makeContext() -> CLIContext {
        let keychain = KeychainStore()
        let socketPath = AppEnvironment.controlSocketDirectory
            .appendingPathComponent("askpass-cli-\(ProcessInfo.processInfo.processIdentifier)").path
        let askpassServer = try? AskpassServer(socketPath: socketPath, keychain: keychain)
        let askpass = askpassServer.flatMap { server in
            Bundle.main.executablePath.map { SSHManager.Askpass(helperPath: $0, socketPath: server.socketPath) }
        }
        return CLIContext(
            keychain: keychain,
            askpassServer: askpassServer,
            ssh: SSHManager(keychain: keychain, askpass: askpass)
        )
    }

    private static func select(
        _ selector: String?,
        from servers: [Server],
        provider: ServerProvider? = nil
    ) -> [Server]? {
        if let selector {
            guard let server = selectOne(selector, from: servers) else { return nil }
            return [server]
        }
        return provider.map { provider in servers.filter { $0.provider == provider } } ?? servers
    }

    private static func selectOne(_ selector: String, from servers: [Server]) -> Server? {
        let matches: [Server]
        if let id = UUID(uuidString: selector), let server = servers.first(where: { $0.id == id }) {
            matches = [server]
        } else {
            matches = servers.filter {
                $0.name.compare(selector, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                    || $0.host.compare(selector, options: .caseInsensitive) == .orderedSame
            }
        }
        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            writeError(code: "server_not_found", message: "No server matches \(selector).")
        default:
            writeError(code: "server_ambiguous", message: "More than one server matches \(selector); use its UUID.")
        }
        return nil
    }

    private static func status(for servers: [Server], ssh: SSHManager) async -> [StatusOutput] {
        await withTaskGroup(of: (Int, StatusOutput).self) { group in
            for (index, server) in servers.enumerated() {
                group.addTask {
                    do {
                        let result = try await MonitoringService(ssh: ssh).refresh(server: server)
                        return (index, StatusOutput(server: server, metrics: result.metrics))
                    } catch {
                        return (index, StatusOutput(server: server, error: error.localizedDescription))
                    }
                }
            }
            var ordered: [(Int, StatusOutput)] = []
            for await result in group { ordered.append(result) }
            return ordered.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func traffic(for servers: [Server], keychain: KeychainStore) async -> [TrafficOutput] {
        await withTaskGroup(of: (Int, TrafficOutput).self) { group in
            for (index, server) in servers.enumerated() {
                group.addTask {
                    guard server.provider.supportsTrafficAPI else {
                        return (index, TrafficOutput(server: server, error: "Traffic API is not available for this provider."))
                    }
                    do {
                        switch server.provider {
                        case .bandwagonHost:
                            guard let apiKey = try keychain.read(for: server.id, kind: .kiwiAPIKey), !apiKey.isEmpty else {
                                return (index, TrafficOutput(server: server, error: "No KiwiVM API key is saved."))
                            }
                            let value = try await KiwiVMClient().serviceInfo(veid: server.veid, apiKey: apiKey)
                            return (index, TrafficOutput(server: server, value: value))
                        case .awsLightsail:
                            guard let access = try keychain.read(for: server.id, kind: .awsAccessKeyID), !access.isEmpty,
                                  let secret = try keychain.read(for: server.id, kind: .awsSecretAccessKey), !secret.isEmpty else {
                                return (index, TrafficOutput(server: server, error: "No AWS access key ID and secret access key are saved."))
                            }
                            let token = try keychain.read(for: server.id, kind: .awsSessionToken)
                            let value = try await AWSLightsailClient().monthlyTraffic(
                                instanceName: server.awsInstanceName,
                                region: server.awsRegion,
                                credentials: AWSCredentials(accessKeyID: access, secretAccessKey: secret, sessionToken: token),
                                quotaOverrideGB: server.awsMonthlyTransferOverrideGB
                            )
                            return (index, TrafficOutput(server: server, value: value))
                        case .vultr, .hetznerCloud:
                            guard let token = try keychain.readCloudToken(for: server.id, provider: server.provider), !token.isEmpty else {
                                return (index, TrafficOutput(server: server, error: "No provider API token is saved. SSH monitoring and files are available."))
                            }
                            let value = try await CloudProviderClient().fetchTraffic(server: server, apiToken: token)
                            return (index, TrafficOutput(server: server, value: value))
                        case .genericLinux, .digitalOcean, .alibabaCloud, .tencentCloud, .oracleCloud:
                            return (index, TrafficOutput(server: server, error: "Traffic API is not available for this provider."))
                        }
                    } catch {
                        return (index, TrafficOutput(server: server, error: error.localizedDescription))
                    }
                }
            }
            var ordered: [(Int, TrafficOutput)] = []
            for await result in group { ordered.append(result) }
            return ordered.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func runShell(server: Server, ssh: SSHManager) -> Int32 {
        do {
            let invocation = try ssh.terminalInvocation(for: server)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = invocation.arguments
            process.environment = ProcessInfo.processInfo.environment.merging(invocation.environment) { _, value in value }
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            writeError(code: "shell_failed", message: error.localizedDescription)
            return 1
        }
    }

    private static func installLauncher() -> Int32 {
        guard let executable = Bundle.main.executablePath else {
            writeError(code: "installation_failed", message: "ServerDock executable path is unavailable.")
            return 1
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
        let launchers = [directory.appendingPathComponent("serverdock"), directory.appendingPathComponent("bwmonitor")]
        let script = "#!/bin/sh\nexec \(shellQuote(executable)) --cli \"$@\"\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for launcher in launchers {
                if FileManager.default.fileExists(atPath: launcher.path) {
                    let existing = try String(contentsOf: launcher, encoding: .utf8)
                    guard existing.contains("BWMonitor.app/Contents/MacOS/BWMonitor")
                        || existing.contains("ServerDock.app/Contents/MacOS/BWMonitor") else {
                        writeError(code: "launcher_exists", message: "\(launcher.path) already exists and was not created by ServerDock.")
                        return 1
                    }
                }
            }
            for launcher in launchers {
                try script.write(to: launcher, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
            }
            return encode(InstallResponse(schemaVersion: schemaVersion, installed: true, path: launchers[0].path)) ? 0 : 1
        } catch {
            writeError(code: "installation_failed", message: error.localizedDescription)
            return 1
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private static func encode<T: Encodable>(_ value: T) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(value) + Data("\n".utf8)
            FileHandle.standardOutput.write(data)
            return true
        } catch {
            writeError(code: "encoding_failed", message: error.localizedDescription)
            return false
        }
    }

    private static func writeError(code: String, message: String) {
        let response = ErrorResponse(schemaVersion: schemaVersion, error: CLIErrorOutput(code: code, message: message))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(response) + Data("\n".utf8) {
            FileHandle.standardError.write(data)
        }
    }

    private static func write(_ value: String, to handle: FileHandle = .standardOutput) {
        handle.write(Data(value.utf8))
    }
}

private struct CLIContext {
    let keychain: KeychainStore
    // Retain the server while ssh and its askpass helpers are running.
    let askpassServer: AskpassServer?
    let ssh: SSHManager
}

private struct ServerReference: Codable, Sendable {
    let id: UUID
    let name: String

    init(_ server: Server) {
        id = server.id
        name = server.name
    }
}

private struct ServerOutput: Codable, Sendable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    let username: String
    let provider: String
    let operatingSystem: String
    let authentication: String
    let hostKeyTrusted: Bool

    init(server: Server, trusted: Bool) {
        id = server.id
        name = server.name
        host = server.host
        port = server.port
        username = server.username
        provider = server.provider.rawValue
        operatingSystem = server.operatingSystem
        authentication = server.authentication.rawValue
        hostKeyTrusted = trusted
    }
}

private struct StatusOutput: Codable, Sendable {
    let server: ServerReference
    let ok: Bool
    let metrics: ServerMetrics?
    let error: String?

    init(server: Server, metrics: ServerMetrics) {
        self.server = ServerReference(server)
        ok = true
        self.metrics = metrics
        error = nil
    }

    init(server: Server, error: String) {
        self.server = ServerReference(server)
        ok = false
        metrics = nil
        self.error = error
    }
}

private struct TrafficOutput: Codable, Sendable {
    let server: ServerReference
    let ok: Bool
    let used: UInt64?
    let limit: UInt64?
    let remaining: UInt64?
    let usagePercentage: Double?
    let nextReset: Date?
    let inbound: UInt64?
    let outbound: UInt64?
    let latestDataPoint: Date?
    let lastUpdated: Date?
    let quotaSource: String?
    let serverOnline: Bool?
    let error: String?

    init(server: Server, value: BandwagonTraffic) {
        self.server = ServerReference(server)
        ok = true
        used = value.used
        limit = value.limit
        remaining = value.remaining
        usagePercentage = value.usagePercentage
        nextReset = value.nextReset
        serverOnline = value.serverOnline
        inbound = nil
        outbound = nil
        latestDataPoint = nil
        lastUpdated = value.lastUpdated
        quotaSource = nil
        error = nil
    }

    init(server: Server, value: AWSMonthlyTraffic) {
        self.server = ServerReference(server)
        ok = true
        used = value.used
        limit = value.limit
        remaining = value.remaining
        usagePercentage = value.usagePercentage
        nextReset = value.nextReset
        serverOnline = nil
        inbound = value.inbound
        outbound = value.outbound
        latestDataPoint = value.latestDataPoint
        lastUpdated = value.lastUpdated
        quotaSource = value.quotaSource.rawValue
        error = nil
    }

    init(server: Server, value: CloudProviderTraffic) {
        self.server = ServerReference(server)
        ok = true
        used = value.used
        limit = value.limit
        remaining = value.remaining
        usagePercentage = value.usagePercentage
        nextReset = value.nextReset
        serverOnline = value.serverOnline
        inbound = value.inbound
        outbound = value.outbound
        latestDataPoint = value.latestDataPoint
        lastUpdated = value.lastUpdated
        quotaSource = value.quotaSource
        error = nil
    }

    init(server: Server, error: String) {
        self.server = ServerReference(server)
        ok = false
        used = nil
        limit = nil
        remaining = nil
        usagePercentage = nil
        nextReset = nil
        serverOnline = nil
        inbound = nil
        outbound = nil
        latestDataPoint = nil
        lastUpdated = nil
        quotaSource = nil
        self.error = error
    }
}

private struct ServersResponse: Codable { let schemaVersion: Int; let servers: [ServerOutput] }
private struct StatusResponse: Codable { let schemaVersion: Int; let statuses: [StatusOutput] }
private struct TrafficResponse: Codable { let schemaVersion: Int; let traffic: [TrafficOutput] }
private struct FilesResponse: Codable { let schemaVersion: Int; let server: ServerReference; let path: String; let entries: [RemoteFileEntry] }
private struct FileTransferResponse: Codable { let schemaVersion: Int; let server: ServerReference; let ok: Bool; let path: String }
private struct ExecuteResponse: Codable { let schemaVersion: Int; let server: ServerReference; let stdout: String }
private struct VersionResponse: Codable { let schemaVersion: Int; let version: String; let build: String }
private struct InstallResponse: Codable { let schemaVersion: Int; let installed: Bool; let path: String }
private struct CLIErrorOutput: Codable { let code: String; let message: String }
private struct ErrorResponse: Codable { let schemaVersion: Int; let error: CLIErrorOutput }
