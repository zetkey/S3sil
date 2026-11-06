import Foundation

/// FTP/FTPS backend shelling out to `/usr/bin/curl`.
public struct FTPBackend: StorageBackend, Sendable {
    public let container: String = ""
    public let capabilities: StorageCapabilities = .none

    private let profile: ConnectionProfile
    private let credentials: S3Credentials
    private let baseURL: String  // ftp[s]://host:port/basePath/
    private let curlPath = "/usr/bin/curl"

    public init(profile: ConnectionProfile, credentials: S3Credentials) {
        self.profile = profile
        self.credentials = credentials

        let scheme = profile.useTLS ? "ftps" : "ftp"
        let host = profile.host
        let port = profile.port ?? (profile.useTLS ? 990 : 21)
        var path = profile.basePath
        if !path.isEmpty && !path.hasPrefix("/") { path = "/" + path }
        if !path.hasSuffix("/") { path += "/" }

        baseURL = "\(scheme)://\(host):\(port)\(path)"
    }

    // MARK: - Helpers

    private func urlPath(_ suffix: String) -> String {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let cleanSuffix = suffix.hasPrefix("/") ? suffix : "/" + suffix
        return base + cleanSuffix
    }

    private func absolutePath(_ suffix: String) -> String {
        if profile.basePath.isEmpty { return suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return "\(profile.basePath)/\(suffix)"
            .replacingOccurrences(of: "//", with: "/")
    }

    // MARK: - List

    public func list(prefix: String, maxKeys: Int) async throws -> ObjectListing {
        let dirPath = prefix.hasSuffix("/") ? prefix : prefix + "/"
        let absDir = absolutePath(dirPath)

        // Try MLSD first, then fall back to plain LIST.
        var listing: String
        do {
            var mlsdArgs = buildBaseArgs()
            mlsdArgs.append(contentsOf: ["--list-only", "-Q", "MLSD \(absDir)", urlPath(dirPath)])
            listing = try await runCurl(mlsdArgs)
            if listing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw S3Error(message: "empty listing")
            }
        } catch {
            var listArgs = buildBaseArgs()
            listArgs.append(urlPath(dirPath))
            listing = try await runCurl(listArgs)
        }

        let entries = RemoteListingParser.parse(listing: listing)
        let limited = Array(entries.prefix(maxKeys > 0 ? maxKeys : entries.count))

        let objects = limited.map { entry -> S3Object in
            let key = prefix.isEmpty ? entry.name : joinKeyPath(prefix, entry.name)
            let displayKey = entry.isDirectory && !key.hasSuffix("/") ? key + "/" : key
            let displayName = entry.isDirectory && !entry.name.hasSuffix("/") ? entry.name + "/" : entry.name
            return S3Object(
                key: displayKey,
                name: displayName,
                size: entry.size,
                lastModified: entry.lastModified,
                etag: "",
                kind: entry.isDirectory ? .folder : .file
            )
        }

        return ObjectListing(objects: objects, nextToken: nil, isTruncated: limited.count < entries.count)
    }

    private func joinKeyPath(_ prefix: String, _ name: String) -> String {
        if prefix.hasSuffix("/") { return prefix + name }
        return prefix + "/" + name
    }

    // MARK: - Create folder

    public func createFolder(_ key: String) async throws {
        var cleanKey = key
        if cleanKey.hasSuffix("/") { cleanKey = String(cleanKey.dropLast()) }
        let absPath = absolutePath(cleanKey)

        var args = buildBaseArgs()
        args.append(contentsOf: ["-Q", "MKD \(absPath)", baseURL])
        _ = try await runCurl(args)
    }

    // MARK: - Delete

    public func delete(_ keys: [String], status: @escaping @Sendable (String) -> Void) async throws {
        guard !keys.isEmpty else { return }

        let fileKeys = keys.filter { !$0.hasSuffix("/") }
        let folderKeys = keys.filter { $0.hasSuffix("/") }

        if !fileKeys.isEmpty {
            status("Deleting \(fileKeys.count) file\(fileKeys.count == 1 ? "" : "s")…")
            for key in fileKeys {
                let absPath = absolutePath(key)
                var args = buildBaseArgs()
                args.append(contentsOf: ["-Q", "DELE \(absPath)", baseURL])
                do {
                    _ = try await runCurl(args)
                } catch {
                    throw S3Error(message: "Failed to delete \(key): \(error.localizedDescription)")
                }
            }
        }

        for folder in folderKeys {
            status("Deleting \(folder)…")
            try await deleteFolderContents(folder: folder, status: status)
        }
    }

