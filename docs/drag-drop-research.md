# Drag-out download from SwiftUI Table — research

Environment verified: macOS 27.0.1 (build 26A434), Swift 6.4 (swiftlang-6.4.0.34.1), Xcode 27.1.
Evidence tags: **[V]** = verified locally (SDK swiftinterface, prototype run), **[D]** = Apple docs, **[I]** = inferred.

## 1. Does `.onDrag` deliver all selected rows?

**No — it cannot, by API shape.** [V] Verified in the macOS 27 SDK swiftinterface
(`SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface`):

- Line 32470: `func onDrag(_ data: @escaping () -> NSItemProvider) -> some View` — the closure returns
  **one** `NSItemProvider` (the second overload, line 32477, only adds a `preview`). One gesture ⇒ one
  provider ⇒ one drag item. Multi-file drag = multiple drag items; not expressible.
- Line 4546: Table rows have their own single-provider variant,
  `TableRowContent.itemProvider(_ action: (() -> NSItemProvider?)?)` — same one-item shape.
- Line 32509: `onDragSessionUpdated(_ onUpdate: (DragSession) -> Void)` exists (session awareness only).

Prototype (/tmp/ddproto, SwiftUI Table 20 rows + `Set<Int>` selection, CGEvent synthetic mouse):
selection via shift/⌘-click worked (logged `[0,1,2]`); a drag from a selected row started a session
(Table auto-scrolled through all 20 rows mid-drag), but synthetic drags never complete AppKit's drag
loop, so end-to-end Finder delivery had to be judged from the API signature above **[V]** plus docs **[D]**.
One `NSItemProvider` = one dragged item is documented behavior of pasteboard drag items **[D]**.

Docs: https://developer.apple.com/documentation/swiftui/view/ondrag(_:)

## 2. `registerFileRepresentation` vs `NSFilePromiseProvider`

- Both produce real Finder file promises. `NSItemProvider.registerFileRepresentation(...)` gives a
  lazily-invoked load handler: Finder shows a placeholder file until the handler writes the file and
  calls the completion. `NSFilePromiseProvider` is the AppKit-native promise: Finder asks the delegate
  for a filename, then `writePromiseTo(url:completionHandler:)`. https://developer.apple.com/documentation/appkit/supporting-drag-and-drop-through-file-promises **[D]**
- Multiple files in one drag: `NSFilePromiseProvider` — yes, put one provider per file in the
  pasteboard's `NSDraggingItem`s / `beginDraggingSession(with:)` items. `NSItemProvider` — a single
  provider carries multiple *representations* (same payload in several UTTypes), **not** multiple
  independent files; each dragged item is one file at the destination **[D/I]**.
- Filename at the destination: `NSFilePromiseProvider` → Finder uses exactly
  `filePromiseProvider(_:fileNameForType:)` — full control, no surprises.
  https://developer.apple.com/documentation/appkit/nsfilepromiseproviderdelegate/filepromiseprovider(_:filenamefortype:) **[D]**
  `NSItemProvider` → destination uses `suggestedName` (+ extension derived from the representation
  type) **[I]**; if `suggestedName` is unset you get the load-handler temp URL's UUID-ish name **[I]**.
- Temp lifetime: for `registerFileRepresentation`, the system copies your file; you may delete yours
  after the handler returns; the system copy lives until the receiver consumes it / drag ends **[D]**.
  For `NSFilePromiseProvider`, the delegate writes directly to the Finder-supplied destination URL;
  any app-side temp staging is yours to clean in the completion handler **[D]**.

## 3. Smallest AppKit bridge when multi-drag is needed

Keep the SwiftUI Table for display/selection. Add one `NSViewRepresentable` overlay view covering the
table:

- Overlay's `hitTest(_:)` returns `nil` normally → clicks/selecting pass through to the Table
  untouched. A local `NSEvent` monitor (`addLocalMonitorForEvents`) observes `mouseDown` + movement;
  once the drag threshold (~4–6 px) is crossed while `selection.count > 0`, call
  `beginDraggingSession(with:pasteboardWriterItems:event:)` on the overlay with **N**
  `NSFilePromiseProvider`s (N = selected rows). [I] — standard pattern; not exercised end-to-end here.
