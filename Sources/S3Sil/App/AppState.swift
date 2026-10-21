import AppKit
import Observation
import S3SilKit

enum SidebarSelection: Hashable {
    case profile(UUID)
    case bucket(UUID, String)
}

struct BucketActionTarget: Identifiable, Hashable {
    let profile: ConnectionProfile
    let bucket: String

    var id: String { "\(profile.id.uuidString)/\(bucket)" }
}

enum ConnectionEditorTarget: Identifiable {
    case new
    case edit(ConnectionProfile, S3Credentials?)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let profile, _): return profile.id.uuidString
        }
    }
}

@MainActor
@Observable
final class AppState {
    private let store: ConnectionStore

    var profiles: [ConnectionProfile] = []
    var selection: SidebarSelection?
    var bucketsByProfile: [UUID: [Bucket]] = [:]
    var bucketErrors: [UUID: String] = [:]
    var loadingBuckets: Set<UUID> = []
    var testingProfiles: Set<UUID> = []

    var browser: ObjectBrowserModel?
    var isInspectorPresented = false
    var editingTarget: ConnectionEditorTarget?
    var alert: AppAlert?
    var toast: String?
    var connectionPendingDelete: ConnectionProfile?
    var bucketCreateTarget: ConnectionProfile?
    var aclTarget: BucketActionTarget?
    var bucketPendingDelete: BucketActionTarget?
    var bucketOperationStatus: String?

    var uploadRequest = 0
    var deleteRequest = 0
    var newFolderRequest = 0

    var transfers = TransferManager()
    var didStart = false

    private var browserTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(store: ConnectionStore = .defaultStore()) {
        self.store = store
        do {
            profiles = try store.load().sorted(by: Self.profileNameOrder)
        } catch {
            var message = error.localizedDescription
            if let backup = try? store.backUpCorruptedFile() {
                message += "\n\nThe unreadable file was moved to \(backup.lastPathComponent)."
            }
            alert = AppAlert(title: "Couldn’t Load Connections", message: message)
        }
        if let first = profiles.first {
            selection = .profile(first.id)
        }
        transfers.onUploadCompleted = { [weak self] item in
            self?.handleUploadCompleted(item)
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !didStart else { return }
        didStart = true
        if let id = selectedProfile?.id {
            await loadBuckets(for: id)
        }
    }

    private static func profileNameOrder(_ lhs: ConnectionProfile, _ rhs: ConnectionProfile) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    // MARK: - Selection

    var selectedProfile: ConnectionProfile? {
        switch selection {
        case .profile(let id), .bucket(let id, _):
            return profiles.first { $0.id == id }
        case nil:
            return nil
        }
    }

    func select(_ newSelection: SidebarSelection?) {
        selection = newSelection
        switch newSelection {
        case .profile(let id):
            browserTask?.cancel()
            browser = nil
            if profiles.contains(where: { $0.id == id }) {
                Task { await loadBuckets(for: id) }
            }
        case .bucket(let id, let name):
            guard let profile = profiles.first(where: { $0.id == id }) else { return }
            openBucket(profile: profile, bucket: name)
        case nil:
            browserTask?.cancel()
            browser = nil
        }
    }

    func openBucket(profile: ConnectionProfile, bucket: String) {
        browserTask?.cancel()
        browser = nil
        do {
            let client = try client(for: profile)
            let model = ObjectBrowserModel(
                profile: profile,
                bucket: bucket,
                client: client
            ) { [weak self] error in
                self?.present(error)
            }
            browser = model
            browserTask = Task { await model.loadInitial() }
        } catch {
            present(error)
            if case .bucket = selection {
                selection = .profile(profile.id)
            }
        }
    }

    // MARK: - Buckets

    func loadBuckets(for profileID: UUID, force: Bool = false) async {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        guard !loadingBuckets.contains(profileID) else { return }
        if !force, bucketsByProfile[profileID] != nil { return }

        loadingBuckets.insert(profileID)
        bucketErrors[profileID] = nil
        do {
            let client = try client(for: profile)
            let buckets = try await client.listBuckets()
            bucketsByProfile[profileID] = buckets.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            bucketErrors[profileID] = nil
        } catch {
            bucketErrors[profileID] = (error as? S3Error)?.alertMessage ?? error.localizedDescription
            if bucketsByProfile[profileID] == nil {
                bucketsByProfile[profileID] = []
            }
        }
        loadingBuckets.remove(profileID)
    }

    func refreshBuckets(for profileID: UUID) {
        Task { await loadBuckets(for: profileID, force: true) }
    }

    func beginCreateBucket(_ profile: ConnectionProfile) {
        guard bucketOperationStatus == nil else { return }
        bucketCreateTarget = profile
    }

    /// Creates the bucket, refreshes the profile's list, then opens the new bucket.
    func createBucket(named rawName: String, in profile: ConnectionProfile) async throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = BucketNameValidator.validationError(for: name, provider: profile.provider) {
            throw S3Error.validation(problem)
        }
        guard bucketOperationStatus == nil else {
            throw S3Error.validation("Another bucket operation is still running.")
        }
        bucketOperationStatus = "Creating “\(name)”…"
        defer { bucketOperationStatus = nil }

        let client = try client(for: profile)
        try await client.createBucket(name)
        await reloadBucketsNow(for: profile)
        select(.bucket(profile.id, name))
        showToast("Bucket “\(name)” created")
    }

