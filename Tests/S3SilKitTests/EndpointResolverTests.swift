import Foundation
import Testing
@testable import S3SilKit

@Test("AWS endpoint derives from region and uses virtual-hosted style")
func awsEndpoint() throws {
    let profile = ConnectionProfile(
        name: "AWS",
        provider: .aws,
        region: "eu-west-1"
    )
    let endpoint = try EndpointResolver.resolve(profile: profile)
    #expect(endpoint.scheme == "https")
    #expect(endpoint.host == "s3.eu-west-1.amazonaws.com")
    #expect(endpoint.port == nil)
    #expect(endpoint.pathStyle == false)
    #expect(endpoint.hostHeader(bucket: "my-bucket") == "my-bucket.s3.eu-west-1.amazonaws.com")
    #expect(endpoint.path(bucket: "my-bucket", key: "a b/c+d.txt") == "/a%20b/c%2Bd.txt")

    let url = try endpoint.url(bucket: "my-bucket", key: "a b/c+d.txt",
                               query: [("list-type", "2"), ("prefix", "a b/")])
    #expect(url.absoluteString == "https://my-bucket.s3.eu-west-1.amazonaws.com/a%20b/c%2Bd.txt?list-type=2&prefix=a%20b%2F")
}

@Test("R2 derives endpoint from account ID and forces path-style with region auto")
func r2Endpoint() throws {
    let profile = ConnectionProfile(
        name: "R2",
        provider: .cloudflareR2,
        region: "us-east-1",
        accountID: "0123456789abcdef",
        pathStyle: false
    )
    let endpoint = try EndpointResolver.resolve(profile: profile)
    #expect(endpoint.scheme == "https")
    #expect(endpoint.host == "0123456789abcdef.r2.cloudflarestorage.com")
    #expect(endpoint.region == "auto")
    #expect(endpoint.pathStyle == true)
    #expect(endpoint.hostHeader(bucket: "assets") == "0123456789abcdef.r2.cloudflarestorage.com")
    #expect(endpoint.path(bucket: "assets", key: "img/photo 1.jpg") == "/assets/img/photo%201.jpg")
}

@Test("MinIO defaults to http and path-style")
func minioEndpoint() throws {
    let profile = ConnectionProfile(
        name: "MinIO",
        provider: .minio,
        endpoint: "127.0.0.1:9000",
        region: "us-east-1"
    )
    let endpoint = try EndpointResolver.resolve(profile: profile)
    #expect(endpoint.scheme == "http")
    #expect(endpoint.host == "127.0.0.1")
    #expect(endpoint.port == 9000)
    #expect(endpoint.hostHeader() == "127.0.0.1:9000")
    #expect(endpoint.hostHeader(bucket: "photos") == "127.0.0.1:9000")
    #expect(endpoint.path(bucket: "photos", key: "folder/photo one.jpg") == "/photos/folder/photo%20one.jpg")

    let explicit = ConnectionProfile(
        name: "MinIO TLS",
        provider: .minio,
        endpoint: "https://minio.example.com:9443",
        region: "us-east-1"
    )
    let tls = try EndpointResolver.resolve(profile: explicit)
    #expect(tls.scheme == "https")
    #expect(tls.port == 9443)
}

@Test("Hitachi and generic endpoints honor base paths and addressing toggles")
func customEndpoints() throws {
    let hitachi = try EndpointResolver.resolve(profile: ConnectionProfile(
        name: "Hitachi",
        provider: .hitachi,
        endpoint: "https://hcp.example.com",
        region: ""
    ))
    #expect(hitachi.region == "us-east-1")
    #expect(hitachi.pathStyle == true)

    let generic = ConnectionProfile(
        name: "Generic",
        provider: .generic,
        endpoint: "https://s3.example.com:8443/gateway/",
        region: "eu-central-1",
        pathStyle: false
    )
    let endpoint = try EndpointResolver.resolve(profile: generic)
    #expect(endpoint.basePath == "/gateway")
    #expect(endpoint.hostHeader(bucket: "data") == "data.s3.example.com:8443")
    #expect(endpoint.path(bucket: "data", key: "x/y z.txt") == "/gateway/x/y%20z.txt")
    #expect(try endpoint.url(bucket: "data", key: "x.txt").absoluteString
            == "https://data.s3.example.com:8443/gateway/x.txt")
}

