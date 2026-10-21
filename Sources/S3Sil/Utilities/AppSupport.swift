import AppKit
import SwiftUI
import S3SilKit

struct AppAlert: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

extension Error {
    var appAlert: AppAlert {
        if let error = self as? S3Error {
            return AppAlert(title: error.title, message: error.alertMessage)
        }
        return AppAlert(title: "Something Went Wrong", message: localizedDescription)
    }
}

enum Format {
    static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static func size(_ value: Int64) -> String {
        bytes.string(fromByteCount: value)
    }

    static func modified(_ date: Date?) -> String {
        date.map(dateTime.string(from:)) ?? "—"
    }

    static func created(_ date: Date?) -> String {
        date.map(dateOnly.string(from:)) ?? "Unknown"
    }
}

@MainActor
enum FilePanels {
    static func saveURL(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Download Object"
        panel.prompt = "Download"
        panel.message = "Choose where to save “\(suggestedName)”."
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func directory(prompt: String = "Download Here") -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Download Objects"
        panel.prompt = prompt
        panel.message = "Choose a folder for the downloaded objects."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func uniqueDestination(in directory: URL, name: String) -> URL {
        var candidate = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let filename = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            candidate = directory.appendingPathComponent(filename)
            index += 1
        }
        return candidate
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    static func isRegularFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}

extension ProviderKind {
    var tint: Color {
        switch self {
        case .aws: return .orange
        case .cloudflareR2: return .indigo
        case .hitachi: return .red
        case .minio: return .pink
        case .generic: return .teal
        }
    }
}

struct ProviderBadge: View {
    let provider: ProviderKind
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: provider.symbolName)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(provider.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .help(provider.displayName)
    }
}

struct ToastView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}

struct LoadingOverlay: View {
    var title: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(26)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

enum PresignExpiry: Int, CaseIterable, Identifiable {
    case fifteenMinutes = 900
    case oneHour = 3_600
    case oneDay = 86_400
    case sevenDays = 604_800

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .fifteenMinutes: return "15 Minutes"
        case .oneHour: return "1 Hour"
        case .oneDay: return "24 Hours"
        case .sevenDays: return "7 Days"
        }
    }
}
