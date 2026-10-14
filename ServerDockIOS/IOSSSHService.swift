import Citadel
import Crypto
import Foundation
import NIO
import NIOSSH
import Security

enum MobileConnectionError: LocalizedError {
    case missingPassword, missingKey, unsupportedKey, changedHostKey, invalidPath
    var errorDescription: String? {
        switch self {
        case .missingPassword: "请编辑服务器并保存 SSH 密码。"
        case .missingKey: "请编辑服务器并导入 OpenSSH 私钥。Mac 上的密钥不会自动传到 iPhone。"
        case .unsupportedKey: "支持 RSA / Ed25519 OpenSSH 私钥，以及未加密的 RSA PEM。请检查密钥格式和密码，或选择密码认证。"
        case .changedHostKey: "服务器的 SSH 主机密钥已改变，连接已停止。请向服务器管理员核实，确认后在设置中重置主机信任。"
        case .invalidPath: "文件路径无效。"
        }
    }
}

struct HostKeyApproval: Identifiable, Error, LocalizedError, Sendable {
    let server: Server
    let publicKey: String
    let fingerprint: String
    var id: UUID { server.id }
    var errorDescription: String? { "首次连接，需要确认 SSH 主机指纹。" }
}

/// Private key text stays in this app's Keychain, never in servers.json.
enum MobileKeyStore {
    static func key(for id: UUID) throws -> String? {
        var query = base(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data,
              let text = String(data: data, encoding: .utf8) else { throw KeychainError.status(status) }
        return text
    }

    static func save(_ text: String, for id: UUID) throws {
        let query = base(id)
        let data = Data(text.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError.status(added) }
        } else if status != errSecSuccess { throw KeychainError.status(status) }
    }

    static func delete(_ id: UUID) throws {
        let status = SecItemDelete(base(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    private static func base(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: AppEnvironment.keychainService + ".privatekeys",
         kSecAttrAccount as String: id.uuidString,
         kSecAttrSynchronizable as String: false]
    }
}

private final class PinnedHostValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let server: Server
    private let lock = NSLock()
    private var pending: HostKeyApproval?
    var approval: HostKeyApproval? { lock.lock(); defer { lock.unlock() }; return pending }

    init(server: Server) { self.server = server }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        let pinned = UserDefaults.standard.string(forKey: Self.preferenceKey(server))
        if let pinned {
            if pinned == key { validationCompletePromise.succeed(()) }
            else { validationCompletePromise.fail(MobileConnectionError.changedHostKey) }
            return
        }
        let parts = key.split(separator: " ")
        guard parts.count >= 2, let bytes = Data(base64Encoded: String(parts[1])) else {
            validationCompletePromise.fail(MobileConnectionError.changedHostKey)
            return
        }
        let digest = Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let challenge = HostKeyApproval(server: server, publicKey: key, fingerprint: "SHA256:" + digest)
        lock.lock(); pending = challenge; lock.unlock()
        validationCompletePromise.fail(challenge)
    }

    static func preferenceKey(_ server: Server) -> String { "ssh.hostkey.\(server.host):\(server.port)" }
}

/// Native TCP SSH: no subprocess, Mac dependency, or permissive host-key validator.
struct IOSSSHService: Sendable {
    let keychain = KeychainStore()

    static func trust(_ approval: HostKeyApproval) {
        UserDefaults.standard.set(approval.publicKey, forKey: PinnedHostValidator.preferenceKey(approval.server))
    }
    static func forgetTrust(_ server: Server) {
        UserDefaults.standard.removeObject(forKey: PinnedHostValidator.preferenceKey(server))
    }

    func authentication(for server: Server) throws -> SSHAuthenticationMethod {
        if server.authentication == .password {
            guard let password = try keychain.read(for: server.id, kind: .sshPassword), !password.isEmpty else {
                throw MobileConnectionError.missingPassword
            }
            return .passwordBased(username: server.username, password: password)
        }
        guard let text = try MobileKeyStore.key(for: server.id), !text.isEmpty else { throw MobileConnectionError.missingKey }
        let password = try keychain.read(for: server.id, kind: .privateKeyPassphrase)
        return try Self.keyAuthentication(text, username: server.username, passphrase: password)
    }

    static func keyAuthentication(_ text: String, username: String, passphrase: String?) throws -> SSHAuthenticationMethod {
        let text = try RSAPEMImport.openSSH(text)
        let decryption = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        guard text.contains("BEGIN OPENSSH PRIVATE KEY") else { throw MobileConnectionError.unsupportedKey }
        if let ed25519 = try? Curve25519.Signing.PrivateKey(sshEd25519: text, decryptionKey: decryption) {
            return .ed25519(username: username, privateKey: ed25519)
        }
        if let rsa = try? Insecure.RSA.PrivateKey(sshRsa: text, decryptionKey: decryption) {
            return .rsa(username: username, privateKey: rsa)
        }
        throw MobileConnectionError.unsupportedKey
    }

    private func connect(_ server: Server) async throws -> SSHClient {
        try Task.checkCancellation()
        let authentication = try authentication(for: server)
        let validator = PinnedHostValidator(server: server)
        var settings = SSHClientSettings(host: server.host, port: server.port,
            authenticationMethod: { authentication }, hostKeyValidator: .custom(validator))
        settings.connectTimeout = .seconds(20)
        do { return try await SSHClient.connect(to: settings) }
        catch { if let approval = validator.approval { throw approval }; throw error }
    }

