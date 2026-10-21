import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Async S3 client. Networking runs off the main actor; each request is signed with SigV4.
public actor S3Client {
    public nonisolated let profile: ConnectionProfile
    public nonisolated let endpoint: ResolvedEndpoint

    private let credentials: S3Credentials
    private let session: URLSession
    private let transferSession: TransferURLSession = TransferURLSession()

    public init(profile: ConnectionProfile, credentials: S3Credentials) throws {
        self.profile = profile
        self.credentials = credentials
        self.endpoint = try EndpointResolver.resolve(profile: profile)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Buckets

    public func listBuckets() async throws -> [Bucket] {
        let request = try signedRequest(method: "GET", bucket: nil)
        let data = try await execute(request)
        return try S3XML.parseBuckets(data)
    }

    @discardableResult
    public func createBucket(_ name: String) async throws -> Int {
        if let problem = BucketNameValidator.validationError(for: name, provider: profile.provider) {
            throw S3Error.validation(problem)
        }
        let body = S3XML.createBucketConfiguration(provider: profile.provider, region: endpoint.region)
        let extraHeaders = body == nil ? [] : [("content-type", "application/xml")]
        let request = try signedRequest(method: "PUT", bucket: name,
                                        extraHeaders: extraHeaders, body: body)
        let result = try await executeWithStatus(request)
        return result.statusCode
    }

    @discardableResult
    public func deleteBucket(_ name: String) async throws -> Int {
        let request = try signedRequest(method: "DELETE", bucket: name)
        let result = try await executeWithStatus(request)
        return result.statusCode
    }

    // MARK: - Bucket ACLs

    public func getBucketACL(_ bucket: String) async throws -> BucketACL {
        let request = try signedRequest(method: "GET", bucket: bucket, query: [("acl", "")])
        let data = try await execute(request)
        return try S3XML.parseBucketACL(data)
    }

    public func putBucketACL(_ bucket: String, cannedACL: CannedACL) async throws {
        let request = try signedRequest(
            method: "PUT",
            bucket: bucket,
            query: [("acl", "")],
            extraHeaders: [("x-amz-acl", cannedACL.rawValue)]
        )
        _ = try await executeWithStatus(request)
    }

    // MARK: - Objects

    public func listObjects(
        bucket: String,
        prefix: String = "",
        delimiter: String? = "/",
        continuationToken: String? = nil,
        maxKeys: Int = 1000
    ) async throws -> ObjectListing {
        var query: [(String, String)] = [("list-type", "2")]
        if let delimiter, !delimiter.isEmpty {
            query.append(("delimiter", delimiter))
        }
        if !prefix.isEmpty {
            query.append(("prefix", prefix))
        }
        if let continuationToken, !continuationToken.isEmpty {
            query.append(("continuation-token", continuationToken))
        }
        query.append(("max-keys", String(min(max(1, maxKeys), 1000))))

        let request = try signedRequest(method: "GET", bucket: bucket, query: query)
        let data = try await execute(request)
        return try S3XML.parseObjectListing(data, prefix: prefix, delimiter: delimiter)
    }

    @discardableResult
    public func putObject(
        bucket: String,
        key: String,
        data: Data,
        contentType: String = "application/octet-stream"
    ) async throws -> Int {
        let request = try signedRequest(
            method: "PUT",
            bucket: bucket,
            key: key,
            extraHeaders: [("content-type", contentType)],
            body: data
        )
        let result = try await executeWithStatus(request)
        return result.statusCode
    }

    public func headObject(bucket: String, key: String) async throws -> ObjectHead {
        let request = try signedRequest(method: "HEAD", bucket: bucket, key: key)
        let result = try await executeWithStatus(request)
        let lastModified = result.response.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.httpDate)
        return ObjectHead(
            size: result.response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) ?? 0,
            etag: (result.response.value(forHTTPHeaderField: "ETag") ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
            lastModified: lastModified,
            storageClass: result.response.value(forHTTPHeaderField: "x-amz-storage-class"),
            contentType: result.response.value(forHTTPHeaderField: "Content-Type"),
            statusCode: result.statusCode
        )
    }

    /// Creates a folder using a zero-byte object whose key ends in "/".
    public func createFolder(bucket: String, key: String) async throws {
        guard !key.isEmpty, key.hasSuffix("/") else {
            throw S3Error.validation("A folder key must end with “/”.")
        }
        try await putObject(bucket: bucket, key: key, data: Data(), contentType: "application/x-directory")
    }

    /// Deletes up to 1000 objects in one request. Returns per-key failures.
    public func deleteObjects(bucket: String, keys: [String]) async throws -> [DeleteFailure] {
        guard !keys.isEmpty else { return [] }
        guard keys.count <= 1000 else {
            throw S3Error.validation("DeleteObjects accepts at most 1000 keys per request.")
        }
        var xml = "<Delete>"
        for key in keys {
            xml += "<Object><Key>\(S3XML.escape(key))</Key></Object>"
        }
        xml += "</Delete>"
        let body = Data(xml.utf8)
        let md5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
        let request = try signedRequest(
            method: "POST",
            bucket: bucket,
            query: [("delete", "")],
            extraHeaders: [
                ("content-type", "application/xml"),
                ("content-md5", md5)
            ],
            body: body
        )
        let data = try await execute(request)
        guard !data.isEmpty else { return [] }
        return try S3XML.parseDeleteFailures(data)
    }

    // MARK: - Transfers

    public func download(
        bucket: String,
        key: String,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws {
        let request = try signedRequest(method: "GET", bucket: bucket, key: key, timeout: 3600)
        let result: HTTPResult
        do {
            result = try await transferSession.download(request, to: destination, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw S3Error.network(error, host: endpoint.displayHost)
        }
        guard (200..<300).contains(result.statusCode) else {
            throw S3Error.from(data: result.body, statusCode: result.statusCode, headers: result.headers)
        }
    }

    public func upload(
        fileURL: URL,
        bucket: String,
        key: String,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws {
        let payloadHash = try AWSSigV4.sha256Hex(fileAt: fileURL)
        let request = try signedRequest(
            method: "PUT",
            bucket: bucket,
            key: key,
            extraHeaders: [("content-type", mimeType(for: fileURL))],
            payloadHash: payloadHash,
            timeout: 3600
        )
        let result: HTTPResult
        do {
            result = try await transferSession.upload(request, from: fileURL, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw S3Error.network(error, host: endpoint.displayHost)
        }
        guard (200..<300).contains(result.statusCode) else {
            throw S3Error.from(data: result.body, statusCode: result.statusCode, headers: result.headers)
        }
    }

    // MARK: - Multipart uploads

    public func initiateMultipartUpload(
        bucket: String,
        key: String,
        contentType: String = "application/octet-stream"
    ) async throws -> String {
        let request = try signedRequest(
            method: "POST",
            bucket: bucket,
            key: key,
            query: [("uploads", "")],
            extraHeaders: [("content-type", contentType)]
        )
        let data = try await execute(request)
        return try S3XML.parseUploadID(data)
    }

    /// Uploads one part and returns the ETag header exactly as the server sent it.
    public func uploadPart(
        bucket: String,
        key: String,
        uploadID: String,
        partNumber: Int,
        data: Data,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> String {
        guard (1...MultipartUploadPlan.maximumPartCount).contains(partNumber) else {
            throw S3Error.validation("Part numbers must be between 1 and 10,000.")
        }
        guard !data.isEmpty else {
            throw S3Error.validation("A multipart part cannot be empty.")
        }
        let request = try signedRequest(
            method: "PUT",
            bucket: bucket,
            key: key,
            query: [("partNumber", String(partNumber)), ("uploadId", uploadID)],
            body: data,
            timeout: 3600
        )
        let result: HTTPResult
        do {
            result = try await transferSession.upload(request, from: data, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw S3Error.network(error, host: endpoint.displayHost)
        }
        guard (200..<300).contains(result.statusCode) else {
            throw S3Error.from(data: result.body, statusCode: result.statusCode, headers: result.headers)
        }
        guard let etag = result.headers["etag"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !etag.isEmpty else {
            throw S3Error(message: "The endpoint did not return an ETag for part \(partNumber).")
        }
        return etag
    }

    public func completeMultipartUpload(
        bucket: String,
        key: String,
        uploadID: String,
        parts: [UploadedPart]
    ) async throws {
        guard !parts.isEmpty else {
            throw S3Error.validation("A multipart upload needs at least one part.")
        }
        let body = S3XML.completeMultipartUploadBody(parts: parts)
        let request = try signedRequest(
            method: "POST",
            bucket: bucket,
            key: key,
            query: [("uploadId", uploadID)],
            extraHeaders: [("content-type", "application/xml")],
            body: body,
            timeout: 3600
        )
        let result = try await executeWithStatus(request)
        // S3 may answer CompleteMultipartUpload with HTTP 200 and an <Error> body.
        if !result.data.isEmpty,
           let root = try? S3XML.parse(result.data),
           root.name == "Error" {
            throw S3Error.from(
                data: result.data,
                statusCode: result.statusCode,
                headers: headerDictionary(result.response)
            )
        }
    }

    public func abortMultipartUpload(bucket: String, key: String, uploadID: String) async throws {
        let request = try signedRequest(
            method: "DELETE",
            bucket: bucket,
            key: key,
            query: [("uploadId", uploadID)]
        )
        _ = try await executeWithStatus(request)
    }

    /// Uses multipart above 64 MiB and a single PutObject below it.
    public func uploadFile(
        fileURL: URL,
        bucket: String,
        key: String,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws {
        let size = try fileSize(fileURL)
        if MultipartUploadPlan.plan(totalBytes: size) != nil {
            try await multipartUpload(fileURL: fileURL, bucket: bucket, key: key, progress: progress)
        } else {
            try await upload(fileURL: fileURL, bucket: bucket, key: key, progress: progress)
        }
    }

    /// Runs a multipart upload with bounded part concurrency. Any failure or
    /// cancellation aborts the upload so no incomplete multipart upload is left behind.
    public func multipartUpload(
        fileURL: URL,
        bucket: String,
        key: String,
        partSize: Int64 = MultipartUploadPlan.defaultPartSize,
        maxConcurrentParts: Int = 4,
        progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws {
        let totalBytes = try fileSize(fileURL)
        guard let plan = MultipartUploadPlan.plan(
            totalBytes: totalBytes,
            partSize: partSize,
            threshold: 0
        ) else {
            throw S3Error.validation("The file is empty and cannot be uploaded in parts.")
        }

        let uploadID = try await initiateMultipartUpload(
            bucket: bucket,
            key: key,
            contentType: mimeType(for: fileURL)
        )
        let tracker = MultipartProgress(totalBytes: plan.totalBytes, report: progress)
        let client = self
        let width = max(1, min(maxConcurrentParts, 4))

        do {
            var completed: [UploadedPart] = []
            let operation: @Sendable (Int, Int64, Int64) async throws -> UploadedPart = {
                partNumber, offset, length in
                try Task.checkCancellation()
                let data = try Self.readFilePart(url: fileURL, offset: offset, length: length)
                let etag = try await client.uploadPart(
                    bucket: bucket,
                    key: key,
                    uploadID: uploadID,
                    partNumber: partNumber,
                    data: data
                ) { sent, _ in
                    tracker.update(part: partNumber, bytes: sent, length: length)
                }
                tracker.complete(part: partNumber, length: length)
                return UploadedPart(partNumber: partNumber, etag: etag)
            }

            try await withThrowingTaskGroup(of: UploadedPart.self) { group in
                var next = 1
                while next <= min(width, plan.partCount) {
                    let number = next
                    group.addTask {
                        try await operation(
                            number,
                            plan.offset(forPart: number),
                            plan.length(forPart: number)
                        )
                    }
                    next += 1
                }
                while let part = try await group.next() {
                    completed.append(part)
                    if next <= plan.partCount {
                        let number = next
                        group.addTask {
                            try await operation(
                                number,
                                plan.offset(forPart: number),
                                plan.length(forPart: number)
                            )
                        }
                        next += 1
                    }
                }
            }

            try Task.checkCancellation()
            guard completed.count == plan.partCount else {
                throw S3Error(message: "The multipart upload did not receive every part.")
            }
            try await completeMultipartUpload(
                bucket: bucket,
                key: key,
                uploadID: uploadID,
                parts: completed.sorted { $0.partNumber < $1.partNumber }
            )
            progress(plan.totalBytes, plan.totalBytes)
        } catch {
            // The request may already be cancelled, so an independent task performs the abort.
            let abortTask = Task.detached { [client] in
                try? await client.abortMultipartUpload(bucket: bucket, key: key, uploadID: uploadID)
            }
            _ = await abortTask.value
            throw error
        }
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw S3Error(message: "The file size could not be read.")
        }
        return Int64(size)
    }

    nonisolated private static func readFilePart(url: URL, offset: Int64, length: Int64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var data = Data()
        data.reserveCapacity(Int(length))
        while data.count < Int(length) {
            guard let chunk = try handle.read(upToCount: Int(length) - data.count), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        guard data.count == Int(length) else {
            throw S3Error(
                message: "The file changed while it was being uploaded.",
                underlying: "Expected \(length) bytes at offset \(offset), read \(data.count)."
            )
        }
        return data
    }

    // MARK: - Presigning

    public func presignedURL(bucket: String, key: String, expires: Int = 3600, now: Date = Date()) throws -> URL {
        let path = endpoint.rawPath(bucket: bucket, key: key)
        let host = endpoint.hostHeader(bucket: bucket)
        let result = try AWSSigV4.presign(
            method: "GET",
            path: path,
            host: host,
            credentials: credentials,
            region: endpoint.region,
            timestamp: now,
            expires: expires
        )
        let query = result.canonicalQuery + "&X-Amz-Signature=" + result.signature
        return try endpoint.url(bucket: bucket, key: key, percentEncodedQuery: query)
    }

    // MARK: - Request construction

    private func signedRequest(
        method: String,
        bucket: String?,
        key: String = "",
        query: [(String, String)] = [],
        extraHeaders: [(String, String)] = [],
        body: Data? = nil,
        payloadHash: String? = nil,
        timeout: TimeInterval = 120
    ) throws -> URLRequest {
        let path: String
        if let bucket {
            path = endpoint.rawPath(bucket: bucket, key: key)
        } else {
            path = endpoint.basePath.isEmpty ? "/" : endpoint.basePath
        }
        let host = endpoint.hostHeader(bucket: bucket)
        let hash = payloadHash ?? AWSSigV4.sha256Hex(body ?? Data())
        var headers: [(String, String)] = [("host", host)]
        headers.append(contentsOf: extraHeaders)

        let signature = try AWSSigV4.signHeaders(
            method: method,
            path: path,
            query: query,
            headers: headers,
            payloadHash: hash,
            credentials: credentials,
            region: endpoint.region
        )

        var request = URLRequest(url: try endpoint.url(bucket: bucket, key: key, query: query))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(signature.authorization, forHTTPHeaderField: "Authorization")
        request.setValue(signature.amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(hash, forHTTPHeaderField: "x-amz-content-sha256")
        if let token = credentials.sessionToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "x-amz-security-token")
        }
        return request
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        try await executeWithStatus(request).data
    }

    private func executeWithStatus(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse, statusCode: Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw S3Error(message: "The server returned an invalid response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw S3Error.from(data: data, statusCode: http.statusCode, headers: headerDictionary(http))
            }
            return (data, http, http.statusCode)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as S3Error {
            throw error
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw S3Error.network(error, host: endpoint.displayHost)
        }
    }

    private static func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }

    private func headerDictionary(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                result[key.lowercased()] = value
            }
        }
        return result
    }

    private func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

/// Accumulates per-part byte counts so the transfer UI sees one aggregate number.
private final class MultipartProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let totalBytes: Int64
    private let report: @Sendable (Int64, Int64) -> Void
    private var partBytes: [Int: Int64] = [:]

    init(totalBytes: Int64, report: @escaping @Sendable (Int64, Int64) -> Void) {
        self.totalBytes = totalBytes
        self.report = report
    }

    func update(part: Int, bytes: Int64, length: Int64) {
        lock.lock()
        partBytes[part] = min(max(0, bytes), length)
        let total = partBytes.values.reduce(0, +)
        lock.unlock()
        report(total, totalBytes)
    }

    func complete(part: Int, length: Int64) {
        update(part: part, bytes: length, length: length)
    }
}