- You do **not** need to locate the backing `NSTableView` or row rects: the overlay only initiates a
  session; the drag image can be a rendered snapshot of the selection text, not per-row rects.
  Avoid introspecting SwiftUI's private NSTableView — it is not public API and breaks silently. [I]
- Pitfalls: (a) don't start a session on plain `mouseDown` or clicks die — threshold first; (b) if
  selection is empty, do nothing and let events pass; (c) AppKit's drag loop takes over the event
  stream once begun, ending SwiftUI's internal tracking — that is desired; (d) `mouseDownCanMoveWindow`
  must be `false` on the overlay; (e) update selection state via a shared binding, never by reading
  SwiftUI internals mid-gesture. [I]

## 4. `NSFilePromiseProviderDelegate` requirements

- Required: `filePromiseProvider(_:fileNameForType:)` (destination filename) and
  `filePromiseProvider(_:writePromiseTo:completionHandler:)` (write the bytes to `url`, then call the
  completion with `nil`, or with an `NSError` on failure — always call it).
  https://developer.apple.com/documentation/appkit/nsfilepromiseproviderdelegate **[D]**
- Threading: `writePromiseTo` is invoked off-main; the download/write should run on a background
  queue and the completion handler is safe to call from that queue **[D]**.
- Multiple promises per session: one delegate call pair per provider; order is not guaranteed — treat
  each provider as independent (identify the file via the provider instance, e.g. a dictionary
  `[NSFilePromiseProvider: TransferTask]`) **[I]**.
- Cancellation: the delegate has no "receiver cancelled" callback. If the in-app transfer fails or the
  user cancels it, call the completion with an error; clean staging files in the completion **[I]**.
- Progress: Finder shows its own placeholder/progress for promises; your app can surface progress by
  wrapping the transfer in a `Progress` and updating your own transfer-queue UI — nothing in the
  delegate API feeds progress *to* Finder **[D/I]**.

## 5. Sandbox / entitlements / Info.plist

- Dragging out to Finder needs **no** sandbox entitlement, no `NSAppleEventsUsageDescription`, no
  Info.plist keys. A non-sandboxed, ad-hoc-signed app can start drag sessions and write into
  Finder-supplied destination URLs (Finder performs the write coordination). The app only touches its
  own temp/staging files **[I]** — consistent with the file-promise contract where the *destination*
  app writes via Finder mediation **[D]**. For a sandboxed app the same flow works (temp files inside
  the container; promise write mediated by Finder) **[I]**.
- Downloading from an HTTP(S) server needs no entitlement; ATS applies as usual (not drag-specific).

## 6. Recommendation (smallest correct implementation)

Keep the existing SwiftUI Table. Add:

1. **Multi-drag overlay** (`NSViewRepresentable`, ~120 lines total): hit-test-transparent; local event
   monitor arms on `mouseDown` inside the table frame; on threshold-cross with `selection.count > 0`,
   `beginDraggingSession` with one `NSFilePromiseProvider` per selected row, drag image = selection
   snapshot; `NSDraggingSource` = `.copyOnly`.
2. **Promise delegate**: `fileNameForType` = S3 object key's last path component (already unique per
   row; dedupe with `name-2.ext` if needed); `writePromiseTo` kicks off/awaits the existing MinIO
   download, streams to the destination URL, calls the completion (error on failure), cleans staging.
3. **Progress**: existing transfer queue UI keyed by the provider↔task dictionary; no Finder progress.

Why not `.onDrag` + `registerFileRepresentation`: one provider per gesture caps you at one file per
drag **[V]**; `suggestedName`-based naming is less deterministic **[I]**. Keep `.onDrag` if single-file
drag-out is ever needed for another surface.

## Prototype locations (throwaway)

- `/tmp/ddproto` — SwiftUI Table/List/plain-`Text` probe with `.onDrag`, selection logging to
  `/tmp/ddproto-log.txt`; `/tmp/drag3.swift` → `/tmp/cgevent`-`/tmp/drag3` CGEvent drivers;
  `/tmp/hit2.swift` AX hit-test tool. Safe to delete.
