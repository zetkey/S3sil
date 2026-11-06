import Foundation

// MARK: - StorageCapabilities

public struct StorageCapabilities: Sendable, Equatable {
    public var supportsBuckets: Bool
    public var supportsPresignedURLs: Bool
    public var supportsACLs: Bool

    public init(supportsBuckets: Bool, supportsPresignedURLs: Bool, supportsACLs: Bool) {
        self.supportsBuckets = supportsBuckets
        self.supportsPresignedURLs = supportsPresignedURLs
        self.supportsACLs = supportsACLs
    }

    /// Standard S3 capabilities: everything on.
    public static let s3 = StorageCapabilities(
        supportsBuckets: true, supportsPresignedURLs: true, supportsACLs: true
    )

    /// No advanced features (WebDAV, FTP, SFTP).
    public static let none = StorageCapabilities(
        supportsBuckets: false, supportsPresignedURLs: false, supportsACLs: false
    )
}

// MARK: - StorageBackend

public protocol StorageBackend: Sendable {
    /// The logical container name (bucket for S3, empty string for flat backends).
    var container: String { get }
    var capabilities: StorageCapabilities { get }

    func list(prefix: String, maxKeys: Int) async throws -> ObjectListing
    func createFolder(_ key: String) async throws
    func delete(_ keys: [String], status: @escaping @Sendable (String) -> Void) async throws
    func download(key: String, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
    func upload(fileURL: URL, key: String,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
}