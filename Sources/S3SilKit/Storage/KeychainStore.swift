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

    /// All credentials live in a single generic-password item under this account,
    /// so macOS prompts for Keychain access at most once per launch.
    static let consolidatedAccount = "all-profiles"

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
    }

    private static func itemQuery(account: String) -> [String: Any] {
        var query = baseQuery()
        query[kSecAttrAccount as String] = account
        return query
    }

    // MARK: - Public API

    /// Reads the consolidated credential dictionary and, on first call, migrates
    /// any legacy per-profile items into the single item.
    public static func loadAll() throws -> [UUID: S3Credentials] {
        var existing: [String: S3Credentials] = [:]
        if let data = try readItemData(account: consolidatedAccount) {
            existing = try JSONDecoder().decode([String: S3Credentials].self, from: data)
        }

        var strays: [(profileID: String, credentials: S3Credentials)] = []
        for account in try legacyAccounts() {
            guard let data = try readItemData(account: account),
                  let credentials = try? JSONDecoder().decode(S3Credentials.self, from: data) else { continue }
            strays.append((profileID: account, credentials: credentials))
        }

        let merged = merge(existing: existing, strays: strays)
        if merged != existing {
            try writeConsolidated(merged)
        }
        for stray in strays {
            try? deleteItem(account: stray.profileID)
        }
        return uuidDict(from: merged)
    }

    public static func save(_ credentials: S3Credentials, profileID: UUID) throws {
        var dict = try loadAll()
        dict[profileID] = credentials
        try writeConsolidated(stringDict(from: dict))
    }

    public static func delete(profileID: UUID) throws {
        var dict = try loadAll()
        dict.removeValue(forKey: profileID)
        if dict.isEmpty {
            try deleteItem(account: consolidatedAccount)
        } else {
            try writeConsolidated(stringDict(from: dict))
        }
    }

    /// Pure merge of a consolidated dictionary with stray per-profile items.
    /// Existing values win on collision; non-UUID accounts are ignored.
    static func merge(
        existing: [String: S3Credentials],
        strays: [(profileID: String, credentials: S3Credentials)]
    ) -> [String: S3Credentials] {
        var merged = existing
        for stray in strays {
            guard UUID(uuidString: stray.profileID) != nil else { continue }
            merged[stray.profileID] = merged[stray.profileID] ?? stray.credentials
        }
        return merged
    }

    // MARK: - Keychain plumbing

    private static func readItemData(account: String) throws -> Data? {
        var query = itemQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status, "read") }
        return result as? Data
    }

    /// Attributes-only enumeration of every stored account. Never combined with
    /// `kSecReturnData` — macOS rejects that pairing with `kSecMatchLimitAll`.
    private static func legacyAccounts() throws -> [String] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.status(status, "read") }

        guard let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String else { return nil }
            guard UUID(uuidString: account) != nil, account != consolidatedAccount else { return nil }
            return account
        }
    }

    private static func writeConsolidated(_ dict: [String: S3Credentials]) throws {
        let data = try JSONEncoder().encode(dict)
        let query = itemQuery(account: consolidatedAccount)
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            }
        }

        guard status == errSecSuccess else {
            throw KeychainError.status(status, "save")
        }
    }

    private static func deleteItem(account: String) throws {
        let status = SecItemDelete(itemQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status, "delete")
        }
    }

    // MARK: - Key conversion

    private static func uuidDict(from stringDict: [String: S3Credentials]) -> [UUID: S3Credentials] {
        var out: [UUID: S3Credentials] = [:]
        for (key, value) in stringDict {
            if let uuid = UUID(uuidString: key) {
                out[uuid] = value
            }
        }
        return out
    }

    private static func stringDict(from uuidDict: [UUID: S3Credentials]) -> [String: S3Credentials] {
        var out: [String: S3Credentials] = [:]
        for (uuid, value) in uuidDict {
            out[uuid.uuidString] = value
        }
        return out
    }
}