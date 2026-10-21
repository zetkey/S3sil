import Foundation

/// Everything needed to address an S3 endpoint except credentials, which live in the Keychain.
public struct ConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var provider: ProviderKind
    /// May be empty for AWS (derived from region) and R2 (derived from account ID).
    public var endpoint: String
    public var region: String
    public var accountID: String
    public var pathStyle: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        provider: ProviderKind,
        endpoint: String = "",
        region: String = "",
        accountID: String = "",
        pathStyle: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.endpoint = endpoint
        self.region = region.isEmpty ? provider.defaultRegion : region
        self.accountID = accountID
        self.pathStyle = pathStyle ?? provider.defaultPathStyle
    }
}

/// Secrets are stored as one generic-password item per profile UUID.
public struct S3Credentials: Codable, Equatable, Sendable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken?.isEmpty == true ? nil : sessionToken
    }

}

public struct Bucket: Identifiable, Hashable, Codable, Sendable {
    public var name: String
    public var creationDate: Date?

    public var id: String { name }

    public init(name: String, creationDate: Date? = nil) {
        self.name = name
        self.creationDate = creationDate
    }
}

public struct S3Object: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case folder
        case file
    }

    /// Full object key, or the full prefix (with trailing slash) for a folder.
    public var key: String
    /// Display name relative to the listing prefix.
    public var name: String
    public var size: Int64
    public var lastModified: Date?
    public var etag: String
    public var storageClass: String?
    public var kind: Kind

    public var id: String { key }
    public var isFolder: Bool { kind == .folder }
    public var sortableModified: Date { lastModified ?? .distantPast }
    public var sortableStorageClass: String { storageClass ?? "" }

    public init(
        key: String,
        name: String,
        size: Int64 = 0,
        lastModified: Date? = nil,
        etag: String = "",
        storageClass: String? = nil,
        kind: Kind
    ) {
        self.key = key
        self.name = name
        self.size = size
        self.lastModified = lastModified
        self.etag = etag
        self.storageClass = storageClass
        self.kind = kind
    }
}

public struct ObjectListing: Sendable {
    public var objects: [S3Object]
    public var nextToken: String?
    public var isTruncated: Bool

    public init(objects: [S3Object], nextToken: String?, isTruncated: Bool) {
        self.objects = objects
        self.nextToken = nextToken
        self.isTruncated = isTruncated
    }
}

public struct ObjectHead: Sendable, Equatable {
    public var size: Int64
    public var etag: String
    public var lastModified: Date?
    public var storageClass: String?
    public var contentType: String?
    public var statusCode: Int

    public init(size: Int64, etag: String, lastModified: Date?, storageClass: String?,
                contentType: String?, statusCode: Int) {
        self.size = size
        self.etag = etag
        self.lastModified = lastModified
        self.storageClass = storageClass
        self.contentType = contentType
        self.statusCode = statusCode
    }
}

public struct DeleteFailure: Sendable, Equatable {
    public var key: String
    public var code: String
    public var message: String

    public init(key: String, code: String, message: String) {
        self.key = key
        self.code = code
        self.message = message
    }
}

// MARK: - Bucket names

public enum BucketNameValidator {
    /// Returns a user-facing problem, or nil when the name is acceptable for the provider.
    /// AWS-specific rules are not applied to providers that accept broader names.
    public static func validationError(for name: String, provider: ProviderKind) -> String? {
        guard !name.isEmpty else { return "Enter a bucket name." }
        guard name.count >= 3, name.count <= 63 else {
            return "Bucket names must be between 3 and 63 characters."
        }
        guard !name.contains("/") else { return "Bucket names cannot contain “/”." }
        guard name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return "Bucket names cannot contain spaces or line breaks."
        }
        if provider == .aws {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
            guard name.unicodeScalars.allSatisfy(allowed.contains) else {
                return "AWS bucket names may contain only lowercase letters, digits, dots, and hyphens."
            }
            guard let first = name.first, let last = name.last,
                  first.isASCII, last.isASCII,
                  first.isLetter || first.isNumber,
                  last.isLetter || last.isNumber else {
                return "AWS bucket names must start and end with a letter or digit."
            }
            guard !name.contains("..") else { return "AWS bucket names cannot contain two adjacent dots." }
            guard !isIPv4Address(name) else { return "AWS bucket names cannot be formatted as an IP address." }
        }
        return nil
    }

    private static func isIPv4Address(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return false }
            return (0...255).contains(value)
        }
    }
}