    func beginBucketACL(_ bucket: String, profile: ConnectionProfile) {
        guard profile.provider.showsBucketACLInfo else { return }
        aclTarget = BucketActionTarget(profile: profile, bucket: bucket)
    }

    func requestDeleteBucket(_ bucket: String, profile: ConnectionProfile) {
        guard bucketOperationStatus == nil else { return }
        bucketPendingDelete = BucketActionTarget(profile: profile, bucket: bucket)
    }

    func deletePendingBucket() {
        guard let target = bucketPendingDelete else { return }
        bucketPendingDelete = nil
        Task { await deleteBucket(target) }
    }

    private func deleteBucket(_ target: BucketActionTarget) async {
        guard bucketOperationStatus == nil else { return }
        bucketOperationStatus = "Deleting “\(target.bucket)”…"
        defer { bucketOperationStatus = nil }

        do {
            let client = try client(for: target.profile)
            _ = try await client.deleteBucket(target.bucket)
            await reloadBucketsNow(for: target.profile)
            if case .bucket(let id, let name) = selection,
               id == target.profile.id, name == target.bucket {
                browserTask?.cancel()
                browser = nil
                selection = .profile(target.profile.id)
            }
            showToast("Bucket “\(target.bucket)” deleted")
        } catch {
            await reloadBucketsNow(for: target.profile)
            present(error)
        }
    }

    /// Lists buckets directly after a mutation so the sidebar never keeps a stale entry.
    private func reloadBucketsNow(for profile: ConnectionProfile) async {
        do {
            let client = try client(for: profile)
            let buckets = try await client.listBuckets()
            bucketsByProfile[profile.id] = buckets.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            bucketErrors[profile.id] = nil
        } catch {
            bucketErrors[profile.id] = (error as? S3Error)?.alertMessage ?? error.localizedDescription
            if bucketsByProfile[profile.id] == nil {
                bucketsByProfile[profile.id] = []
            }
        }
    }

    // MARK: - Clients

    func client(for profile: ConnectionProfile) throws -> S3Client {
        guard let credentials = try KeychainStore.load(profileID: profile.id) else {
            throw S3Error.validation("No credentials are stored for “\(profile.name)”. Edit the connection to add them.")
        }
        guard !credentials.accessKeyID.isEmpty, !credentials.secretAccessKey.isEmpty else {
            throw S3Error.validation("The credentials for “\(profile.name)” are incomplete. Edit the connection.")
        }
        return try S3Client(profile: profile, credentials: credentials)
    }

    // MARK: - Connection editing

    func beginNewConnection() {
        editingTarget = .new
    }

    func beginEdit(_ profile: ConnectionProfile) {
        do {
            let credentials = try KeychainStore.load(profileID: profile.id)
            editingTarget = .edit(profile, credentials)
        } catch {
            present(error)
            editingTarget = .edit(profile, nil)
        }
    }

    func beginEditSelectedConnection() {
        guard let profile = selectedProfile else { return }
        beginEdit(profile)
    }

    func saveConnection(_ profile: ConnectionProfile, credentials: S3Credentials) throws {
        let isNew = !profiles.contains { $0.id == profile.id }
        let previous = profiles
        var updated = profiles
        if let index = updated.firstIndex(where: { $0.id == profile.id }) {
            updated[index] = profile
        } else {
            updated.append(profile)
        }
        updated.sort(by: Self.profileNameOrder)

        do {
            try store.save(updated)
        } catch {
            throw error
        }
        do {
            try KeychainStore.save(credentials, profileID: profile.id)
        } catch {
            try? store.save(previous)
            throw error
        }

        profiles = updated
        editingTarget = nil

        if isNew {
            select(.profile(profile.id))
        } else if case .bucket(let id, let name) = selection, id == profile.id {
            Task { await loadBuckets(for: id, force: true) }
            openBucket(profile: profile, bucket: name)
        } else if case .profile(let id) = selection, id == profile.id {
            Task { await loadBuckets(for: profile.id, force: true) }
        }
    }

    func requestDeleteConnection(_ profile: ConnectionProfile) {
        connectionPendingDelete = profile
    }

    func deletePendingConnection() {
        guard let profile = connectionPendingDelete else { return }
        connectionPendingDelete = nil
        do {
            try KeychainStore.delete(profileID: profile.id)
        } catch {
            present(error)
            return
        }

        var updated = profiles
        updated.removeAll { $0.id == profile.id }
        do {
            try store.save(updated)
        } catch {
            present(error)
            return
        }

        profiles = updated
        bucketsByProfile[profile.id] = nil
        bucketErrors[profile.id] = nil

        if selectedProfile?.id == profile.id {
            browserTask?.cancel()
            browser = nil
            if let first = profiles.first {
                select(.profile(first.id))
            } else {
                select(nil)
            }
        }
        showToast("Connection deleted")
    }

