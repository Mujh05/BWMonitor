import Citadel
import Crypto
import NIO
import NIOSSH
import Security
import XCTest
@testable import ServerDock

/// A real loopback SSH/SFTP server with synthetic credentials and an isolated
/// temporary filesystem. It exercises iOS networking without reading Mac keys.
final class IOSSSHServiceTests: XCTestCase {
    func testHostVerificationAndLosslessExclusiveSFTP() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = FixtureFilesystem(root: root)
        let port = Int.random(in: 22_000...45_000)
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let host = try await SSHServer.host(host: "127.0.0.1", port: port, hostKeys: [hostKey],
            authenticationDelegate: FixtureAuthentication(), group: .singleton)
        host.enableExec(withDelegate: FixtureExec(filesystem: fixture))
        host.enableSFTP(withDelegate: fixture)
        defer { Task { try? await host.close() } }
        let server = Server(name: "Local integration fixture", host: "127.0.0.1", port: port,
                            username: "fixture", authentication: .password)
        let service = IOSSSHService()
        try service.keychain.save("synthetic-loopback-password", for: server.id, kind: .sshPassword)
        defer { try? service.keychain.deleteSecrets(for: server.id); IOSSSHService.forgetTrust(server) }

        do { _ = try await service.execute("fixture-echo", on: server); XCTFail("Untrusted host must be rejected") }
        catch let approval as HostKeyApproval {
            XCTAssertTrue(approval.fingerprint.hasPrefix("SHA256:"))
            IOSSSHService.trust(approval)
        }
        let output = try await service.execute("fixture-echo", on: server)
        XCTAssertEqual(output, "loopback-ssh-ok\n")
        let before = try await service.directory(".", on: server)
        XCTAssertEqual(before.path, "/fixture")
        XCTAssertTrue(before.entries.isEmpty)

        let inputFolder = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: inputFolder, withIntermediateDirectories: true)
        let file = inputFolder.appendingPathComponent("binary file '中文'.bin")
        let bytes = Data((0..<160_007).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: file)
        try await service.upload(file, directory: "/fixture", on: server)
        let uploaded = try await service.directory("/fixture", on: server)
        let entry = try XCTUnwrap(uploaded.entries.first { $0.name == file.lastPathComponent })
        XCTAssertEqual(entry.size, UInt64(bytes.count))
        let downloaded = try await service.download(entry, on: server)
        defer { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: downloaded), bytes)
        try Data("replacement-must-not-overwrite".utf8).write(to: file)
        do { try await service.upload(file, directory: "/fixture", on: server); XCTFail("Existing file must be preserved") }
        catch { /* Required: exclusive publish fails instead of overwriting. */ }
        let secondDownload = try await service.download(entry, on: server)
        defer { try? FileManager.default.removeItem(at: secondDownload.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: secondDownload), bytes)
        let after = try await service.directory("/fixture", on: server)
        XCTAssertFalse(after.entries.contains { $0.name.hasPrefix(".serverdock-upload-") })

        let wrongKey = NIOSSHPrivateKey(ed25519Key: .init())
        let mismatch = HostKeyApproval(server: server, publicKey: String(openSSHPublicKey: wrongKey.publicKey), fingerprint: "test")
        IOSSSHService.trust(mismatch)
        do { _ = try await service.execute("fixture-echo", on: server); XCTFail("Changed host key must be rejected") }
        catch MobileConnectionError.changedHostKey { }
    }

    func testRSAImportRejectsMalformedAndEncryptedPEM() {
        XCTAssertThrowsError(try RSAPEMImport.openSSH("-----BEGIN RSA PRIVATE KEY-----\nAA==\n-----END RSA PRIVATE KEY-----"))
        XCTAssertThrowsError(try RSAPEMImport.openSSH("-----BEGIN ENCRYPTED PRIVATE KEY-----\nAA==\n-----END ENCRYPTED PRIVATE KEY-----"))
    }

    func testUnencryptedRSAPEMImportsNativeKey() throws {
        var error: Unmanaged<CFError>?
        let key = try XCTUnwrap(SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048
        ] as CFDictionary, &error))
        let encoded = try XCTUnwrap(SecKeyCopyExternalRepresentation(key, &error)) as Data
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n" + encoded.base64EncodedString()
            + "\n-----END RSA PRIVATE KEY-----\n"
        let converted = try RSAPEMImport.openSSH(pem)
        XCTAssertTrue(converted.contains("BEGIN OPENSSH PRIVATE KEY"))
        XCTAssertNoThrow(try IOSSSHService.keyAuthentication(pem, username: "fixture", passphrase: nil))
    }

    func testCancelledUploadRemovesPartialFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = FixtureFilesystem(root: root, slowWrites: true)
        let port = Int.random(in: 22_000...45_000)
        let key = NIOSSHPrivateKey(ed25519Key: .init())
        let host = try await SSHServer.host(host: "127.0.0.1", port: port, hostKeys: [key],
            authenticationDelegate: FixtureAuthentication(), group: .singleton)
        host.enableExec(withDelegate: FixtureExec(filesystem: fixture))
        host.enableSFTP(withDelegate: fixture)
        defer { Task { try? await host.close() } }
        let server = Server(name: "Cancellation fixture", host: "127.0.0.1", port: port,
                            username: "fixture", authentication: .password)
        let service = IOSSSHService()
        try service.keychain.save("synthetic-loopback-password", for: server.id, kind: .sshPassword)
        IOSSSHService.trust(HostKeyApproval(server: server, publicKey: String(openSSHPublicKey: key.publicKey), fingerprint: "fixture"))
        defer { try? service.keychain.deleteSecrets(for: server.id); IOSSSHService.forgetTrust(server) }
        let input = root.appendingPathComponent("cancel.bin")
        try Data(repeating: 0x5a, count: 160_007).write(to: input)
        let upload = Task { try await service.upload(input, directory: "/fixture", on: server) }
        // Cancel only after the real SFTP server received the first partial write.
        for _ in 0..<100 {
            if await fixture.hasStartedWriting() { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let started = await fixture.hasStartedWriting()
        XCTAssertTrue(started)
        upload.cancel()
        do { try await upload.value; XCTFail("Cancelled transfer must fail") }
        catch is CancellationError { }
        let listing = try await service.directory("/fixture", on: server)
        XCTAssertTrue(listing.entries.isEmpty, "Cancellation must remove the temporary upload and never publish a destination")
    }
}

