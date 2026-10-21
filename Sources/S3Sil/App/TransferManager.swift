import Foundation
import Observation
import S3SilKit

@MainActor
@Observable
final class TransferManager {
    enum Direction: String {
        case upload
        case download
    }

    enum Status: String {
        case queued
        case running
        case completed
        case failed
        case cancelled
    }

    struct Item: Identifiable {
        let id: UUID
        let direction: Direction
        let profileID: UUID
        let profileName: String
        let bucket: String
        let key: String
        let displayName: String
        let sourceURL: URL?
        let destinationURL: URL?
        let client: S3Client
        var status: Status
        var progress: Double
        var bytesTransferred: Int64
        var totalBytes: Int64
        var errorMessage: String?
        var multipartLabel: String? = nil
    }

    private(set) var items: [Item] = []
    var isPanelVisible = false
    var isExpanded = true
    var onUploadCompleted: ((Item) -> Void)?

    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Callbacks for drag-out file promises. The destination is temporary until the
    /// transfer succeeds, so failures remove it before reporting back to Finder.
    private var promiseCompletions: [UUID: @Sendable (Result<Void, Error>) -> Void] = [:]
    private var pending: [UUID] = []
    private var running: Set<UUID> = []
    private var lastProgressAt: [UUID: Date] = [:]
    private let maxConcurrent = 3

    var activeCount: Int {
        items.filter { $0.status == .running || $0.status == .queued }.count
    }

    var runningCount: Int {
        items.filter { $0.status == .running }.count
    }

    var queuedCount: Int {
        items.filter { $0.status == .queued }.count
    }

    var completedCount: Int {
        items.filter { $0.status == .completed }.count
    }

    var failedCount: Int {
        items.filter { $0.status == .failed }.count
    }

    var aggregateProgress: Double {
        let relevant = items.filter { $0.status != .cancelled }
        guard !relevant.isEmpty else { return 0 }
        return relevant.map(\.progress).reduce(0, +) / Double(relevant.count)
    }

    var statusSummary: String {
        var parts: [String] = []
        if runningCount > 0 { parts.append("\(runningCount) active") }
        if queuedCount > 0 { parts.append("\(queuedCount) queued") }
        if completedCount > 0 { parts.append("\(completedCount) done") }
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        return parts.isEmpty ? "No transfers" : parts.joined(separator: " · ")
    }

    var canClearFinished: Bool {
        items.contains { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }
    }

    func enqueueUpload(fileURL: URL, key: String, profile: ConnectionProfile,
                       bucket: String, client: S3Client) {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let multipartLabel = MultipartUploadPlan.plan(totalBytes: Int64(size)).map {
            "Multipart · \($0.partCount) parts"
        }
        let item = Item(
            id: UUID(),
            direction: .upload,
            profileID: profile.id,
            profileName: profile.name,
            bucket: bucket,
            key: key,
            displayName: fileURL.lastPathComponent,
            sourceURL: fileURL,
            destinationURL: nil,
            client: client,
            status: .queued,
            progress: 0,
            bytesTransferred: 0,
            totalBytes: Int64(size),
            errorMessage: nil,
            multipartLabel: multipartLabel
        )
        insert(item)
    }

    func enqueueDownload(object: S3Object, profile: ConnectionProfile,
                         bucket: String, destination: URL, client: S3Client,
                         completion: (@Sendable (Result<Void, Error>) -> Void)? = nil) {
        let item = Item(
            id: UUID(),
            direction: .download,
            profileID: profile.id,
            profileName: profile.name,
            bucket: bucket,
            key: object.key,
            displayName: object.name,
            sourceURL: nil,
            destinationURL: destination,
            client: client,
            status: .queued,
            progress: 0,
            bytesTransferred: 0,
            totalBytes: object.size,
            errorMessage: nil
        )
        if let completion {
            promiseCompletions[item.id] = completion
        }
        insert(item)
    }

    private func insert(_ item: Item) {
        items.insert(item, at: 0)
        pending.append(item.id)
        isPanelVisible = true
        pump()
    }

