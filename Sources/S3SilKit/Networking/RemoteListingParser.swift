import Foundation

/// Shared parser for FTP LIST / MLSD output, reused by FTP and SFTP backends.
public enum RemoteListingParser {

    public struct ParsedEntry: Sendable {
        public let name: String
        public let isDirectory: Bool
        public let size: Int64
        public let lastModified: Date?

        public init(name: String, isDirectory: Bool, size: Int64, lastModified: Date?) {
            self.name = name
            self.isDirectory = isDirectory
            self.size = size
            self.lastModified = lastModified
        }
    }

    /// Parses raw LIST/MLSD output lines into entries.
    /// - If any line matches MLSD format, uses MLSD parser.
    /// - Otherwise tries Unix, then DOS.
    public static func parse(listing: String) -> [ParsedEntry] {
        let lines = listing.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return [] }

        if lines.contains(where: { isMLSDLine(String($0)) }) {
            return lines.compactMap { parseMLSDLine(String($0)) }
        }

        let unixEntries = lines.compactMap { parseUnixLine(String($0)) }
        if !unixEntries.isEmpty {
            return unixEntries
        }

        return lines.compactMap { parseDOSLine(String($0)) }
    }

    // MARK: - MLSD (RFC 3659)

    private static let mlsdDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func isMLSDLine(_ line: String) -> Bool {
        line.contains("; ") && line.contains("=") && !line.hasPrefix("d") && !line.hasPrefix("-") && !line.hasPrefix("l")
    }

    public static func parseMLSDLine(_ line: String) -> ParsedEntry? {
        guard let semiIndex = line.lastIndex(of: ";") else { return nil }
        let factPart = String(line[..<semiIndex])
        let filename = String(line[line.index(after: semiIndex)...]).trimmingCharacters(in: .whitespaces)

        let facts = factPart.split(separator: ";").reduce(into: [String: String]()) { dict, fact in
            let trimmed = fact.trimmingCharacters(in: .whitespaces)
            let kv = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { dict[kv[0].lowercased()] = kv[1] }
        }

        let isDirectory: Bool
        switch facts["type"] {
        case "dir": isDirectory = true
        default:    isDirectory = false
        }

        let size = Int64(facts["size"] ?? "0") ?? 0
        let lastModified = facts["modify"].flatMap { mlsdDateFormatter.date(from: String($0)) }

        return ParsedEntry(
            name: filename,
            isDirectory: isDirectory,
            size: size,
            lastModified: lastModified
        )
    }

    // MARK: - Unix `ls -l`

    /// Matches e.g. `drwxr-xr-x  2 user group  4096 Jan 01 12:00 filename`
    private static let unixLineRegex = try! NSRegularExpression(
        pattern: "^([d\\-l])([rwxSstT\\-]{9})\\s+\\d+\\s+\\S+\\s+\\S+\\s+(\\d+)\\s+" +
                 "(\\w{3})\\s+(\\d{1,2})\\s+(\\d{1,2}:\\d{2})\\s+(.+)$"
    )

    public static func parseUnixLine(_ line: String) -> ParsedEntry? {
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = unixLineRegex.firstMatch(in: line, range: nsRange),
              let typeRange = Range(match.range(at: 1), in: line),
              let sizeRange = Range(match.range(at: 3), in: line),
              let monthRange = Range(match.range(at: 4), in: line),
              let dayRange = Range(match.range(at: 5), in: line),
              let timeRange = Range(match.range(at: 6), in: line),
              let nameRange = Range(match.range(at: 7), in: line)
        else { return nil }

        let typeChar = line[typeRange]
        let isDirectory = typeChar == "d"
        let size = Int64(line[sizeRange]) ?? 0
        let name = String(line[nameRange])

        let month = String(line[monthRange])
        let day = String(line[dayRange])
        let time = String(line[timeRange])
        let dateString = "\(month) \(day) \(time)"

        let date = parseUnixDate(dateString)

        return ParsedEntry(name: name, isDirectory: isDirectory, size: size, lastModified: date)
    }

    private static func parseUnixDate(_ s: String) -> Date? {
        let withYear: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MMM d HH:mm yyyy"
            f.timeZone = TimeZone.current
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()

        let parts = s.split(separator: " ")
        guard parts.count >= 3 else { return nil }

        if parts[2].contains(":") {
            // Format: "Jan 01 12:00" — use current year
            let currentYear = Calendar.current.component(.year, from: Date())
            return withYear.date(from: "\(parts[0]) \(parts[1]) \(parts[2]) \(currentYear)")
        } else {
            // Format: "Jan 01  2024" — has a year
            let yearString = parts[2].trimmingCharacters(in: .whitespaces)
            return withYear.date(from: "\(parts[0]) \(parts[1]) 00:00 \(yearString)")
        }
    }

    // MARK: - DOS `dir`

    /// Matches e.g. `01-01-23  12:00PM       <DIR>          dirname`
    private static let dosDirRegex = try! NSRegularExpression(
        pattern: "^(\\d{2}-\\d{2}-\\d{2,4})\\s+(\\d{1,2}:\\d{2}[APap][Mm])\\s+<DIR>\\s+(.+)$"
    )
    private static let dosFileRegex = try! NSRegularExpression(
        pattern: "^(\\d{2}-\\d{2}-\\d{2,4})\\s+(\\d{1,2}:\\d{2}[APap][Mm])\\s+(\\d+)\\s+(.+)$"
    )

    public static func parseDOSLine(_ line: String) -> ParsedEntry? {
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)

        // Try directory first
        if let match = dosDirRegex.firstMatch(in: line, range: nsRange),
           let dateRange = Range(match.range(at: 1), in: line),
           let timeRange = Range(match.range(at: 2), in: line),
           let nameRange = Range(match.range(at: 3), in: line) {
            let date = parseDOSDate(String(line[dateRange]), String(line[timeRange]))
            return ParsedEntry(
                name: String(line[nameRange]).trimmingCharacters(in: .whitespaces),
                isDirectory: true, size: 0, lastModified: date
            )
        }

        // Try file
        if let match = dosFileRegex.firstMatch(in: line, range: nsRange),
           let dateRange = Range(match.range(at: 1), in: line),
           let timeRange = Range(match.range(at: 2), in: line),
           let sizeRange = Range(match.range(at: 3), in: line),
           let nameRange = Range(match.range(at: 4), in: line) {
            let date = parseDOSDate(String(line[dateRange]), String(line[timeRange]))
            return ParsedEntry(
                name: String(line[nameRange]).trimmingCharacters(in: .whitespaces),
                isDirectory: false,
                size: Int64(line[sizeRange]) ?? 0,
                lastModified: date
            )
        }

        return nil
    }

    private static func parseDOSDate(_ dateStr: String, _ timeStr: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "MM-dd-yy hh:mma"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: "\(dateStr) \(timeStr.lowercased())")
    }
}