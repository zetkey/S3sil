import Foundation

/// Pure helpers for turning object rows into Finder-friendly dragged files.
public enum DragExport {
    /// The file name a promise should publish. Object names are already leaf-relative,
    /// but be defensive about separators and Finder-reserved names.
    public static func safeFileName(_ rawName: String) -> String {
        var name = (rawName as NSString).lastPathComponent
        // ":" is reserved by the classic Mac file system; control characters are never valid.
        name = name.replacingOccurrences(of: ":", with: "-")
        name = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." {
            return "download"
        }
        return name
    }

    /// Non-folder objects in listing order, restricted to the current selection.
    public static func fileObjects(in objects: [S3Object], selectedKeys: Set<String>) -> [S3Object] {
        objects.filter { !$0.isFolder && selectedKeys.contains($0.key) }
    }
}
