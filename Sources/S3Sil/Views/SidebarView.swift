import SwiftUI
import S3SilKit

struct SidebarView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: Binding(
            get: { app.selection },
            set: { app.select($0) }
        )) {
            Section("Connections") {
                if app.profiles.isEmpty {
                    Text("No connections yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(app.profiles) { profile in
                    connectionRow(profile)
                        .tag(SidebarSelection.profile(profile.id))
                        .contextMenu {
                            Button("Edit…") { app.beginEdit(profile) }
                            Button("Test Connection") { app.testConnection(profile) }
                            Button("Create Bucket…") { app.beginCreateBucket(profile) }
                                .disabled(app.bucketOperationStatus != nil)
                            Divider()
                            Button("Delete…", role: .destructive) {
                                app.requestDeleteConnection(profile)
                            }
                        }
                }
            }

            if let profile = app.selectedProfile {
                Section("Buckets") {
                    let buckets = app.bucketsByProfile[profile.id] ?? []
                    if app.loadingBuckets.contains(profile.id), buckets.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading buckets…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = app.bucketErrors[profile.id] {
                        VStack(alignment: .leading, spacing: 5) {
                            Label("Couldn’t load buckets", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                            Button("Retry") { app.refreshBuckets(for: profile.id) }
                                .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    } else if buckets.isEmpty {
                        Text("No buckets")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(buckets) { bucket in
                            Label {
                                Text(bucket.name)
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: "shippingbox.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .tag(SidebarSelection.bucket(profile.id, bucket.name))
                            .contextMenu {
                                Button("Open") {
                                    app.select(.bucket(profile.id, bucket.name))
                                }
                                Button("Copy Bucket Name") {
                                    FilePanels.copy(bucket.name)
                                    app.showToast("Bucket name copied")
                                }
                                if profile.provider.showsBucketACLInfo {
                                    Divider()
                                    Button("Access Control…") {
                                        app.beginBucketACL(bucket.name, profile: profile)
                                    }
                                }
                                Divider()
                                Button("Delete Bucket…", role: .destructive) {
                                    app.requestDeleteBucket(bucket.name, profile: profile)
                                }
                                .disabled(app.bucketOperationStatus != nil)
                            }
                        }
                    }

                    HStack(spacing: 12) {
                        Button {
                            app.beginCreateBucket(profile)
                        } label: {
                            Label("Create Bucket", systemImage: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .disabled(app.bucketOperationStatus != nil)

                        Spacer()

                        if !app.loadingBuckets.contains(profile.id) {
                            Button {
                                app.refreshBuckets(for: profile.id)
                            } label: {
                                Label("Refresh Buckets", systemImage: "arrow.clockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    app.beginNewConnection()
                } label: {
                    Label("Add Connection", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(10)
            }
            .background(.bar)
        }
        .navigationTitle("S3Sil")
        .sheet(item: $app.bucketCreateTarget) { profile in
            CreateBucketSheet(profile: profile) { name in
                try await app.createBucket(named: name, in: profile)
            }
        }
    }

    private func connectionRow(_ profile: ConnectionProfile) -> some View {
        HStack(spacing: 9) {
            ProviderBadge(provider: profile.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(endpointSummary(profile))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if app.testingProfiles.contains(profile.id) {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    private func endpointSummary(_ profile: ConnectionProfile) -> String {
        let endpoint = EndpointResolver.displayEndpoint(for: profile)
        let addressing = (try? EndpointResolver.resolve(profile: profile))?.addressingDescription.lowercased()
            ?? (profile.pathStyle ? "path-style" : "virtual-hosted")
        return "\(profile.provider.shortName) · \(addressing) · \(endpoint)"
    }
}
