import SwiftUI
import S3SilKit

struct ContentView: View {
    @Environment(AppState.self) private var app
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            detail
                .sheet(item: $app.aclTarget) { target in
                    BucketACLSheet(target: target)
                }
                .confirmationDialog(
                    app.bucketPendingDelete.map { "Delete “\($0.bucket)”?" } ?? "Delete Bucket?",
                    isPresented: Binding(
                        get: { app.bucketPendingDelete != nil },
                        set: { if !$0 { app.bucketPendingDelete = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Delete Bucket", role: .destructive) {
                        app.deletePendingBucket()
                    }
                    Button("Cancel", role: .cancel) {
                        app.bucketPendingDelete = nil
                    }
                } message: {
                    Text("The bucket must be empty before it can be deleted. Deletion is irreversible; S3 does not delete the objects for you.")
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if app.transfers.isPanelVisible, !app.transfers.items.isEmpty {
                        TransferQueueView()
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 940, minHeight: 580)
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                ToastView(message: toast)
                    .padding(.bottom, app.transfers.isPanelVisible && !app.transfers.items.isEmpty ? 190 : 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            if let status = app.bucketOperationStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status)
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
                .padding(16)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: app.toast)
        .animation(.snappy(duration: 0.25), value: app.transfers.isPanelVisible)
        .animation(.easeOut(duration: 0.15), value: app.bucketOperationStatus)
        .alert(item: $app.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .confirmationDialog(
            app.connectionPendingDelete.map { "Delete “\($0.name)”?" } ?? "Delete Connection?",
            isPresented: Binding(
                get: { app.connectionPendingDelete != nil },
                set: { if !$0 { app.connectionPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Connection", role: .destructive) {
                app.deletePendingConnection()
            }
            Button("Cancel", role: .cancel) {
                app.connectionPendingDelete = nil
            }
        } message: {
            Text("The connection and its Keychain credentials will be removed. Objects in the bucket are not affected.")
        }
        .sheet(item: $app.editingTarget) { target in
            ConnectionEditorView(target: target) { profile, credentials in
                try app.saveConnection(profile, credentials: credentials)
            }
        }
        .task {
            await app.start()
        }
    }

    @ViewBuilder
    private var detail: some View {
        if app.profiles.isEmpty {
            welcome
        } else if let browser = app.browser {
            ObjectBrowserView(model: browser)
                .id(browser.identity)
        } else if let profile = app.selectedProfile {
            BucketOverviewView(profile: profile)
        } else {
            ContentUnavailableView {
                Label("Select a Connection", systemImage: "sidebar.left")
            } description: {
                Text("Choose a connection in the sidebar to browse its buckets.")
            }
        }
    }

    private var welcome: some View {
        ContentUnavailableView {
            Label("Welcome to S3Sil", systemImage: "externaldrive.badge.icloud")
        } description: {
            Text("Browse AWS S3, Cloudflare R2, Hitachi HCP or Vantara, MinIO, and any S3-compatible endpoint — natively on your Mac.")
        } actions: {
            Button("Add Connection") {
                app.beginNewConnection()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.08), Color(nsColor: .windowBackgroundColor)],
                startPoint: .top,
                endPoint: .center
            )
        )
    }
}
