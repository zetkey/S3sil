import Foundation

/// An error from an S3 endpoint, a validation failure, or the network layer.
public struct S3Error: Error, LocalizedError, Equatable, Sendable {
    public var code: String?
    public var message: String
    public var requestID: String?
    public var hostID: String?
    public var resource: String?
    public var statusCode: Int?
    public var regionHint: String?
    public var underlying: String?

    public init(
        code: String? = nil,
        message: String,
        requestID: String? = nil,
        hostID: String? = nil,
        resource: String? = nil,
        statusCode: Int? = nil,
        regionHint: String? = nil,
        underlying: String? = nil
    ) {
        self.code = code
        self.message = message
        self.requestID = requestID
        self.hostID = hostID
        self.resource = resource
        self.statusCode = statusCode
        self.regionHint = regionHint
        self.underlying = underlying
    }

    public static func validation(_ message: String) -> S3Error {
        S3Error(message: message)
    }

    public var errorDescription: String? { message }

    public var title: String {
        if let code {
            switch code {
            case "AccessDenied", "AllAccessDisabled": return "Access Denied"
            case "NoSuchBucket": return "Bucket Not Found"
            case "NoSuchKey": return "Object Not Found"
            case "InvalidAccessKeyId", "SignatureDoesNotMatch": return "Authentication Failed"
            case "PermanentRedirect": return "Wrong Region"
            case "NoSuchUpload": return "Upload Not Found"
            case "BucketNotEmpty": return "Bucket Not Empty"
            default: break
            }
        }
        if let statusCode {
            switch statusCode {
            case 401, 403: return "Access Denied"
            case 404: return "Not Found"
            case 409: return "Conflict"
            case 429: return "Too Many Requests"
            case 301, 307: return "Wrong Region"
            case 500...599: return "Server Error"
            default: break
            }
        }
        return "Request Failed"
    }

    public var alertMessage: String {
        var lines = [message.isEmpty ? title : message]
        if let code { lines.append("Code: \(code)") }
        if let regionHint { lines.append("Bucket region: \(regionHint)") }
        if let statusCode { lines.append("HTTP \(statusCode)") }
        if let requestID { lines.append("Request ID: \(requestID)") }
        if let hostID, !hostID.isEmpty { lines.append("Host ID: \(hostID)") }
        if let underlying, underlying != message { lines.append(underlying) }
        if let recoverySuggestion { lines.append(""); lines.append(recoverySuggestion) }
        return lines.joined(separator: "\n")
    }

    /// A user-facing explanation when the endpoint or credentials cannot use bucket ACLs.
    public var aclUnavailableReason: String? {
        switch code {
        case "AccessControlListNotSupported":
            return "ACLs are disabled for this bucket. AWS Object Ownership or a bucket policy controls access instead."
        case "NotImplemented", "MethodNotAllowed":
            return "This endpoint does not implement bucket ACLs."
        case "AccessDenied":
            return "ACL access is not available for this role or bucket. The credentials need s3:GetBucketAcl and s3:PutBucketAcl."
        default:
            break
        }
        if statusCode == 403 {
            return "ACL access is not available for this role or bucket. The credentials need s3:GetBucketAcl and s3:PutBucketAcl."
        }
        if statusCode == 501 || statusCode == 405 {
            return "This endpoint does not implement bucket ACLs."
        }
        return nil
    }

    public var recoverySuggestion: String? {
        if let regionHint {
            return "The bucket is in \(regionHint). Update the profile region and try again."
        }
        switch code {
        case "AccessDenied", "AllAccessDisabled":
            return "Check the access key, secret key, and bucket permissions."
        case "InvalidAccessKeyId":
            return "The access key ID is not recognized by this endpoint. Check the credentials."
        case "SignatureDoesNotMatch":
            return "The secret key or region is incorrect for this endpoint. Check both, then try again."
        case "NoSuchBucket":
            return "Verify the bucket name and endpoint, then refresh the bucket list."
        case "NoSuchKey":
            return "The object may have been deleted or moved. Refresh the folder."
        case "BucketNotEmpty":
            return "Delete every object, including all versions and incomplete multipart uploads, then try again."
        case "PermanentRedirect":
            return "The bucket belongs to a different region. Edit the profile's region."
        default: break
        }
        if let statusCode, statusCode >= 500 {
            return "The endpoint returned a server error. Try again in a moment."
        }
        return nil
    }

    /// Parses an S3 `<Error>` document. Falls back to the HTTP status when the body is not XML.
    public static func from(data: Data, statusCode: Int, headers: [String: String] = [:]) -> S3Error {
        let regionHint = headers.first { $0.key.lowercased() == "x-amz-bucket-region" }?.value
        if let root = try? S3XML.parse(data) {
            let code = root.child("Code")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = root.child("Message")?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if code != nil || message != nil {
                return S3Error(
                    code: code,
                    message: message?.isEmpty == false ? message! : defaultStatusMessage(statusCode),
                    requestID: root.child("RequestId")?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    hostID: root.child("HostId")?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    resource: root.child("Resource")?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    statusCode: statusCode,
                    regionHint: regionHint
                )
            }
        }
        return S3Error(
            message: defaultStatusMessage(statusCode),
            statusCode: statusCode,
            regionHint: regionHint
        )
    }

    public static func network(_ error: Error, host: String) -> S3Error {
        if error is CancellationError {
            return S3Error(message: "The request was cancelled.", underlying: "Cancelled")
        }
        if let urlError = error as? URLError {
            let message: String
            switch urlError.code {
            case .cannotFindHost:
                message = "The server “\(host)” could not be found."
            case .cannotConnectToHost:
                message = "Could not connect to \(host)."
            case .timedOut:
                message = "The request to \(host) timed out."
            case .notConnectedToInternet:
                message = "This Mac is not connected to the internet."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                message = "The secure connection to \(host) failed."
            case .networkConnectionLost:
                message = "The connection to \(host) was lost."
            case .cancelled:
                message = "The request was cancelled."
            default:
                message = "The request to \(host) failed."
            }
            return S3Error(message: message, underlying: urlError.localizedDescription)
        }
        return S3Error(
            message: "The request to \(host) failed.",
            underlying: error.localizedDescription
        )
    }

    private static func defaultStatusMessage(_ status: Int) -> String {
        HTTPURLResponse.localizedString(forStatusCode: status).capitalized
    }
}
