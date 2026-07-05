import AppKit

/// Seam for the "Reveal in Finder" file action (ACT-001, PRD FR7). The largest-files
/// section depends on this abstraction rather than `NSWorkspace` directly so the row's
/// button wiring is unit-testable without actually activating Finder, and so ACT-002's
/// "Move to Trash" action can join the same seam without reshaping the view.
///
/// The one production conformance calls `NSWorkspace.shared.activateFileViewerSelecting`
/// with the exact file URL — a percent-decoded `file:` URL, so paths with spaces and
/// unicode survive intact (PRD FR7). Paths are never logged (TECHSPEC §7).
protocol FinderRevealing {
    /// Opens Finder with the file at `url` selected in its containing folder.
    func reveal(_ url: URL)
}

/// Production `FinderRevealing`: reveals the file via `NSWorkspace`. Selecting a single
/// URL opens (or brings forward) the enclosing Finder window with just that file
/// highlighted — the standard "Reveal in Finder" behavior.
struct WorkspaceFinderRevealer: FinderRevealing {
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Seam for the "Move to Trash" file action (ACT-002, PRD FR8, TECHSPEC §7). The
/// largest-files section drives this through the view model rather than touching
/// `FileManager` directly, so the confirm-state machine (activate → confirm → trashed,
/// or activate → cancel) is unit-testable without ever moving a real file — no test
/// touches the filesystem (the SCAN-001/003 "no real Spotlight in tests" discipline
/// extended to destructive actions).
///
/// **Recoverable only.** The one production conformance calls
/// `FileManager.trashItem(at:resultingItemURL:)` — the file lands in the macOS Trash
/// and is restorable. There is deliberately no `removeItem`/permanent-delete path
/// anywhere in the app (TECHSPEC §7): the protocol's single method is *move to trash*,
/// so no conformance — production or test — can express a permanent delete.
protocol FileTrashing {
    /// Moves the file at `url` to the macOS Trash. Throws on failure (locked file,
    /// permission denied, missing file) so the caller can surface the error inline
    /// without crashing; never deletes permanently.
    func trash(_ url: URL) throws
}

/// Production `FileTrashing`: moves the file to the Trash via `FileManager`.
///
/// Uses `trashItem(at:resultingItemURL:)` exclusively — the recoverable path. The
/// `resultingItemURL` out-parameter (the file's new location inside the Trash) is not
/// needed by any caller, so it is discarded; the call still moves the item rather than
/// deleting it. A throw here (locked/permission/missing) propagates to the view model,
/// which shows an inline error on the row (never a crash, never a silent failure).
struct FileManagerFileTrasher: FileTrashing {
    func trash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
