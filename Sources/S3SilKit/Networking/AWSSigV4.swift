import CryptoKit
import Foundation

public struct SigV4Result: Sendable {
    public let canonicalRequest: String
    public let stringToSign: String
    public let signature: String
    public let authorization: String
    public let amzDate: String
    /// Headers that must be sent with the request (Authorization, x-amz-date, ...).
    public let headers: [String: String]
}

public struct PresignedResult: Sendable {
    public let canonicalRequest: String
    public let stringToSign: String
    public let signature: String
    /// Canonical (sorted, percent-encoded) query without X-Amz-Signature.
    public let canonicalQuery: String
    /// All X-Amz-* query parameters.
    public let parameters: [(String, String)]
}

/// AWS Signature Version 4, implemented from the specification.
///
/// Verified against the official awslabs/aws-c-auth signing test suite and the
/// S3 presigned URL example in the AWS documentation (see tests).
public enum AWSSigV4 {
    public static let algorithm = "AWS4-HMAC-SHA256"
    public static let emptyPayloadHash = sha256Hex(Data())

    // MARK: - Encoding

    /// RFC 3986 percent encoding with uppercase hex. Only A-Z, a-z, 0-9, '-', '.', '_' and '~' pass through.
    public static func uriEncode(_ value: String, encodeSlash: Bool = true) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                result.append(Character(UnicodeScalar(byte)))
            case 0x2F where !encodeSlash:
                result.append("/")
            default:
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    /// Encodes each path segment while preserving the separating slashes.
    public static func encodePath(_ path: String) -> String {
        guard !path.isEmpty else { return "/" }
        return path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { uriEncode(String($0)) }
            .joined(separator: "/")
    }

    /// Canonical query string: encoded names and values, sorted by name then value.
    public static func canonicalQuery(_ items: [(String, String)]) -> String {
        var encoded: [(String, String)] = []
        encoded.reserveCapacity(items.count)
        for item in items {
            encoded.append((uriEncode(item.0), uriEncode(item.1)))
        }
        encoded.sort { lhs, rhs in
            if lhs.0 == rhs.0 { return lhs.1 < rhs.1 }
            return lhs.0 < rhs.0
        }
        var parts: [String] = []
        parts.reserveCapacity(encoded.count)
        for item in encoded {
            parts.append(item.0 + "=" + item.1)
        }
        return parts.joined(separator: "&")
    }

    // MARK: - Hashing

