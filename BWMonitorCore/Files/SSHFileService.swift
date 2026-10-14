import Foundation

public struct SSHFileService: Sendable {
    private let ssh: SSHManager

    public init(ssh: SSHManager) { self.ssh = ssh }

    public func list(path: String, on server: Server) async throws -> RemoteDirectoryListing {
        let output = try await ssh.execute(RemoteFileCommands.list(path: path), on: server)
        return try RemoteFileCommands.parseListing(output)
    }

    /// SFTP transport uses the same pinned identity and authenticated SSH master.
    /// A private temporary file is linked atomically; an existing name is never replaced.
    public func upload(_ local: URL, to directory: String, on server: Server) async throws {
        let values = try local.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw RemoteFileError.regularFilesOnly }
        let target = try RemoteFileCommands.join(directory: directory, name: local.lastPathComponent)
        let temporary = try RemoteFileCommands.join(directory: directory, name: ".serverdock-upload-" + UUID().uuidString)
        let q = RemoteFileCommands.quote
        do {
            _ = try await ssh.execute("set -e\numask 077\n(set -C; : > \(q(temporary)))", on: server)
            try await transfer(local.path, remote: temporary, upload: true, on: server)
            try Task.checkCancellation()
            // Hard linking in the same directory provides a no-clobber publication.
            do {
                _ = try await ssh.execute(Self.publishUpload(temporary: temporary, target: target), on: server)
            } catch let SSHError.commandFailed(message) where message.contains("File exists") {
                throw RemoteFileError.destinationExists
            }
        } catch {
            // Cleanup runs outside the cancelled UI task and never removes the destination.
            let manager = ssh
            Task.detached { _ = try? await manager.execute("rm -f -- \(q(temporary))", on: server) }
            throw error
        }
    }

    public func download(_ entry: RemoteFileEntry, to local: URL, on server: Server, overwrite: Bool = false) async throws {
        guard entry.kind == .file, entry.path.hasPrefix("/"), !entry.path.contains("\0") else {
            throw RemoteFileError.regularFilesOnly
        }
        let temporary = local.deletingLastPathComponent().appendingPathComponent(".serverdock-download-" + UUID().uuidString)
        do {
            _ = try await ssh.execute("true", on: server)
            try await transfer(temporary.path, remote: entry.path, upload: false, on: server)
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            // The UI handles overwrite consent. Stage a complete download before replacement.
            if overwrite && FileManager.default.fileExists(atPath: local.path) {
                _ = try FileManager.default.replaceItemAt(local, withItemAt: temporary)
            } else {
                do {
                    try FileManager.default.linkItem(at: temporary, to: local)
                } catch {
                    if FileManager.default.fileExists(atPath: local.path) { throw RemoteFileError.destinationExists }
                    throw error
                }
                try FileManager.default.removeItem(at: temporary)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func publishUpload(temporary: String, target: String) -> String {
        let q = RemoteFileCommands.quote
        // -T rejects an existing directory or a symlink to one as well as files.
        return "set -e\nexport LC_ALL=C\nchmod 600 -- \(q(temporary))\nln -T -- \(q(temporary)) \(q(target))\nrm -- \(q(temporary))"
    }

    private func transfer(_ local: String, remote: String, upload: Bool, on server: Server) async throws {
        let invocation = try ssh.makeInvocation(for: server, channel: .shared, remoteCommand: [])
        let options = Self.scpOptions(from: invocation.arguments)
        let host = server.host.contains(":") && !server.host.hasPrefix("[") ? "[\(server.host)]" : server.host
        // SFTP scp paths are literal for uploads; escape glob syntax for downloads.
        let path = upload ? remote : Self.escapeRemoteGlob(remote)
        let remoteArgument = "\(server.username)@\(host):\(path)"
        let paths = upload ? [local, remoteArgument] : [remoteArgument, local]
        let output = try await ProcessRunner.run("/usr/bin/scp", arguments: options + ["--"] + paths,
                                                environment: invocation.environment, timeout: 3_600)
        guard output.status == 0 else {
            if output.status == 255 { throw SSHError.classify(stderr: output.stderr) }
            throw RemoteFileError.transferFailed(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func scpOptions(from sshArguments: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < sshArguments.count {
            let value = sshArguments[index]
            if value == "--" { break }
            if value == "-l" { index += 2; continue }
            if value == "-T" || value == "-tt" { index += 1; continue }
            result.append(value == "-p" ? "-P" : value)
            index += 1
        }
        return result
    }

    static func escapeRemoteGlob(_ path: String) -> String {
        path.reduce(into: "") { result, character in
            if "\\*?[]".contains(character) { result.append("\\") }
            result.append(character)
        }
    }
}
