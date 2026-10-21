import SwiftUI
import S3SilKit

struct BucketACLSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let target: BucketActionTarget

    @State private var acl: BucketACL?
    @State private var isLoading = true
    @State private var unavailableReason: String?
    @State private var loadErrorMessage: String?
    @State private var applyErrorMessage: String?
    @State private var applyNotice: String?
    @State private var applyBlockedReason: String?
    @State private var selectedACL: CannedACL = .privateAccess
    @State private var isApplying = false

    private var capability: BucketACLCapability {
        target.profile.provider.bucketACLCapability
    }

    private var isEditable: Bool {
        capability == .editable
    }

    private var gatedReason: String? {
        switch capability {
        case .editable: return nil
        case .readOnly(let reason), .unsupported(let reason): return reason
        }
    }

    private var unavailableTitle: String {
        switch capability {
        case .readOnly:
            return "Bucket ACLs are not enforceable on \(target.profile.provider.displayName)"
        case .unsupported:
            return "Bucket ACLs are not supported by \(target.profile.provider.displayName)"
        case .editable:
            return "ACL not available for this role or bucket"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isLoading {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Loading bucket ACL…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                    } else if let unavailableReason {
                        unavailableState(unavailableReason)
                    } else if let loadErrorMessage {
                        errorState(loadErrorMessage)
                    } else if let acl {
                        ownerSection(acl)
                        grantsSection(acl)
                        if let applyBlockedReason {
                            Divider()
                            Label(applyBlockedReason, systemImage: "lock.slash")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if isEditable {
                            Divider()
                            cannedACLSection
                            if let applyNotice {
                                Label(applyNotice, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let applyErrorMessage {
                                Label(applyErrorMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        if isEditable, applyBlockedReason == nil {
                            Text("Object ACLs and grant-by-grant editing are not supported. Applying a canned ACL replaces the bucket's existing grants.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 560)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ProviderBadge(provider: target.profile.provider, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bucket Access Control")
                    .font(.headline)
                Text(target.bucket)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if isEditable, applyBlockedReason == nil {
                Button {
                    apply()
                } label: {
                    if isApplying {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Apply Canned ACL")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var canApply: Bool {
        acl != nil && !isLoading && !isApplying && unavailableReason == nil
            && loadErrorMessage == nil && applyBlockedReason == nil
    }

    private func ownerSection(_ acl: BucketACL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Owner")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(acl.ownerDisplayName ?? (acl.ownerID.isEmpty ? "Unknown owner" : acl.ownerID))
                        .font(.callout.weight(.medium))
                    if acl.ownerDisplayName != nil, !acl.ownerID.isEmpty {
                        Text(acl.ownerID)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func grantsSection(_ acl: BucketACL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Grants (\(acl.grants.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if acl.grants.isEmpty {
                Text("The server returned no grants.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(acl.grants.enumerated()), id: \.offset) { index, grant in
                        grantRow(grant)
                        if index < acl.grants.count - 1 {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func grantRow(_ grant: BucketACL.Grant) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: grantIcon(grant.granteeType))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(grantName(grant))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(grant.granteeType.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let uri = grant.uri {
                    Text(uri)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(grant.permission.replacingOccurrences(of: "_", with: " "))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var cannedACLSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Canned ACL")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Canned ACL", selection: $selectedACL) {
                ForEach(CannedACL.allCases) { acl in
                    Text("\(acl.displayName) — \(acl.rawValue)").tag(acl)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)

            Label(
                "Applying a canned ACL replaces all existing grants on this bucket.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func unavailableState(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(unavailableTitle, systemImage: "lock.slash")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isEditable {
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Couldn’t Load ACL", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button("Retry") { Task { await load() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    private func grantIcon(_ type: BucketACL.GranteeType) -> String {
        switch type {
        case .canonicalUser: return "person.crop.circle"
        case .group: return "person.2.circle"
        case .amazonCustomerByEmail: return "envelope.circle"
        case .unknown: return "questionmark.circle"
        }
    }

    private func grantName(_ grant: BucketACL.Grant) -> String {
        grant.displayName ?? grant.granteeID ?? grant.uri ?? "Unknown grantee"
    }

    private func load() async {
        isLoading = true
        applyErrorMessage = nil
        applyNotice = nil
        if let gatedReason {
            acl = nil
            unavailableReason = gatedReason
            loadErrorMessage = nil
            isLoading = false
            return
        }
        do {
            let client = try app.client(for: target.profile)
            acl = try await client.getBucketACL(target.bucket)
            unavailableReason = nil
            loadErrorMessage = nil
        } catch let error as S3Error {
            acl = nil
            if let reason = error.aclUnavailableReason {
                unavailableReason = reason
                loadErrorMessage = nil
            } else {
                unavailableReason = nil
                loadErrorMessage = error.alertMessage
            }
        } catch {
            acl = nil
            unavailableReason = nil
            loadErrorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func apply() {
        guard canApply else { return }
        isApplying = true
        applyErrorMessage = nil
        applyNotice = nil
        let before = acl
        Task {
            var putAccepted = false
            do {
                let client = try app.client(for: target.profile)
                try await client.putBucketACL(target.bucket, cannedACL: selectedACL)
                putAccepted = true
                // A provider may accept the write and change nothing, so verify by re-reading.
                let updated = try await client.getBucketACL(target.bucket)
                acl = updated
                unavailableReason = nil
                if grantsUnchanged(before, updated) {
                    applyNotice = "The server accepted the canned ACL, but the re-fetched grants are unchanged. " +
                        "This endpoint may not enforce canned ACLs; do not rely on this result."
                } else {
                    app.showToast("Applied \(selectedACL.displayName) ACL")
                }
            } catch let error as S3Error {
                if putAccepted {
                    applyErrorMessage = "The ACL request was accepted, but the updated ACL could not be verified. "
                        + error.alertMessage
                } else if let reason = error.aclUnavailableReason {
                    applyBlockedReason = reason
                } else {
                    applyErrorMessage = error.alertMessage
                }
            } catch {
                if putAccepted {
                    applyErrorMessage = "The ACL request was accepted, but the updated ACL could not be verified. "
                        + error.localizedDescription
                } else {
                    applyErrorMessage = error.localizedDescription
                }
            }
            isApplying = false
        }
    }

    private func grantsUnchanged(_ before: BucketACL?, _ after: BucketACL) -> Bool {
        guard let before else { return false }
        return before.ownerID == after.ownerID
            && before.ownerDisplayName == after.ownerDisplayName
            && before.grants == after.grants
    }
}
