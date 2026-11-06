import AppKit
import SwiftUI
import S3SilKit

// MARK: - Protocol group

private enum ProtocolGroup: String, CaseIterable, Identifiable {
    case s3
    case webdav
    case ftp
    case sftp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .s3:      return "S3"
        case .webdav:  return "WebDAV"
        case .ftp:     return "FTP"
        case .sftp:    return "SFTP"
        }
    }

    var symbolName: String {
        switch self {
        case .s3:      return "externaldrive.connected.to.line.below"
        case .webdav:  return "globe"
        case .ftp:     return "arrow.triangle.swap"
        case .sftp:    return "terminal"
        }
    }

    var tint: Color {
        switch self {
        case .s3:      return .orange
        case .webdav:  return .blue
        case .ftp:     return .yellow
        case .sftp:    return .green
        }
    }

    /// The ProviderKind this group locks to (nil for S3, where the user picks).
    var providerKind: ProviderKind? {
        switch self {
        case .s3:      return nil
        case .webdav:  return .webdav
        case .ftp:     return .ftp
        case .sftp:    return .sftp
        }
    }

    /// Which S3 ProviderKind to restore when switching back to .s3.
    static func restoreS3Provider(from provider: ProviderKind) -> ProviderKind {
        provider.isS3 ? provider : .aws
    }
}

