import Foundation

/// Remembers a menu-bar redraw that could not be performed yet.
///
/// Redraws are suppressed while a popover is open, because mutating the
/// status-item button dismisses a transient NSPopover. Suppressing is correct;
/// forgetting is not. Without this, an edit made in the dropdown was simply lost
/// and the menu bar stayed stale until the next refresh tick - up to five
/// minutes when the market is closed and the poll interval stretches out.
///
/// Any number of suppressed redraws collapse into a single one, because
/// redrawing is idempotent: it renders whatever the current state is.
struct DeferredRedraw {
    private(set) var isPending = false

    mutating func request() {
        isPending = true
    }

    /// Hands back whether a redraw is owed, and clears it.
    mutating func take() -> Bool {
        defer { isPending = false }
        return isPending
    }
}
