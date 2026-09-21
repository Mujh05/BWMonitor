import Foundation
import Security

public enum SecretKind: String, CaseIterable, Sendable {
    case kiwiAPIKey
    case sshPassword
    case privateKeyPassphrase
    /// Values typed in the server editor but not saved yet. They exist only
    /// while a connection test or key installation runs.
    case pendingPassword
    case pendingPassphrase

    /// Secrets that OpenSSH may request through the askpass helper.
    public var isAskpassSecret: Bool {
        switch self {
        case .sshPassword, .privateKeyPassphrase, .pendingPassword, .pendingPassphrase: true
        case .kiwiAPIKey: false
        }
    }
}

public enum KeychainError: LocalizedError {
    case unexpectedData
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unexpectedData:
            NSLocalizedString(
                "The Keychain returned data in an unexpected format.",
                comment: "Keychain data error"
            )
        case let .status(status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? String(format: NSLocalizedString("Keychain error %d", comment: "Keychain status error"), status)
        }
    }
}

public final class KeychainStore: @unchecked Sendable {
    private let service: String

    public init(service: String = AppEnvironment.keychainService) {
        self.service = service
    }

    public func save(_ value: String, for serverID: UUID, kind: SecretKind) throws {
        let data = Data(value.utf8)
        let query = baseQuery(Self.account(serverID, kind))
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.status(updateStatus)
        }
    }

    public func read(for serverID: UUID, kind: SecretKind) throws -> String? {
        try read(account: Self.account(serverID, kind))
    }

    public func read(account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return value
    }

    /// Checks for an item without reading its value, so it never prompts.
    public func contains(_ serverID: UUID, kind: SecretKind) -> Bool {
        var query = baseQuery(Self.account(serverID, kind))
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    public func delete(_ serverID: UUID, kind: SecretKind) throws {
        let status = SecItemDelete(baseQuery(Self.account(serverID, kind)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    public func deleteSecrets(for serverID: UUID) throws {
        for kind in SecretKind.allCases {
            try delete(serverID, kind: kind)
        }
    }

    /// Deletes every item of the given kinds, whatever server it belongs to.
    public func deleteAll(of kinds: Set<SecretKind>) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        query[kSecAttrSynchronizable as String] = false
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let parsed = Self.parse(account: account),
                  kinds.contains(parsed.kind) else { continue }
            try? delete(parsed.serverID, kind: parsed.kind)
        }
    }

    public static func account(_ serverID: UUID, _ kind: SecretKind) -> String {
        "\(serverID.uuidString).\(kind.rawValue)"
    }

    /// Splits an account name back into its server and kind.
    public static func parse(account: String) -> (serverID: UUID, kind: SecretKind)? {
        let parts = account.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[0]), let kind = SecretKind(rawValue: parts[1]) else {
            return nil
        }
        return (id, kind)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}
