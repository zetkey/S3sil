import SwiftUI
import S3SilKit

struct InspectorView: View {
    @Environment(AppState.self) private var app
    let model: ObjectBrowserModel

    @State private var expiry: PresignExpiry = .oneHour
    @State private var presignedURL: URL?
    @State private var presignError: String?
    @State private var isPresigning = false

    private var selected: [S3Object] {
        model.selectedObjects
    }

    private var single: S3Object? {
        selected.count == 1 ? selected[0] : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if selected.isEmpty {
                    ContentUnavailableView {
                        Label("No Selection", systemImage: "sidebar.right")
                    } description: {
                        Text("Select an object to inspect its key, size, ETag, and presigned URL.")
                    }
                    .padding(.top, 30)
                } else if let object = single {
                    objectHeader(object)
                    infoCard(object)
                    if !object.isFolder {
                        presignCard(object)
                    }
                } else {
                    multiSelection
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.regularMaterial)
        .task(id: presignTaskID) {
            await generatePresignedURL()
        }
    }

    private func objectHeader(_ object: S3Object) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: object.isFolder ? "folder.fill" : "doc.text.fill")
                .font(.title2)
                .foregroundStyle(object.isFolder ? Color.accentColor : Color.secondary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(object.name)
                    .font(.system(.headline, design: .monospaced))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text(object.isFolder ? "Folder" : Format.size(object.size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func infoCard(_ object: S3Object) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)
            detail("Key", object.key, monospaced: true)
            if !object.isFolder {
                detail("Size", "\(Format.size(object.size)) (\(object.size) bytes)", monospaced: false)
            }
            detail("Modified", Format.modified(object.lastModified), monospaced: false)
            if !object.isFolder {
                detail("ETag", object.etag.isEmpty ? "—" : object.etag, monospaced: true)
                detail("Storage Class", object.storageClass ?? "STANDARD", monospaced: true)
            }
            detail("Bucket", model.bucket, monospaced: true)
            detail("Profile", model.profile.name, monospaced: false)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
    }

    private func presignCard(_ object: S3Object) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Presigned URL")
                    .font(.headline)
                Spacer()
                Picker("Expiry", selection: $expiry) {
                    ForEach(PresignExpiry.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)
            }

            if isPresigning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Signing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let url = presignedURL {
                Text(url.absoluteString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button {
                        FilePanels.copy(url.absoluteString)
                        app.showToast("Presigned URL copied")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if let presignError {
                Text(presignError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
    }

    private var multiSelection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(selected.count) Items Selected")
                .font(.headline)
            let total = selected.reduce(Int64(0)) { $0 + ($1.isFolder ? 0 : $1.size) }
            Text("\(Format.size(total)) across \(selected.filter { !$0.isFolder }.count) objects")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Folders are not included in the size total.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack {
                Button {
                    app.downloadSelected()
                } label: {
                    Label("Download…", systemImage: "square.and.arrow.down")
                }
                Button(role: .destructive) {
                    app.requestDelete()
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
            }
            .controlSize(.small)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
    }

    private func detail(_ label: String, _ value: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var presignTaskID: String {
        let key = single?.key ?? ""
        return "\(key)|\(expiry.rawValue)"
    }

    private func generatePresignedURL() async {
        presignedURL = nil
        presignError = nil
        guard let object = single, !object.isFolder else {
            isPresigning = false
            return
        }
        isPresigning = true
        defer { isPresigning = false }
        do {
            let url = try await model.client.presignedURL(
                bucket: model.bucket,
                key: object.key,
                expires: expiry.rawValue
            )
            guard !Task.isCancelled else { return }
            if single?.key == object.key {
                presignedURL = url
            }
        } catch {
            guard !Task.isCancelled else { return }
            presignError = (error as? S3Error)?.alertMessage ?? error.localizedDescription
        }
    }
}