    public static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hex(Data(hasher.finalize()))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func hmac(key: Data, message: String) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return Data(code)
    }

    // MARK: - Dates

    public static func amzDate(_ date: Date) -> String {
        let parts = dateParts(date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ",
                      parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second)
    }

    public static func dateStamp(_ date: Date) -> String {
        let parts = dateParts(date)
        return String(format: "%04d%02d%02d", parts.year, parts.month, parts.day)
    }

    private static func dateParts(_ date: Date) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return (c.year ?? 1970, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    // MARK: - Header signing

    public static func signHeaders(
        method: String,
        path: String,
        query: [(String, String)] = [],
        headers: [(String, String)],
        payloadHash: String,
        credentials: S3Credentials,
        region: String,
        service: String = "s3",
        timestamp: Date = Date(),
        includePayloadHashHeader: Bool = true
    ) throws -> SigV4Result {
        guard headers.contains(where: { $0.0.lowercased() == "host" }) else {
            throw S3Error.validation("The Host header is required for signing.")
        }

        let amzDate = amzDate(timestamp)
        let stamp = dateStamp(timestamp)
        var allHeaders = headers

        if !allHeaders.contains(where: { $0.0.lowercased() == "x-amz-date" }) {
            allHeaders.append(("x-amz-date", amzDate))
        }
        if includePayloadHashHeader,
           !allHeaders.contains(where: { $0.0.lowercased() == "x-amz-content-sha256" }) {
            allHeaders.append(("x-amz-content-sha256", payloadHash))
        }
        if let token = credentials.sessionToken, !token.isEmpty,
           !allHeaders.contains(where: { $0.0.lowercased() == "x-amz-security-token" }) {
            allHeaders.append(("x-amz-security-token", token))
        }

        let canonical = canonicalRequest(
            method: method,
            path: path,
            query: query,
            headers: allHeaders,
            payloadHash: payloadHash
        )
        let scope = "\(stamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            algorithm,
            amzDate,
            scope,
            sha256Hex(Data(canonical.request.utf8))
        ].joined(separator: "\n")

        let signature = signature(stringToSign: stringToSign, secret: credentials.secretAccessKey,
                                  stamp: stamp, region: region, service: service)
        let authorization = "\(algorithm) Credential=\(credentials.accessKeyID)/\(scope), " +
            "SignedHeaders=\(canonical.signedHeaders), Signature=\(signature)"

        var resultHeaders: [String: String] = [
            "Authorization": authorization,
            "x-amz-date": amzDate
        ]
        if includePayloadHashHeader {
            resultHeaders["x-amz-content-sha256"] = payloadHash
        }
        if let token = credentials.sessionToken, !token.isEmpty {
            resultHeaders["x-amz-security-token"] = token
        }

        return SigV4Result(
            canonicalRequest: canonical.request,
            stringToSign: stringToSign,
            signature: signature,
            authorization: authorization,
            amzDate: amzDate,
            headers: resultHeaders
        )
    }

    /// Builds the canonical request. Used by tests and by header signing.
    public static func canonicalRequest(
        method: String,
        path: String,
        query: [(String, String)],
        headers: [(String, String)],
        payloadHash: String
    ) -> (request: String, signedHeaders: String) {
        var grouped: [String: [String]] = [:]
        for (name, value) in headers {
            let key = name.lowercased()
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            grouped[key, default: []].append(normalized)
        }
        let sortedNames = grouped.keys.sorted()
        let canonicalHeaders = sortedNames
            .map { "\($0):\((grouped[$0] ?? []).joined(separator: ","))" }
            .joined(separator: "\n") + "\n"
        let signedHeaders = sortedNames.joined(separator: ";")
        let request = [
            method.uppercased(),
            encodePath(path),
            canonicalQuery(query),
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")
        return (request, signedHeaders)
    }

    public static func signature(
        stringToSign: String,
        secret: String,
        stamp: String,
        region: String,
        service: String
    ) -> String {
        let dateKey = hmac(key: Data(("AWS4" + secret).utf8), message: stamp)
        let regionKey = hmac(key: dateKey, message: region)
        let serviceKey = hmac(key: regionKey, message: service)
        let signingKey = hmac(key: serviceKey, message: "aws4_request")
        return hex(hmac(key: signingKey, message: stringToSign))
    }

    // MARK: - Presigning

    public static func presign(
        method: String,
        path: String,
        query: [(String, String)] = [],
        host: String,
        credentials: S3Credentials,
        region: String,
        service: String = "s3",
        timestamp: Date = Date(),
        expires: Int
    ) throws -> PresignedResult {
        guard (1...604_800).contains(expires) else {
            throw S3Error.validation("Presigned URL expiry must be between 1 second and 7 days.")
        }
        let amzDate = amzDate(timestamp)
        let stamp = dateStamp(timestamp)
        let scope = "\(stamp)/\(region)/\(service)/aws4_request"

        var params = query
        params.append(("X-Amz-Algorithm", algorithm))
        params.append(("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope)"))
        params.append(("X-Amz-Date", amzDate))
        params.append(("X-Amz-Expires", String(expires)))
        params.append(("X-Amz-SignedHeaders", "host"))
        if let token = credentials.sessionToken, !token.isEmpty {
            params.append(("X-Amz-Security-Token", token))
        }

        let queryString = canonicalQuery(params)
        let canonical = [
            method.uppercased(),
            encodePath(path),
            queryString,
            "host:\(host)\n",
            "host",
            "UNSIGNED-PAYLOAD"
        ].joined(separator: "\n")
        let stringToSign = [
            algorithm,
            amzDate,
            scope,
            sha256Hex(Data(canonical.utf8))
        ].joined(separator: "\n")
        let signature = signature(stringToSign: stringToSign, secret: credentials.secretAccessKey,
                                  stamp: stamp, region: region, service: service)

        return PresignedResult(
            canonicalRequest: canonical,
            stringToSign: stringToSign,
            signature: signature,
            canonicalQuery: queryString,
            parameters: params
        )
    }
}
