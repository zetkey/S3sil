import AppKit
import SwiftUI
import UniformTypeIdentifiers
import S3SilKit

/// SwiftUI's `Table` has no drag-session API. This transparent AppKit overlay
/// sits above the backing `NSTableView` so mouse-downs reach us before the
/// table's private tracking loop, selects rows like the table does, and starts
/// a native multi-item `NSFilePromiseProvider` drag session when the mouse moves.
struct ObjectDragSource: NSViewRepresentable {
    /// File objects to promise for the row the drag started on; empty aborts the drag.
    let fileObjects: (Int) -> [S3Object]
    let startDownload: (S3Object, URL, @escaping @Sendable (Result<Void, Error>) -> Void) -> Void
    /// Update table selection for a click; -1 means the empty area.
    let selectRow: (Int, NSEvent.ModifierFlags) -> Void
    /// Double-click action for a row.
    let activateRow: (Int) -> Void
    /// Select a right-clicked row only when it is not already part of the selection.
    let prepareContextMenu: (Int) -> Void
    /// Finder uploads land on the overlay because it sits above SwiftUI's drop target.
    let upload: ([URL]) -> Void
    let setDropTargeted: (Bool) -> Void

    func makeNSView(context: Context) -> RowDragOverlayView {
        let view = RowDragOverlayView()
        view.fileObjects = fileObjects
        view.startDownload = startDownload
        view.selectRow = selectRow
        view.activateRow = activateRow
        view.prepareContextMenu = prepareContextMenu
        view.upload = upload
        view.setDropTargeted = setDropTargeted
        return view
    }

    func updateNSView(_ nsView: RowDragOverlayView, context: Context) {
        nsView.fileObjects = fileObjects
        nsView.startDownload = startDownload
        nsView.selectRow = selectRow
        nsView.activateRow = activateRow
        nsView.prepareContextMenu = prepareContextMenu
        nsView.upload = upload
        nsView.setDropTargeted = setDropTargeted
    }
}

final class RowDragOverlayView: NSView, NSDraggingSource {
    var fileObjects: ((Int) -> [S3Object])?
    var startDownload: ((S3Object, URL, @escaping @Sendable (Result<Void, Error>) -> Void) -> Void)?
    var selectRow: ((Int, NSEvent.ModifierFlags) -> Void)?
    var activateRow: ((Int) -> Void)?
    var prepareContextMenu: ((Int) -> Void)?
    var upload: (([URL]) -> Void)?
    var setDropTargeted: ((Bool) -> Void)?

    private weak var knownTable: NSTableView?
    private var downEvent: NSEvent?
    private var dragged = false
    private var providers: [NSFilePromiseProvider] = []
    private var delegates: [FilePromiseDelegate] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    private var tableView: NSTableView? {
        if let knownTable, knownTable.window === window { return knownTable }
        guard let contentView = window?.contentView else { return nil }
        knownTable = Self.findTable(in: contentView)
        return knownTable
    }

