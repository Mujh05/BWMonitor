import CryptoKit
import Foundation
import SystemConfiguration

/// What BWMonitor knows about a private key file without decrypting it.
public struct SSHKeyInfo: Equatable, Hashable, Identifiable, Sendable {
    public var path: String
    /// Key algorithm, for example `ssh-ed25519`. Empty when unknown.
    public var algorithm: String
    /// The `authorized_keys` line, when the public key is known.
    public var publicKey: String?
    public var fingerprint: String?
    public var isEncrypted: Bool
    public var comment: String

    public var id: String { path }

    public var displayAlgorithm: String {
        switch algorithm {
        case "ssh-ed25519": "ED25519"
        case "ssh-rsa": "RSA"
        case "ssh-dss": "DSA"
        case let value where value.hasPrefix("ecdsa-"): "ECDSA"
        case let value where value.hasPrefix("sk-"): NSLocalizedString("Security key", comment: "SSH key type")
        case "": NSLocalizedString("Unknown type", comment: "SSH key type")
        default: algorithm
        }
    }

    public var displayPath: String {
        NSString(string: path).abbreviatingWithTildeInPath
    }
}

public enum SSHKeyError: LocalizedError, Equatable {
    case notFound(String)
    case notAPrivateKey
    case publicKeyFile
    case puttyFormat
    case alreadyExists(String)
    case generationFailed(String)
    case publicKeyUnavailable
    case incorrectPassphrase

    public var errorDescription: String? {
        switch self {
        case let .notFound(path):
            String(
                format: NSLocalizedString("The private key file %@ was not found.", comment: "SSH key error"),
                NSString(string: path).abbreviatingWithTildeInPath
            )
        case .notAPrivateKey:
            NSLocalizedString("This is not an SSH private key.", comment: "SSH key error")
        case .publicKeyFile:
            NSLocalizedString(
                "This is a public key. Choose the matching private key (the file without “.pub”).",
                comment: "SSH key error"
            )
        case .puttyFormat:
            NSLocalizedString(
                "PuTTY keys (.ppk) are not supported. Export the key in OpenSSH format with PuTTYgen first.",
                comment: "SSH key error"
            )
        case let .alreadyExists(path):
            String(
                format: NSLocalizedString("A key already exists at %@.", comment: "SSH key error"),
                NSString(string: path).abbreviatingWithTildeInPath
            )
        case let .generationFailed(message):
            String(format: NSLocalizedString("The key could not be created: %@", comment: "SSH key error"), message)
        case .publicKeyUnavailable:
            NSLocalizedString(
                "The public key for this private key could not be read.",
                comment: "SSH key error"
            )
        case .incorrectPassphrase:
            NSLocalizedString("The passphrase for this key is incorrect.", comment: "SSH key error")
        }
    }
}

