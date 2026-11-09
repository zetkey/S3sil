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

    /// Server-side directory the browser is rooted at. Empty → the SSH session's
    /// home directory (sftp's default cwd), not "/" — FileZilla's "remote site"
    /// default, and the only path that works on chrooted servers (which expose
    /// "/" as a read-only system root with no user files in it).
    private var basePath: String {
        let bp = profile.basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return bp.isEmpty ? "." : bp
    }

    private func remotePath(_ key: String) -> String {
        if basePath == "." {
            return key.hasPrefix("/") ? key : (key.isEmpty ? "." : key)
        }
        let base = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        let cleanKey = key.hasPrefix("/") ? String(key.dropFirst()) : key
        if cleanKey.isEmpty { return base }
        return "\(base)/\(cleanKey)"
    }

    // MARK: - list

    /// Absolute server path of the most recently listed directory (what the
    /// server's `pwd` reports there). Empty until the first successful list.
    public var lastRealPath: String { realPathBox.value }

    /// Reference box — SFTPBackend is a struct copied per call.
    private let realPathBox = RealPathBox()
    private final class RealPathBox: @unchecked Sendable {
        let lock = NSLock()
        var storage = ""
        var value: String {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); defer { lock.unlock() }; storage = newValue }
        }
    }

    public func list(prefix: String, maxKeys: Int) async throws -> ObjectListing {
        let path = remotePath(prefix)
        // pwd rides along in the same batch — zero extra round trips — so the
        // UI can show the real OS path (FileZilla's "remote site").
        let commands = "pwd\nls -l \(escapeArg(path))"
        let raw = try await runBatch(commands: commands)

        var realPath = ""
        var listing = raw
        if let pwdRange = raw.range(of: "Remote working directory: ") {
            let lineEnd = raw[pwdRange.upperBound...].firstIndex(of: "\n") ?? raw.endIndex
            realPath = String(raw[pwdRange.upperBound..<lineEnd])
                .trimmingCharacters(in: .whitespaces)
            listing = String(raw[lineEnd...])
        }
        realPathBox.value = realPath

        let entries = RemoteListingParser.parse(listing: stripSFTPPrompts(listing))
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
            let script = try Self.writeAskpassScript(password: credentials.secretAccessKey)
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
        // Reuse one authenticated master connection across operations (OpenSSH's
        // own connection sharing). `ensureMaster` starts `ssh -M -N -f` once;
        // every sftp op then multiplexes over that socket — FileZilla-class
        // latency without any custom session/framing code.
        let controlPath = Self.controlPath(profile: profile, credentials: credentials)
        try await Self.ensureMaster(
            profile: profile, credentials: credentials,
            knownHostsPath: knownHostsURL.path, controlPath: controlPath
        )
        args.append(contentsOf: [
            "-o", "ControlPath=\(controlPath)",
        ])

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

            // Drain stdout/stderr WHILE the child runs — waiting for exit first
            // deadlocks on large listings: the 64 KiB pipe fills, sftp blocks
            // writing, never exits, and the termination handler never fires.
            var outBox = Data()
            var errBox = Data()
            let dataLock = NSLock()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let d = handle.availableData
                if d.isEmpty { handle.readabilityHandler = nil; return }
                dataLock.lock(); outBox.append(d); dataLock.unlock()
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let d = handle.availableData
                if d.isEmpty { handle.readabilityHandler = nil; return }
                dataLock.lock(); errBox.append(d); dataLock.unlock()
            }

            process.terminationHandler = { proc in
                // Handlers may still hold the final bytes; read to EOF after exit.
                let tailOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let tailErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                dataLock.lock()
                outBox.append(tailOut)
                errBox.append(tailErr)
                let stdout = String(data: outBox, encoding: .utf8) ?? ""
                let stderr = String(data: errBox, encoding: .utf8) ?? ""
                dataLock.unlock()
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

    static func writeAskpassScript(password: String) throws -> URL {
        let safePass = password.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\necho '\(safePass)'\n"
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("s3sil-sftp-askpass-\(UUID().uuidString)")
        try script.write(to: url, atomically: true, encoding: .utf8)
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
            // No leading "/" on keys: `enter()` feeds key straight into
            // navigate(prefix:) → remotePath(), which joins it onto basePath.
            // A leading slash would escape the base and list the server root
            // instead of the folder the user double-clicked.
            let key = (normPrefix == "/" ? "" : normPrefix) + entry.name
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

    /// Unix-socket path for the shared SSH master connection, unique per
    /// user@host:port. Lives in the app's data dir alongside known_hosts.
    static func controlPath(profile: ConnectionProfile, credentials: S3Credentials) -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".s3sil", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let port = profile.port ?? 22
        let safeHost = profile.host.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let safeUser = credentials.accessKeyID.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return dir.appendingPathComponent("cm-\(safeUser)@\(safeHost):\(port)").path
    }

    /// Starts a backgrounded `ssh -M -N -f` master for user@host:port if one is
    /// not already listening. Idempotent: checks the ControlPath socket via
    /// `ssh -O check` before spawning. Subsequent sftp ops multiplex over it.
    static func ensureMaster(
        profile: ConnectionProfile, credentials: S3Credentials,
        knownHostsPath: String, controlPath: String
    ) async throws {
        let port = profile.port ?? 22
        let needsAskpass = !credentials.secretAccessKey.isEmpty
        var env = ProcessInfo.processInfo.environment
        var askpassURL: URL?
        if needsAskpass {
            let script = try Self.writeAskpassScript(password: credentials.secretAccessKey)
            askpassURL = script
            env["SSH_ASKPASS"] = script.path
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        }
        defer {
            if let u = askpassURL { try? FileManager.default.removeItem(at: u) }
        }

        // In-process cache: skip the `ssh -O check` subprocess on every op.
        if await masterUpTracks[controlPath] == true { return }

        // Fast path: master already alive (e.g. from a previous app run).
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        check.arguments = [
            "-O", "check",
            "-o", "ControlPath=\(controlPath)",
            "\(credentials.accessKeyID)@\(profile.host)",
        ]
        check.standardOutput = Pipe()
        check.standardError = Pipe()
        try? check.run()
        check.waitUntilExit()
        if check.terminationStatus == 0 {
            masterUpTracks[controlPath] = true
            return
        }

        // Spawn the master. It authenticates like any ssh session: keys or
        // askpass for the password — BatchMode is NOT used.
        let master = Process()
        master.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var mArgs: [String] = ["-M", "-N", "-f"]
        if let keyPath = profile.privateKeyPath, !keyPath.isEmpty {
            mArgs.append(contentsOf: ["-i", keyPath])
        } else if needsAskpass {
            mArgs.append(contentsOf: ["-o", "IdentitiesOnly=yes", "-o", "PubkeyAuthentication=no"])
        }
        mArgs.append(contentsOf: [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsPath)",
            "-o", "ConnectTimeout=30",
            "-o", "ServerAliveInterval=60",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=10m",
        ])
        if port != 22 {
            mArgs.append(contentsOf: ["-p", "\(port)"])
        }
        mArgs.append("\(credentials.accessKeyID)@\(profile.host)")

        master.arguments = mArgs
        master.environment = env
        master.standardOutput = Pipe()
        master.standardError = Pipe()

        // Give the handshake a bounded wait; -f backgrounds itself on success.
        try master.run()
        let deadline = Date().addingTimeInterval(35)
        while master.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        guard FileManager.default.fileExists(atPath: controlPath) else {
            if master.isRunning { master.terminate() }
            throw S3Error(
                code: "SftpError",
                message: "Could not establish the SSH master connection (auth failed or host unreachable)."
            )
        }
        masterUpTracks[controlPath] = true
    }

    /// controlPath → master confirmed alive in this app run.
    private static var masterUpTracks: [String: Bool] {
        get { LockIsolatedBox.value }
        set { LockIsolatedBox.value = newValue }
    }

    private final class LockIsolatedBox {
        private static let lock = NSLock()
        private static var storage: [String: Bool] = [:]
        static var value: [String: Bool] {
            get { lock.lock(); defer { lock.unlock() }; return storage }
            set { lock.lock(); defer { lock.unlock() }; storage = newValue }
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