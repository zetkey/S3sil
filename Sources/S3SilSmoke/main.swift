import Foundation
import S3SilKit

// End-to-end smoke harness for any S3-compatible endpoint (primarily MinIO).
// Credentials come from the environment and are never printed.
//
// Required: MINIO_ENDPOINT, MINIO_ACCESS_KEY, MINIO_SECRET_KEY
// Optional: MINIO_REGION (default us-east-1)

enum SmokeError: LocalizedError {
    case missing(String)
    case assertion(String)
    case curl(Int32)

    var errorDescription: String? {
        switch self {
        case .missing(let name): return "Missing environment variable \(name)"
        case .assertion(let message): return message
        case .curl(let code): return "curl exited with status \(code)"
        }
    }
}

func requiredEnvironment(_ name: String) -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        FileHandle.standardError.write(Data("""
        error: \(name) is required.
        usage: MINIO_ENDPOINT=... MINIO_ACCESS_KEY=... MINIO_SECRET_KEY=... swift run S3SilSmoke

        """.utf8))
        exit(2)
    }
    return value
}

func log(_ message: String) {
    print(message)
    fflush(stdout)
}

struct CurlFetch {
    let status: Int
    let body: Data
}

func fetchWithCurl(_ url: URL) throws -> CurlFetch {
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("s3sil-curl-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = [
        "-sS", "--max-time", "30",
        "-o", outputURL.path,
        "-w", "%{http_code}",
        url.absoluteString
    ]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()

    let statusText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw SmokeError.curl(process.terminationStatus)
    }
    let body = (try? Data(contentsOf: outputURL)) ?? Data()
    return CurlFetch(status: Int(statusText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0, body: body)
}

let endpointText = requiredEnvironment("MINIO_ENDPOINT")
let accessKey = requiredEnvironment("MINIO_ACCESS_KEY")
let secretKey = requiredEnvironment("MINIO_SECRET_KEY")
let region = ProcessInfo.processInfo.environment["MINIO_REGION"] ?? "us-east-1"

let bucket = "s3sil-smoke-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8).lowercased())"
let payload = Data("hello from S3Sil — 你好 🌍".utf8)
let unicodeKey = "smoke/hello world-😀.txt"
let uploadKey = "smoke/uploaded file-😀.txt"
let objects: [(key: String, data: Data)] = [
    ("smoke/a.txt", Data("alpha".utf8)),
    ("smoke/b.txt", Data("bravo".utf8)),
    (unicodeKey, payload),
    (uploadKey, payload),
    ("smoke/nested/one.txt", Data("one".utf8)),
    ("smoke/nested/two.txt", Data("two".utf8))
]
let uploadSource = FileManager.default.temporaryDirectory
    .appendingPathComponent("s3sil-upload-\(UUID().uuidString).txt")
try? Data(payload).write(to: uploadSource)
defer { try? FileManager.default.removeItem(at: uploadSource) }

let profile = ConnectionProfile(
    name: "MinIO Smoke",
    provider: .minio,
    endpoint: endpointText,
    region: region
)
let credentials = S3Credentials(accessKeyID: accessKey, secretAccessKey: secretKey)

let mode = CommandLine.arguments.dropFirst().first

