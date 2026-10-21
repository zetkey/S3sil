import Foundation
import Observation
import S3SilKit

@MainActor
@Observable
final class ObjectBrowserModel {
    let profile: ConnectionProfile
    let bucket: String
    let client: S3Client
    let identity = UUID()

    var prefix: String
    var objects: [S3Object] = []
    var selection: Set<String> = []
    var searchText = ""
    var isLoading = false
    var isLoadingMore = false
    var isDeleting = false
    var deleteStatus: String?
    var loadError: S3Error?
    var loadMoreError: String?
    var hasMore = false

    private var nextToken: String?
    private var generation = 0
    private let onError: (S3Error) -> Void

    init(profile: ConnectionProfile, bucket: String, client: S3Client,
         onError: @escaping (S3Error) -> Void) {
        self.profile = profile
        self.bucket = bucket
        self.client = client
        self.prefix = ""
        self.onError = onError
    }

    var selectedObjects: [S3Object] {
        objects.filter { selection.contains($0.key) }
    }

    var filteredObjects: [S3Object] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return objects }
        return objects.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    var segments: [(name: String, prefix: String)] {
        var result: [(String, String)] = []
        var running = prefix.hasPrefix("/") ? "/" : ""
        for part in prefix.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty { continue }
            running += part + "/"
            result.append((String(part), running))
        }
        return result
    }

    // MARK: - Loading

    func loadInitial() async {
        guard objects.isEmpty, !isLoading else { return }
        await reload()
    }

    func reload(clearSelection: Bool = false) async {
        generation += 1
        let generation = self.generation
        isLoading = true
        isLoadingMore = false
        loadError = nil
        loadMoreError = nil
        if clearSelection { selection.removeAll() }

        do {
            let page = try await client.listObjects(
                bucket: bucket,
                prefix: prefix,
                delimiter: "/",
                continuationToken: nil
            )
            guard generation == self.generation else { return }
            objects = Self.sorted(page.objects)
            nextToken = page.nextToken
            hasMore = page.isTruncated && page.nextToken != nil
            let keys = Set(objects.map(\.key))
            selection.formIntersection(keys)
        } catch is CancellationError {
            return
        } catch {
            guard generation == self.generation else { return }
            loadError = error as? S3Error ?? S3Error(message: error.localizedDescription)
        }

        if generation == self.generation {
            isLoading = false
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore, let token = nextToken else { return }
        let generation = self.generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        loadMoreError = nil

        do {
            let page = try await client.listObjects(
                bucket: bucket,
                prefix: prefix,
                delimiter: "/",
                continuationToken: token
            )
            guard generation == self.generation else { return }
            let existing = Set(objects.map(\.key))
            objects = Self.sorted(objects + page.objects.filter { !existing.contains($0.key) })
            nextToken = page.nextToken
            hasMore = page.isTruncated && page.nextToken != nil && page.nextToken != token
        } catch is CancellationError {
            return
        } catch {
            guard generation == self.generation else { return }
            loadMoreError = (error as? S3Error)?.alertMessage ?? error.localizedDescription
        }

    }

    func navigate(to newPrefix: String) async {
        var normalized = newPrefix
        if !normalized.isEmpty && !normalized.hasSuffix("/") {
            normalized += "/"
        }
        generation += 1
        isLoadingMore = false
        prefix = normalized
        objects = []
        selection.removeAll()
        searchText = ""
        nextToken = nil
        hasMore = false
        loadError = nil
        loadMoreError = nil
        await reload()
    }

    func enter(_ folder: S3Object) async {
        guard folder.isFolder else { return }
        await navigate(to: folder.key)
    }

    func goUp() async {
        guard !prefix.isEmpty else { return }
        var parts = prefix.split(separator: "/", omittingEmptySubsequences: true)
        if !parts.isEmpty { parts.removeLast() }
        let parent = parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
        await navigate(to: parent)
    }

    func refreshAfterChange() async {
        await reload()
    }

    func pruneSelection() {
        let visible = Set(filteredObjects.map(\.key))
        selection.formIntersection(visible)
    }

    // MARK: - Mutations

    func createFolder(named name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw S3Error.validation("Enter a folder name.")
        }
        guard trimmed != ".", trimmed != ".." else {
            throw S3Error.validation("That folder name is reserved.")
        }
        guard !trimmed.contains("/") else {
            throw S3Error.validation("Folder names cannot contain “/”.")
        }
        try await client.createFolder(bucket: bucket, key: prefix + trimmed + "/")
        await reload()
    }

    func deleteSelected() async {
        let targets = selectedObjects
        guard !targets.isEmpty, !isDeleting else { return }
        isDeleting = true
        defer {
            isDeleting = false
            deleteStatus = nil
        }

        do {
            let fileKeys = targets.filter { !$0.isFolder }.map(\.key)
            if !fileKeys.isEmpty {
                deleteStatus = "Deleting \(fileKeys.count) object\(fileKeys.count == 1 ? "" : "s")…"
                try await deleteKeys(fileKeys)
            }

            for folder in targets where folder.isFolder {
                deleteStatus = "Listing \(folder.name)…"
                let keys = try await allKeys(under: folder.key)
                if !keys.isEmpty {
                    deleteStatus = "Deleting \(keys.count) item\(keys.count == 1 ? "" : "s") in \(folder.name)…"
                    try await deleteKeys(keys)
                }
            }

            selection.removeAll()
            await reload()
        } catch {
            await reload()
            onError(error as? S3Error ?? S3Error(message: error.localizedDescription))
        }
    }

    private func allKeys(under folderPrefix: String) async throws -> [String] {
        var keys: [String] = []
        var token: String?
        while true {
            let page = try await client.listObjects(
                bucket: bucket,
                prefix: folderPrefix,
                delimiter: nil,
                continuationToken: token,
                maxKeys: 1000
            )
            keys.append(contentsOf: page.objects.filter { !$0.isFolder }.map(\.key))
            guard page.isTruncated, let next = page.nextToken, next != token else { break }
            token = next
        }
        return keys
    }

    private func deleteKeys(_ keys: [String]) async throws {
        guard !keys.isEmpty else { return }
        let chunks = stride(from: 0, to: keys.count, by: 1000).map {
            Array(keys[$0..<min($0 + 1000, keys.count)])
        }
        let client = self.client
        let bucket = self.bucket
        let width = min(4, chunks.count)
        var failures: [DeleteFailure] = []

        try await withThrowingTaskGroup(of: [DeleteFailure].self) { group in
            var next = 0
            while next < width {
                let chunk = chunks[next]
                group.addTask {
                    try await client.deleteObjects(bucket: bucket, keys: chunk)
                }
                next += 1
            }
            while let result = try await group.next() {
                failures.append(contentsOf: result)
                if next < chunks.count {
                    let chunk = chunks[next]
                    group.addTask {
                        try await client.deleteObjects(bucket: bucket, keys: chunk)
                    }
                    next += 1
                }
            }
        }

        if let first = failures.first {
            throw S3Error(
                code: first.code,
                message: "\(failures.count) of \(keys.count) objects could not be deleted. " +
                    "\(first.key): \(first.message)"
            )
        }
    }

    private static func sorted(_ objects: [S3Object]) -> [S3Object] {
        objects.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