    func execute(_ command: String, on server: Server, outputLimit: Int = 2_000_000) async throws -> String {
        let client = try await connect(server)
        let deadline = Task { try await Task.sleep(for: .seconds(30)); try? await client.close() }
        defer { deadline.cancel() }
        do {
            let output = try await withTaskCancellationHandler {
                try await client.executeCommand(command, maxResponseSize: outputLimit)
            } onCancel: { Task { try? await client.close() } }
            try? await client.close()
            try Task.checkCancellation()
            return String(decoding: output.readableBytesView, as: UTF8.self)
        } catch { try? await client.close(); try Task.checkCancellation(); throw error }
    }

    func directory(_ path: String, on server: Server) async throws -> RemoteDirectoryListing {
        let client = try await connect(server)
        let deadline = Task { try await Task.sleep(for: .seconds(30)); try? await client.close() }
        defer { deadline.cancel() }
        do {
            return try await withTaskCancellationHandler {
            let sftp = try await client.openSFTP()
            let actual = try await sftp.getRealPath(atPath: path)
            let groups = try await sftp.listDirectory(atPath: actual)
            let entries = try groups.flatMap(\.components).filter { $0.filename != "." && $0.filename != ".." }.map { item in
                let mode = (item.attributes.permissions ?? 0) & 0o170000
                let kind: RemoteFileKind = mode == 0o040000 ? .directory : mode == 0o120000 ? .symbolicLink : mode == 0o100000 ? .file : .other
                return RemoteFileEntry(name: item.filename, path: try RemoteFileCommands.join(directory: actual, name: item.filename),
                    kind: kind, size: item.attributes.size ?? 0, modifiedAt: item.attributes.accessModificationTime?.modificationTime)
            }.sorted { lhs, rhs in
                if (lhs.kind == .directory) != (rhs.kind == .directory) { return lhs.kind == .directory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            try await sftp.close(); try? await client.close()
            return RemoteDirectoryListing(path: actual, entries: entries)
            } onCancel: { Task { try? await client.close() } }
        } catch { try? await client.close(); try Task.checkCancellation(); throw error }
    }

    func upload(_ localURL: URL, directory: String, on server: Server) async throws {
        let destination = try RemoteFileCommands.join(directory: directory, name: localURL.lastPathComponent)
        let temporary = try RemoteFileCommands.join(directory: directory, name: ".serverdock-upload-\(UUID().uuidString).part")
        let access = localURL.startAccessingSecurityScopedResource()
        defer { if access { localURL.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        let client = try await connect(server)
        let deadline = Task { try await Task.sleep(for: .seconds(180)); try? await client.close() }
        defer { deadline.cancel() }
        do {
            try await withTaskCancellationHandler {
            let sftp = try await client.openSFTP()
            // Publish only a complete file. Hard-link creation atomically rejects an
            // existing destination, even a symlink, without exposing a partial upload.
            try await sftp.withFile(filePath: temporary, flags: [.write, .create, .forceCreate]) { file in
                var offset: UInt64 = 0
                while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
                    try Task.checkCancellation()
                    try await file.write(ByteBuffer(bytes: data), at: offset)
                    offset += UInt64(data.count)
                }
            }
            try Task.checkCancellation()
            _ = try await client.executeCommand("ln -T -- \(RemoteFileCommands.quote(temporary)) \(RemoteFileCommands.quote(destination)) && rm -f -- \(RemoteFileCommands.quote(temporary))", maxResponseSize: 8_192)
            try await sftp.close(); try? await client.close()
            } onCancel: { Task { try? await client.close() } }
        } catch {
            try? await client.close()
            await removePartialUpload(temporary, from: server)
            try Task.checkCancellation()
            throw error
        }
    }

    private func removePartialUpload(_ path: String, from server: Server) async {
        // Cancellation and the transfer deadline close the original connection.
        // A fresh, bounded connection can still remove our exact temporary file.
        await Task.detached {
            guard let client = try? await connect(server) else { return }
            let deadline = Task { try await Task.sleep(for: .seconds(10)); try? await client.close() }
            defer { deadline.cancel() }
            if let sftp = try? await client.openSFTP() {
                try? await sftp.remove(at: path)
                try? await sftp.close()
            }
            try? await client.close()
        }.value
    }

    func download(_ entry: RemoteFileEntry, on server: Server) async throws -> URL {
        guard entry.kind == .file else { throw MobileConnectionError.invalidPath }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent((entry.name as NSString).lastPathComponent)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: folder) } }
        let client = try await connect(server)
        let deadline = Task { try await Task.sleep(for: .seconds(180)); try? await client.close() }
        defer { deadline.cancel() }
        do {
            try await withTaskCancellationHandler {
            let sftp = try await client.openSFTP()
            try await sftp.withFile(filePath: entry.path, flags: .read) { file in
                var offset: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    let chunk = try await file.read(from: offset, length: 65_536)
                    if chunk.readableBytes == 0 { break }
                    try handle.write(contentsOf: Data(chunk.readableBytesView))
                    offset += UInt64(chunk.readableBytes)
                }
            }
            try await sftp.close(); try? await client.close()
            } onCancel: { Task { try? await client.close() } }
            try Task.checkCancellation()
            completed = true
            return url
        } catch { try? await client.close(); try Task.checkCancellation(); throw error }
    }
}