private struct FixtureAuthentication: NIOSSHServerUserAuthenticationDelegate {
    let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = [.password]
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .password(let value) = request.request,
           request.username == "fixture", value.password == "synthetic-loopback-password" { responsePromise.succeed(.success) }
        else { responsePromise.succeed(.failure) }
    }
}

private enum FixtureError: Error { case unsupported, outsideSandbox, exists }

private actor FixtureFilesystem: SFTPDelegate {
    let root: URL
    let slowWrites: Bool
    private var writingStarted = false
    init(root: URL, slowWrites: Bool = false) {
        self.root = root.appendingPathComponent("remote"); self.slowWrites = slowWrites
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }
    func hasStartedWriting() -> Bool { writingStarted }
    func delayWrite() async throws {
        writingStarted = true
        if slowWrites { try await Task.sleep(for: .seconds(2)) }
    }
    func url(_ path: String) throws -> URL {
        guard path == "/fixture" || path.hasPrefix("/fixture/") else { throw FixtureError.outsideSandbox }
        let relative = path == "/fixture" ? "" : String(path.dropFirst("/fixture/".count))
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { throw FixtureError.outsideSandbox }
        return candidate
    }
    func publish(from: String, to: String) throws {
        try FileManager.default.linkItem(at: url(from), to: url(to))
        try FileManager.default.removeItem(at: url(from))
    }
    func remove(_ path: String) throws { if FileManager.default.fileExists(atPath: try url(path).path) { try FileManager.default.removeItem(at: url(path)) } }
    func attributes(_ url: URL) throws -> SFTPFileAttributes {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        var result = SFTPFileAttributes(size: (values[.size] as? NSNumber)?.uint64Value)
        result.permissions = (values[.type] as? FileAttributeType) == .typeDirectory ? 0o040755 : 0o100644
        return result
    }
    func fileAttributes(atPath path: String, context: SSHContext) async throws -> SFTPFileAttributes { try attributes(url(path)) }
    func openFile(_ filePath: String, withAttributes: SFTPFileAttributes, flags: SFTPOpenFileFlags, context: SSHContext) async throws -> SFTPFileHandle {
        let target = try url(filePath)
        if flags.contains(.create) {
            if flags.contains(.forceCreate), FileManager.default.fileExists(atPath: target.path) { throw FixtureError.exists }
            FileManager.default.createFile(atPath: target.path, contents: nil)
        }
        return try FixtureFile(url: target, writing: flags.contains(.write), filesystem: self)
    }
    func realPath(for canonicalUrl: String, context: SSHContext) async throws -> [SFTPPathComponent] {
        let path = canonicalUrl == "." ? "/fixture" : canonicalUrl
        _ = try url(path)
        return [SFTPPathComponent(filename: path, longname: path, attributes: .none)]
    }
    func openDirectory(atPath path: String, context: SSHContext) async throws -> SFTPDirectoryHandle {
        let folder = try url(path)
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).map { item in
            SFTPFileListing(path: [SFTPPathComponent(filename: item.lastPathComponent, longname: item.lastPathComponent, attributes: try attributes(item))])
        }
        return FixtureDirectory(entries: entries)
    }
    func removeFile(_ path: String, context: SSHContext) async throws -> SFTPStatusCode { try remove(path); return .ok }
    func createDirectory(_ filePath: String, withAttributes: SFTPFileAttributes, context: SSHContext) async throws -> SFTPStatusCode { throw FixtureError.unsupported }
    func removeDirectory(_ filePath: String, context: SSHContext) async throws -> SFTPStatusCode { throw FixtureError.unsupported }
    func setFileAttributes(to attributes: SFTPFileAttributes, atPath path: String, context: SSHContext) async throws -> SFTPStatusCode { throw FixtureError.unsupported }
    func addSymlink(linkPath: String, targetPath: String, context: SSHContext) async throws -> SFTPStatusCode { throw FixtureError.unsupported }
    func readSymlink(atPath path: String, context: SSHContext) async throws -> [SFTPPathComponent] { throw FixtureError.unsupported }
    func rename(oldPath: String, newPath: String, flags: UInt32, context: SSHContext) async throws -> SFTPStatusCode { throw FixtureError.unsupported }
}

