import Foundation

private struct StudyLayoutTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct KeyboardStudyLayoutTests {
    static func main() throws {
        try compactGeometryRemainsExact()
        try expansionAndCaps()
        try smallAndUnavailableScreens()
        try insetsAreCountedOnce()
        try repeatedLayoutIsStable()
        try tabletViewports()
        print("PASS: study height — compact geometry, half-screen portrait request with host and system strip reserve, landscape unchanged, small-screen fallback, single safe-area accounting and stable repeated calculations; pure geometry only, not device height negotiation")
    }

    private static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw StudyLayoutTestFailure(description: message) }
    }

    private static func compactGeometryRemainsExact() throws {
        // normal is the existing Controller-provided content height; safe area
        // belongs to the outer keyboard and must not change these key geometries.
        for (normal, landscape) in [(263.0, false), (268.0, false), (214.0, true), (211.0, true)] {
            for bottomInset in [0.0, 21.0, 34.0, 75.0] {
                let actual = KeyboardStudyLayout.contentHeight(normal: normal, expanded: false,
                    screenHeight: landscape ? 393 : 852, landscape: landscape, bottomInset: bottomInset)
                try expect(actual == normal, "Collapsed content must retain exact \(normal) pt geometry")
            }
        }
        print("PASS: collapsed 263/268 pt portrait and 214/211 pt landscape content stays exact")
    }

    private static func expansionAndCaps() throws {
        for normal in [263.0, 268.0] {
            let actual = KeyboardStudyLayout.contentHeight(normal: normal, expanded: true,
                screenHeight: 852, landscape: false, bottomInset: 34)
            try expect(actual == 392, "852 pt portrait requests half-screen 426 pt total, with 34 pt bottom inset counted once")
            try expect(actual + 34 < 698, "Reject the excessive 698 pt request that overlapped host navigation")
        }
        let portraitCap = KeyboardStudyLayout.contentHeight(normal: 263, expanded: true,
            screenHeight: 1_366, landscape: false, bottomInset: 34)
        try expect(portraitCap == 520, "Large portrait screen must stop at 520 pt content")
        let landscapeCap = KeyboardStudyLayout.contentHeight(normal: 214, expanded: true,
            screenHeight: 768, landscape: true, bottomInset: 21)
        try expect(landscapeCap == 300, "Large landscape screen must stop at 300 pt content")
        let phoneLandscape = KeyboardStudyLayout.contentHeight(normal: 214, expanded: true,
            screenHeight: 393, landscape: true, bottomInset: 21)
        try expect(phoneLandscape > 214 && phoneLandscape <= 300,
                   "Phone landscape should expand without applying portrait's 520 pt ceiling")
        let smallPhone = KeyboardStudyLayout.contentHeight(normal: 263, expanded: true,
            screenHeight: 568, landscape: false, bottomInset: 0)
        try expect(smallPhone == 263, "Small portrait phone falls back to normal height instead of squeezing host controls")
        for screen in [667.0, 812, 852, 896, 932, 956, 1024, 1366] {
            let requested = KeyboardStudyLayout.contentHeight(normal: 263, expanded: true,
                screenHeight: screen, landscape: false, bottomInset: 34) + 34
            try expect(requested <= screen - 340 && requested <= 554 && requested <= floor(screen * 0.5),
                       "Portrait study request must leave host chrome, multiline composer and external system strip space")
        }
        print("PASS: portrait 426 pt total on 852 pt screen, 520 pt content ceiling and 340 pt combined reserve; landscape unchanged")
    }

    private static func smallAndUnavailableScreens() throws {
        for normal in [263.0, 268.0] {
            let actual = KeyboardStudyLayout.contentHeight(normal: normal, expanded: true,
                screenHeight: 320, landscape: false, bottomInset: 34)
            try expect(actual == normal, "A small screen must not shrink content below its normal key geometry")
        }
        let smallLandscape = KeyboardStudyLayout.contentHeight(normal: 211, expanded: true,
            screenHeight: 280, landscape: true, bottomInset: 21)
        try expect(smallLandscape == 211, "Small landscape must retain its normal height")
        for height in [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity] {
            let actual = KeyboardStudyLayout.contentHeight(normal: 263, expanded: true,
                screenHeight: height, landscape: false, bottomInset: 34)
            try expect(actual == 263, "Unavailable or invalid screen dimensions must fall back to normal height")
        }
        print("PASS: small, unavailable and non-finite screen sizes safely retain normal content height")
    }

    private static func insetsAreCountedOnce() throws {
        let noInset = KeyboardStudyLayout.contentHeight(normal: 263, expanded: true,
            screenHeight: 852, landscape: false, bottomInset: 0)
        let withInset = KeyboardStudyLayout.contentHeight(normal: 263, expanded: true,
            screenHeight: 852, landscape: false, bottomInset: 34)
        try expect(withInset + 34 == noInset,
                   "Adding the outer keyboard safe area once must restore the intended screen budget")
        let negativeInset = KeyboardStudyLayout.contentHeight(normal: 263, expanded: true,
            screenHeight: 852, landscape: false, bottomInset: -34)
        try expect(negativeInset == noInset, "Negative insets must not enlarge the screen budget")
        let collapsedContent = KeyboardStudyLayout.contentHeight(normal: 263, expanded: false,
            screenHeight: 852, landscape: false, bottomInset: 34)
        try expect(collapsedContent + 34 == 297, "Collapsed root height adds safe area exactly once outside the helper")
        print("PASS: expanded screen budget subtracts one bottom inset; collapsed content does not include it")
    }

    private static func repeatedLayoutIsStable() throws {
        let physicalScreenHeight = 852.0
        var rootKeyboardHeight = 263.0 + 34
        var expandedContentHeights: [Double] = []
        for expanded in [true, true, true, false, true, false, true, true] {
            let content = KeyboardStudyLayout.contentHeight(normal: 263, expanded: expanded,
                screenHeight: physicalScreenHeight, landscape: false, bottomInset: 34)
            rootKeyboardHeight = content + 34
            if expanded { expandedContentHeights.append(content) }
            try expect(rootKeyboardHeight <= 426 && rootKeyboardHeight >= 297,
                       "Repeated layout must remain within normal and expanded bounds")
        }
        try expect(Set(expandedContentHeights).count == 1,
                   "Re-layout and collapse/reopen must not feed the changing keyboard height back into screen size")
        print("PASS: repeated layout and collapse/reopen return the same screen-based expanded height without growth or shrink loops")
    }

    private static func tabletViewports() throws {
        for (width, landscape, screenHeight) in [(810.0, false, 1080.0), (1080.0, true, 810.0)] {
            let viewport = KeyboardStudyLayout.viewport(width: width, screenWidth: 810,
                screenHeight: 1080, landscape: landscape, isPad: true)
            try expect(!viewport.compactKeys && viewport.normalHeight(nineKey: false) == 314
                && viewport.normalHeight(nineKey: true) == 314,
                "iPad 8 portrait and landscape retain full-height keys, including nine-key")
            try expect(viewport.screenHeight == screenHeight, "iPad screen height follows scene orientation")
            let height = KeyboardStudyLayout.contentHeight(normal: 314, expanded: true,
                screenHeight: viewport.screenHeight, landscape: viewport.landscape,
                bottomInset: 0, isPad: true, keyboardWidth: width)
            try expect(height == floor(screenHeight * 0.5), "Full tablet learning uses half-screen in both orientations")
            try expect(KeyboardStudyLayout.contentHeight(normal: 314, expanded: false,
                screenHeight: viewport.screenHeight, landscape: landscape, bottomInset: 0,
                isPad: true, keyboardWidth: width) == 314, "Collapse restores tablet keys exactly")
        }
        let portrait = KeyboardStudyLayout.viewport(width: 320, screenWidth: 810,
            screenHeight: 1080, landscape: false, isPad: true)
        let landscape = KeyboardStudyLayout.viewport(width: 320, screenWidth: 810,
            screenHeight: 1080, landscape: true, isPad: true)
        try expect(portrait != landscape, "Orientation changes invalidate layout even at an unchanged split-view width")
        for viewport in [portrait, landscape] {
            try expect(!viewport.compactKeys && viewport.normalHeight(nineKey: true) == 268,
                       "Narrow tablet keeps touchable phone-portrait keys")
            let height = KeyboardStudyLayout.contentHeight(normal: 268, expanded: true,
                screenHeight: viewport.screenHeight, landscape: viewport.landscape,
                bottomInset: 20, isPad: true, keyboardWidth: viewport.width)
            try expect(height == 360, "Narrow tablet reading is bounded without squeezing keys")
        }
        let missingScene = KeyboardStudyLayout.viewport(width: 810, screenWidth: nil,
            screenHeight: nil, landscape: nil, isPad: true)
        try expect(!missingScene.landscape && !missingScene.compactKeys,
                   "Detached iPad never mistakes its portrait width for a landscape phone")
        let phone = KeyboardStudyLayout.viewport(width: 852, screenWidth: nil,
            screenHeight: nil, landscape: nil, isPad: false)
        try expect(phone.compactKeys && phone.normalHeight(nineKey: false) == 214,
                   "Detached phone keeps the existing landscape fallback")
        print("PASS: iPad 8 both orientations, half-screen study, split-width rotation, narrow/floating bounds and unchanged phone fallback")
    }
}
