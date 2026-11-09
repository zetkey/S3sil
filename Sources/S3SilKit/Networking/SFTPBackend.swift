import Foundation

// MARK: - SFTP Backend

/// Implements StorageBackend by shelling out to `/usr/bin/sftp` in batch mode.
public struct SFTPBackend: StorageBackend, Sendable {
    public let container: String = ""
    public let capabilities: StorageCapabilities = .none

    private let profile: ConnectionProfile
    private let credentials: S3Credentials

    public init(profile: ConnectionProfile, credentials: S3Credentials) {
        self.profile = profile
        self.credentials = credentials
    }

    // MARK: - Remote path helpers

    private var basePath: String {
        let bp = profile.basePath
        return bp.isEmpty ? "/" : bp
    }

    private func remotePath(_ key: String) -> String {
        let base = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        let cleanKey = key.hasPrefix("/") ? String(key.dropFirst()) : key
        if cleanKey.isEmpty { return base }
        return "\(base)/\(cleanKey)"
    }

    // MARK: - list

    public func list(prefix: String, maxKeys: Int) async throws -> ObjectListing {
        let path = remotePath(prefix)
        let commands = "ls -l \(escapeArg(path))"
        let raw = try await runBatch(commands: commands)

        let entries = RemoteListingParser.parse(listing: stripSFTPPrompts(raw))
        let objects = entriesToObjects(entries, parentPrefix: prefix)

        let limited = maxKeys > 0 ? Array(objects.prefix(maxKeys)) : objects
        return ObjectListing(objects: limited, nextToken: nil, isTruncated: limited.count < objects.count)
    }

    // MARK: - createFolder

    public func createFolder(_ key: String) async throws {
        let cleaned = key.hasSuffix("/") ? String(key.dropLast()) : key
        let path = remotePath(cleaned)
        let commands = "mkdir \(escapeArg(path))"
        _ = try await runBatch(commands: commands)
    }

    // MARK: - delete

    public func delete(_ keys: [String], status: @escaping @Sendable (String) -> Void) async throws {
        guard !keys.isEmpty else { return }

        let fileKeys = keys.filter { !$0.hasSuffix("/") }
        let folderKeys = keys.filter { $0.hasSuffix("/") }

        if !fileKeys.isEmpty {
            status("Deleting \(fileKeys.count) file\(fileKeys.count == 1 ? "" : "s")…")
            let cmds = fileKeys.map { "rm \(escapeArg(remotePath($0)))" }.joined(separator: "\n")
            _ = try await runBatch(commands: cmds)
        }

        for folderKey in folderKeys {
            status("Listing \(folderKey)…")
            let folderPath = remotePath(folderKey)
            let allItems = try await listRecursive(remoteFolder: folderPath)
            if !allItems.isEmpty {
                status("Deleting \(allItems.count) item\(allItems.count == 1 ? "" : "s") in \(folderKey)…")

                let files = allItems.filter { !$0.isDirectory }
                let dirs = allItems.filter { $0.isDirectory }

                if !files.isEmpty {
                    let rmCmds = files.map { "rm \(escapeArg($0.name))" }.joined(separator: "\n")
                    _ = try await runBatch(commands: rmCmds)
                }
                if !dirs.isEmpty {
                    let rmdirCmds = dirs.sorted(by: { $0.name > $1.name })
                        .map { "rmdir \(escapeArg($0.name))" }.joined(separator: "\n")
                    _ = try await runBatch(commands: rmdirCmds)
                }
            }
            _ = try await runBatch(commands: "rmdir \(escapeArg(folderPath))")
        }
    }

    // MARK: - download

