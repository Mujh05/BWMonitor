import Foundation
import Security

public enum SecretKind: String, Sendable {
    case kiwiAPIKey
    case sshPassword
    case privateKeyPassphrase
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

    public init(service: String = "com.mujh.BWMonitor.credentials") {
        self.service = service
    }

    public func save(_ value: String, for serverID: UUID, kind: SecretKind) throws {
        let account = account(serverID, kind)
        let data = Data(value.utf8)
        let query = baseQuery(account)
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
        var query = baseQuery(account(serverID, kind))
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

    public func deleteSecrets(for serverID: UUID) throws {
        for kind in [SecretKind.kiwiAPIKey, .sshPassword, .privateKeyPassphrase] {
            let status = SecItemDelete(baseQuery(account(serverID, kind)) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.status(status)
            }
        }
    }

    private func account(_ serverID: UUID, _ kind: SecretKind) -> String {
        "\(serverID.uuidString).\(kind.rawValue)"
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
