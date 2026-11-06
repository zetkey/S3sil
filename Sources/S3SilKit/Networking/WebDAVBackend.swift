import Foundation
import UniformTypeIdentifiers

/// WebDAV backend implementing StorageBackend. Uses Basic auth, PROPFIND for listing,
/// MKCOL/PUT/GET/DELETE for operations. No buckets; container is always "".
public struct WebDAVBackend: StorageBackend, Sendable {
    public let container: String = ""
    public let capabilities: StorageCapabilities = .none

    private let profile: ConnectionProfile
    private let credentials: S3Credentials
    private let session: URLSession
    private let transferSession: TransferURLSession
    private let baseURL: URL

    public init(profile: ConnectionProfile, credentials: S3Credentials) throws {
        self.profile = profile
        self.credentials = credentials

        guard !profile.endpoint.isEmpty,
              let url = URL(string: profile.endpoint.hasSuffix("/")
                            ? String(profile.endpoint.dropLast())
                            : profile.endpoint) else {
            throw S3Error.validation("WebDAV endpoint URL is missing or invalid.")
        }
        self.baseURL = url

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.transferSession = TransferURLSession()
    }

    // MARK: - StorageBackend

    public func list(prefix: String, maxKeys: Int) async throws -> ObjectListing {
        let url = urlForKey(prefix)
        var request = buildRequest(method: "PROPFIND", url: url)
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.httpBody = propfindBody

        let (data, response) = try await execute(request)
        let entries = try parsePropfind(data, relativeTo: url)
        let limited = Array(entries.prefix(maxKeys))
        return ObjectListing(objects: limited, nextToken: nil, isTruncated: false)
    }

    public func createFolder(_ key: String) async throws {
        let folderKey = key.hasSuffix("/") ? key : key + "/"
        let url = urlForKey(folderKey)
        var request = buildRequest(method: "MKCOL", url: url)
        // Some servers want an empty PUT body with content-type for folders.
        // MKCOL is standard WebDAV; if it fails, fall through to the caller.
        _ = try await executeWithStatus(request)
    }

    public func delete(_ keys: [String],
                       status: @escaping @Sendable (String) -> Void) async throws {
        guard !keys.isEmpty else { return }

        let fileKeys = keys.filter { !$0.hasSuffix("/") }
        let folderKeys = keys.filter { $0.hasSuffix("/") }

        if !fileKeys.isEmpty {
            status("Deleting \(fileKeys.count) item\(fileKeys.count == 1 ? "" : "s")…")
            for key in fileKeys {
                let url = urlForKey(key)
                var request = buildRequest(method: "DELETE", url: url)
                _ = try await executeWithStatus(request)
            }
        }

        for folder in folderKeys {
            status("Listing \(folder)…")
            let nested = try await allKeys(under: folder)
            let total = nested.count + 1
            status("Deleting \(total) item\(total == 1 ? "" : "s") in \(folder)…")
            // Delete files first (not folders), deepest first
            for key in nested.sorted().reversed() {
                let url = urlForKey(key)
                var request = buildRequest(method: "DELETE", url: url)
                _ = try await executeWithStatus(request)
            }
            // Delete the folder itself
            let url = urlForKey(folder)
            var request = buildRequest(method: "DELETE", url: url)
            _ = try await executeWithStatus(request)
        }
    }

