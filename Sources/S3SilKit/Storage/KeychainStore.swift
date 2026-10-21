import Foundation
import Security

public enum KeychainError: Error, LocalizedError, Equatable {
    case status(OSStatus, String)

    public var errorDescription: String? {
        switch self {
        case let .status(status, operation):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
            return "Keychain \(operation) failed: \(message)"
        }
    }
}

public enum KeychainStore {
    public static let service = "com.s3sil.credentials"

    private static func baseQuery(profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
    }

    public static func save(_ credentials: S3Credentials, profileID: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        var query = baseQuery(profileID: profileID)
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(
                    baseQuery(profileID: profileID) as CFDictionary,
                    attributes as CFDictionary
                )
            }
        }

        guard status == errSecSuccess else {
            throw KeychainError.status(status, "save")
        }
    }

    public static func load(profileID: UUID) throws -> S3Credentials? {
        var query = baseQuery(profileID: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.status(status, "read")
        }
        return try JSONDecoder().decode(S3Credentials.self, from: data)
    }

    public static func delete(profileID: UUID) throws {
        let status = SecItemDelete(baseQuery(profileID: profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status, "delete")
        }
    }
}
