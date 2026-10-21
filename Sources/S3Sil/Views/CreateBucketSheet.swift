import SwiftUI
import S3SilKit

struct CreateBucketSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: ConnectionProfile
    let onCreate: (String) async throws -> Void

    @State private var name = ""
    @State private var errorMessage: String?
    @State private var isSaving = false
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationError: String? {
        BucketNameValidator.validationError(for: trimmedName, provider: profile.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProviderBadge(provider: profile.provider, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create Bucket")
                        .font(.headline)
                    Text(profile.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Bucket name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("my-bucket", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($nameFocused)
                    .onSubmit(create)
                Text("3–63 characters. No slashes or spaces.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                metadataPill(icon: "cloud", text: profile.provider.displayName)
                metadataPill(icon: "globe", text: profile.region.isEmpty ? "auto" : profile.region)
            }
            .lineLimit(1)

            Text(EndpointResolver.displayEndpoint(for: profile))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let validationError, !trimmedName.isEmpty {
                Label(validationError, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
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
                .disabled(validationError != nil || isSaving)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { nameFocused = true }
    }

    private func metadataPill(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
    }

    private func create() {
        guard !isSaving else { return }
        let name = trimmedName
        if let problem = BucketNameValidator.validationError(for: name, provider: profile.provider) {
            errorMessage = problem
            return
        }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await onCreate(name)
                dismiss()
            } catch {
                errorMessage = (error as? S3Error)?.alertMessage ?? error.localizedDescription
                isSaving = false
            }
        }
    }
}
