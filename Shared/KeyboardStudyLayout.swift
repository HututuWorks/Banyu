import Foundation

/// The compact input keyboard keeps its established geometry. Learning uses
/// screen dimensions, never the keyboard window's own changing height.
enum KeyboardStudyLayout {
    static func contentHeight(normal: Double, expanded: Bool,
                              screenHeight: Double, landscape: Bool,
                              bottomInset: Double) -> Double {
        guard expanded, screenHeight.isFinite, screenHeight > 0 else { return normal }
        let inset = bottomInset.isFinite ? max(0, bottomInset) : 0
        if landscape {
            return max(normal, min(300, floor(screenHeight * 0.68 - inset)))
        }
        // The host can accept a tall input view even when its own composer then
        // collides with its navigation bar. Acceptance is not a usable-height
        // signal. The user chose a half-screen reading area. Separately
        // reserve room for host chrome, a multiline composer and iOS's keyboard
        // utility strip (which is outside this controller on current iPhones).
        let totalBudget = min(floor(screenHeight * 0.50), floor(screenHeight - 340))
        return max(normal, min(520, totalBudget - inset))
    }
}
