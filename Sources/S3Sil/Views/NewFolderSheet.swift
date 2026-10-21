import SwiftUI
import S3SilKit

struct NewFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (String) async throws -> Void

    @State private var name = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.plus")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Folder")
                        .font(.headline)
                    Text("Creates a zero-byte object whose key ends in “/”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(create)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    create()
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await onCreate(trimmed)
                dismiss()
            } catch {
                errorMessage = (error as? S3Error)?.alertMessage ?? error.localizedDescription
                isSaving = false
            }
        }
    }
}