    public func download(key: String, to destination: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let url = urlForKey(key)
        let request = buildRequest(method: "GET", url: url)
        let result: HTTPResult
        do {
            result = try await transferSession.download(request, to: destination, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw S3Error.network(error, host: profile.endpoint)
        }
        guard (200..<300).contains(result.statusCode) else {
            throw S3Error.from(data: result.body, statusCode: result.statusCode, headers: result.headers)
        }
    }

    public func upload(fileURL: URL, key: String,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let url = urlForKey(key)
        var request = buildRequest(method: "PUT", url: url)
        let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        request.setValue(mime, forHTTPHeaderField: "Content-Type")

        let result: HTTPResult
        do {
            result = try await transferSession.upload(request, from: fileURL, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw S3Error.network(error, host: profile.endpoint)
        }
        guard (200..<300).contains(result.statusCode) else {
            throw S3Error.from(data: result.body, statusCode: result.statusCode, headers: result.headers)
        }
    }

    // MARK: - Private helpers

    private var propfindBody: Data {
        let xml = """
        <d:propfind xmlns:d="DAV:">\
        <d:prop>\
        <d:displayname/>\
        <d:getcontentlength/>\
        <d:getlastmodified/>\
        <d:getetag/>\
        <d:resourcetype/>\
        <d:getcontenttype/>\
        </d:prop>\
        </d:propfind>
        """
        return Data(xml.utf8)
    }

    private func urlForKey(_ key: String) -> URL {
        guard !key.isEmpty else { return baseURL }
        let encoded = key
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        // If key ends with "/", trailing segment is empty → preserve trailing slash
        let trailing = key.hasSuffix("/") ? "/" : ""
        return URL(string: encoded + trailing, relativeTo: baseURL)?.absoluteURL ?? baseURL
    }

    private func buildRequest(method: String, url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        let auth = "\(credentials.accessKeyID):\(credentials.secretAccessKey)"
        let encoded = Data(auth.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Execution

    private func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response, _) = try await executeWithStatus(request)
        return (data, response)
    }

    @discardableResult
    private func executeWithStatus(_ request: URLRequest) async throws -> (Data, HTTPURLResponse, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw S3Error(message: "The server returned an invalid response.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw S3Error.from(data: data, statusCode: http.statusCode, headers: headerDict(http))
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
            throw S3Error.network(error, host: profile.endpoint)
        }
    }

    private func headerDict(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                result[k.lowercased()] = v
            }
        }
        return result
    }

    // MARK: - Recursive listing for delete

    private func allKeys(under folderPrefix: String) async throws -> [String] {
        var keys: [String] = []
        var stack: [String] = [folderPrefix]
        while let prefix = stack.popLast() {
            let url = urlForKey(prefix)
            var request = buildRequest(method: "PROPFIND", url: url)
            request.setValue("1", forHTTPHeaderField: "Depth")
            request.httpBody = propfindBody
            let (data, _) = try await execute(request)
            let entries = try parsePropfind(data, relativeTo: url)
            for entry in entries {
                keys.append(entry.key)
                if entry.isFolder, entry.key != prefix {
                    stack.append(entry.key)
                }
            }
        }
        return keys
    }

    // MARK: - PROPFIND parsing

    private func parsePropfind(_ data: Data, relativeTo requestURL: URL) throws -> [S3Object] {
        let parser = XMLParser(data: data)
        let delegate = PropfindDelegate(baseURL: baseURL, requestURL: requestURL)
        parser.delegate = delegate
        guard parser.parse() else {
            if let error = parser.parserError {
                throw S3Error(message: "Failed to parse WebDAV response: \(error.localizedDescription)")
            }
            throw S3Error(message: "Failed to parse WebDAV response.")
        }
        return delegate.entries
    }
}

// MARK: - XMLParser delegate for PROPFIND multistatus

