import Foundation
import Testing
@testable import S3SilKit

/// Optional end-to-end check against a local MinIO server. Enable with
/// S3SIL_MINIO_TEST=1; scripts/smoke-minio.sh does this automatically.
@Suite("MinIOIntegration", .enabled(if: ProcessInfo.processInfo.environment["S3SIL_MINIO_TEST"] == "1"))
struct MinIOIntegrationTests {
    @Test("list, put, get, presign, delete")
    func roundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        let endpoint = try #require(environment["S3SIL_MINIO_ENDPOINT"])
        let bucket = try #require(environment["S3SIL_MINIO_BUCKET"])
        let credentials = S3Credentials(
            accessKeyID: try #require(environment["S3SIL_MINIO_ACCESS_KEY"]),
            secretAccessKey: try #require(environment["S3SIL_MINIO_SECRET_KEY"])
        )
        let profile = ConnectionProfile(
            name: "MinIO Smoke",
            provider: .minio,
            endpoint: endpoint,
            region: "us-east-1"
        )
        let client = try S3Client(profile: profile, credentials: credentials)
        let key = "smoke/\(UUID().uuidString).txt"
        let payload = Data("hello from S3Sil".utf8)

        let buckets = try await client.listBuckets()
        #expect(buckets.contains { $0.name == bucket })

        try await client.putObject(bucket: bucket, key: key, data: payload, contentType: "text/plain")

        let listing = try await client.listObjects(bucket: bucket, prefix: "smoke/")
        #expect(listing.objects.contains { $0.key == key && $0.size == Int64(payload.count) })

        let presigned = try await client.presignedURL(bucket: bucket, key: key, expires: 300)
        let (presignedBody, presignedResponse) = try await URLSession.shared.data(from: presigned)
        #expect((presignedResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(presignedBody == payload)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("s3sil-minio-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: destination) }
        try await client.download(bucket: bucket, key: key, to: destination)
        #expect(try Data(contentsOf: destination) == payload)

        let failures = try await client.deleteObjects(bucket: bucket, keys: [key])
        #expect(failures.isEmpty)

        let after = try await client.listObjects(bucket: bucket, prefix: key, delimiter: nil)
        #expect(!after.objects.contains { $0.key == key })
    }
}
