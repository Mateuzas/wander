import SwiftUI

// Layout constants from PLAN.md §10: 16 pt margins, 8 pt grid, 44 pt touch targets.
enum Layout {
    /// One step of the 8 pt spacing grid.
    static let grid: CGFloat = 8
    /// Screen and sheet side margins.
    static let margin: CGFloat = 16
    /// Minimum touch target edge.
    static let minTouch: CGFloat = 44
    /// Height of the sheet's peek detent.
    static let peekHeight: CGFloat = 120
    /// Primary button height.
    static let primaryButtonHeight: CGFloat = 52
    /// Bead diameter, normal and selected.
    static let bead: CGFloat = 22
    static let beadSelected: CGFloat = 30
}

extension PresentationDetent {
    /// About 120 pt: search field or plan summary.
    static let peek = PresentationDetent.height(Layout.peekHeight)
}