public enum SSHKeyInspector {
    /// Reads a private key file. For OpenSSH-format keys the public key is
    /// stored unencrypted inside the file, so no passphrase is needed.
    public static func inspect(path: String) throws -> SSHKeyInfo {
        let expanded = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { throw SSHKeyError.notFound(path) }
        let attributes = try? FileManager.default.attributesOfItem(atPath: expanded)
        if let size = attributes?[.size] as? Int, size > 256 * 1_024 { throw SSHKeyError.notAPrivateKey }
        guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            throw SSHKeyError.notAPrivateKey
        }
        let publicText = try? String(contentsOfFile: expanded + ".pub", encoding: .utf8)
        return try inspect(privateKeyText: text, path: expanded, publicKeyText: publicText)
    }

    static func inspect(privateKeyText text: String, path: String, publicKeyText: String?) throws -> SSHKeyInfo {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("PuTTY-User-Key-File-") { throw SSHKeyError.puttyFormat }
        if parsePublicKeyLine(trimmed) != nil { throw SSHKeyError.publicKeyFile }

        if let openSSH = parseOpenSSHPrivateKey(trimmed) {
            let algorithm = algorithmName(inPublicBlob: openSSH.publicBlob) ?? ""
            let comment = publicKeyText.flatMap(parsePublicKeyLine)?.comment ?? ""
            return SSHKeyInfo(
                path: path,
                algorithm: algorithm,
                publicKey: authorizedKeysLine(algorithm: algorithm, blob: openSSH.publicBlob, comment: comment),
                fingerprint: fingerprint(ofPublicBlob: openSSH.publicBlob),
                isEncrypted: openSSH.cipher != "none",
                comment: comment
            )
        }

        guard let label = pemLabel(trimmed), label.hasSuffix("PRIVATE KEY") else {
            throw SSHKeyError.notAPrivateKey
        }
        let isEncrypted = label == "ENCRYPTED PRIVATE KEY" || trimmed.contains("Proc-Type: 4,ENCRYPTED")
        var info = SSHKeyInfo(
            path: path,
            algorithm: legacyAlgorithm(forLabel: label),
            publicKey: nil,
            fingerprint: nil,
            isEncrypted: isEncrypted,
            comment: ""
        )
        if let publicKeyText, let parsed = parsePublicKeyLine(publicKeyText) {
            info.algorithm = parsed.algorithm
            info.publicKey = authorizedKeysLine(algorithm: parsed.algorithm, blob: parsed.blob, comment: parsed.comment)
            info.fingerprint = fingerprint(ofPublicBlob: parsed.blob)
            info.comment = parsed.comment
        }
        return info
    }

    /// Private keys in `~/.ssh`, with the usual default key names first.
    public static func discoverKeys(
        in directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    ) -> [SSHKeyInfo] {
        let skipped: Set<String> = ["config", "known_hosts", "authorized_keys", "authorized_keys2", "environment", "rc"]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let preferred = ["id_ed25519", "id_ecdsa", "id_rsa"]
        return names
            .filter { name in
                !skipped.contains(name)
                    && !name.hasPrefix("known_hosts")
                    && !name.hasPrefix(".")
                    && !name.hasSuffix(".pub")
                    && !name.hasSuffix(".old")
            }
            .compactMap { name -> SSHKeyInfo? in
                let url = directory.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { return nil }
                return try? inspect(path: url.path)
            }
            .sorted { lhs, rhs in
                let left = preferred.firstIndex(of: URL(fileURLWithPath: lhs.path).lastPathComponent) ?? preferred.count
                let right = preferred.firstIndex(of: URL(fileURLWithPath: rhs.path).lastPathComponent) ?? preferred.count
                return left == right ? lhs.path < rhs.path : left < right
            }
    }

    /// Whether the SSH agent holds this key, so ssh can use it without the
    /// passphrase.
    public static func isLoadedInAgent(_ key: SSHKeyInfo) async -> Bool {
        guard let publicKey = key.publicKey, let blob = parsePublicKeyLine(publicKey)?.blob,
              let output = try? await ProcessRunner.run("/usr/bin/ssh-add", arguments: ["-L"], timeout: 5),
              output.status == 0 else {
            return false
        }
        return output.stdout.components(separatedBy: .newlines).contains { parsePublicKeyLine($0)?.blob == blob }
    }

    /// True when group or others can read the file; OpenSSH refuses such keys.
    public static func hasLoosePermissions(path: String) -> Bool {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let mode = (try? FileManager.default.attributesOfItem(atPath: expanded))?[.posixPermissions] as? Int else {
            return false
        }
        return mode & 0o077 != 0
    }

    public static func restrictPermissions(path: String) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: NSString(string: path).expandingTildeInPath
        )
    }

    /// `SHA256:…`, matching `ssh-keygen -l`.
    public static func fingerprint(ofPublicBlob blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Parses an `authorized_keys`-style line: `type base64 [comment]`.
    public static func parsePublicKeyLine(_ line: String) -> (algorithm: String, blob: Data, comment: String)? {
        let fields = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count >= 2,
              let blob = Data(base64Encoded: String(fields[1])),
              let algorithm = algorithmName(inPublicBlob: blob),
              algorithm == String(fields[0]) else {
            return nil
        }
        let comment = fields.count > 2 ? String(fields[2]).components(separatedBy: .newlines)[0] : ""
        return (algorithm, blob, comment)
    }

    static func authorizedKeysLine(algorithm: String, blob: Data, comment: String) -> String {
        let base = "\(algorithm) \(blob.base64EncodedString())"
        return comment.isEmpty ? base : "\(base) \(comment)"
    }

    static func parseOpenSSHPrivateKey(_ text: String) -> (cipher: String, publicBlob: Data)? {
        guard pemLabel(text) == "OPENSSH PRIVATE KEY",
              let data = Data(base64Encoded: pemBody(text), options: .ignoreUnknownCharacters) else {
            return nil
        }
        var reader = SSHWireReader(data)
        guard reader.consume(prefix: Data("openssh-key-v1\0".utf8)),
              let cipher = reader.readString(),
              reader.readString() != nil, // KDF name
              reader.readString() != nil, // KDF options
              let count = reader.readUInt32(), count >= 1,
              let publicBlob = reader.readString() else {
            return nil
        }
        return (String(decoding: cipher, as: UTF8.self), publicBlob)
    }

    static func algorithmName(inPublicBlob blob: Data) -> String? {
        var reader = SSHWireReader(blob)
        guard let name = reader.readString(), !name.isEmpty, name.count < 64 else { return nil }
        let value = String(decoding: name, as: UTF8.self)
        return value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-@.".contains($0)) }) ? value : nil
    }

    private static func pemLabel(_ text: String) -> String? {
        guard let line = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("-----BEGIN ") }),
              line.hasSuffix("-----") else {
            return nil
        }
        return String(line.dropFirst("-----BEGIN ".count).dropLast("-----".count))
    }

    private static func pemBody(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.contains(":") }
            .joined()
    }

    private static func legacyAlgorithm(forLabel label: String) -> String {
        switch label {
        case "RSA PRIVATE KEY": "ssh-rsa"
        case "DSA PRIVATE KEY": "ssh-dss"
        case "EC PRIVATE KEY": "ecdsa-sha2-nistp256"
        default: ""
        }
    }
}