private actor FixtureDirectory: SFTPDirectoryHandle {
    var entries: [SFTPFileListing]
    init(entries: [SFTPFileListing]) { self.entries = entries }
    func listFiles(context: SSHContext) async throws -> [SFTPFileListing] { defer { entries = [] }; return entries }
}

private actor FixtureFile: SFTPFileHandle {
    let handle: FileHandle
    let url: URL
    let filesystem: FixtureFilesystem
    init(url: URL, writing: Bool, filesystem: FixtureFilesystem) throws {
        self.url = url; self.filesystem = filesystem
        handle = try writing ? FileHandle(forWritingTo: url) : FileHandle(forReadingFrom: url)
    }
    func read(at offset: UInt64, length: UInt32) async throws -> ByteBuffer {
        try handle.seek(toOffset: offset)
        return ByteBuffer(bytes: try handle.read(upToCount: Int(length)) ?? Data())
    }
    func write(_ data: ByteBuffer, atOffset offset: UInt64) async throws -> SFTPStatusCode {
        try handle.seek(toOffset: offset); try handle.write(contentsOf: Data(data.readableBytesView))
        try await filesystem.delayWrite()
        return .ok
    }
    func close() async throws -> SFTPStatusCode { try handle.close(); return .ok }
    func readFileAttributes() async throws -> SFTPFileAttributes { SFTPFileAttributes(size: (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value) }
    func setFileAttributes(to attributes: SFTPFileAttributes) async throws { throw FixtureError.unsupported }
}

private final class FixtureExec: ExecDelegate, @unchecked Sendable {
    let filesystem: FixtureFilesystem
    init(filesystem: FixtureFilesystem) { self.filesystem = filesystem }
    func setEnvironmentValue(_ value: String, forKey key: String) async throws {}
    struct Context: ExecCommandContext { func terminate() async throws {} }
    func start(command: String, outputHandler: ExecOutputHandler) async throws -> ExecCommandContext {
        let parts = Self.words(command)
        var status = 0
        if command == "fixture-echo" {
            outputHandler.stdoutPipe.fileHandleForWriting.write(Data("loopback-ssh-ok\n".utf8))
        } else if parts.count >= 5, parts[0] == "ln" {
            do { try await filesystem.publish(from: parts[3], to: parts[4]) } catch { status = 1 }
        } else if parts.count >= 4, parts[0] == "rm" {
            do { try await filesystem.remove(parts[3]) } catch { status = 1 }
        } else { status = 127 }
        try? outputHandler.stdoutPipe.fileHandleForWriting.close()
        let exit = status
        // Give the actual NIO pipe channel time to drain before sending exit-status.
        Task { try? await Task.sleep(for: .milliseconds(100)); outputHandler.succeed(exitCode: exit) }
        return Context()
    }
    private static func words(_ text: String) -> [String] {
        var tokens: [String] = [], token = "", quoted = false, escaped = false
        for character in text {
            if escaped { token.append(character); escaped = false }
            else if character == "\\" && !quoted { escaped = true }
            else if character == "'" { quoted.toggle() }
            else if character.isWhitespace && !quoted { if !token.isEmpty { tokens.append(token); token = "" } }
            else { token.append(character) }
        }
        if !token.isEmpty { tokens.append(token) }
        return tokens
    }
}
