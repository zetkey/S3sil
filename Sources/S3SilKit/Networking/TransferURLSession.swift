import Foundation

public struct HTTPResult: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// URLSession wrapper that reports upload/download progress and supports task cancellation.
public final class TransferURLSession: NSObject, URLSessionDownloadDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private final class Handler {
        let continuation: CheckedContinuation<HTTPResult, Error>
        let progress: @Sendable (Int64, Int64) -> Void
        let destination: URL?
        var fileError: Error?
        var body = Data()

        init(
            continuation: CheckedContinuation<HTTPResult, Error>,
            progress: @escaping @Sendable (Int64, Int64) -> Void,
            destination: URL?
        ) {
            self.continuation = continuation
            self.progress = progress
            self.destination = destination
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false
        private var task: URLSessionTask?

        func cancel() {
            lock.lock()
            isCancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }

        func attach(_ task: URLSessionTask) {
            lock.lock()
            self.task = task
            let cancelled = isCancelled
            lock.unlock()
            if cancelled { task.cancel() }
        }

        var cancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isCancelled
        }
    }

    private let lock = NSLock()
    private var handlers: [Int: Handler] = [:]
    private var session: URLSession!

    public override convenience init() {
        self.init(configuration: .ephemeral)
    }

    public init(configuration: URLSessionConfiguration) {
        let config = (configuration.copy() as? URLSessionConfiguration) ?? URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 6
        let queue = OperationQueue()
        queue.name = "com.s3sil.transfer-delegate"
        queue.maxConcurrentOperationCount = 1
        super.init()
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    // MARK: - Public API

    public func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> HTTPResult {
        try await run(progress: progress, destination: destination) { continuation in
            let task = self.session.downloadTask(with: request)
            self.register(task, continuation: continuation, progress: progress, destination: destination)
            return task
        }
    }

    public func upload(
        _ request: URLRequest,
        from fileURL: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> HTTPResult {
        try await run(progress: progress, destination: nil) { continuation in
            let task = self.session.uploadTask(with: request, fromFile: fileURL)
            self.register(task, continuation: continuation, progress: progress, destination: nil)
            return task
        }
    }

    public func upload(
        _ request: URLRequest,
        from data: Data,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> HTTPResult {
        var request = request
        request.httpBody = nil
        return try await run(progress: progress, destination: nil) { continuation in
            let task = self.session.uploadTask(with: request, from: data)
            self.register(task, continuation: continuation, progress: progress, destination: nil)
            return task
        }
    }

    private func run(
        progress: @escaping @Sendable (Int64, Int64) -> Void,
        destination: URL?,
        create: @escaping (CheckedContinuation<HTTPResult, Error>) -> URLSessionTask
    ) async throws -> HTTPResult {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if cancellation.cancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let task = create(continuation)
                cancellation.attach(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func register(
        _ task: URLSessionTask,
        continuation: CheckedContinuation<HTTPResult, Error>,
        progress: @escaping @Sendable (Int64, Int64) -> Void,
        destination: URL?
    ) {
        let handler = Handler(continuation: continuation, progress: progress, destination: destination)
        lock.lock()
        handlers[task.taskIdentifier] = handler
        lock.unlock()
    }

    private func handler(for task: URLSessionTask) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[task.taskIdentifier]
    }

    private func removeHandler(for task: URLSessionTask) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers.removeValue(forKey: task.taskIdentifier)
    }

    // MARK: - URLSessionDownloadDelegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        handler(for: downloadTask)?.progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let handler = handler(for: downloadTask) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status), let destination = handler.destination {
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: location)
                } else {
                    try FileManager.default.moveItem(at: location, to: destination)
                }
            } catch {
                handler.fileError = error
                try? FileManager.default.removeItem(at: location)
            }
        } else {
            handler.body = (try? Data(contentsOf: location)) ?? Data()
            try? FileManager.default.removeItem(at: location)
        }
    }

    // MARK: - URLSessionTaskDelegate

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        handler(for: task)?.progress(totalBytesSent, totalBytesExpectedToSend)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let handler = removeHandler(for: task) else { return }
        if let error {
            if (error as? URLError)?.code == .cancelled {
                handler.continuation.resume(throwing: CancellationError())
            } else {
                handler.continuation.resume(throwing: error)
            }
            return
        }
        if let fileError = handler.fileError {
            handler.continuation.resume(throwing: fileError)
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            handler.continuation.resume(throwing: S3Error(
                message: "The server returned an invalid response."
            ))
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key.lowercased()] = value
            }
        }
        handler.continuation.resume(returning: HTTPResult(
            statusCode: response.statusCode,
            headers: headers,
            body: handler.body
        ))
    }

    // MARK: - URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handler = handler(for: dataTask) else { return }
        if handler.body.count < 1 << 20 {
            handler.body.append(data)
        }
    }
}