@Test("Invalid endpoint configurations are rejected")
func invalidEndpoints() {
    #expect(throws: S3Error.self) {
        try EndpointResolver.resolve(profile: ConnectionProfile(
            name: "R2", provider: .cloudflareR2, region: "auto", accountID: ""
        ))
    }
    #expect(throws: S3Error.self) {
        try EndpointResolver.resolve(profile: ConnectionProfile(
            name: "MinIO", provider: .minio, endpoint: "ftp://127.0.0.1:9000"
        ))
    }
    #expect(throws: S3Error.self) {
        try EndpointResolver.resolve(profile: ConnectionProfile(
            name: "Bad", provider: .generic, endpoint: "https://user:pass@example.com"
        ))
    }
    #expect(throws: S3Error.self) {
        try EndpointResolver.resolve(profile: ConnectionProfile(
            name: "Missing", provider: .minio, endpoint: ""
        ))
    }
}

@Test("Signing encodes a raw key path exactly once")
func canonicalPathIsEncodedOnce() throws {
    let profile = ConnectionProfile(
        name: "Generic",
        provider: .generic,
        endpoint: "https://s3.example.com",
        region: "us-east-1",
        pathStyle: true
    )
    let endpoint = try EndpointResolver.resolve(profile: profile)
    let rawPath = endpoint.rawPath(bucket: "bucket", key: "a b/😀.txt")
    #expect(rawPath == "/bucket/a b/😀.txt")
    #expect(endpoint.path(bucket: "bucket", key: "a b/😀.txt") == "/bucket/a%20b/%F0%9F%98%80.txt")

    let signed = try AWSSigV4.signHeaders(
        method: "PUT",
        path: rawPath,
        headers: [("host", endpoint.hostHeader(bucket: "bucket"))],
        payloadHash: AWSSigV4.emptyPayloadHash,
        credentials: S3Credentials(accessKeyID: "AKID", secretAccessKey: "SECRET"),
        region: "us-east-1",
        timestamp: ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z")!
    )
    #expect(signed.canonicalRequest.contains("/bucket/a%20b/%F0%9F%98%80.txt"))
    #expect(!signed.canonicalRequest.contains("%25"))
}

@Test("Dotted buckets fall back to path-style for transport, signing, and presigning")
func dottedBucketPathStyleFallback() async throws {
    let profile = ConnectionProfile(
        name: "AWS",
        provider: .aws,
        region: "us-east-1"
    )
    let endpoint = try EndpointResolver.resolve(profile: profile)
    #expect(endpoint.pathStyle == false)
    #expect(endpoint.usesPathStyle(bucket: "my.bucket"))
    #expect(endpoint.usesPathStyle(bucket: "normal-bucket") == false)
    #expect(endpoint.hostHeader(bucket: "my.bucket") == "s3.us-east-1.amazonaws.com")
    #expect(endpoint.rawPath(bucket: "my.bucket", key: "folder/a b.txt")
            == "/my.bucket/folder/a b.txt")
    #expect(endpoint.path(bucket: "my.bucket", key: "folder/a b.txt")
            == "/my.bucket/folder/a%20b.txt")
    #expect(try endpoint.url(bucket: "my.bucket", key: "folder/a b.txt").absoluteString
            == "https://s3.us-east-1.amazonaws.com/my.bucket/folder/a%20b.txt")

    let client = try S3Client(
        profile: profile,
        credentials: S3Credentials(accessKeyID: "AKID", secretAccessKey: "SECRET")
    )
    let presigned = try await client.presignedURL(
        bucket: "my.bucket",
        key: "folder/a b.txt",
        expires: 3600,
        now: ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z")!
    )
    let components = try #require(URLComponents(url: presigned, resolvingAgainstBaseURL: false))
    #expect(components.host == "s3.us-east-1.amazonaws.com")
    #expect(components.path == "/my.bucket/folder/a b.txt")
    #expect(components.query?.contains("X-Amz-SignedHeaders=host") == true)
    #expect(components.query?.contains("X-Amz-Signature=") == true)
}
