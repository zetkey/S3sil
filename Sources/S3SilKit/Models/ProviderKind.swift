import Foundation

public enum BucketACLCapability: Sendable, Equatable {
    /// The provider exposes effective bucket ACLs; attempt GET and PUT.
    case editable
    /// ACLs are reported but not enforceable, so show an explanation and no editor.
    case readOnly(String)
    /// The provider has no bucket ACL API, so hide the entry point.
    case unsupported(String)
}

/// The storage providers S3Sil knows how to configure.
public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case aws
    case cloudflareR2
    case hitachi
    case minio
    case generic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .aws: return "AWS S3"
        case .cloudflareR2: return "Cloudflare R2"
        case .hitachi: return "Hitachi HCP / Vantara"
        case .minio: return "MinIO"
        case .generic: return "S3-Compatible"
        }
    }

    public var shortName: String {
        switch self {
        case .aws: return "AWS"
        case .cloudflareR2: return "R2"
        case .hitachi: return "Hitachi"
        case .minio: return "MinIO"
        case .generic: return "Custom"
        }
    }

    public var defaultRegion: String {
        switch self {
        case .cloudflareR2: return "auto"
        default: return "us-east-1"
        }
    }

    public var defaultPathStyle: Bool {
        self != .aws
    }

    public var requiresEndpoint: Bool {
        switch self {
        case .aws, .cloudflareR2: return false
        default: return true
        }
    }

    public var defaultScheme: String {
        self == .minio ? "http" : "https"
    }

    /// How bucket ACLs behave for this provider. R2 has none; MinIO emulates them
    /// (a constant GET stub, and a private PUT that changes nothing), so neither gets an editor.
    public var bucketACLCapability: BucketACLCapability {
        switch self {
        case .cloudflareR2:
            return .unsupported("Cloudflare R2 does not support bucket ACLs.")
        case .minio:
            return .readOnly(
                "MinIO reports bucket ACLs but does not enforce them. GET returns a constant stub, " +
                "PUT private is a no-op, and other canned ACLs are not implemented. Use bucket policies instead."
            )
        default:
            return .editable
        }
    }

    public var supportsACLs: Bool {
        bucketACLCapability == .editable
    }

    /// MinIO still gets a read-only explanation sheet; R2 gets no ACL entry point.
    public var showsBucketACLInfo: Bool {
        switch bucketACLCapability {
        case .unsupported: return false
        case .readOnly, .editable: return true
        }
    }

    /// Short capability badge for the profile overview.
    public var aclSummary: String? {
        switch bucketACLCapability {
        case .unsupported: return "No ACLs"
        case .readOnly: return "ACLs not enforced"
        case .editable: return nil
        }
    }

    public var symbolName: String {
        switch self {
        case .aws: return "cloud.fill"
        case .cloudflareR2: return "cloud.bolt.fill"
        case .hitachi: return "building.2.fill"
        case .minio: return "externaldrive.connected.to.line.below"
        case .generic: return "server.rack"
        }
    }

    public var endpointPlaceholder: String {
        switch self {
        case .aws: return "s3.<region>.amazonaws.com (automatic)"
        case .cloudflareR2: return "Derived from account ID"
        case .hitachi: return "https://s3.example.com"
        case .minio: return "http://127.0.0.1:9000"
        case .generic: return "https://s3.example.com"
        }
    }
}
