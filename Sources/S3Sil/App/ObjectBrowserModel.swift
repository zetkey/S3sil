import Foundation
import Observation
import S3SilKit

@MainActor
@Observable
final class ObjectBrowserModel {
    let profile: ConnectionProfile
    let containerName: String
    let backend: any StorageBackend
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

    private var generation = 0
    private let onError: (S3Error) -> Void

    /// Display name for the bucket/container in breadcrumbs (empty for root-only backends).
    var containerDisplayName: String {
        containerName.isEmpty ? profile.name : containerName
    }

    init(profile: ConnectionProfile, containerName: String, backend: any StorageBackend,
         onError: @escaping (S3Error) -> Void) {
        self.profile = profile
        self.containerName = containerName
        self.backend = backend
        self.prefix = ""
        self.onError = onError
    }

    var selectedObjects: [S3Object] {
        objects.filter { selection.contains($0.key) }
    }

    /// Bumped whenever `objects` changes. Lets the view observe row-set changes
    /// without materializing a 10k-element key array per render.
    var objectsRevision: Int {
        objects.count + (hasMore ? 1 : 0) + (loadError == nil ? 0 : 10_000_000) + prefix.hashValue
    }

    var filteredObjects: [S3Object] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return objects }
        return objects.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    /// Sort applied by the view; kept here so the sorted result is cached
    /// instead of re-sorting 10k rows on every SwiftUI render pass.
    var sortDescriptors: [KeyPathComparator<S3Object>] = []

    private var cachedSort: (inputs: (count: Int, descriptorCount: Int), rows: [S3Object])?
    /// Filtered rows in the user's chosen order. Cached until the filtered set
    /// or descriptors change. Descriptor identity is approximated by count —
    /// the table only ever swaps between no-sort and one-column sort.
    func sortedVisibleObjects() -> [S3Object] {
        let filtered = filteredObjects
        let key = (count: filtered.count, descriptorCount: sortDescriptors.count)
        if let cached = cachedSort,
           cached.inputs.count == key.count,
           cached.inputs.descriptorCount == key.descriptorCount {
            return cached.rows
        }
        let rows = sortDescriptors.isEmpty ? filtered : filtered.sorted(using: sortDescriptors)
        cachedSort = (key, rows)
        return rows
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
            let page = try await backend.list(prefix: prefix, maxKeys: 1000)
            guard generation == self.generation else { return }
            objects = Self.sorted(page.objects)
            cachedSort = nil
            hasMore = page.isTruncated
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
        guard hasMore, !isLoading, !isLoadingMore else { return }
        let generation = self.generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        loadMoreError = nil

        do {
            let page = try await backend.list(prefix: prefix, maxKeys: 1000)
            guard generation == self.generation else { return }
            let existing = Set(objects.map(\.key))
            objects = Self.sorted(objects + page.objects.filter { !existing.contains($0.key) })
            cachedSort = nil
            hasMore = page.isTruncated
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
        try await backend.createFolder(prefix + trimmed + "/")
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
            let keys = targets.map(\.key)
            try await backend.delete(keys) { [weak self] status in
                Task { @MainActor in self?.deleteStatus = status }
            }
            selection.removeAll()
            await reload()
        } catch {
            await reload()
            onError(error as? S3Error ?? S3Error(message: error.localizedDescription))
        }
    }

    private static func sorted(_ objects: [S3Object]) -> [S3Object] {
        objects.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
