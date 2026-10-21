import Foundation
import Testing
@testable import S3SilKit

struct OfficialVector: Sendable, CustomTestStringConvertible {
    let name: String
    let method: String
    let path: String
    let query: [(String, String)]
    let headers: [(String, String)]
    let body: String
    let includePayloadHashHeader: Bool
    let sessionToken: String?

    var testDescription: String { name }
}

private let vectorDate = ISO8601DateFormatter().date(from: "2015-08-30T12:36:00Z")!
private let testCredentials = S3Credentials(
    accessKeyID: "AKIDEXAMPLE",
    secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
)

private let officialVectors: [OfficialVector] = [
    .init(name: "get-vanilla", method: "GET", path: "/",
          query: [], headers: [("Host", "example.amazonaws.com")],
          body: "", includePayloadHashHeader: false, sessionToken: nil),
    .init(name: "get-vanilla-query-order-key-case", method: "GET", path: "/",
          query: [("Param2", "value2"), ("Param1", "value1")],
          headers: [("Host", "example.amazonaws.com")],
          body: "", includePayloadHashHeader: false, sessionToken: nil),
    .init(name: "get-vanilla-query-order-encoded", method: "GET", path: "/",
          query: [("Param-3", "Value3"), ("Param", "Value2"), ("ሴ", "Value1")],
          headers: [("Host", "example.amazonaws.com")],
          body: "", includePayloadHashHeader: false, sessionToken: nil),
    .init(name: "get-vanilla-utf8-query", method: "GET", path: "/",
          query: [("ሴ", "bar")],
          headers: [("Host", "example.amazonaws.com")],
          body: "", includePayloadHashHeader: false, sessionToken: nil),
    .init(name: "get-unreserved", method: "GET",
          path: "/-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
          query: [], headers: [("Host", "example.amazonaws.com")],
          body: "", includePayloadHashHeader: false, sessionToken: nil),
    .init(name: "get-space-unnormalized", method: "GET", path: "/example space/",
          query: [], headers: [("Host", "example.amazonaws.com")],
          body: "", includePayloadHashHeader: false, sessionToken: nil),
    .init(name: "get-header-value-trim", method: "GET", path: "/",
          query: [],
          headers: [
            ("Host", "example.amazonaws.com"),
            ("My-Header1", " value1"),
            ("My-Header2", " \"a   b   c\"")
          ],
          body: "", includePayloadHashHeader: false, sessionToken: nil),
    .init(name: "get-header-value-order", method: "GET", path: "/",
          query: [],
          headers: [
            ("Host", "example.amazonaws.com"),
            ("My-Header1", "value4"),
            ("My-Header1", "value1"),
            ("My-Header1", "value3"),
            ("My-Header1", "value2")
          ],
          body: "", includePayloadHashHeader: false, sessionToken: nil),
    .init(name: "get-vanilla-with-session-token", method: "GET", path: "/",
          query: [], headers: [("Host", "example.amazonaws.com")],
          body: "", includePayloadHashHeader: false,
          sessionToken: "6e86291e8372ff2a2260956d9b8aae1d763fbf315fa00fa31553b73ebf194267"),
    .init(name: "post-x-www-form-urlencoded", method: "POST", path: "/",
          query: [],
          headers: [
            ("Content-Type", "application/x-www-form-urlencoded"),
            ("Host", "example.amazonaws.com"),
            ("Content-Length", "13")
          ],
          body: "Param1=value1", includePayloadHashHeader: true, sessionToken: nil),
    .init(name: "get-vanilla-query-unreserved", method: "GET", path: "/",
          query: [("-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz",
                   "-._~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")],
          headers: [("Host", "example.amazonaws.com")],
          body: "", includePayloadHashHeader: false, sessionToken: nil)
]

private func fixture(_ relative: String) throws -> String {
    guard let base = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
        throw S3Error(message: "Fixtures missing from test bundle")
    }
    return try String(contentsOf: base.appendingPathComponent(relative), encoding: .utf8)
        .trimmingCharacters(in: .newlines)
}

