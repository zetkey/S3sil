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
    case webdav
    case ftp
    case sftp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .aws: return "AWS S3"
        case .cloudflareR2: return "Cloudflare R2"
        case .hitachi: return "Hitachi HCP / Vantara"
        case .minio: return "MinIO"
        case .generic: return "S3-Compatible"
        case .webdav: return "WebDAV"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        }
    }

    public var shortName: String {
        switch self {
        case .aws: return "AWS"
        case .cloudflareR2: return "R2"
        case .hitachi: return "Hitachi"
        case .minio: return "MinIO"
        case .generic: return "Custom"
        case .webdav: return "WebDAV"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        }
    }

    public var defaultRegion: String {
        switch self {
        case .cloudflareR2: return "auto"
        case .webdav, .ftp, .sftp: return ""
        default: return "us-east-1"
        }
    }

    public var defaultPathStyle: Bool {
        switch self {
        case .aws: return false
        case .webdav, .ftp, .sftp: return false
        default: return true
        }
    }

    public var requiresEndpoint: Bool {
        switch self {
        case .aws, .cloudflareR2: return false
        default: return true
        }
    }

    public var defaultScheme: String {
        switch self {
        case .minio: return "http"
        case .webdav: return "https"
        case .ftp: return "ftp"
        case .sftp: return ""
        default: return "https"
        }
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
        case .webdav, .ftp, .sftp:
            return .unsupported("\(displayName) does not support S3 bucket ACLs.")
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
        case .webdav: return "globe"
        case .ftp: return "arrow.triangle.swap"
        case .sftp: return "terminal"
        }
    }

    public var endpointPlaceholder: String {
        switch self {
        case .aws: return "s3.<region>.amazonaws.com (automatic)"
        case .cloudflareR2: return "Derived from account ID"
        case .hitachi: return "https://s3.example.com"
        case .minio: return "http://127.0.0.1:9000"
        case .generic: return "https://s3.example.com"
        case .webdav: return "https://webdav.example.com"
        case .ftp: return "ftp.example.com"
        case .sftp: return "sftp.example.com"
        }
    }
}