    private func deleteFolderContents(folder: String, status: @escaping @Sendable (String) -> Void) async throws {
        let folderPath = folder.hasSuffix("/") ? folder : folder + "/"

        let listing = try await list(prefix: folderPath, maxKeys: 10000)
        let objects = listing.objects

        let subfolders = objects.filter { $0.isFolder }
        let files = objects.filter { !$0.isFolder }

        for sub in subfolders {
            try await deleteFolderContents(folder: sub.key, status: status)
        }

        for file in files {
            let absPath = absolutePath(file.key)
            var args = buildBaseArgs()
            args.append(contentsOf: ["-Q", "DELE \(absPath)", baseURL])
            do {
                _ = try await runCurl(args)
            } catch {
                throw S3Error(message: "Failed to delete \(file.key): \(error.localizedDescription)")
            }
        }

        let cleanFolder = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        let absPath = absolutePath(cleanFolder)
        var args = buildBaseArgs()
        args.append(contentsOf: ["-Q", "RMD \(absPath)", baseURL])
        _ = try? await runCurl(args)
    }

    // MARK: - Download

    public func download(key: String, to destination: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let filePath = urlPath(key)

        var args = buildBaseArgs()
        args.append(contentsOf: ["-o", destination.path, filePath])

        let task = Process()
        task.executableURL = URL(fileURLWithPath: curlPath)
        task.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        let pollingTask = Task.detached {
            var lastSize: Int64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
                   let size = attrs[.size] as? Int64,
                   size > lastSize {
                    await MainActor.run { progress(size, size) }
                    lastSize = size
                }
            }
        }

        do {
            try await withTaskCancellationHandler {
                try task.run()
                task.waitUntilExit()
                pollingTask.cancel()

                if task.terminationStatus != 0 {
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8) ?? "curl exited with status \(task.terminationStatus)"
                    throw S3Error(message: errMsg.trimmingCharacters(in: .whitespacesAndNewlines))
                }

                let finalSize: Int64 = {
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
                       let s = attrs[.size] as? Int64 { return s }
                    return 0
                }()
                progress(finalSize, finalSize)
            } onCancel: {
                task.terminate()
                pollingTask.cancel()
            }
        } catch {
            pollingTask.cancel()
            throw error
        }
    }

    // MARK: - Upload

    public func upload(fileURL: URL, key: String,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let filePath = urlPath(key)

        let fileSize: Int64 = {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let s = attrs[.size] as? Int64 { return s }
            return 0
        }()

        var args = buildBaseArgs()
        if profile.useTLS, profile.endpoint.contains("insecure") {
            args.append("--insecure")
        }
        args.append(contentsOf: ["-T", fileURL.path, filePath])

        do {
            _ = try await runCurl(args)
            progress(fileSize, fileSize)
        } catch {
            throw S3Error(message: "Upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: curl execution

    private func buildBaseArgs() -> [String] {
        var args = ["--connect-timeout", "30", "--max-time", "300", "-sS"]

        if !credentials.accessKeyID.isEmpty {
            let password = credentials.secretAccessKey.isEmpty ? "" : credentials.secretAccessKey
            args.append(contentsOf: ["--user", "\(credentials.accessKeyID):\(password)"])
        }

        if profile.useTLS, profile.endpoint.contains("insecure") {
            args.append("--insecure")
        }

        return args
    }

    private func runCurl(_ args: [String]) async throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: curlPath)
        task.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        return try await withTaskCancellationHandler {
            try task.run()
            task.waitUntilExit()

            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""

            if task.terminationStatus != 0 {
                let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if msg.isEmpty {
                    throw S3Error(message: "curl exited with status \(task.terminationStatus)")
                }
                throw S3Error(message: msg)
            }

            return stdout
        } onCancel: {
            task.terminate()
        }
    }

    private func joinPath(_ base: String, _ component: String) -> String {
        if base.isEmpty { return component }
        if component.isEmpty { return base }
        if base.hasSuffix("/") { return base + component }
        return base + "/" + component
    }
}