private final class PropfindDelegate: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private let requestURL: URL
    var entries: [S3Object] = []

    private var currentPath: [String] = []
    private var currentText: String = ""

    // Per-response accumulators
    private var currentHref: String?
    private var currentDisplayName: String?
    private var currentContentLength: Int64 = 0
    private var currentLastModified: Date?
    private var currentEtag: String?
    private var currentIsCollection: Bool = false
    private var currentContentType: String?
    private var currentPropstatStatus: Int?  // nil until we see the status

    private var insideResponse = false
    private var insidePropstat = false

    init(baseURL: URL, requestURL: URL) {
        self.baseURL = baseURL
        self.requestURL = requestURL
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let localName = stripNamespace(qName ?? elementName)
        currentPath.append(localName)
        currentText = ""

        if localName == "response" {
            insideResponse = true
            resetResponseState()
        } else if localName == "propstat" {
            insidePropstat = true
            currentPropstatStatus = nil
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let localName = stripNamespace(qName ?? elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if insideResponse {
            if insidePropstat {
                switch localName {
                case "status":
                    currentPropstatStatus = parseStatus(text)
                case "getcontentlength":
                    currentContentLength = Int64(text) ?? 0
                case "getlastmodified":
                    currentLastModified = Self.parseDate(text)
                case "getetag":
                    currentEtag = text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                case "displayname":
                    currentDisplayName = text.isEmpty ? nil : text
                case "collection":
                    currentIsCollection = true
                case "getcontenttype":
                    currentContentType = text.isEmpty ? nil : text
                case "propstat":
                    // Only keep values if status was 2xx
                    if let status = currentPropstatStatus, (200..<300).contains(status) {
                        // values already set
                    } else {
                        // Non-2xx propstat: discard
                        currentContentLength = 0
                        currentLastModified = nil
                        currentEtag = ""
                        currentIsCollection = false
                        currentContentType = nil
                        currentDisplayName = nil
                    }
                    insidePropstat = false
                default:
                    break
                }
            } else {
                switch localName {
                case "href":
                    currentHref = text
                case "response":
                    insideResponse = false
                    commitEntry()
                default:
                    break
                }
            }
        }

        currentPath.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    // MARK: - Private

    private func stripNamespace(_ name: String) -> String {
        if let idx = name.lastIndex(of: ":") {
            return String(name[name.index(after: idx)...])
        }
        return name
    }

    private func resetResponseState() {
        currentHref = nil
        currentDisplayName = nil
        currentContentLength = 0
        currentLastModified = nil
        currentEtag = ""
        currentIsCollection = false
        currentContentType = nil
        currentPropstatStatus = nil
    }

    private func parseStatus(_ text: String) -> Int? {
        // "HTTP/1.1 200 OK" → 200
        let parts = text.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    private func commitEntry() {
        guard let href = currentHref, !href.isEmpty else { return }

        // Decode percent-encoded href
        let decoded = href.removingPercentEncoding ?? href

        // Normalize: make it relative to baseURL
        let key = normalizeKey(from: decoded)

        // Skip self-referencing entry
        let requestPath = requestURL.path.hasSuffix("/") ? requestURL.path : requestURL.path + "/"
        let entryPath = key.hasSuffix("/") ? key : key + "/"
        let requestKey = String(requestPath.dropFirst(baseURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let entryKey = key.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if requestKey == entryKey, !key.isEmpty { return }
        if key.isEmpty { return }

        // Determine kind
        let isFolder: Bool = currentIsCollection
            || key.hasSuffix("/")
            || (currentContentType?.lowercased().contains("directory") == true)
        let kind: S3Object.Kind = isFolder ? .folder : .file

        let name = currentDisplayName
            ?? key.split(separator: "/").last.map(String.init)
            ?? key

        let entry = S3Object(
            key: key,
            name: name,
            size: currentContentLength,
            lastModified: currentLastModified,
            etag: currentEtag ?? "",
            storageClass: nil,
            kind: kind
        )
        entries.append(entry)
    }

    /// Convert an absolute or relative href to a key relative to baseURL root.
    private func normalizeKey(from href: String) -> String {
        // If href is a full URL, strip scheme and host
        let path: String
        if href.hasPrefix("http://") || href.hasPrefix("https://") {
            guard let url = URL(string: href) else { return href }
            path = url.path
        } else {
            path = href.hasPrefix("/") ? href : "/" + href
        }

        // Strip baseURL path prefix
        let basePath = baseURL.path.hasSuffix("/") ? baseURL.path : baseURL.path + "/"
        var relative = path
        if path.hasPrefix(basePath) {
            relative = String(path.dropFirst(basePath.count))
        } else if path.hasPrefix("/") {
            relative = String(path.dropFirst(1))
        }

        // Remove leading slash
        if relative.hasPrefix("/") {
            relative = String(relative.dropFirst(1))
        }

        return relative
    }

    private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",  // RFC 1123
            "yyyy-MM-dd'T'HH:mm:ssZ",          // ISO 8601
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        ]
        return formats.map { fmt in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(secondsFromGMT: 0)
            df.dateFormat = fmt
            return df
        }
    }()

    static func parseDate(_ value: String) -> Date? {
        for formatter in dateFormatters {
            if let date = formatter.date(from: value) { return date }
        }
        // Try ISO8601DateFormatter as fallback
        if #available(macOS 10.12, *) {
            return ISO8601DateFormatter().date(from: value)
        }
        return nil
    }
}