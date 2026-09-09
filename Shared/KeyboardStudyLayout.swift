import Foundation

/// The compact input keyboard keeps its established geometry. Learning uses
/// screen dimensions, never the keyboard window's own changing height.
enum KeyboardStudyLayout {
    struct Viewport: Equatable {
        let width: Double
        let screenHeight: Double
        let landscape: Bool
        let isPad: Bool

        var compactKeys: Bool { !isPad && landscape }

        func normalHeight(nineKey: Bool) -> Double {
            if isPad && width >= 600 { return 314 }
            return nineKey ? (compactKeys ? 211 : 268) : (compactKeys ? 214 : 263)
        }
    }

    /// Screen dimensions are independent of the extension's requested height.
    /// A wide iPad portrait keyboard must never imply phone landscape geometry.
    static func viewport(width: Double, screenWidth: Double?, screenHeight: Double?,
                         landscape: Bool?, isPad: Bool) -> Viewport {
        let width = width.isFinite && width > 0 ? width : 393
        let fallback = isPad ? (810.0, 1080.0) : (393.0, 852.0)
        let validScreen = screenWidth.map { $0.isFinite && $0 > 0 } == true
            && screenHeight.map { $0.isFinite && $0 > 0 } == true
        let short = validScreen ? min(screenWidth!, screenHeight!) : fallback.0
        let long = validScreen ? max(screenWidth!, screenHeight!) : fallback.1
        // A detached controller has no scene orientation yet. Keep the previous
        // phone fallback, while iPad waits for its actual scene orientation.
        let landscape = landscape ?? (!isPad && width > 600)
        return Viewport(width: width, screenHeight: landscape ? short : long,
                        landscape: landscape, isPad: isPad)
    }

    static func contentHeight(normal: Double, expanded: Bool,
                              screenHeight: Double, landscape: Bool,
                              bottomInset: Double, isPad: Bool = false,
                              keyboardWidth: Double = 0) -> Double {
        guard expanded, screenHeight.isFinite, screenHeight > 0 else { return normal }
        let inset = bottomInset.isFinite ? max(0, bottomInset) : 0
        if isPad {
            // Full-sized tablet learning uses roughly half the screen in either
            // orientation. Narrow/floating keyboards keep a smaller scrollable
            // viewport; host-negotiated height can be smaller still.
            let ceiling = keyboardWidth >= 500 ? 560.0 : 360.0
            let totalBudget = min(floor(screenHeight * 0.50), floor(screenHeight - 280))
            return max(normal, min(ceiling, totalBudget - inset))
        }
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