/// Keys that BWMonitor creates and stores itself.
public struct SSHKeyStore: Sendable {
    public let directory: URL

    public init(directory: URL = AppEnvironment.supportDirectory.appendingPathComponent("Keys", isDirectory: true)) {
        self.directory = directory
    }

    /// The key BWMonitor generates for itself. Like a key in `~/.ssh`, it is a
    /// file only your user account can read.
    public var appKeyPath: String {
        directory.appendingPathComponent("id_ed25519").path
    }

    public func appKey() -> SSHKeyInfo? {
        try? SSHKeyInspector.inspect(path: appKeyPath)
    }

    public func generateAppKey() async throws -> SSHKeyInfo {
        try AppEnvironment.makePrivateDirectory(directory)
        return try await Self.generateKey(at: appKeyPath, comment: Self.defaultComment())
    }

    /// Saves a pasted private key under the Keys folder.
    public func importPrivateKey(_ text: String) throws -> SSHKeyInfo {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        _ = try SSHKeyInspector.inspect(privateKeyText: normalized, path: "", publicKeyText: nil)
        try AppEnvironment.makePrivateDirectory(directory)
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.omitted))
        var url = directory.appendingPathComponent("imported-\(stamp)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("imported-\(stamp)-\(suffix)")
            suffix += 1
        }
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data(normalized.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try SSHKeyInspector.inspect(path: url.path)
    }

    public static func generateKey(at path: String, comment: String) async throws -> SSHKeyInfo {
        guard !FileManager.default.fileExists(atPath: path) else { throw SSHKeyError.alreadyExists(path) }
        let output = try await ProcessRunner.run(
            "/usr/bin/ssh-keygen",
            arguments: ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", path],
            timeout: 20
        )
        guard output.status == 0 else {
            throw SSHKeyError.generationFailed(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        try SSHKeyInspector.restrictPermissions(path: path)
        return try SSHKeyInspector.inspect(path: path)
    }

    /// `BWMonitor@<local host name>`, limited to characters that are safe
    /// in an `authorized_keys` comment.
    public static func defaultComment() -> String {
        let host = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? ""
        let safe = String(host.unicodeScalars.filter {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "."
        }.map(Character.init))
        return safe.isEmpty ? "BWMonitor" : "BWMonitor@\(safe)"
    }
}

/// Reads SSH wire-format values (big-endian lengths, length-prefixed strings).
struct SSHWireReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func consume(prefix: Data) -> Bool {
        guard data.count - (offset - data.startIndex) >= prefix.count,
              data[offset..<(offset + prefix.count)] == prefix else {
            return false
        }
        offset += prefix.count
        return true
    }

    mutating func readUInt32() -> UInt32? {
        guard data.endIndex - offset >= 4 else { return nil }
        let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 4
        return value
    }

    mutating func readString() -> Data? {
        guard let length = readUInt32(), data.endIndex - offset >= Int(length) else { return nil }
        let value = data[offset..<(offset + Int(length))]
        offset += Int(length)
        return Data(value)
    }
}
