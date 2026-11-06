import Foundation

/// Adapts an S3Client + bucket to the StorageBackend protocol.
public struct S3BucketBackend: StorageBackend, Sendable {
    public let container: String
    public let capabilities: StorageCapabilities = .s3

    public let client: S3Client
    private let bucket: String

    public init(client: S3Client, bucket: String) {
        self.client = client
        self.bucket = bucket
        self.container = bucket
    }

    public func list(prefix: String, maxKeys: Int) async throws -> ObjectListing {
        try await client.listObjects(bucket: bucket, prefix: prefix, maxKeys: maxKeys)
    }

    public func createFolder(_ key: String) async throws {
        try await client.createFolder(bucket: bucket, key: key)
    }

    public func delete(_ keys: [String],
                       status: @escaping @Sendable (String) -> Void) async throws {
        guard !keys.isEmpty else { return }

        let fileKeys = keys.filter { !$0.hasSuffix("/") }
        let folderKeys = keys.filter { $0.hasSuffix("/") }

        if !fileKeys.isEmpty {
            status("Deleting \(fileKeys.count) object\(fileKeys.count == 1 ? "" : "s")…")
            try await deleteKeys(fileKeys)
        }

        for folder in folderKeys {
            status("Listing \(folder)…")
            let nested = try await allKeys(under: folder)
            if !nested.isEmpty {
                status("Deleting \(nested.count) item\(nested.count == 1 ? "" : "s") in \(folder)…")
                try await deleteKeys(nested)
            }
        }
    }

    public func download(key: String, to destination: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await client.download(bucket: bucket, key: key, to: destination, progress: progress)
    }

    public func upload(fileURL: URL, key: String,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await client.uploadFile(fileURL: fileURL, bucket: bucket, key: key, progress: progress)
    }

    /// Generates a presigned URL for S3 object download (S3 only).
    public func presignedURL(key: String, expires: Int = 3600) async throws -> URL {
        try await client.presignedURL(bucket: bucket, key: key, expires: expires)
    }

    // MARK: - Private

    private func allKeys(under folderPrefix: String) async throws -> [String] {
        var keys: [String] = []
        var token: String?
        while true {
            let page = try await client.listObjects(
                bucket: bucket,
                prefix: folderPrefix,
                delimiter: nil,
                continuationToken: token,
                maxKeys: 1000
            )
            keys.append(contentsOf: page.objects.map(\.key))
            guard page.isTruncated, let next = page.nextToken, next != token else { break }
            token = next
        }
        return keys
    }

    private func deleteKeys(_ keys: [String]) async throws {
        guard !keys.isEmpty else { return }
        let chunks = stride(from: 0, to: keys.count, by: 1000).map {
            Array(keys[$0..<min($0 + 1000, keys.count)])
        }
        let width = min(4, chunks.count)
        var failures: [DeleteFailure] = []

        try await withThrowingTaskGroup(of: [DeleteFailure].self) { group in
            var next = 0
            while next < width {
                let chunk = chunks[next]
                group.addTask { [client, bucket] in
                    try await client.deleteObjects(bucket: bucket, keys: chunk)
                }
                next += 1
            }
            while let result = try await group.next() {
                failures.append(contentsOf: result)
                if next < chunks.count {
                    let chunk = chunks[next]
                    group.addTask { [client, bucket] in
                        try await client.deleteObjects(bucket: bucket, keys: chunk)
                    }
                    next += 1
                }
            }
        }

        if let first = failures.first {
            throw S3Error(
                code: first.code,
                message: "\(failures.count) of \(keys.count) objects could not be deleted. " +
                    "\(first.key): \(first.message)"
            )
        }
    }
}