    func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].status {
        case .queued:
            items[index].status = .cancelled
            pending.removeAll { $0 == id }
            settlePromise(id: id, result: .failure(CancellationError()), removeDestination: true)
        case .running:
            tasks[id]?.cancel()
        default:
            break
        }
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].status == .failed || items[index].status == .cancelled else { return }
        items[index].status = .queued
        items[index].progress = 0
        items[index].bytesTransferred = 0
        items[index].errorMessage = nil
        pending.append(id)
        pump()
    }

    func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].status != .running && items[index].status != .queued else { return }
        items.remove(at: index)
        tasks[id] = nil
        lastProgressAt[id] = nil
    }

    func clearFinished() {
        items.removeAll {
            $0.status == .completed || $0.status == .failed || $0.status == .cancelled
        }
    }

    func togglePanel() {
        if items.isEmpty { return }
        isPanelVisible.toggle()
    }

    // MARK: - Queue

    private func pump() {
        while running.count < maxConcurrent, !pending.isEmpty {
            let id = pending.removeFirst()
            guard let index = items.firstIndex(where: { $0.id == id }),
                  items[index].status == .queued else { continue }
            start(id: id, item: items[index])
        }
    }

    private func start(id: UUID, item: Item) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .running
        running.insert(id)

        let manager = self
        tasks[id] = Task { [weak self, manager] in
            do {
                switch item.direction {
                case .upload:
                    guard let source = item.sourceURL else {
                        throw S3Error.validation("The source file is missing.")
                    }
                    try await item.client.uploadFile(
                        fileURL: source,
                        bucket: item.bucket,
                        key: item.key
                    ) { sent, total in
                        Task { @MainActor [weak manager] in
                            manager?.updateProgress(id: id, transferred: sent, total: total)
                        }
                    }
                case .download:
                    guard let destination = item.destinationURL else {
                        throw S3Error.validation("The download destination is missing.")
                    }
                    try await item.client.download(
                        bucket: item.bucket,
                        key: item.key,
                        to: destination
                    ) { received, total in
                        Task { @MainActor [weak manager] in
                            manager?.updateProgress(id: id, transferred: received, total: total)
                        }
                    }
                }
                self?.finish(id: id)
            } catch is CancellationError {
                self?.markCancelled(id: id)
            } catch {
                self?.fail(id: id, error: error)
            }
        }
    }

    private func updateProgress(id: UUID, transferred: Int64, total: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].status == .running else { return }
        let now = Date()
        if total > 0, transferred < total,
           now.timeIntervalSince(lastProgressAt[id] ?? .distantPast) < 0.1 {
            return
        }
        lastProgressAt[id] = now
        items[index].bytesTransferred = max(transferred, 0)
        let effectiveTotal = total > 0 ? total : items[index].totalBytes
        if effectiveTotal > 0 {
            items[index].totalBytes = effectiveTotal
            items[index].progress = min(1, Double(transferred) / Double(effectiveTotal))
        }
    }

    private func finish(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .completed
        items[index].progress = 1
        if items[index].totalBytes <= 0 {
            items[index].totalBytes = items[index].bytesTransferred
        }
        items[index].bytesTransferred = max(items[index].bytesTransferred, items[index].totalBytes)
        let completed = items[index]
        tasks[id] = nil
        lastProgressAt[id] = nil
        running.remove(id)
        if completed.direction == .upload {
            onUploadCompleted?(completed)
        }
        settlePromise(id: id, result: .success(()), removeDestination: false)
        pump()
    }

    private func fail(id: UUID, error: Error) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .failed
        items[index].errorMessage = (error as? S3Error)?.alertMessage ?? error.localizedDescription
        tasks[id] = nil
        lastProgressAt[id] = nil
        running.remove(id)
        isPanelVisible = true
        settlePromise(id: id, result: .failure(error), removeDestination: true)
        pump()
    }

    private func markCancelled(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = .cancelled
        tasks[id] = nil
        lastProgressAt[id] = nil
        running.remove(id)
        settlePromise(id: id, result: .failure(CancellationError()), removeDestination: true)
        pump()
    }

    /// File promises must hear back exactly once. A failed promise removes the
    /// partial destination so Finder never publishes a corrupt file.
    private func settlePromise(id: UUID, result: Result<Void, Error>, removeDestination: Bool) {
        guard let completion = promiseCompletions.removeValue(forKey: id) else { return }
        if removeDestination,
           let destination = items.first(where: { $0.id == id })?.destinationURL {
            try? FileManager.default.removeItem(at: destination)
        }
        completion(result)
    }
}
