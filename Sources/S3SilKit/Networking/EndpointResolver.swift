import Foundation

public struct ResolvedEndpoint: Equatable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int?
    /// Decoded path prefix without a trailing slash, or "".
    public let basePath: String
    public let pathStyle: Bool
    public let region: String

    public var displayHost: String {
        let name = host.contains(":") ? "[\(host)]" : host
        if let port { return "\(name):\(port)" }
        return name
    }

    public var origin: String {
        "\(scheme)://\(displayHost)\(basePath)"
    }

    public var addressingDescription: String {
        pathStyle ? "Path-style" : "Virtual-hosted"
    }

    public func usesPathStyle(bucket: String?) -> Bool {
        if pathStyle { return true }
        guard let bucket, !bucket.isEmpty else { return false }
        // TLS wildcards never match a dotted bucket as a virtual host, so AWS requires path-style.
        return bucket.contains(".")
    }

    public func hostHeader(bucket: String? = nil) -> String {
        var name = host.contains(":") ? "[\(host)]" : host
        if let bucket, !bucket.isEmpty, !usesPathStyle(bucket: bucket) {
            name = "\(bucket).\(name)"
        }
        if let port { name += ":\(port)" }
        return name
    }

    /// Unencoded request path including the bucket. Signers encode this exactly once.
    public func rawPath(bucket: String, key: String = "") -> String {
        if usesPathStyle(bucket: bucket) {
            var path = basePath + "/" + bucket
            if !key.isEmpty {
                path += "/" + key
            }
            return path.isEmpty ? "/" : path
        }
        let path = basePath + "/" + key
        return path.isEmpty ? "/" : path
    }

    /// Canonical, percent-encoded request path including the bucket.
    public func path(bucket: String, key: String = "") -> String {
        AWSSigV4.encodePath(rawPath(bucket: bucket, key: key))
    }

    public func url(bucket: String?, key: String = "", query: [(String, String)] = []) throws -> URL {
        try url(bucket: bucket, key: key,
                percentEncodedQuery: query.isEmpty ? nil : AWSSigV4.canonicalQuery(query))
    }

    public func url(bucket: String?, key: String = "", percentEncodedQuery: String?) throws -> URL {
        var components = URLComponents()
        components.scheme = scheme
        var urlHost = host
        if let bucket, !bucket.isEmpty, !usesPathStyle(bucket: bucket) {
            urlHost = "\(bucket).\(host)"
        }
        components.host = urlHost
        if let port { components.port = port }
        components.percentEncodedPath = bucket == nil
            ? (basePath.isEmpty ? "/" : AWSSigV4.encodePath(basePath))
            : path(bucket: bucket!, key: key)
        components.percentEncodedQuery = percentEncodedQuery
        guard let url = components.url else {
            throw S3Error.validation("The endpoint could not be converted into a valid URL.")
        }
        return url
    }
}

public enum EndpointResolver {
    public static func resolve(profile: ConnectionProfile) throws -> ResolvedEndpoint {
        var region = profile.region.trimmingCharacters(in: .whitespacesAndNewlines)
        if profile.provider == .cloudflareR2 {
            region = "auto"
        } else if region.isEmpty {
            if profile.provider == .aws {
                throw S3Error.validation("A region is required for AWS S3.")
            }
            region = profile.provider.defaultRegion
        }

        var text = profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            switch profile.provider {
            case .aws:
                text = "https://s3.\(region).amazonaws.com"
            case .cloudflareR2:
                let account = profile.accountID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !account.isEmpty else {
                    throw S3Error.validation("A Cloudflare account ID is required for R2.")
                }
                guard account.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil else {
                    throw S3Error.validation("The Cloudflare account ID contains invalid characters.")
                }
                text = "https://\(account).r2.cloudflarestorage.com"
            default:
                throw S3Error.validation("An endpoint is required for \(profile.provider.displayName).")
            }
        }

        if !text.contains("://") {
            text = "\(profile.provider.defaultScheme)://\(text)"
        }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw S3Error.validation("Enter a valid http:// or https:// endpoint.")
        }
        if components.user != nil || components.password != nil {
            throw S3Error.validation("The endpoint must not contain credentials. Use the credentials fields.")
        }
        if components.query != nil || components.fragment != nil {
            throw S3Error.validation("The endpoint must not contain a query or fragment.")
        }
        guard var host = components.host?.lowercased(), !host.isEmpty else {
            throw S3Error.validation("The endpoint is missing a host name.")
        }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }

        var port = components.port
        if (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
            port = nil
        }

        var basePath = components.path
        while basePath.count > 1 && basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        if basePath == "/" { basePath = "" }
        if !basePath.isEmpty && !basePath.hasPrefix("/") {
            basePath = "/" + basePath
        }

        var pathStyle = profile.pathStyle
        if profile.provider == .cloudflareR2 {
            pathStyle = true
        }

        return ResolvedEndpoint(
            scheme: scheme,
            host: host,
            port: port,
            basePath: basePath,
            pathStyle: pathStyle,
            region: region
        )
    }

    /// A human-readable endpoint for UI summaries.
    public static func displayEndpoint(for profile: ConnectionProfile) -> String {
        (try? resolve(profile: profile))?.origin ?? (profile.endpoint.isEmpty ? "Not configured" : profile.endpoint)
    }
}