// MARK: - Bucket ACLs

public enum CannedACL: String, CaseIterable, Identifiable, Sendable {
    case privateAccess = "private"
    case publicRead = "public-read"
    case publicReadWrite = "public-read-write"
    case authenticatedRead = "authenticated-read"
    case bucketOwnerRead = "bucket-owner-read"
    case bucketOwnerFullControl = "bucket-owner-full-control"
    case logDeliveryWrite = "log-delivery-write"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .privateAccess: return "Private"
        case .publicRead: return "Public Read"
        case .publicReadWrite: return "Public Read/Write"
        case .authenticatedRead: return "Authenticated Users Read"
        case .bucketOwnerRead: return "Bucket Owner Read"
        case .bucketOwnerFullControl: return "Bucket Owner Full Control"
        case .logDeliveryWrite: return "Log Delivery Write"
        }
    }
}

public struct BucketACL: Sendable, Equatable {
    public enum GranteeType: String, Sendable, Equatable {
        case canonicalUser = "CanonicalUser"
        case group = "Group"
        case amazonCustomerByEmail = "AmazonCustomerByEmail"
        case unknown = "Unknown"
    }

    public struct Grant: Sendable, Equatable {
        public var granteeType: GranteeType
        public var displayName: String?
        public var uri: String?
        public var granteeID: String?
        public var permission: String

        public init(
            granteeType: GranteeType,
            displayName: String? = nil,
            uri: String? = nil,
            granteeID: String? = nil,
            permission: String
        ) {
            self.granteeType = granteeType
            self.displayName = displayName
            self.uri = uri
            self.granteeID = granteeID
            self.permission = permission
        }
    }

    public var ownerID: String
    public var ownerDisplayName: String?
    public var grants: [Grant]

    public init(ownerID: String, ownerDisplayName: String? = nil, grants: [Grant]) {
        self.ownerID = ownerID
        self.ownerDisplayName = ownerDisplayName
        self.grants = grants
    }
}

// MARK: - Multipart uploads

public struct UploadedPart: Sendable, Equatable {
    public var partNumber: Int
    public var etag: String

    public init(partNumber: Int, etag: String) {
        self.partNumber = partNumber
        self.etag = etag
    }
}

public struct MultipartUploadPlan: Sendable, Equatable {
    /// Files at or above this size upload with multipart; smaller files use a single PutObject.
    public static let defaultThreshold: Int64 = 64 * 1024 * 1024
    public static let defaultPartSize: Int64 = 16 * 1024 * 1024
    public static let minimumPartSize: Int64 = 5 * 1024 * 1024
    public static let maximumPartCount = 10_000

    public var totalBytes: Int64
    public var partSize: Int64
    public var partCount: Int

    public init(totalBytes: Int64, partSize: Int64, partCount: Int) {
        self.totalBytes = totalBytes
        self.partSize = partSize
        self.partCount = partCount
    }

    /// Returns nil when the file is below the threshold (or empty).
    public static func plan(
        totalBytes: Int64,
        partSize: Int64 = defaultPartSize,
        threshold: Int64 = defaultThreshold
    ) -> MultipartUploadPlan? {
        guard totalBytes > 0, totalBytes >= threshold else { return nil }
        let mebibyte: Int64 = 1024 * 1024
        var size = max(partSize, minimumPartSize)
        size = ((size + mebibyte - 1) / mebibyte) * mebibyte
        var count = Int((totalBytes + size - 1) / size)
        if count > maximumPartCount {
            let required = (totalBytes + Int64(maximumPartCount) - 1) / Int64(maximumPartCount)
            size = max(minimumPartSize, ((required + mebibyte - 1) / mebibyte) * mebibyte)
            count = Int((totalBytes + size - 1) / size)
        }
        return MultipartUploadPlan(totalBytes: totalBytes, partSize: size, partCount: count)
    }

    public func offset(forPart number: Int) -> Int64 {
        Int64(max(1, number) - 1) * partSize
    }

    public func length(forPart number: Int) -> Int64 {
        let offset = offset(forPart: number)
        return max(0, min(partSize, totalBytes - offset))
    }
}
