import SwiftUI

struct AppStateFocusedValueKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var appState: AppState? {
        get { self[AppStateFocusedValueKey.self] }
        set { self[AppStateFocusedValueKey.self] = newValue }
    }
}

struct S3SilCommands: Commands {
    @FocusedValue(\.appState) private var app

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") {
                app?.beginNewConnection()
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Connection") {
            Button("Edit Connection…") {
                app?.beginEditSelectedConnection()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(app?.selectedProfile == nil)

            Button("Test Connection") {
                if let profile = app?.selectedProfile {
                    app?.testConnection(profile)
                }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(app?.selectedProfile == nil || (app?.isSelectedProfileTesting ?? false))

            Button("Refresh Buckets") {
                if let profile = app?.selectedProfile {
                    app?.refreshBuckets(for: profile.id)
                }
            }
            .keyboardShortcut("r", modifiers: [.option, .command])
            .disabled(app?.selectedProfile == nil)

            Divider()

            Button("Delete Connection…") {
                if let profile = app?.selectedProfile {
                    app?.requestDeleteConnection(profile)
                }
            }
            .disabled(app?.selectedProfile == nil)
        }

        CommandMenu("Object") {
            Button("Upload Files…") {
                app?.requestUpload()
            }
            .keyboardShortcut("u", modifiers: .command)
            .disabled(!(app?.canUpload ?? false))

            Button("Download…") {
                app?.downloadSelected()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!(app?.canDownload ?? false))

            Button("New Folder…") {
                app?.requestNewFolder()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!(app?.canNewFolder ?? false))

            Button("Delete…") {
                app?.requestDelete()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!(app?.canDelete ?? false))

            Divider()

            Menu("Copy Presigned URL") {
                ForEach(PresignExpiry.allCases) { option in
                    Button(option.title) {
                        app?.copyPresignedURLForSelection(expires: option.rawValue)
                    }
                }
            }
            .disabled(!(app?.canCopyPresigned ?? false))

            Button("Refresh") {
                guard let app, let browser = app.browser else { return }
                Task { await browser.reload() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(app?.browser == nil)

            Divider()

            Button("Toggle Inspector") {
                app?.isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.option, .command])
            .disabled(app?.browser == nil)

            Button("Show Transfers") {
                app?.transfers.togglePanel()
            }
            .keyboardShortcut("t", modifiers: [.option, .command])
            .disabled(app?.transfers.items.isEmpty ?? true)
        }
    }
}