    public func download(key: String, to destination: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let remote = remotePath(key)
        let localPath = destination.path

        // Get expected file size
        let sizeRaw = try await runBatch(commands: "ls -l \(escapeArg(remote))")
        let entries = RemoteListingParser.parse(listing: stripSFTPPrompts(sizeRaw))
        let totalSize = entries.first?.size ?? 0

        let progressTask = Task {
            var lastSize: Int64 = 0
            while !Task.isCancelled {
                let attrs = try? FileManager.default.attributesOfItem(atPath: localPath)
                let currentSize = (attrs?[.size] as? Int64) ?? 0
                if currentSize != lastSize {
                    progress(currentSize, totalSize)
                    lastSize = currentSize
                }
                if currentSize >= totalSize, totalSize > 0 { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        defer { progressTask.cancel() }

        try await withTaskCancellationHandler {
            let commands = "get \(escapeArg(remote)) \(escapeArg(localPath))"
            _ = try await runBatch(commands: commands)
            progress(totalSize, totalSize)
        } onCancel: {
            progressTask.cancel()
        }
    }

    // MARK: - upload

    public func upload(fileURL: URL, key: String,
                       progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let remote = remotePath(key)
        let localPath = fileURL.path

        let totalSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        try await withTaskCancellationHandler {
            let commands = "put \(escapeArg(localPath)) \(escapeArg(remote))"
            _ = try await runBatch(commands: commands)
            progress(totalSize, totalSize)
        } onCancel: {}
    }

    // MARK: - Recursive listing (for delete)

    private func listRecursive(remoteFolder: String) async throws -> [RemoteListingParser.ParsedEntry] {
        let commands = "ls -l \(escapeArg(remoteFolder))"
        let raw = try await runBatch(commands: commands)
        let entries = RemoteListingParser.parse(listing: stripSFTPPrompts(raw))

        var all: [RemoteListingParser.ParsedEntry] = []
        for entry in entries {
            all.append(entry)
            if entry.isDirectory {
                let fullPath = remoteFolder.hasSuffix("/")
                    ? remoteFolder + entry.name
                    : remoteFolder + "/" + entry.name
                let children = try await listRecursive(remoteFolder: fullPath)
                all.append(contentsOf: children)
            }
        }
        return all
    }

    // MARK: - SFTP process execution

    private func runBatch(commands: String) async throws -> String {
        let host = profile.host
        let port = profile.port ?? 22

        let knownHostsURL = try knownHostsPath()

        var askpassScript: URL?
        var env = ProcessInfo.processInfo.environment

        let needsAskpass = !credentials.secretAccessKey.isEmpty
        if needsAskpass {
            let script = try writeAskpassScript(password: credentials.secretAccessKey)
            askpassScript = script
            env["SSH_ASKPASS"] = script.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        }

        defer {
            if let s = askpassScript { try? FileManager.default.removeItem(at: s) }
        }

        var args: [String] = []

        // Identity file for key auth
        if let keyPath = profile.privateKeyPath, !keyPath.isEmpty {
            args.append(contentsOf: ["-i", keyPath])
        } else if needsAskpass {
            // Password-only login: never let agent/default keys eat the server's
            // MaxAuthTries before the password attempt (FileZilla behaves the same).
            args.append(contentsOf: ["-o", "IdentitiesOnly=yes", "-o", "PubkeyAuthentication=no"])
        }

        // NOTE: do NOT use `sftp -b <file>` and do NOT pass `-o BatchMode=yes`:
        // both imply BatchMode, which disables password prompting (and thus
        // SSH_ASKPASS) — the reason SFTP password logins silently failed.
        // Commands are piped via stdin instead; non-interactive-ness comes from
        // the closed pipe + SSH_ASKPASS_REQUIRE=force.
        args.append(contentsOf: ["-o", "StrictHostKeyChecking=accept-new"])
        args.append(contentsOf: ["-o", "UserKnownHostsFile=\(knownHostsURL.path)"])
        args.append(contentsOf: ["-o", "ConnectTimeout=30"])
        args.append(contentsOf: ["-o", "ServerAliveInterval=60"])

        if port != 22 {
            args.append(contentsOf: ["-P", "\(port)"])
        }

        let user = credentials.accessKeyID
        args.append("\(user)@\(host)")

        let result = try await runProcess(
            executable: "/usr/bin/sftp",
            arguments: args,
            environment: env,
            stdin: commands + "\nexit\n"
        )

        // Non-zero exit = auth/connection failure (e.g. wrong password → 255).
        guard result.exitCode == 0 else {
            throw S3Error(
                code: "SftpError",
                message: Self.sftpCommandFailure(in: result.stderr)
                    ?? (result.stderr.isEmpty
                        ? "sftp exited with code \(result.exitCode)"
                        : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            )
        }

        // In stdin mode sftp command errors (Can't ls/rm/mkdir, No such file,
        // Permission denied, …) are reported on stderr while exit stays 0.
        if let failure = Self.sftpCommandFailure(in: result.stderr) {
            throw S3Error(code: "SftpError", message: failure)
        }

        return result.stdout
    }

    /// sftp failure lines that do not set a non-zero exit in stdin mode.
    private static let sftpErrorMarkers = [
        "Can't ", "Couldn't ", "Unable to ",
        "No such file or directory", "Permission denied",
        "Failure", "Host key verification failed",
    ]

    static func sftpCommandFailure(in stderr: String) -> String? {
        // OpenSSH writes CRLF and informational banners on stderr; strip both so
        // the failure reason (e.g. "Permission denied") is what the user sees.
        let noise: [String] = [
            "WARNING:", "post-quantum", "store now, decrypt later",
            "openssh.com", "Permanently added", "Connected to",
        ]
        let lines = stderr
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let failures = lines.filter { line in
            !line.isEmpty
                && !noise.contains { line.contains($0) }
                && sftpErrorMarkers.contains { line.contains($0) }
        }
        guard !failures.isEmpty else { return nil }
        return failures.joined(separator: "\n")
    }

    private func runProcess(executable: String, arguments: [String],
                            environment: [String: String],
                            stdin: String? = nil) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            var stdinPipe: Pipe?
            if stdin != nil {
                let pipe = Pipe()
                process.standardInput = pipe
                stdinPipe = pipe
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: S3Error(
                    code: "SftpError",
                    message: "Failed to launch sftp: \(error.localizedDescription)"
                ))
                return
            }

            // Write after run(): a payload larger than the 64 KiB pipe buffer
            // would block forever if written before the child exists to drain it.
            if let stdin, let pipe = stdinPipe {
                let handle = pipe.fileHandleForWriting
                DispatchQueue.global().async {
                    handle.write(Data(stdin.utf8))
                    handle.closeFile()
                }
            }

            process.terminationHandler = { proc in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(returning: ProcessResult(
                    exitCode: proc.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
                ))
            }
        }
    }

    // MARK: - Temp files

    private func writeTempFile(content: String, prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(prefix + UUID().uuidString)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func writeAskpassScript(password: String) throws -> URL {
        let safePass = password.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\necho '\(safePass)'\n"
        let url = try writeTempFile(content: script, prefix: "s3sil-sftp-askpass-")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Known hosts

    private func knownHostsPath() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".s3sil")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("known_hosts")
    }

    // MARK: - Parsing helpers

    /// Strip "sftp> " prompt lines from batch output.
    private func stripSFTPPrompts(_ output: String) -> String {
        output.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("sftp> ") }
            .joined(separator: "\n")
    }

    /// Convert RemoteListingParser.ParsedEntry array to S3Object array.
    private func entriesToObjects(_ entries: [RemoteListingParser.ParsedEntry],
                                  parentPrefix: String) -> [S3Object] {
        let normPrefix = parentPrefix.hasSuffix("/") ? parentPrefix : parentPrefix + "/"
        return entries.compactMap { entry in
            guard !entry.name.isEmpty, entry.name != ".", entry.name != ".." else { return nil }
            let key = normPrefix + entry.name
            return S3Object(
                key: key,
                name: entry.name,
                size: entry.size,
                lastModified: entry.lastModified,
                etag: "",
                kind: entry.isDirectory ? .folder : .file
            )
        }
    }

    // MARK: - Shell escaping

    private func escapeArg(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

// MARK: - Process result

private struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}