if mode == "--seed", CommandLine.arguments.count >= 3 {
    let bucket = CommandLine.arguments[2]
    do {
        let client = try S3Client(profile: profile, credentials: credentials)
        _ = try await client.createBucket(bucket)
        let demo: [(key: String, body: String, type: String)] = [
            ("README.txt", "S3Sil demo bucket\n", "text/plain; charset=utf-8"),
            ("Design/brand-guide.pdf", "%PDF-1.4\nS3Sil demo placeholder\n", "application/pdf"),
            ("Design/icons/logo.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"/>", "image/svg+xml"),
            ("Documents/Quarterly report.pdf", "%PDF-1.4\nQuarterly report\n", "application/pdf"),
            ("Documents/hello world-😀.txt", "Live MinIO data, unicode key\n", "text/plain; charset=utf-8"),
            ("photos/2024/sunrise.jpg", "demo image bytes", "image/jpeg"),
            ("photos/2024/sunset.jpg", "demo image bytes", "image/jpeg")
        ]
        for item in demo {
            _ = try await client.putObject(
                bucket: bucket,
                key: item.key,
                data: Data(item.body.utf8),
                contentType: item.type
            )
        }
        log("Seeded bucket \(bucket) with \(demo.count) objects")
    } catch {
        let message = (error as? S3Error)?.alertMessage ?? error.localizedDescription
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
    exit(0)
}

if mode == "--list" || mode == "--delete-bucket" {
    do {
        let client = try S3Client(profile: profile, credentials: credentials)
        if mode == "--list" {
            let buckets = try await client.listBuckets()
            for bucket in buckets.sorted(by: { $0.name < $1.name }) {
                log(bucket.name)
            }
        } else {
            for name in CommandLine.arguments.dropFirst(2) {
                try await purgeBucket(name, client: client)
            }
        }
    } catch {
        let message = (error as? S3Error)?.alertMessage ?? error.localizedDescription
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
    exit(0)
}

var createdBucket = false
var uploadedKeys: [String] = []

@MainActor
func cleanup(_ client: S3Client) async {
    if !uploadedKeys.isEmpty {
        _ = try? await client.deleteObjects(bucket: bucket, keys: uploadedKeys)
        uploadedKeys = []
    }
    if createdBucket {
        _ = try? await client.deleteBucket(bucket)
        createdBucket = false
    }
}


@MainActor
func purgeBucket(_ name: String, client: S3Client) async throws {
    var token: String?
    var keys: [String] = []
    repeat {
        let page = try await client.listObjects(
            bucket: name,
            prefix: "",
            delimiter: nil,
            continuationToken: token,
            maxKeys: 1000
        )
        keys.append(contentsOf: page.objects.map(\.key))
        token = page.isTruncated ? page.nextToken : nil
    } while token != nil

    for start in stride(from: 0, to: keys.count, by: 1000) {
        let chunk = Array(keys[start..<min(start + 1000, keys.count)])
        _ = try await client.deleteObjects(bucket: name, keys: chunk)
    }
    let status = try await client.deleteBucket(name)
    log("Deleted bucket \(name) (HTTP \(status))")
}

do {
    let multipartPartSize: Int64 = 5 * 1024 * 1024
    let multipartKey = "multipart/large-\(UUID().uuidString).bin"
    let multipartSource = FileManager.default.temporaryDirectory
        .appendingPathComponent("s3sil-multipart-\(UUID().uuidString).bin")
    var multipartFixture = Data(capacity: 12 * 1024 * 1024)
    for index in 0..<(12 * 1024 * 1024) {
        multipartFixture.append(UInt8(truncatingIfNeeded: index))
    }
    try multipartFixture.write(to: multipartSource)
    defer { try? FileManager.default.removeItem(at: multipartSource) }

    let client = try S3Client(profile: profile, credentials: credentials)
    log("Endpoint: \(endpointText) (region \(region), path-style)")

    let before = try await client.listBuckets()
    log("GET / (ListBuckets): OK, \(before.count) bucket(s)")

    let createStatus = try await client.createBucket(bucket)
    createdBucket = true
    log("PUT /\(bucket) (CreateBucket): HTTP \(createStatus)")

    do {
        let acl = try await client.getBucketACL(bucket)
        log("GET /\(bucket)?acl: owner \(acl.ownerDisplayName ?? acl.ownerID), \(acl.grants.count) grant(s)")
        do {
            try await client.putBucketACL(bucket, cannedACL: .publicRead)
            let updated = try await client.getBucketACL(bucket)
            let isPublic = updated.grants.contains {
                $0.granteeType == .group && $0.uri?.contains("AllUsers") == true
            }
            log("PUT /\(bucket)?acl (public-read): HTTP 200; re-read \(updated.grants.count) grant(s), public-read=\(isPublic)")
        } catch {
            let failure = error as? S3Error
            log("PUT /\(bucket)?acl (public-read): not applied — " +
                "\(failure?.code ?? "error") / HTTP \(failure?.statusCode.map(String.init) ?? "?")")
        }
    } catch {
        let failure = error as? S3Error
        log("GET /\(bucket)?acl: not available — " +
            "\(failure?.code ?? "error") / HTTP \(failure?.statusCode.map(String.init) ?? "?")" +
            (failure?.aclUnavailableReason.map { " — \($0)" } ?? ""))
    }

    for object in objects {
        if object.key == uploadKey {
            try await client.upload(fileURL: uploadSource, bucket: bucket, key: object.key)
            let uploadedHead = try await client.headObject(bucket: bucket, key: object.key)
            guard uploadedHead.size == Int64(object.data.count) else {
                throw SmokeError.assertion("File upload size did not match")
            }
            uploadedKeys.append(object.key)
            log("PUT /\(bucket)/\(object.key) (\(object.data.count) bytes, file upload): OK")
        } else {
            let status = try await client.putObject(
                bucket: bucket,
                key: object.key,
                data: object.data,
                contentType: "text/plain; charset=utf-8"
            )
            uploadedKeys.append(object.key)
            log("PUT /\(bucket)/\(object.key) (\(object.data.count) bytes): HTTP \(status)")
        }
    }

    let multipartData = try Data(contentsOf: multipartSource)
    guard let multipartPlan = MultipartUploadPlan.plan(
        totalBytes: Int64(multipartData.count),
        partSize: multipartPartSize,
        threshold: 0
    ) else {
        throw SmokeError.assertion("Multipart plan was nil for a 12 MiB file")
    }
    try await client.multipartUpload(
        fileURL: multipartSource,
        bucket: bucket,
        key: multipartKey,
        partSize: multipartPartSize
    )
    uploadedKeys.append(multipartKey)
    log("POST /\(bucket)/\(multipartKey)?uploads (Initiate): OK, " +
        "\(multipartPlan.partCount) parts of \(multipartPlan.partSize) bytes")

    let multipartHead = try await client.headObject(bucket: bucket, key: multipartKey)
    guard multipartHead.size == Int64(multipartData.count) else {
        throw SmokeError.assertion(
            "Multipart HEAD size \(multipartHead.size) did not match \(multipartData.count)"
        )
    }
    let multipartDownload = FileManager.default.temporaryDirectory
        .appendingPathComponent("s3sil-multipart-download-\(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: multipartDownload) }
    try await client.download(bucket: bucket, key: multipartKey, to: multipartDownload)
    let downloadedMultipart = try Data(contentsOf: multipartDownload)
    guard downloadedMultipart == multipartData else {
        throw SmokeError.assertion("Multipart download bytes did not match uploaded bytes")
    }
    log("Multipart upload complete + HEAD + signed download: OK, " +
        "\(downloadedMultipart.count) bytes, ETag \(multipartHead.etag)")

    let after = try await client.listBuckets()
    guard after.contains(where: { $0.name == bucket }) else {
        throw SmokeError.assertion("Created bucket did not appear in ListBuckets")
    }
    log("GET / (ListBuckets): OK, created bucket is visible")

    let head = try await client.headObject(bucket: bucket, key: unicodeKey)
    guard head.size == Int64(payload.count) else {
        throw SmokeError.assertion("HEAD size \(head.size) did not match \(payload.count)")
    }
    guard !head.etag.isEmpty else {
        throw SmokeError.assertion("HEAD returned no ETag")
    }
    log("HEAD /\(bucket)/\(unicodeKey): HTTP \(head.statusCode), \(head.size) bytes, ETag \(head.etag)")

    var token: String?
    var pages = 0
    var listedFiles = Set<String>()
    var listedPrefixes = Set<String>()
    repeat {
        let page = try await client.listObjects(
            bucket: bucket,
            prefix: "smoke/",
            delimiter: "/",
            continuationToken: token,
            maxKeys: 2
        )
        pages += 1
        for object in page.objects {
            if object.isFolder {
                listedPrefixes.insert(object.key)
            } else {
                listedFiles.insert(object.key)
            }
        }
        let shown = page.objects.map { $0.isFolder ? $0.key : $0.name }.joined(separator: ", ")
        log("GET ?list-type=2&prefix=smoke/&delimiter=/&max-keys=2 page \(pages): \(shown)" +
            (page.isTruncated ? " [continuation token]" : " [end]"))
        token = page.isTruncated ? page.nextToken : nil
    } while token != nil

    guard pages >= 2 else {
        throw SmokeError.assertion("Pagination was not exercised (only \(pages) page)")
    }
    guard listedFiles == Set(objects.filter { !$0.key.hasPrefix("smoke/nested/") }.map(\.key)) else {
        throw SmokeError.assertion("Delimited listing returned unexpected files: \(listedFiles)")
    }
    guard listedPrefixes == ["smoke/nested/"] else {
        throw SmokeError.assertion("Delimited listing returned unexpected prefixes: \(listedPrefixes)")
    }
    log("Pagination + delimiter: \(pages) pages, \(listedFiles.count) files, prefixes \(listedPrefixes.sorted())")

    var recursiveKeys = Set<String>()
    token = nil
    var recursivePages = 0
    repeat {
        let page = try await client.listObjects(
            bucket: bucket,
            prefix: "smoke/",
            delimiter: nil,
            continuationToken: token,
            maxKeys: 2
        )
        recursivePages += 1
        recursiveKeys.formUnion(page.objects.map(\.key))
        token = page.isTruncated ? page.nextToken : nil
    } while token != nil
    guard recursiveKeys == Set(objects.map(\.key)) else {
        throw SmokeError.assertion("Recursive listing returned \(recursiveKeys.count) of \(objects.count) keys")
    }
    log("Recursive pagination (max-keys=2): \(recursivePages) pages, all \(recursiveKeys.count) keys")

    let downloadURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("s3sil-smoke-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: downloadURL) }
    try await client.download(bucket: bucket, key: unicodeKey, to: downloadURL)
    let downloaded = try Data(contentsOf: downloadURL)
    guard downloaded == payload else {
        throw SmokeError.assertion("Downloaded bytes did not match uploaded bytes")
    }
    log("GET /\(bucket)/\(unicodeKey) (signed download): OK, \(downloaded.count) bytes")

    let presigned = try await client.presignedURL(bucket: bucket, key: unicodeKey, expires: 300)
    let fetched = try fetchWithCurl(presigned)
    guard fetched.status == 200 else {
        throw SmokeError.assertion("Presigned curl request returned HTTP \(fetched.status)")
    }
    guard fetched.body == payload else {
        throw SmokeError.assertion("Presigned curl body did not match uploaded bytes")
    }
    log("GET presigned URL via curl: HTTP \(fetched.status), \(fetched.body.count) bytes (signature verified)")

    let failures = try await client.deleteObjects(bucket: bucket, keys: uploadedKeys)
    guard failures.isEmpty else {
        throw SmokeError.assertion("DeleteObjects reported \(failures.count) failure(s)")
    }
    uploadedKeys = []
    log("POST /\(bucket)?delete (DeleteObjects): HTTP 200, 0 failures")

    let remaining = try await client.listObjects(bucket: bucket, prefix: "", delimiter: nil)
    guard remaining.objects.isEmpty else {
        throw SmokeError.assertion("Objects remained after delete: \(remaining.objects.map(\.key))")
    }
    log("GET ?list-type=2 (root, after delete): 0 objects")

    let deleteStatus = try await client.deleteBucket(bucket)
    createdBucket = false
    log("DELETE /\(bucket) (DeleteBucket): HTTP \(deleteStatus)")

    let finalBuckets = try await client.listBuckets()
    guard !finalBuckets.contains(where: { $0.name == bucket }) else {
        throw SmokeError.assertion("Deleted bucket still appears in ListBuckets")
    }
    log("GET / (ListBuckets): OK, test bucket removed")
    log("PASS: list, create, put, paginate, head, get, presign, delete object, delete bucket")
} catch {
    let message = (error as? S3Error)?.alertMessage ?? error.localizedDescription
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    if let client = try? S3Client(profile: profile, credentials: credentials) {
        await cleanup(client)
    }
    exit(1)
}
