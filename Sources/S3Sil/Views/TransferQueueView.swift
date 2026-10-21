import SwiftUI
import S3SilKit

struct TransferQueueView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var transfers = app.transfers
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.arrow.down.circle.fill")
                    .foregroundStyle(.tint)
                Text("Transfers")
                    .font(.headline)
                Text(transfers.statusSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ProgressView(value: transfers.aggregateProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 140)
                    .opacity(transfers.activeCount > 0 ? 1 : 0.35)

                Spacer()

                if transfers.canClearFinished {
                    Button("Clear Finished") { transfers.clearFinished() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                Button {
                    transfers.isExpanded.toggle()
                } label: {
                    Image(systemName: transfers.isExpanded ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
                .help(transfers.isExpanded ? "Collapse transfers" : "Expand transfers")

                Button {
                    transfers.isPanelVisible = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Hide transfers")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if transfers.isExpanded {
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(transfers.items) { item in
                            TransferRow(item: item)
                            if item.id != transfers.items.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.6))
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .frame(maxWidth: 900)
    }
}

private struct TransferRow: View {
    @Environment(AppState.self) private var app
    let item: TransferManager.Item

    private var progressColor: Color {
        switch item.status {
        case .failed: return .red
        case .completed: return .green
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }

    private var revealURL: URL? {
        item.direction == .download ? item.destinationURL : item.sourceURL
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(item.direction == .upload ? Color.blue : Color.green)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.system(.callout, design: .default).weight(.medium))
                        .lineLimit(1)
                    Text(item.status.rawValue.capitalized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(progressColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(progressColor.opacity(0.12), in: Capsule())
                    if let label = item.multipartLabel {
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }

                if item.status == .failed, let message = item.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(message)
                } else {
                    Text("\(item.bucket) / \(item.key)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack(spacing: 8) {
                    ProgressView(value: min(max(item.progress, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(progressColor)
                    Text(item.totalBytes > 0
                         ? "\(Format.size(item.bytesTransferred)) of \(Format.size(item.totalBytes))"
                         : Format.size(item.bytesTransferred))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 110, alignment: .trailing)
                }
            }

            Group {
                switch item.status {
                case .queued, .running:
                    Button {
                        app.transfers.cancel(item.id)
                    } label: {
                        Image(systemName: "stop.circle")
                    }
                    .help("Cancel transfer")
                case .failed, .cancelled:
                    Button {
                        app.transfers.retry(item.id)
                    } label: {
                        Image(systemName: "arrow.clockwise.circle")
                    }
                    .help("Retry transfer")
                case .completed:
                    if let url = revealURL {
                        Button {
                            FilePanels.reveal(url)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Reveal in Finder")
                    }
                }
                if item.status == .completed || item.status == .failed || item.status == .cancelled {
                    Button {
                        app.transfers.remove(item.id)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .help("Remove from list")
                }
            }
            .buttonStyle(.borderless)
            .font(.body)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
