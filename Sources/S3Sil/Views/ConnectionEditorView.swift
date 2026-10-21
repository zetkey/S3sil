import AppKit
import SwiftUI
import S3SilKit

struct ConnectionEditorView: View {
    private enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    @Environment(\.dismiss) private var dismiss
    let target: ConnectionEditorTarget
    let onSave: (ConnectionProfile, S3Credentials) throws -> Void

    @State private var profileID: UUID
    @State private var name: String
    @State private var provider: ProviderKind
    @State private var endpoint: String
    @State private var region: String
    @State private var accountID: String
    @State private var pathStyle: Bool
    @State private var accessKey: String
    @State private var secretKey: String
    @State private var sessionToken: String
    @State private var revealSecrets = false
    @State private var errors: [String: String] = [:]
    @State private var saveError: String?
    @State private var testState: TestState = .idle
    @State private var testTask: Task<Void, Never>?

    init(target: ConnectionEditorTarget,
         onSave: @escaping (ConnectionProfile, S3Credentials) throws -> Void) {
        self.target = target
        self.onSave = onSave

        let profile: ConnectionProfile?
        let credentials: S3Credentials?
        switch target {
        case .new:
            profile = nil
            credentials = nil
        case .edit(let value, let creds):
            profile = value
            credentials = creds
        }

        _profileID = State(initialValue: profile?.id ?? UUID())
        _name = State(initialValue: profile?.name ?? "")
        _provider = State(initialValue: profile?.provider ?? .aws)
        _endpoint = State(initialValue: profile?.endpoint ?? "")
        _region = State(initialValue: profile?.region ?? ProviderKind.aws.defaultRegion)
        _accountID = State(initialValue: profile?.accountID ?? "")
        _pathStyle = State(initialValue: profile?.pathStyle ?? ProviderKind.aws.defaultPathStyle)
        _accessKey = State(initialValue: credentials?.accessKeyID ?? "")
        _secretKey = State(initialValue: credentials?.secretAccessKey ?? "")
        _sessionToken = State(initialValue: credentials?.sessionToken ?? "")
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    providerSection
                    connectionSection
                    credentialsSection
                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 700)
        .onChange(of: provider) { _, newProvider in
            applyPreset(newProvider)
        }
        .onDisappear {
            testTask?.cancel()
        }
    }

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            ProviderBadge(provider: provider, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit Connection" : "New Connection")
                    .font(.title3.weight(.semibold))
                Text("Credentials are stored in the macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var providerSection: some View {
        EditorSection(title: "Provider", icon: "square.grid.2x2") {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                spacing: 8
            ) {
                ForEach(ProviderKind.allCases) { kind in
                    Button {
                        provider = kind
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: kind.symbolName)
                                .font(.title3)
                                .foregroundStyle(provider == kind ? kind.tint : Color.secondary)
                            Text(kind.displayName)
                                .font(.caption2.weight(.medium))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .padding(6)
                        .background(
                            provider == kind ? kind.tint.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(
                                    provider == kind ? kind.tint.opacity(0.8) : Color.secondary.opacity(0.2),
                                    lineWidth: provider == kind ? 1.5 : 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var connectionSection: some View {
        EditorSection(title: "Connection", icon: "network") {
            LabeledField(
                title: "Name",
                prompt: "e.g. Production Assets",
                text: $name,
                monospaced: false,
                error: errors["name"]
            )

            if provider == .cloudflareR2 {
                LabeledField(
                    title: "Account ID",
                    prompt: "Cloudflare account ID",
                    text: $accountID,
                    monospaced: true,
                    error: errors["account"]
                )
            }

            LabeledField(
                title: "Endpoint",
                prompt: provider.endpointPlaceholder,
                text: $endpoint,
                monospaced: true,
                error: errors["endpoint"]
            )
            Text(endpointCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            HStack(alignment: .bottom, spacing: 12) {
                LabeledField(
                    title: provider == .cloudflareR2 ? "Region (auto)" : "Region",
                    prompt: "us-east-1",
                    text: $region,
                    monospaced: true,
                    error: errors["region"],
                    disabled: provider == .cloudflareR2
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Addressing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Toggle("Path-style requests", isOn: $pathStyle)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .disabled(provider == .cloudflareR2)
                }
                .padding(.bottom, 3)
            }
            Text(addressingCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var credentialsSection: some View {
        EditorSection(title: "Credentials", icon: "key") {
            LabeledField(
                title: "Access Key ID",
                prompt: "AKIA…",
                text: $accessKey,
                monospaced: true,
                error: errors["access"]
            )
            SecretField(
                title: "Secret Access Key",
                prompt: "Secret access key",
                text: $secretKey,
                reveal: $revealSecrets,
                error: errors["secret"]
            )
            SecretField(
                title: "Session Token",
                prompt: "Optional — for temporary credentials",
                text: $sessionToken,
                reveal: $revealSecrets,
                error: nil
            )
            Text("Secrets are saved as a generic-password item per connection in the Keychain.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                test()
            } label: {
                Label("Test Connection", systemImage: "bolt.horizontal")
            }
            .disabled(isTesting)

            testStatus

            Spacer()

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isEditing ? "Save" : "Add Connection") {
                save()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle:
            Text("Not tested")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(1)
                .help(message)
        case .failure(let message):
            Label("Failed", systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .help(message)
        }
    }

    private var isTesting: Bool {
        if case .testing = testState { return true }
        return false
    }

    private var endpointCaption: String {
        switch provider {
        case .aws:
            return "Leave empty to use https://s3.\(region.isEmpty ? "<region>" : region).amazonaws.com"
        case .cloudflareR2:
            return "Leave empty to derive https://<account>.r2.cloudflarestorage.com from the account ID."
        case .minio:
            return "HTTP is allowed for LAN MinIO endpoints. Include the port, e.g. http://127.0.0.1:9000."
        case .hitachi:
            return "Enter the S3 gateway endpoint for HCP or Vantara."
        case .generic:
            return "Any S3-compatible endpoint, optionally with a path prefix."
        }
    }

    private var addressingCaption: String {
        if provider == .cloudflareR2 {
            return "R2 requires path-style addressing and the auto region."
        }
        if pathStyle {
            return "Requests use https://endpoint/bucket/key."
        }
        return "Requests use https://bucket.endpoint/key."
    }

    private func applyPreset(_ newProvider: ProviderKind) {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = newProvider.displayName
        }
        accountID = newProvider == .cloudflareR2 ? accountID : ""
        testState = .idle
        switch newProvider {
        case .aws:
            endpoint = ""
            region = ProviderKind.aws.defaultRegion
            pathStyle = false
        case .cloudflareR2:
            endpoint = ""
            region = "auto"
            pathStyle = true
        case .hitachi:
            endpoint = ""
            region = "us-east-1"
            pathStyle = true
        case .minio:
            endpoint = "http://127.0.0.1:9000"
            region = "us-east-1"
            pathStyle = true
        case .generic:
            endpoint = ""
            region = "us-east-1"
            pathStyle = true
        }
    }

    private func draftProfile() -> ConnectionProfile {
        ConnectionProfile(
            id: profileID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: provider,
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            region: provider == .cloudflareR2 ? "auto" : region.trimmingCharacters(in: .whitespacesAndNewlines),
            accountID: accountID.trimmingCharacters(in: .whitespacesAndNewlines),
            pathStyle: provider == .cloudflareR2 ? true : pathStyle
        )
    }

    private func draftCredentials() -> S3Credentials {
        let token = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return S3Credentials(
            accessKeyID: accessKey.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: secretKey,
            sessionToken: token.isEmpty ? nil : token
        )
    }

    private func validate() -> [String: String] {
        var result: [String: String] = [:]
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result["name"] = "Required"
        }
        if provider == .aws && region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result["region"] = "Required"
        }
        if provider == .cloudflareR2 && accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result["account"] = "Required"
        }
        do {
            _ = try EndpointResolver.resolve(profile: draftProfile())
        } catch {
            let message = (error as? S3Error)?.message ?? error.localizedDescription
            if provider == .cloudflareR2, accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result["account"] = message
            } else if provider == .aws, region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result["region"] = message
            } else {
                result["endpoint"] = message
            }
        }
        if accessKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result["access"] = "Required"
        }
        if secretKey.isEmpty {
            result["secret"] = "Required"
        }
        return result
    }

    private func save() {
        let validation = validate()
        errors = validation
        saveError = nil
        let profile = draftProfile()
        let credentials = draftCredentials()
        guard validation.isEmpty else { return }
        do {
            try onSave(profile, credentials)
            dismiss()
        } catch {
            saveError = (error as? S3Error)?.alertMessage ?? error.localizedDescription
        }
    }

    private func test() {
        let validation = validate()
        errors = validation
        guard validation.isEmpty else { return }
        testState = .testing
        testTask?.cancel()
        let profile = draftProfile()
        let credentials = draftCredentials()
        testTask = Task {
            do {
                let client = try S3Client(profile: profile, credentials: credentials)
                let buckets = try await client.listBuckets()
                guard !Task.isCancelled else { return }
                testState = .success("Connected — \(buckets.count) bucket\(buckets.count == 1 ? "" : "s") found")
            } catch is CancellationError {
                testState = .idle
            } catch {
                guard !Task.isCancelled else { return }
                testState = .failure((error as? S3Error)?.alertMessage ?? error.localizedDescription)
            }
        }
    }
}

private struct EditorSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator.opacity(0.5))
        )
    }
}

private struct LabeledField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var monospaced = true
    var error: String?
    var disabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .disabled(disabled)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    Color(nsColor: .textBackgroundColor).opacity(disabled ? 0.35 : 0.7),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(
                            error != nil ? Color.red.opacity(0.55) : Color.secondary.opacity(0.25)
                        )
                )
        }
    }
}

private struct SecretField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    @Binding var reveal: Bool
    var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let error {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            HStack(spacing: 6) {
                Group {
                    if reveal {
                        TextField(prompt, text: $text)
                    } else {
                        SecureField(prompt, text: $text)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))

                Button {
                    reveal.toggle()
                } label: {
                    Image(systemName: reveal ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(reveal ? "Hide secrets" : "Reveal secrets")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                Color(nsColor: .textBackgroundColor).opacity(0.7),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(error != nil ? Color.red.opacity(0.55) : Color.secondary.opacity(0.25))
            )
        }
    }
}
