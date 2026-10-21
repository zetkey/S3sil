import SwiftUI
import S3SilKit

struct BucketOverviewView: View {
    @Environment(AppState.self) private var app
    let profile: ConnectionProfile

    private var buckets: [Bucket] {
        app.bucketsByProfile[profile.id] ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if let status = app.bucketOperationStatus {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                metadata
                content
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            LinearGradient(
                colors: [providerTint.opacity(0.08), Color(nsColor: .windowBackgroundColor)],
                startPoint: .topLeading,
                endPoint: .center
            )
        )
        .navigationTitle(profile.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    app.beginCreateBucket(profile)
                } label: {
                    Label("Create Bucket", systemImage: "plus")
                }
                .disabled(app.bucketOperationStatus != nil)
                Button {
                    app.beginEdit(profile)
                } label: {
                    Label("Edit Connection", systemImage: "pencil")
                }
                Button {
                    app.testConnection(profile)
                } label: {
                    Label("Test Connection", systemImage: "bolt.horizontal.circle")
                }
                .disabled(app.testingProfiles.contains(profile.id))
                Button {
                    app.refreshBuckets(for: profile.id)
                } label: {
                    Label("Refresh Buckets", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var providerTint: Color {
        profile.provider.tint
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ProviderBadge(provider: profile.provider, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(1)
                Text(profile.provider.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if app.testingProfiles.contains(profile.id) {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            metadataPill(icon: "link", text: EndpointResolver.displayEndpoint(for: profile))
            metadataPill(icon: "globe", text: profile.region.isEmpty ? "auto" : profile.region)
            metadataPill(
                icon: "arrow.left.arrow.right",
                text: resolvedAddressing
            )
            if let aclSummary = profile.provider.aclSummary {
                metadataPill(icon: "lock.shield", text: aclSummary)
            }
        }
        .lineLimit(1)
    }

    private var resolvedAddressing: String {
        (try? EndpointResolver.resolve(profile: profile)).map(\.addressingDescription)
            ?? (profile.pathStyle ? "Path-style" : "Virtual-hosted")
    }

    private func metadataPill(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
    }

    @ViewBuilder
    private var content: some View {
        if app.loadingBuckets.contains(profile.id), buckets.isEmpty {
            HStack {
                Spacer()
                LoadingOverlay(title: "Loading buckets…")
                Spacer()
            }
            .padding(.top, 40)
        } else if let error = app.bucketErrors[profile.id] {
            VStack(alignment: .leading, spacing: 12) {
                Label("Couldn’t Load Buckets", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("Retry") { app.refreshBuckets(for: profile.id) }
                        .buttonStyle(.borderedProminent)
                    Button("Edit Connection") { app.beginEdit(profile) }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.red.opacity(0.25))
            )
        } else if buckets.isEmpty {
            ContentUnavailableView {
                Label("No Buckets", systemImage: "shippingbox")
            } description: {
                Text("This account returned no buckets. If you expected some, check the credentials and permissions.")
            } actions: {
                Button("Create Bucket") { app.beginCreateBucket(profile) }
                    .buttonStyle(.borderedProminent)
                Button("Refresh") { app.refreshBuckets(for: profile.id) }
                Button("Edit Connection") { app.beginEdit(profile) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(buckets) { bucket in
                    BucketCard(profile: profile, bucket: bucket) {
                        app.select(.bucket(profile.id, bucket.name))
                    }
                }
            }
        }
    }
}

private struct BucketCard: View {
    @Environment(AppState.self) private var app
    let profile: ConnectionProfile
    let bucket: Bucket
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "shippingbox.fill")
                        .font(.title3)
                        .foregroundStyle(profile.provider.tint)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(bucket.name)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Text("Created \(Format.created(bucket.creationDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(hovering ? profile.provider.tint.opacity(0.55) : Color(nsColor: .separatorColor).opacity(0.5))
            )
            .shadow(color: .black.opacity(hovering ? 0.12 : 0.04), radius: hovering ? 10 : 3, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { open() }
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
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