    private static func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView, table.tableColumns.count >= 2 { return table }
        for child in view.subviews {
            if let table = findTable(in: child) { return table }
        }
        return nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        knownTable = nil
    }

    /// Let clicks in the header (sorting, column resizing) and scrollbars fall through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let table = tableView, let superview else { return nil }
        let own = convert(point, from: superview)
        guard bounds.contains(own) else { return nil }
        if let header = table.headerView {
            let headerRect = convert(header.bounds, from: header)
            if headerRect.contains(own) { return nil }
        }
        if let scrollers = table.enclosingScrollView {
            for scroller in [scrollers.verticalScroller, scrollers.horizontalScroller] {
                guard let scroller, !scroller.isHidden else { continue }
                if convert(scroller.bounds, from: scroller).contains(own) { return nil }
            }
        }
        return self
    }

    private func row(at event: NSEvent) -> Int {
        guard let table = tableView else { return -1 }
        return table.row(at: table.convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, !dragged, let table = tableView, event.window === window else { return }
        let distance = hypot(
            event.locationInWindow.x - down.locationInWindow.x,
            event.locationInWindow.y - down.locationInWindow.y
        )
        guard distance >= 4 else { return }

        let row = table.row(at: table.convert(down.locationInWindow, from: nil))
        guard row >= 0, let objects = fileObjects?(row), !objects.isEmpty else { return }
        dragged = true
        beginDrag(table: table, event: down, objects: objects)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged {
            let row = row(at: event)
            selectRow?(row, event.modifierFlags)
            if row >= 0, event.clickCount == 2 {
                activateRow?(row)
            }
        }
        downEvent = nil
        dragged = false
    }

    override func rightMouseDown(with event: NSEvent) {
        let row = row(at: event)
        if row >= 0 {
            prepareContextMenu?(row)
        }
        tableView?.rightMouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if let scroller = tableView?.enclosingScrollView {
            scroller.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: - NSDraggingDestination (Finder uploads)

    private func draggedFiles(_ sender: NSDraggingInfo) -> [URL]? {
        guard sender.draggingSource == nil else { return nil }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options
        ) as? [URL] else { return nil }
        let files = urls.filter(FilePanels.isRegularFile)
        return files.isEmpty ? nil : files
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedFiles(sender) != nil else { return [] }
        setDropTargeted?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedFiles(sender) == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDropTargeted?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDropTargeted?(false)
        guard let files = draggedFiles(sender) else { return false }
        upload?(files)
        return true
    }

    private func beginDrag(table: NSTableView, event: NSEvent, objects: [S3Object]) {
        let point = table.convert(event.locationInWindow, from: nil)
        var items: [NSDraggingItem] = []
        providers.removeAll()
        delegates.removeAll()

        for (index, object) in objects.enumerated() {
            let name = DragExport.safeFileName(object.name)
            let fileType = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
            let delegate = FilePromiseDelegate(
                fileName: name,
                object: object,
                startDownload: startDownload ?? { _, _, completion in
                    completion(.failure(S3Error.validation("The download is unavailable.")))
                }
            ) { [weak self] finished in
                self?.delegates.removeAll { $0 === finished }
            }
            let provider = NSFilePromiseProvider(fileType: fileType.identifier, delegate: delegate)
            let item = NSDraggingItem(pasteboardWriter: provider)
            let icon = NSWorkspace.shared.icon(for: fileType)
            icon.size = NSSize(width: 32, height: 32)
            let offset = CGFloat(index) * 8
            item.setDraggingFrame(
                NSRect(x: point.x + offset, y: point.y + offset, width: 32, height: 32),
                contents: icon
            )
            items.append(item)
            providers.append(provider)
            delegates.append(delegate)
        }

        let session = table.beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        downEvent = nil
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        providers.removeAll()
        // Finder may request promises after the drop; keep live writers until
        // their completion, and drop unused delegates after a grace period.
        let pending = delegates.filter { !$0.didStart }
        delegates.removeAll { !$0.didStart }
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            _ = pending
        }
    }
}

/// One promise per file. Kept alive by the overlay until Finder is done.
private final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let fileName: String
    private let object: S3Object
    private let startDownload: (S3Object, URL, @escaping @Sendable (Result<Void, Error>) -> Void) -> Void
    private let onFinished: (FilePromiseDelegate) -> Void
    private let once = PromiseOnce()
    private(set) var didStart = false

    init(fileName: String, object: S3Object,
         startDownload: @escaping (S3Object, URL, @escaping @Sendable (Result<Void, Error>) -> Void) -> Void,
         onFinished: @escaping (FilePromiseDelegate) -> Void) {
        self.fileName = fileName
        self.object = object
        self.startDownload = startDownload
        self.onFinished = onFinished
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        fileName
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        DispatchQueue.main.async {
            guard self.once.claim() else { return }
            self.didStart = true
            self.startDownload(self.object, url) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        completionHandler(nil)
                    case .failure(let error):
                        completionHandler(error)
                    }
                    self.onFinished(self)
                }
            }
        }
    }
}

private final class PromiseOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
