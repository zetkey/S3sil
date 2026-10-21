import AppKit
import SwiftUI
import UniformTypeIdentifiers
import S3SilKit

struct ObjectBrowserView: View {
    @Environment(AppState.self) private var app
    @Bindable var model: ObjectBrowserModel

    @State private var sortOrder: [KeyPathComparator<S3Object>] = []
    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var pendingDelete: [S3Object] = []
    @State private var showDeleteConfirm = false
    @State private var isDropTargeted = false
    @State private var selectionAnchor: Int?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            statusBar
        }
        .navigationTitle(model.bucket)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter objects")
        .toolbar { toolbarContent }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                app.upload(urls: urls)
            case .failure(let error):
                app.present(error)
            }
        }
        .sheet(isPresented: $showNewFolder) {
            NewFolderSheet { name in
                try await model.createFolder(named: name)
                app.showToast("Folder created")
            }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .onChange(of: app.uploadRequest) { _, _ in
            showImporter = true
        }
        .onChange(of: app.newFolderRequest) { _, _ in
            showNewFolder = true
        }
        .onChange(of: app.deleteRequest) { _, _ in
            beginDeleteSelection()
        }
        .onChange(of: model.searchText) { _, _ in
            model.pruneSelection()
            selectionAnchor = nil
        }
        .onChange(of: model.prefix) { _, _ in
            selectionAnchor = nil
        }
        .onChange(of: sortOrder) { _, _ in
            selectionAnchor = nil
        }
        .onChange(of: visibleObjects.map(\.key)) { _, _ in
            selectionAnchor = nil
        }
        .inspector(isPresented: Binding(
            get: { app.isInspectorPresented },
            set: { app.isInspectorPresented = $0 }
        )) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.tint)
                    .font(.title3)
                Text(model.bucket)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProviderBadge(provider: model.profile.provider, size: 18)
                Spacer()
                if model.isLoading, !model.objects.isEmpty {
                    ProgressView().controlSize(.small)
                }
                Text(model.objects.count == 1 ? "1 item loaded" : "\(model.objects.count) items loaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 5) {
                if !model.prefix.isEmpty {
                    Button {
                        Task { await model.goUp() }
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .help("Enclosing Folder")
                }

                Button {
                    Task { await model.navigate(to: "") }
                } label: {
                    Text(model.bucket)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.prefix.isEmpty ? Color.primary : Color.secondary)

                ForEach(model.segments, id: \.prefix) { segment in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Button {
                        Task { await model.navigate(to: segment.prefix) }
                    } label: {
                        Text(segment.name)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.bar)
    }

    // MARK: - Content

    private var visibleObjects: [S3Object] {
        let filtered = model.filteredObjects
        guard !sortOrder.isEmpty else { return filtered }
        return filtered.sorted(using: sortOrder)
    }

    private var content: some View {
        ZStack {
            if showTable {
                table
            } else {
                stateView
            }

            if isDropTargeted {
                dropOverlay
            }

            if model.isDeleting {
                Rectangle()
                    .fill(.black.opacity(0.06))
                    .ignoresSafeArea()
                LoadingOverlay(title: model.deleteStatus ?? "Deleting…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.6))
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(FilePanels.isRegularFile)
            guard !files.isEmpty else { return false }
            app.upload(urls: files)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    private var showTable: Bool {
        !model.objects.isEmpty && model.loadError == nil && !model.filteredObjects.isEmpty
    }

    private var table: some View {
        Table(visibleObjects, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \S3Object.name) { object in
                HStack(spacing: 8) {
                    Image(systemName: object.isFolder ? "folder.fill" : "doc.text")
                        .foregroundStyle(object.isFolder ? Color.accentColor : Color.secondary)
                        .frame(width: 16)
                    Text(object.name)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
                .onAppear {
                    if object.id == visibleObjects.last?.id {
                        Task { await model.loadMore() }
                    }
                }
            }
            .width(min: 240, ideal: 430)

            TableColumn("Size", value: \S3Object.size) { object in
                Text(object.isFolder ? "—" : Format.size(object.size))
                    .font(.system(.caption, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100, max: 160)

            TableColumn("Modified", value: \S3Object.sortableModified) { object in
                Text(Format.modified(object.lastModified))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 170, max: 220)

            TableColumn("Storage Class", value: \S3Object.sortableStorageClass) { object in
                Text(object.storageClass ?? (object.isFolder ? "—" : "STANDARD"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 120, max: 160)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .id(model.prefix)
        .contextMenu(forSelectionType: String.self) { keys in
            contextMenu(keys: keys)
        } primaryAction: { keys in
            primaryAction(keys: keys)
        }
        .overlay {
            ObjectDragSource(
                fileObjects: { row in
                    let all = visibleObjects
                    guard row >= 0, row < all.count, !all[row].isFolder else { return [] }
                    let selected = DragExport.fileObjects(in: all, selectedKeys: model.selection)
                    return selected.contains { $0.key == all[row].key } ? selected : [all[row]]
                },
                startDownload: { object, url, completion in
                    app.downloadForDrag(
                        object,
                        to: url,
                        profile: model.profile,
                        bucket: model.bucket,
                        client: model.client,
                        completion: completion
                    )
                },
                selectRow: { row, flags in
                    handleRowClick(row, flags: flags)
                },
                activateRow: { row in
                    let all = visibleObjects
                    guard row >= 0, row < all.count else { return }
                    primaryAction(keys: [all[row].key])
                },
                prepareContextMenu: { row in
                    let all = visibleObjects
                    guard row >= 0, row < all.count else { return }
                    let key = all[row].key
                    if !model.selection.contains(key) {
                        model.selection = [key]
                        selectionAnchor = row
                    }
                },
                upload: { urls in
                    app.upload(urls: urls)
                },
                setDropTargeted: { targeted in
                    isDropTargeted = targeted
                }
            )
        }
    }

    /// Mirrors the table's selection semantics now that the drag overlay owns row clicks.
    private func handleRowClick(_ row: Int, flags: NSEvent.ModifierFlags) {
        let all = visibleObjects
        guard row >= 0, row < all.count else {
            model.selection.removeAll()
            selectionAnchor = nil
            return
        }
        let key = all[row].key
        if flags.contains(.command) {
            if model.selection.contains(key) {
                model.selection.remove(key)
            } else {
                model.selection.insert(key)
            }
            selectionAnchor = row
        } else if flags.contains(.shift), let anchor = selectionAnchor, all.indices.contains(anchor) {
            let range = anchor <= row ? anchor...row : row...anchor
            model.selection = Set(all[range].map(\.key))
        } else {
            model.selection = [key]
            selectionAnchor = row
        }
    }

    @ViewBuilder
    private func contextMenu(keys: Set<String>) -> some View {
        let objects = visibleObjects.filter { keys.contains($0.key) }
        if objects.isEmpty {
            Button("Upload Files…") { showImporter = true }
            Button("New Folder…") { showNewFolder = true }
            Button("Refresh") { Task { await model.reload() } }
        } else {
            let files = objects.filter { !$0.isFolder }
            if objects.count == 1, objects[0].isFolder {
                Button("Open") { Task { await model.enter(objects[0]) } }
            }
            Button("Download") { app.download(objects: objects) }
                .disabled(files.isEmpty)
            Menu("Copy Presigned URL") {
                ForEach(PresignExpiry.allCases) { option in
                    Button(option.title) {
                        if let file = files.first {
                            app.copyPresignedURL(for: file, expires: option.rawValue)
                        }
                    }
                }
            }
            .disabled(files.count != 1)
            Divider()
            Button("Delete", role: .destructive) {
                beginDelete(objects)
            }
        }
    }

    private func primaryAction(keys: Set<String>) {
        let objects = visibleObjects.filter { keys.contains($0.key) }
        guard objects.count == 1 else { return }
        if objects[0].isFolder {
            Task { await model.enter(objects[0]) }
        } else {
            app.download(objects[0])
        }
    }

    @ViewBuilder
    private var stateView: some View {
        if model.isLoading {
            LoadingOverlay(title: "Loading \(model.bucket)…")
        } else if let error = model.loadError {
            ContentUnavailableView {
                Label("Couldn’t Load Objects", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.alertMessage)
            } actions: {
                Button("Retry") { Task { await model.reload() } }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.objects.isEmpty {
            ContentUnavailableView {
                Label("Empty Folder", systemImage: "folder")
            } description: {
                Text(model.prefix.isEmpty
                     ? "This bucket has no objects at the root."
                     : "“\(model.prefix)” has no objects.")
            } actions: {
                Button("Upload Files…") { showImporter = true }
                Button("New Folder…") { showNewFolder = true }
            }
        } else {
            ContentUnavailableView {
                Label("No Matches", systemImage: "magnifyingglass")
            } description: {
                Text("No objects in this folder match “\(model.searchText)”.")
            }
        }
    }

    private var dropOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                Text("Drop Files to Upload")
                    .font(.headline)
                Text(model.prefix.isEmpty ? "Bucket root" : model.prefix)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(3)
        .allowsHitTesting(false)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isLoadingMore {
                ProgressView().controlSize(.small)
                Text("Loading more…")
            } else if let error = model.loadMoreError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .lineLimit(1)
                    .help(error)
                Button("Retry") { Task { await model.loadMore() } }
                    .buttonStyle(.borderless)
            } else {
                let folders = model.filteredObjects.filter(\.isFolder).count
                let files = model.filteredObjects.count - folders
                Text("\(folders) folder\(folders == 1 ? "" : "s") · \(files) object\(files == 1 ? "" : "s")")
                if !model.searchText.isEmpty {
                    Text("of \(model.objects.count)")
                        .foregroundStyle(.tertiary)
                }
                if model.hasMore {
                    Button {
                        Task { await model.loadMore() }
                    } label: {
                        Label("Load More", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Load the next page of objects")
                }
            }

            Spacer()

            if !model.selection.isEmpty {
                Text("\(model.selection.count) selected")
            }
            Text(model.prefix.isEmpty ? "/" : "/" + model.prefix)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.bar)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showImporter = true
            } label: {
                Label("Upload", systemImage: "square.and.arrow.up")
            }
            .help("Upload files to the current folder")

            Button {
                app.downloadSelected()
            } label: {
                Label("Download", systemImage: "square.and.arrow.down")
            }
            .disabled(!app.canDownload)
            .help("Download selected objects")

            Button {
                showNewFolder = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            .help("Create a folder")

            Button(role: .destructive) {
                beginDeleteSelection()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!app.canDelete)
            .help("Delete selected objects")

            Button {
                Task { await model.reload() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading)
            .help("Refresh this folder")

            if model.profile.provider.showsBucketACLInfo {
                Button {
                    app.beginBucketACL(model.bucket, profile: model.profile)
                } label: {
                    Label("Access Control", systemImage: "lock.shield")
                }
                .help("Bucket access control")
            }

            Button(role: .destructive) {
                app.requestDeleteBucket(model.bucket, profile: model.profile)
            } label: {
                Label("Delete Bucket", systemImage: "trash")
            }
            .disabled(app.bucketOperationStatus != nil)
            .help("Delete this bucket")

            Button {
                app.transfers.togglePanel()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.arrow.down")
                    if app.transfers.activeCount > 0 {
                        Text("\(app.transfers.activeCount)")
                            .font(.caption2.bold().monospacedDigit())
                    }
                }
            }
            .help("Show transfers")

            Button {
                app.isInspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Toggle details inspector")
        }
    }

    // MARK: - Delete

    private func beginDeleteSelection() {
        beginDelete(model.selectedObjects)
    }

    private func beginDelete(_ objects: [S3Object]) {
        guard !objects.isEmpty else { return }
        model.selection = Set(objects.map(\.key))
        pendingDelete = objects
        showDeleteConfirm = true
    }

    private var deleteTitle: String {
        if pendingDelete.count == 1 {
            return "Delete “\(pendingDelete[0].name)”?"
        }
        return "Delete \(pendingDelete.count) Items?"
    }

    private var deleteMessage: String {
        let hasFolders = pendingDelete.contains(where: \.isFolder)
        if hasFolders {
            return "Folders are deleted recursively, including every object inside them. This cannot be undone."
        }
        return "This permanently deletes the selected objects from “\(model.bucket)”. This cannot be undone."
    }
}
