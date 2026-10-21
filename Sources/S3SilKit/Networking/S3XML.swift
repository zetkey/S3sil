import Foundation

public struct XMLNode: Equatable, Sendable {
    public var name: String
    public var text: String
    public var children: [XMLNode]
    /// Attribute names as reported by XMLParser, including any prefix (e.g. "xsi:type").
    public var attributes: [String: String]

    public init(
        name: String,
        text: String = "",
        children: [XMLNode] = [],
        attributes: [String: String] = [:]
    ) {
        self.name = name
        self.text = text
        self.children = children
        self.attributes = attributes
    }

    public func child(_ name: String) -> XMLNode? {
        children.first { $0.name == name }
    }

    public func children(named name: String) -> [XMLNode] {
        children.filter { $0.name == name }
    }

    /// Matches an exact attribute name first, then falls back to the local name
    /// so `attribute("type")` finds `xsi:type`.
    public func attribute(_ name: String) -> String? {
        if let exact = attributes[name] { return exact }
        let local = Self.localName(name)
        return attributes.first { Self.localName($0.key) == local }?.value
    }

    private static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

final class XMLNodeBuilder: NSObject, XMLParserDelegate {
    private var stack: [XMLNode] = []
    private(set) var root: XMLNode?
    private(set) var parseError: Error?

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        stack.append(XMLNode(name: localName(elementName), attributes: attributeDict))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty, let string = String(data: CDATABlock, encoding: .utf8) else { return }
        stack[stack.count - 1].text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let node = stack.popLast() else { return }
        if stack.isEmpty {
            root = node
        } else {
            stack[stack.count - 1].children.append(node)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

public enum S3XML {
    public static func parse(_ data: Data) throws -> XMLNode {
        guard !data.isEmpty else {
            throw S3Error(message: "The endpoint returned an empty response.")
        }
        let builder = XMLNodeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else {
            let underlying = builder.parseError?.localizedDescription
                ?? parser.parserError?.localizedDescription
            throw S3Error(message: "The endpoint returned an unreadable XML response.",
                          underlying: underlying)
        }
        return root
    }

    public static func parseBuckets(_ data: Data) throws -> [Bucket] {
        let root = try parse(data)
        let nodes = root.child("Buckets")?.children(named: "Bucket")
            ?? root.children(named: "Bucket")
        let dates = DateParser()
        return nodes.compactMap { node in
            guard let name = node.child("Name")?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            let created = node.child("CreationDate")
            let creationDate = created.flatMap { dates.parse($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return Bucket(name: name, creationDate: creationDate)
        }
    }

    public static func parseObjectListing(
        _ data: Data,
        prefix: String,
        delimiter: String?
    ) throws -> ObjectListing {
        let root = try parse(data)
        guard root.name == "ListBucketResult" || root.child("Contents") != nil
                || root.child("CommonPrefixes") != nil else {
            throw S3Error(message: "The endpoint did not return an object listing.",
                          underlying: "Unexpected root element “\(root.name)”.")
        }
        let dates = DateParser()
        var objects: [S3Object] = []
        var seen = Set<String>()
        // HCP and B2 return folder markers as zero-byte Contents objects, including
        // the current parent folder. Only delimited listings can distinguish them
        // from files; recursive listings must keep markers so deletion removes them.
        let isDelimited = !(delimiter?.isEmpty ?? true)

        func append(_ object: S3Object) {
            guard seen.insert(object.key).inserted else { return }
            objects.append(object)
        }

        for node in root.children(named: "Contents") {
            guard let key = node.child("Key")?.text, !key.isEmpty else { continue }
            if isDelimited, key == prefix { continue }
            if isDelimited, key.hasSuffix("/") {
                append(S3Object(
                    key: key,
                    name: displayName(key: key, prefix: prefix, isFolder: true),
                    kind: .folder
                ))
                continue
            }
            let etag = (node.child("ETag")?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let size = Int64(node.child("Size")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            let modified: Date?
            if let modifiedNode = node.child("LastModified") {
                modified = dates.parse(modifiedNode.text.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                modified = nil
            }
            let storage = node.child("StorageClass")?.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            append(S3Object(
                key: key,
                name: displayName(key: key, prefix: prefix, isFolder: false),
                size: size,
                lastModified: modified,
                etag: etag,
                storageClass: storage?.isEmpty == true ? nil : storage,
                kind: .file
            ))
        }

        for node in root.children(named: "CommonPrefixes") {
            guard let prefixKey = node.child("Prefix")?.text, !prefixKey.isEmpty else { continue }
            if isDelimited, prefixKey == prefix { continue }
            append(S3Object(
                key: prefixKey,
                name: displayName(key: prefixKey, prefix: prefix, isFolder: true),
                kind: .folder
            ))
        }

        let truncated = (root.child("IsTruncated")?.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
        let token = root.child("NextContinuationToken")?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ObjectListing(
            objects: objects,
            nextToken: token?.isEmpty == false ? token : nil,
            isTruncated: truncated
        )
    }

    public static func parseDeleteFailures(_ data: Data) throws -> [DeleteFailure] {
        let root = try parse(data)
        return root.children(named: "Error").map { node in
            DeleteFailure(
                key: node.child("Key")?.text ?? "",
                code: node.child("Code")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown",
                message: node.child("Message")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
    }

    /// Request body for CreateBucket. AWS sends a location outside us-east-1;
    /// other providers take no location body, even with a non-default region.
    public static func createBucketConfiguration(provider: ProviderKind, region: String) -> Data? {
        guard provider == .aws else { return nil }
        let region = region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !region.isEmpty, region.lowercased() != "us-east-1" else { return nil }
        let xml = """
        <CreateBucketConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
        <LocationConstraint>\(escape(region))</LocationConstraint>\
        </CreateBucketConfiguration>
        """
        return Data(xml.utf8)
    }

    public static func parseUploadID(_ data: Data) throws -> String {
        let root = try parse(data)
        guard let uploadID = root.child("UploadId")?.text
            .trimmingCharacters(in: .whitespacesAndNewlines), !uploadID.isEmpty else {
            throw S3Error(
                message: "The endpoint did not return a multipart upload ID.",
                underlying: "Unexpected root element “\(root.name)”."
            )
        }
        return uploadID
    }

    public static func completeMultipartUploadBody(parts: [UploadedPart]) -> Data {
        var xml = "<CompleteMultipartUpload>"
        for part in parts {
            let etag = quotedETag(part.etag)
            xml += "<Part><PartNumber>\(part.partNumber)</PartNumber>" +
                "<ETag>\(escape(etag))</ETag></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        return Data(xml.utf8)
    }

    public static func parseBucketACL(_ data: Data) throws -> BucketACL {
        let root = try parse(data)
        guard root.name == "AccessControlPolicy" || root.child("AccessControlList") != nil else {
            throw S3Error(
                message: "The endpoint did not return a bucket ACL.",
                underlying: "Unexpected root element “\(root.name)”."
            )
        }
        let owner = root.child("Owner")
        let ownerID = owner?.child("ID")?.text
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ownerName = owner?.child("DisplayName")?.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let grantNodes = (root.child("AccessControlList") ?? root).children(named: "Grant")
        let grants = grantNodes.map { node -> BucketACL.Grant in
            let grantee = node.child("Grantee")
            let uri = grantee?.child("URI")?.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let granteeID = grantee?.child("ID")?.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = grantee?.child("DisplayName")?.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let declared = (grantee?.attribute("xsi:type") ?? grantee?.attribute("type"))
                .flatMap { BucketACL.GranteeType(rawValue: $0) }
            let inferred: BucketACL.GranteeType
            if let uri, !uri.isEmpty {
                inferred = .group
            } else if let granteeID, !granteeID.isEmpty {
                inferred = .canonicalUser
            } else {
                inferred = .unknown
            }
            return BucketACL.Grant(
                granteeType: declared ?? inferred,
                displayName: displayName?.isEmpty == false ? displayName : nil,
                uri: uri?.isEmpty == false ? uri : nil,
                granteeID: granteeID?.isEmpty == false ? granteeID : nil,
                permission: node.child("Permission")?.text
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
        return BucketACL(
            ownerID: ownerID,
            ownerDisplayName: ownerName?.isEmpty == false ? ownerName : nil,
            grants: grants
        )
    }

    public static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func quotedETag(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") { return trimmed }
        return "\"\(trimmed)\""
    }

    static func displayName(key: String, prefix: String, isFolder: Bool) -> String {
        var rest = key
        if !prefix.isEmpty, rest.hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
        }
        if isFolder, rest.hasSuffix("/") {
            rest.removeLast()
        }
        if rest.isEmpty {
            rest = key.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? key
        }
        return rest
    }
}

private final class DateParser {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    func parse(_ string: String) -> Date? {
        fractional.date(from: string) ?? plain.date(from: string)
    }
}
