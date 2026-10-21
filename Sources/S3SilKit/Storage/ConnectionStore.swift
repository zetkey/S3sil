import Foundation

public enum ConnectionStoreError: Error, LocalizedError {
    case unreadable(URL, String)
    case writeFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(url, detail):
            return "Could not read \(url.lastPathComponent): \(detail)"
        case let .writeFailed(url, detail):
            return "Could not save \(url.lastPathComponent): \(detail)"
        }
    }
}

/// Persists connection profiles (never credentials) as JSON in Application Support.
public struct ConnectionStore: Sendable {
    public let fileURL: URL

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("profiles.json", isDirectory: false)
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("S3Sil", isDirectory: true)
    }

    public static func defaultStore() -> ConnectionStore {
        ConnectionStore(directory: defaultDirectory)
    }

    public func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([ConnectionProfile].self, from: data)
        } catch {
            throw ConnectionStoreError.unreadable(fileURL, error.localizedDescription)
        }
    }

    public func save(_ profiles: [ConnectionProfile]) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(profiles)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw ConnectionStoreError.writeFailed(fileURL, error.localizedDescription)
        }
    }

    /// Moves an unreadable profiles file aside so a new save cannot destroy it.
    public func backUpCorruptedFile(now: Date = Date()) throws -> URL? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let stamp = AWSSigV4.amzDate(now).replacingOccurrences(of: ":", with: "-")
        let backup = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("profiles.unreadable-\(stamp).json")
        try FileManager.default.moveItem(at: fileURL, to: backup)
        return backup
    }
}