@Test("Official AWS SigV4 vectors", arguments: officialVectors)
func officialSigV4Vector(_ vector: OfficialVector) throws {
    var credentials = testCredentials
    credentials.sessionToken = vector.sessionToken
    let body = Data(vector.body.utf8)
    let hash = AWSSigV4.sha256Hex(body)

    let result = try AWSSigV4.signHeaders(
        method: vector.method,
        path: vector.path,
        query: vector.query,
        headers: vector.headers,
        payloadHash: hash,
        credentials: credentials,
        region: "us-east-1",
        service: "service",
        timestamp: vectorDate,
        includePayloadHashHeader: vector.includePayloadHashHeader
    )

    #expect(result.canonicalRequest == (try fixture("SigV4/\(vector.name)/header-canonical-request.txt")))
    #expect(result.stringToSign == (try fixture("SigV4/\(vector.name)/header-string-to-sign.txt")))
    #expect(result.signature == (try fixture("SigV4/\(vector.name)/header-signature.txt")))
}

@Test("RFC 3986 encoding")
func uriEncoding() {
    #expect(AWSSigV4.uriEncode("AZaz09-._~") == "AZaz09-._~")
    #expect(AWSSigV4.uriEncode("a b+c/d?e#f") == "a%20b%2Bc%2Fd%3Fe%23f")
    #expect(AWSSigV4.uriEncode("ሴ") == "%E1%88%B4")
    #expect(AWSSigV4.encodePath("/folder/a b/plus+name.txt") == "/folder/a%20b/plus%2Bname.txt")
    #expect(AWSSigV4.canonicalQuery([("b", "2"), ("a", "3"), ("a", "1")]) == "a=1&a=3&b=2")
}

@Test("AWS documented presigned URL example")
func presignedURLExample() async throws {
    // https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sigv4-query-string-auth.html
    let credentials = S3Credentials(
        accessKeyID: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    )
    let date = ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z")!
    let canonicalQuery = "X-Amz-Algorithm=AWS4-HMAC-SHA256&" +
        "X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&" +
        "X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host"
    let canonicalRequest = """
        GET
        /test.txt
        \(canonicalQuery)
        host:examplebucket.s3.amazonaws.com

        host
        UNSIGNED-PAYLOAD
        """

    let result = try AWSSigV4.presign(
        method: "GET",
        path: "/test.txt",
        host: "examplebucket.s3.amazonaws.com",
        credentials: credentials,
        region: "us-east-1",
        timestamp: date,
        expires: 86_400
    )

    #expect(result.canonicalQuery == canonicalQuery)
    #expect(result.canonicalRequest == canonicalRequest)
    #expect(result.stringToSign.hasSuffix("3bfa292879f6447bbcda7001decf97f4a54dc650c8942174ae0a9121cf58ad04"))
    #expect(result.signature == "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")

    let profile = ConnectionProfile(
        name: "Docs",
        provider: .generic,
        endpoint: "https://s3.amazonaws.com",
        region: "us-east-1",
        pathStyle: false
    )
    let client = try S3Client(profile: profile, credentials: credentials)
    let url = try await client.presignedURL(bucket: "examplebucket", key: "test.txt",
                                            expires: 86_400, now: date)
    let expected = "https://examplebucket.s3.amazonaws.com/test.txt?" + canonicalQuery +
        "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
    #expect(url.absoluteString == expected)
}

@Test("Session token is included in presigned URLs")
func presignedToken() throws {
    let credentials = S3Credentials(accessKeyID: "AKID", secretAccessKey: "SECRET", sessionToken: "TOKEN")
    let result = try AWSSigV4.presign(
        method: "GET", path: "/", host: "bucket.example.com",
        credentials: credentials, region: "us-east-1", expires: 900
    )
    #expect(result.canonicalQuery.contains("X-Amz-Security-Token=TOKEN"))
    #expect(result.stringToSign.hasPrefix("AWS4-HMAC-SHA256\n"))
}