// MARK: - ConnectionEditorView

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

    // Protocol
    @State private var protocolGroup: ProtocolGroup
    @State private var lastS3Provider: ProviderKind

    // S3 fields
    @State private var provider: ProviderKind
    @State private var endpoint: String
    @State private var region: String
    @State private var accountID: String
    @State private var pathStyle: Bool

    // Non-S3 fields
    @State private var host: String
    @State private var portString: String
    @State private var basePath: String
    @State private var useTLS: Bool
    @State private var privateKeyPath: String?

    // Common
    @State private var name: String
    @State private var username: String
    @State private var password: String
    @State private var sessionToken: String
    @State private var revealSecrets = false

    // Sheet state
    @State private var errors: [String: String] = [:]
    @State private var saveError: String?
    @State private var testState: TestState = .idle
    @State private var testTask: Task<Void, Never>?

    private let profileID: UUID

    // MARK: - Init

    init(target: ConnectionEditorTarget,
         onSave: @escaping (ConnectionProfile, S3Credentials) throws -> Void) {
        self.target = target
        self.onSave = onSave

        let editProfile: ConnectionProfile?
        let editCreds: S3Credentials?
        switch target {
        case .new:
            editProfile = nil
            editCreds = nil
        case .edit(let value, let creds):
            editProfile = value
            editCreds = creds
        }

        let p = editProfile
        profileID = p?.id ?? UUID()

        // Determine protocol group from the profile’s provider
        let pg: ProtocolGroup
        if let pk = p?.provider {
            switch pk {
            case .webdav: pg = .webdav
            case .ftp:    pg = .ftp
            case .sftp:   pg = .sftp
            default:      pg = .s3
            }
        } else {
            pg = .s3
        }
        _protocolGroup = State(initialValue: pg)
        _lastS3Provider = State(initialValue: ProtocolGroup.restoreS3Provider(from: p?.provider ?? .aws))

        _name = State(initialValue: p?.name ?? "")
        _provider = State(initialValue: pg == .s3 ? (p?.provider ?? .aws) : .aws)
        _endpoint = State(initialValue: p?.endpoint ?? "")
        _region = State(initialValue: p?.region ?? ProviderKind.aws.defaultRegion)
        _accountID = State(initialValue: p?.accountID ?? "")
        _pathStyle = State(initialValue: p?.pathStyle ?? ProviderKind.aws.defaultPathStyle)

        _host = State(initialValue: p?.host ?? "")
        _portString = State(initialValue: p?.port.map(String.init) ?? "")
        _basePath = State(initialValue: p?.basePath ?? "")
        _useTLS = State(initialValue: p?.useTLS ?? false)
        _privateKeyPath = State(initialValue: p?.privateKeyPath)

        _username = State(initialValue: editCreds?.accessKeyID ?? "")
        _password = State(initialValue: editCreds?.secretAccessKey ?? "")
        _sessionToken = State(initialValue: editCreds?.sessionToken ?? "")
    }

    private var isEditing: Bool {
        if case .edit = target { return true }
        return false
    }

    // MARK: - Derived values

    private var effectiveProvider: ProviderKind {
        protocolGroup.providerKind ?? provider
    }

    private var portValue: Int? {
        let trimmed = portString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Int(trimmed)
    }

    private var defaultPort: Int {
        switch protocolGroup {
        case .ftp:  return useTLS ? 990 : 21
        case .sftp: return 22
        default:    return 0
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    protocolSection
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
        .onChange(of: protocolGroup) { _, newGroup in
            applyProtocolGroup(newGroup)
        }
        .onChange(of: provider) { _, _ in
            testState = .idle
        }
        .onDisappear {
            testTask?.cancel()
        }
    }

    // MARK: - Header

    private var sheetHeader: some View {
        HStack(spacing: 12) {
            protocolBadge
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

    private var protocolBadge: some View {
        Image(systemName: protocolGroup.symbolName)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(protocolGroup.tint.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .help(protocolGroup.displayName)
    }

    // MARK: - Protocol section

    private var protocolSection: some View {
        EditorSection(title: "Protocol", icon: "square.grid.2x2") {
            // Segmented picker
            Picker("Protocol", selection: $protocolGroup) {
                ForEach(ProtocolGroup.allCases) { pg in
                    Label(pg.displayName, systemImage: pg.symbolName)
                        .tag(pg)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // S3 provider grid — only when S3
            if protocolGroup == .s3 {
                s3ProviderGrid
            }
        }
    }

    private var s3ProviderGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 8
        ) {
            ForEach(ProviderKind.allCases) { kind in
                // Show only S3-flavoured providers
                if kind.isS3 {
                    Button {
                        provider = kind
                        applyPreset(kind)
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

    // MARK: - Connection section

    private var connectionSection: some View {
        EditorSection(title: "Connection", icon: "network") {
            // Name — always
            LabeledField(
                title: "Name",
                prompt: "e.g. Production Assets",
                text: $name,
                monospaced: false,
                error: errors["name"]
            )

            switch protocolGroup {
            case .s3:
                s3ConnectionFields
            case .webdav:
                webdavConnectionFields
            case .ftp:
                ftpConnectionFields
            case .sftp:
                sftpConnectionFields
            }
        }
    }

    // --- S3 connection fields ---

    @ViewBuilder
    private var s3ConnectionFields: some View {
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

    // --- WebDAV connection fields ---

    @ViewBuilder
    private var webdavConnectionFields: some View {
        LabeledField(
            title: "Endpoint URL",
            prompt: "https://webdav.example.com",
            text: $endpoint,
            monospaced: true,
            error: errors["endpoint"]
        )
        Text("Full WebDAV server URL, e.g. https://webdav.example.com/remote.php/dav/.")
            .font(.caption2)
            .foregroundStyle(.tertiary)

        LabeledField(
            title: "Base Path",
            prompt: "/remote.php/dav/files/username/",
            text: $basePath,
            monospaced: true,
            error: nil
        )
        Text("Optional — a subfolder shown as the root in the browser.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // --- FTP connection fields ---

    @ViewBuilder
    private var ftpConnectionFields: some View {
        HStack(alignment: .bottom, spacing: 12) {
            LabeledField(
                title: "Host",
                prompt: "ftp.example.com",
                text: $host,
                monospaced: true,
                error: errors["host"]
            )

            LabeledField(
                title: "Port",
                prompt: "\(defaultPort)",
                text: $portString,
                monospaced: true,
                error: nil
            )
        }

        Toggle("Use TLS (FTPS)", isOn: $useTLS)
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: useTLS) { _, _ in
                if portString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    portString = String(defaultPort)
                }
            }

        LabeledField(
            title: "Base Path",
            prompt: "/public_html/",
            text: $basePath,
            monospaced: true,
            error: nil
        )
        Text("Optional — a subfolder shown as the root in the browser.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    // --- SFTP connection fields ---

    @ViewBuilder
    private var sftpConnectionFields: some View {
        HStack(alignment: .bottom, spacing: 12) {
            LabeledField(
                title: "Host",
                prompt: "sftp.example.com",
                text: $host,
                monospaced: true,
                error: errors["host"]
            )

            LabeledField(
                title: "Port",
                prompt: "\(defaultPort)",
                text: $portString,
                monospaced: true,
                error: nil
            )
        }

        LabeledField(
            title: "Base Path",
            prompt: "/home/user/files",
            text: $basePath,
            monospaced: true,
            error: nil
        )
        Text("Optional — a subfolder shown as the root in the browser.")
            .font(.caption2)
            .foregroundStyle(.tertiary)

        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Private Key")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(privateKeyPath ?? "None selected")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(privateKeyPath == nil ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Choose…") {
                choosePrivateKey()
            }
            .controlSize(.small)
            if privateKeyPath != nil {
                Button {
                    privateKeyPath = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear key")
            }
        }
    }

    // MARK: - Credentials section

    private var credentialsSection: some View {
        EditorSection(title: "Credentials", icon: "key") {
            LabeledField(
                title: protocolGroup == .s3 ? "Access Key ID" : "Username",
                prompt: protocolGroup == .s3 ? "AKIA…" : "user@example.com",
                text: $username,
                monospaced: true,
                error: errors["access"]
            )

            SecretField(
                title: protocolGroup == .s3 ? "Secret Access Key" : "Password",
                prompt: protocolGroup == .s3 ? "Secret access key" : "Password",
                text: $password,
                reveal: $revealSecrets,
                error: errors["secret"]
            )

            if protocolGroup == .s3 {
                SecretField(
                    title: "Session Token",
                    prompt: "Optional — for temporary credentials",
                    text: $sessionToken,
                    reveal: $revealSecrets,
                    error: nil
                )
            }

            Text("Secrets are saved as a generic-password item per connection in the Keychain.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Footer

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

    // MARK: - Captions

    private var endpointCaption: String {
        if protocolGroup != .s3 { return "" }
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
        default:
            return ""
        }
    }

    private var addressingCaption: String {
        if protocolGroup != .s3 { return "" }
        if provider == .cloudflareR2 {
            return "R2 requires path-style addressing and the auto region."
        }
        if pathStyle {
            return "Requests use https://endpoint/bucket/key."
        }
        return "Requests use https://bucket.endpoint/key."
    }

    // MARK: - Actions

    private func applyPreset(_ newProvider: ProviderKind) {
        guard protocolGroup == .s3 else { return }
        lastS3Provider = newProvider
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
        default:
            break
        }
    }

    private func applyProtocolGroup(_ newGroup: ProtocolGroup) {
        testState = .idle
        switch newGroup {
        case .s3:
            provider = lastS3Provider
            applyPreset(lastS3Provider)
        case .webdav:
            provider = .webdav
            endpoint = "https://"
            host = ""
            portString = ""
            basePath = ""
            useTLS = false
            privateKeyPath = nil
            region = ""
            pathStyle = false
            if provider == .cloudflareR2 { accountID = "" }
        case .ftp:
            provider = .ftp
            endpoint = ""
            host = ""
            portString = ""
            basePath = ""
            useTLS = false
            privateKeyPath = nil
            region = ""
            pathStyle = false
            if provider == .cloudflareR2 { accountID = "" }
        case .sftp:
            provider = .sftp
            endpoint = ""
            host = ""
            portString = ""
            basePath = ""
            useTLS = false
            privateKeyPath = nil
            region = ""
            pathStyle = false
            if provider == .cloudflareR2 { accountID = "" }
        }
    }

    private func choosePrivateKey() {
        let panel = NSOpenPanel()
        panel.title = "Select SSH Private Key"
        panel.allowedContentTypes = [.data]  // not restrictive; keys vary
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            if response == .OK, let url = panel.url {
                privateKeyPath = url.path
            }
        }
    }

    // MARK: - Draft helpers

    private func draftProfile() -> ConnectionProfile {
        ConnectionProfile(
            id: profileID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: effectiveProvider,
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            region: (protocolGroup == .s3 && provider == .cloudflareR2)
                ? "auto"
                : region.trimmingCharacters(in: .whitespacesAndNewlines),
            accountID: accountID.trimmingCharacters(in: .whitespacesAndNewlines),
            pathStyle: (protocolGroup == .s3 && provider == .cloudflareR2) ? true : pathStyle,
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: portValue,
            basePath: basePath.trimmingCharacters(in: .whitespacesAndNewlines),
            useTLS: useTLS,
            privateKeyPath: privateKeyPath
        )
    }

    private func draftCredentials() -> S3Credentials {
        let token = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return S3Credentials(
            accessKeyID: username.trimmingCharacters(in: .whitespacesAndNewlines),
            secretAccessKey: password,
            sessionToken: token.isEmpty ? nil : token
        )
    }

    // MARK: - Validation

    private func validate() -> [String: String] {
        var result: [String: String] = [:]

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result["name"] = "Required"
        }

        switch protocolGroup {
        case .s3:
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

        case .webdav:
            if endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result["endpoint"] = "Required"
            }

        case .ftp, .sftp:
            if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result["host"] = "Required"
            }
        }

        // Username required for all
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result["access"] = "Required"
        }

        // Password required for WebDAV/FTP always; SFTP only if no private key
        switch protocolGroup {
        case .webdav, .ftp:
            if password.isEmpty {
                result["secret"] = "Required"
            }
        case .sftp:
            if password.isEmpty && privateKeyPath == nil {
                result["secret"] = "Required"
            }
        case .s3:
            if password.isEmpty {
                result["secret"] = "Required"
            }
        }

        return result
    }

    // MARK: - Save / Test

    private func save() {
        let validation = validate()
        errors = validation
        saveError = nil
        guard validation.isEmpty else { return }
        do {
            try onSave(draftProfile(), draftCredentials())
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
        let creds = draftCredentials()
        testTask = Task {
            do {
                switch protocolGroup {
                case .s3:
                    let client = try S3Client(profile: profile, credentials: creds)
                    let buckets = try await client.listBuckets()
                    guard !Task.isCancelled else { return }
                    testState = .success("Connected — \(buckets.count) bucket\(buckets.count == 1 ? "" : "s") found")

                case .webdav:
                    let backend = try WebDAVBackend(profile: profile, credentials: creds)
                    _ = try await backend.list(prefix: "", maxKeys: 1)
                    guard !Task.isCancelled else { return }
                    testState = .success("Connected — WebDAV listing succeeded")

                case .ftp:
                    let backend = FTPBackend(profile: profile, credentials: creds)
                    _ = try await backend.list(prefix: "", maxKeys: 1)
                    guard !Task.isCancelled else { return }
                    testState = .success("Connected — FTP listing succeeded")

                case .sftp:
                    let backend = SFTPBackend(profile: profile, credentials: creds)
                    _ = try await backend.list(prefix: "", maxKeys: 1)
                    guard !Task.isCancelled else { return }
                    testState = .success("Connected — SFTP listing succeeded")
                }
            } catch is CancellationError {
                testState = .idle
            } catch {
                guard !Task.isCancelled else { return }
                testState = .failure((error as? S3Error)?.alertMessage ?? error.localizedDescription)
            }
        }
    }
}

// MARK: - Reusable subviews

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