    func testConnection(_ profile: ConnectionProfile) {
        guard !testingProfiles.contains(profile.id) else { return }
        testingProfiles.insert(profile.id)
        Task {
            defer { testingProfiles.remove(profile.id) }
            do {
                let client = try client(for: profile)
                let buckets = try await client.listBuckets()
                bucketsByProfile[profile.id] = buckets.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                bucketErrors[profile.id] = nil
                showToast("Connected to \(profile.name) — \(buckets.count) bucket\(buckets.count == 1 ? "" : "s")")
            } catch {
                present(error)
            }
        }
    }

    // MARK: - Object actions

    var isSelectedProfileTesting: Bool {
        guard let profile = selectedProfile else { return false }
        return testingProfiles.contains(profile.id)
    }

    var canUpload: Bool { browser != nil }
    var canDownload: Bool { browser?.selectedObjects.contains { !$0.isFolder } == true }
    var canDelete: Bool { browser?.selectedObjects.isEmpty == false }
    var canNewFolder: Bool { browser != nil }
    var canCopyPresigned: Bool {
        guard let selected = browser?.selectedObjects else { return false }
        return selected.count == 1 && selected[0].isFolder == false
    }

    func requestUpload() {
        guard canUpload else { return }
        uploadRequest += 1
    }

    func requestDelete() {
        guard canDelete else { return }
        deleteRequest += 1
    }

    func requestNewFolder() {
        guard canNewFolder else { return }
        newFolderRequest += 1
    }

    func upload(urls: [URL]) {
        guard let browser else { return }
        let files = urls.filter(FilePanels.isRegularFile)
        guard !files.isEmpty else { return }
        for file in files {
            transfers.enqueueUpload(
                fileURL: file,
                key: browser.prefix + file.lastPathComponent,
                profile: browser.profile,
                bucket: browser.bucket,
                client: browser.client
            )
        }
        if files.count == 1, let first = files.first {
            showToast("Uploading \(first.lastPathComponent)")
        } else {
            showToast("Uploading \(files.count) files")
        }
    }

    func downloadSelected() {
        guard let browser else { return }
        download(objects: browser.selectedObjects)
    }

    func download(objects: [S3Object]) {
        guard let browser else { return }
        let files = objects.filter { !$0.isFolder }
        guard !files.isEmpty else {
            if objects.isEmpty == false {
                showToast("Open a folder to download its contents.")
            }
            return
        }

        if files.count == 1 {
            download(files[0])
            return
        }
        guard let directory = FilePanels.directory() else { return }
        for file in files {
            let destination = FilePanels.uniqueDestination(in: directory, name: file.name)
            transfers.enqueueDownload(
                object: file,
                profile: browser.profile,
                bucket: browser.bucket,
                destination: destination,
                client: browser.client
            )
        }
        showToast("Downloading \(files.count) files")
    }

    func download(_ object: S3Object) {
        guard let browser, !object.isFolder else { return }
        guard let destination = FilePanels.saveURL(suggestedName: object.name) else { return }
        transfers.enqueueDownload(
            object: object,
            profile: browser.profile,
            bucket: browser.bucket,
            destination: destination,
            client: browser.client
        )
        showToast("Downloading \(object.name)")
    }

    /// Starts a queued download into the URL supplied by a Finder file promise.
    /// The completion fires exactly once and is used to finish the promise.
    func downloadForDrag(
        _ object: S3Object,
        to destination: URL,
        profile: ConnectionProfile,
        bucket: String,
        client: S3Client,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        guard !object.isFolder else {
            completion(.failure(S3Error.validation("Folders can’t be dragged out.")))
            return
        }
        transfers.enqueueDownload(
            object: object,
            profile: profile,
            bucket: bucket,
            destination: destination,
            client: client,
            completion: completion
        )
        showToast("Downloading \(object.name)")
    }

    func copyPresignedURL(for object: S3Object, expires: Int) {
        guard let browser, !object.isFolder else { return }
        Task {
            do {
                let url = try await browser.client.presignedURL(
                    bucket: browser.bucket,
                    key: object.key,
                    expires: expires
                )
                FilePanels.copy(url.absoluteString)
                showToast("Presigned URL copied")
            } catch {
                present(error)
            }
        }
    }

    func copyPresignedURLForSelection(expires: Int) {
        guard let selected = browser?.selectedObjects, selected.count == 1 else { return }
        copyPresignedURL(for: selected[0], expires: expires)
    }

    // MARK: - Feedback

    func present(_ error: Error) {
        alert = error.appAlert
    }

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            if self?.toast == message {
                self?.toast = nil
            }
        }
    }

    private func handleUploadCompleted(_ item: TransferManager.Item) {
        guard let browser,
              item.profileID == browser.profile.id,
              item.bucket == browser.bucket,
              item.key.hasPrefix(browser.prefix) else { return }
        Task { await browser.refreshAfterChange() }
    }
}
