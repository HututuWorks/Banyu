// Real UIKit geometry and interaction checks; no credentials, transport calls,
// audio output or fabricated phone chrome are used by this harness.
import UIKit
import Darwin

private struct SpeechSurfaceFailure: Error { let message: String }

@MainActor
private enum SpeechSurfaceChecks {
    static var assertions = 0
    static let english = "I’d like to set up an agent platform for research, though it might be quite resource-intensive. I'll make it up to you later and throw in some extra perks."
    static let analysis = SentenceAnalysis(kind: "sentence", overview: "我想搭建一个科研智能体平台，可能比较耗费资源。之后会补偿你，再额外给些福利。", insights: [
        .init(source: "I’d like to", title: "委婉地表达想法", explanation: "would like to 后接动词原形，用来表达想做的事。")
    ], expressions: [
        .init(text: "set up", source: "set up", meaning: "建立、搭建"),
        .init(text: "make it up to someone", source: "make it up to you", meaning: "补偿某人", usage: "说出实际对象时，用 you、him 等替换 someone。")
    ])
    static var directory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["EHK_SPEECH_UI_OUTPUT"]!)
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SpeechSurfaceFailure(message: message) }
        assertions += 1
    }

    static func descendant<T: UIView>(_ root: UIView, _ identifier: String, as: T.Type = T.self) throws -> T {
        if let item = root as? T, item.accessibilityIdentifier == identifier { return item }
        for child in root.subviews {
            if let item = try? descendant(child, identifier, as: T.self) { return item }
        }
        throw SpeechSurfaceFailure(message: "Missing \(identifier)")
    }

    static func layout(_ root: UIView, _ surface: KeyboardSurface) {
        root.setNeedsLayout()
        root.layoutIfNeeded()
        surface.setNeedsLayout()
        surface.layoutIfNeeded()
    }

    static func render(_ surface: UIView, name: String) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: surface.bounds.size, format: format).image { _ in
            surface.drawHierarchy(in: surface.bounds, afterScreenUpdates: true)
        }
        guard let png = image.pngData() else { throw SpeechSurfaceFailure(message: "PNG rendering failed") }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    /// Uses UIKit's laid-out character rectangles, rather than estimating text
    /// width from a font. These coordinates exercise the production tap path.
    static func characterPoint(in textView: UITextView, at offset: Int) throws -> CGPoint {
        guard let start = textView.position(from: textView.beginningOfDocument, offset: offset),
              let end = textView.position(from: start, offset: 1),
              let range = textView.textRange(from: start, to: end) else {
            throw SpeechSurfaceFailure(message: "Missing text position at \(offset)")
        }
        let rect = textView.firstRect(for: range)
        try expect(!rect.isEmpty && !rect.isInfinite && !rect.isNull,
                   "UIKit laid out character offset\(offset), rect\(rect), bounds\(textView.bounds), text\(textView.text ?? "nil")")
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    static func checkStudyReading(root: UIView, surface: KeyboardSurface, prefix: String) throws {
        let original: StudyReadingTextView = try descendant(surface, "keyboard.analysisOriginal")
        let studyScroll: UIScrollView = try descendant(surface, "keyboard.analysisScroll")
        let sentenceSpeaker: UIButton = try descendant(surface, "keyboard.speechToggle")
        let expressionSpeaker: UIButton = try descendant(surface, "keyboard.analysisExpressionSpeaker.1")
        let expressionLabel: UILabel = try descendant(surface, "keyboard.analysisExpressionText.1")
        let selectionButton: UIButton = try descendant(surface, "keyboard.analysisReadSelectionButton")
        let readingHint: UIView = try descendant(surface, "keyboard.analysisReadingHint")
        let overview: UILabel = try descendant(surface, "keyboard.analysisOverview")
        let firstInsight: UIView = try descendant(surface, "keyboard.analysisInsight.0")
        let insightAction: UIControl = try descendant(surface, "keyboard.analysisInsightTitle.0")
        let insightExplanation: UILabel = try descendant(surface, "keyboard.analysisInsightExplanation.0")
        let originalText = english as NSString
        var snippets: [String] = []
        var hostActions = 0
        surface.onReadAnalysisText = { snippets.append($0) }
        surface.onAction = { _ in hostActions += 1 }
        surface.onUseEnglish = { hostActions += 1 }
        surface.onUndoEnglish = { hostActions += 1 }

        surface.setSpeech(available: true, state: .idle, text: nil, english: english)
        layout(root, surface)
        try expect(original.text == english, "\(prefix): selectable original preserves every character")
        try expect(!original.isEditable && !original.isScrollEnabled && original.isSelectable,
                   "\(prefix): original is selectable, cannot edit, and shares the outer scroller")
        let font = original.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        let paragraph = original.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        try expect(font?.pointSize == 18 && font?.fontDescriptor.symbolicTraits.contains(.traitBold) == false,
                   "\(prefix): learning English keeps18pt regular")
        try expect(paragraph?.minimumLineHeight == 28 && paragraph?.maximumLineHeight == 28,
                   "\(prefix): selectable original retains28pt reading rhythm")
        try expect(original.contentSize.width <= original.bounds.width + 1 && original.bounds.height > 84,
                   "\(prefix): long original wraps naturally without horizontal text scrolling")
        let firstWordPoint = try characterPoint(in: original, at: 0)
        try expect(expressionLabel.text == "make it up to someone" && !expressionSpeaker.isHidden,
                   "\(prefix): reusable pattern retains its visible phrase speaker")
        try expect(expressionSpeaker.bounds.width >= 44 && expressionSpeaker.bounds.height >= 44,
                   "\(prefix): phrase speaker has a44pt touch target")
        try expect(expressionLabel.frame.maxX <= expressionSpeaker.frame.minX,
                   "\(prefix): phrase title does not overlap its speaker")

        // The compact annotation is one action, including its explanatory
        // text. Tapping its body should focus the source, not edit or speak.
        let explanationPoint = insightExplanation.convert(CGPoint(x: insightExplanation.bounds.midX, y: insightExplanation.bounds.midY), to: insightAction)
        let insightHit = insightAction.hitTest(explanationPoint, with: nil)
        try expect(insightHit === insightAction || insightHit?.isDescendant(of: insightAction) == true,
                   "\(prefix): annotation body remains part of the source-focus action")
        let beforeInsightOffset = studyScroll.contentOffset
        insightAction.sendActions(for: .touchUpInside)
        layout(root, surface)
        try expect(original.highlightedRange == originalText.range(of: "I’d like to") && snippets.isEmpty && hostActions == 0 && studyScroll.contentOffset == beforeInsightOffset,
                   "\(prefix): annotation focus highlights its original source without speech, input changes or scrolling")

        for token in ["I’d", "I'll", "resource-intensive", "research"] {
            let expectedRange = originalText.range(of: token)
            try expect(expectedRange.location != NSNotFound, "fixture contains\(token)")
            // Every character, including apostrophe/hyphen, should read the
            // complete lexical item even when the compound spans a line.
            for offset in expectedRange.location ..< NSMaxRange(expectedRange) {
                let point = try characterPoint(in: original, at: offset)
                let range = original.readingRange(at: point)
                try expect(range == expectedRange, "\(prefix): \(token) stays whole atUTF16 offset\(offset)")
                original.readWord(at: point)
                try expect(snippets.last == token, "\(prefix): point dispatches exact original token\(token)")
            }
        }
        let gap = originalText.range(of: " like").location
        let gapPoint = try characterPoint(in: original, at: gap)
        let count = snippets.count
        try expect(original.readingRange(at: gapPoint) == nil, "\(prefix): inter-word whitespace is not a word")
        original.readWord(at: gapPoint)
        for mark in [",", "."] {
            let markPoint = try characterPoint(in: original, at: originalText.range(of: mark).location)
            try expect(original.readingRange(at: markPoint) == nil, "\(prefix): isolated punctuation is not a word")
            original.readWord(at: markPoint)
        }
        original.readWord(at: CGPoint(x: -8, y: 8))
        original.readWord(at: CGPoint(x: 8, y: original.bounds.maxY + 10))
        try expect(snippets.count == count, "\(prefix): whitespace/outside text never speaks nearest word")

        let unselectedSize = studyScroll.contentSize
        let unselectedOffset = studyScroll.contentOffset
        let originalFrame = original.frame
        let overviewFrame = overview.frame
        let beforeSelection = snippets.count
        try expect(selectionButton.isHidden && readingHint.bounds.height < 44,
                   "\(prefix): the ordinary reading hint does not reserve a button-sized gap")
        try expect(original.frame.maxY <= overview.frame.minY && overview.frame.maxY <= readingHint.frame.minY,
                   "\(prefix): English and its meaning are consecutive, before the secondary interaction hint")
        original.selectedRange = originalText.range(of: " an agent platform ")
        layout(root, surface)
        try expect(!selectionButton.isHidden && selectionButton.isEnabled && selectionButton.bounds.height == 44,
                   "\(prefix): native selection reveals a visible44pt read-selection button")
        try expect(snippets.count == beforeSelection && original.frame == originalFrame && overview.frame == overviewFrame && studyScroll.contentOffset == unselectedOffset,
                   "\(prefix): revealing a selection action neither speaks nor moves the original, its meaning or the viewport")
        try expect(studyScroll.contentSize.height > unselectedSize.height &&
                   readingHint.bounds.contains(selectionButton.frame) &&
                   readingHint.convert(readingHint.bounds, to: studyScroll).maxY <= firstInsight.convert(firstInsight.bounds, to: studyScroll).minY,
                   "\(prefix): expanding the selection action increases scrollable content instead of clipping the button or covering notes")
        let selectionHit = readingHint.hitTest(CGPoint(x: selectionButton.frame.midX, y: selectionButton.frame.maxY - 1), with: nil)
        try expect(selectionHit === selectionButton || selectionHit?.isDescendant(of: selectionButton) == true,
                   "\(prefix): the bottom edge of the selection action remains tappable after its row grows")
        selectionButton.sendActions(for: .touchUpInside)
        try expect(snippets.last == "an agent platform" && hostActions == 0 && original.text == english,
                   "\(prefix): visible selection action reads exact source without dispatching input or replacement")
        try render(surface, name: prefix + "-study-selection")
        let menu = original.textView(original, editMenuForTextIn: original.selectedRange, suggestedActions: [])
        let readSelection = menu?.children.compactMap { $0 as? UIAction }.first { $0.title == "朗读所选" }
        try expect(readSelection != nil, "\(prefix): native text-selection menu exposes read action")
        original.readSelectedText()
        try expect(snippets.last == "an agent platform" && original.highlightedRange == originalText.range(of: "an agent platform"),
                   "\(prefix): arbitrary selected phrase uses original text and trims surrounding space")
        if let readSelection {
            let menuInvoker = UIButton(type: .system)
            menuInvoker.addAction(readSelection, for: .touchUpInside)
            original.selectedRange = originalText.range(of: "throw in some extra perks")
            menuInvoker.sendActions(for: .touchUpInside)
            try expect(snippets.last == "throw in some extra perks", "\(prefix): menu reads current selection rather than stale menu range")
            selectionButton.sendActions(for: .touchUpInside)
            try expect(snippets.last == "throw in some extra perks", "\(prefix): visible button also follows the current selection")
        }
        original.clearSelection()
        let selectionCount = snippets.count
        original.readSelectedText()
        selectionButton.sendActions(for: .touchUpInside)
        try expect(selectionButton.isHidden, "\(prefix): clearing selection restores the quiet hint")
        original.selectedRange = originalText.range(of: ",")
        original.readSelectedText()
        selectionButton.sendActions(for: .touchUpInside)
        try expect(selectionButton.isHidden, "\(prefix): punctuation-only selection cannot expose a read action")
        try expect(snippets.count == selectionCount, "\(prefix): empty or punctuation-only selection cannot speak")
        original.clearSelection()
        layout(root, surface)
        try expect(studyScroll.contentSize == unselectedSize && studyScroll.contentOffset == unselectedOffset && hostActions == 0,
                   "\(prefix): clearing selection restores compact content and retains the reading position without host actions")

        expressionSpeaker.sendActions(for: .touchUpInside)
        try expect(snippets.last == "make it up to you", "\(prefix): phrase speaker reads source, never template placeholders")
        studyScroll.setContentOffset(CGPoint(x: 0, y: 65), animated: false)
        let oldSize = studyScroll.contentSize
        for state in [SpeechPlaybackSession.State.loading, .playing, .idle] {
            surface.setSpeech(available: true, state: state, text: "make it up to you", english: english)
            layout(root, surface)
            let sameOriginal: StudyReadingTextView = try descendant(surface, "keyboard.analysisOriginal")
            try expect(sameOriginal === original && studyScroll.contentOffset.y == 65 && studyScroll.contentSize == oldSize,
                       "\(prefix): snippet state updates preserve original view and scroll geometry")
            try expect(sentenceSpeaker.accessibilityLabel == "朗读英文",
                       "\(prefix): snippet activity cannot masquerade as whole-sentence playback")
            try expect(original.highlightedRange == originalText.range(of: "make it up to you"),
                       "\(prefix): playback focuses the actual spoken phrase inside the original")
        }
        surface.setSpeech(available: true, state: .playing, text: "make it up to you", english: english)
        layout(root, surface)
        let speakerContentY = expressionSpeaker.convert(.zero, to: studyScroll).y
        let phraseOffset = min(max(0, studyScroll.contentSize.height - studyScroll.bounds.height),
                               max(0, speakerContentY - 180))
        studyScroll.setContentOffset(CGPoint(x: 0, y: phraseOffset), animated: false)
        try render(surface, name: prefix + "-study-expression")
        surface.setSpeech(available: false, state: .idle, text: nil, english: english)
        layout(root, surface)
        let unavailableCount = snippets.count
        expressionSpeaker.sendActions(for: .touchUpInside)
        selectionButton.sendActions(for: .touchUpInside)
        original.readWord(at: firstWordPoint)
        try expect(expressionSpeaker.isHidden && selectionButton.isHidden && snippets.count == unavailableCount,
                   "\(prefix): unavailable provider disables both word and phrase dispatch")

        surface.setSpeech(available: true, state: .idle, text: nil, english: english)
        original.selectedRange = originalText.range(of: "an agent platform")
        surface.setAnalysis(available: true, expanded: false, english: english, state: .ready(analysis))
        surface.frame.size.height = 260
        layout(root, surface)
        let closedCount = snippets.count
        expressionSpeaker.sendActions(for: .touchUpInside)
        selectionButton.sendActions(for: .touchUpInside)
        original.readWord(at: firstWordPoint)
        try expect(snippets.count == closedCount, "\(prefix): collapsed learning cannot dispatch hidden controls")
        try expect(original.selectedRange.length == 0 && !original.isFirstResponder,
                   "\(prefix): collapsing learning clears native selection and focus")
        surface.frame.size.height = 440
        surface.setAnalysis(available: true, expanded: true, english: english, state: .ready(analysis))
        layout(root, surface)
        try expect(studyScroll.contentOffset == .zero && studyScroll.bounds.height > 300,
                   "\(prefix): reopening starts at top with a full learning viewport")
        try expect(studyScroll.contentSize == oldSize && original.frame.minY >= 0,
                   "\(prefix): collapse/reopen preserves complete content height and top placement")
        surface.setSpeech(available: false, state: .idle, text: nil, english: english)
        surface.setSpeech(available: true, state: .idle, text: nil, english: english)
        layout(root, surface)
        try render(surface, name: prefix + "-study-tap")

        // Analysis can finish while the user is already selecting/reading the
        // original. Longer text ensures the pre-analysis viewport can scroll.
        let pendingEnglish = Array(repeating: english, count: 4).joined(separator: "\n\n")
        surface.setHint(text: pendingEnglish, loading: false, isTranslation: true, canRetry: false)
        surface.setAnalysis(available: true, expanded: true, english: pendingEnglish, state: .loading)
        surface.setSpeech(available: true, state: .idle, text: nil, english: pendingEnglish)
        layout(root, surface)
        let staleCount = snippets.count
        original.readWord(at: firstWordPoint)
        original.selectedRange = originalText.range(of: "an agent platform")
        original.readSelectedText()
        expressionSpeaker.sendActions(for: .touchUpInside)
        selectionButton.sendActions(for: .touchUpInside)
        if let readSelection {
            let staleMenuInvoker = UIButton(type: .system)
            staleMenuInvoker.addAction(readSelection, for: .touchUpInside)
            staleMenuInvoker.sendActions(for: .touchUpInside)
        }
        try expect(snippets.count == staleCount, "\(prefix): discarded word view, phrase speaker and selection menu cannot read into a newer sentence")
        let pendingOriginal: StudyReadingTextView = try descendant(surface, "keyboard.analysisOriginal")
        let pendingRange = (pendingEnglish as NSString).range(of: "an agent platform")
        pendingOriginal.selectedRange = pendingRange
        studyScroll.setContentOffset(CGPoint(x: 0, y: 25), animated: false)
        surface.setAnalysis(available: true, expanded: true, english: pendingEnglish, state: .ready(analysis))
        layout(root, surface)
        let readyOriginal: StudyReadingTextView = try descendant(surface, "keyboard.analysisOriginal")
        try expect(pendingOriginal === readyOriginal && readyOriginal.selectedRange == pendingRange,
                   "\(prefix): background analysis completion preserves the original view and current selection")
        try expect(studyScroll.contentOffset.y == 25, "\(prefix): background analysis completion preserves reading position")

        // Switching from a deeply scrollable sentence to a lone greeting must
        // remove all former notes and offsets. Selecting its only word must
        // still expose a usable action without manufacturing empty sections.
        let greeting = SentenceAnalysis(kind: "word", overview: "你好；用于打招呼或开启对话。", insights: [], expressions: [])
        studyScroll.setContentOffset(CGPoint(x: 0, y: max(0, studyScroll.contentSize.height - studyScroll.bounds.height)), animated: false)
        surface.setHint(text: "Hello", loading: false, isTranslation: true, canRetry: false)
        surface.setAnalysis(available: true, expanded: true, english: "Hello", state: .ready(greeting))
        surface.setSpeech(available: true, state: .idle, text: nil, english: "Hello")
        layout(root, surface)
        let greetingOriginal: StudyReadingTextView = try descendant(surface, "keyboard.analysisOriginal")
        let greetingOverview: UILabel = try descendant(surface, "keyboard.analysisOverview")
        let greetingHint: UIView = try descendant(surface, "keyboard.analysisReadingHint")
        let greetingSelection: UIButton = try descendant(surface, "keyboard.analysisReadSelectionButton")
        let greetingFrame = greetingOriginal.frame
        try expect(studyScroll.contentOffset == .zero && studyScroll.contentSize.height == studyScroll.bounds.height,
                   "\(prefix): a short greeting clears the previous long sentence's scroll extent")
        try expect((try? descendant(surface, "keyboard.analysisInsightHeading", as: UILabel.self)) == nil &&
                   (try? descendant(surface, "keyboard.analysisExpressionHeading", as: UILabel.self)) == nil,
                   "\(prefix): a greeting does not inherit or fabricate usage and expression sections")
        for _ in 0 ..< 3 {
            greetingOriginal.selectedRange = NSRange(location: 0, length: 5)
            layout(root, surface)
            try expect(!greetingSelection.isHidden && greetingHint.bounds.contains(greetingSelection.frame) &&
                       greetingOriginal.frame == greetingFrame && greetingOverview.frame.maxY <= greetingHint.frame.minY,
                       "\(prefix): repeated greeting selection reveals a complete action without moving or covering text")
            surface.setAnalysis(available: true, expanded: false, english: "Hello", state: .ready(greeting))
            surface.frame.size.height = 260
            layout(root, surface)
            surface.frame.size.height = 440
            surface.setAnalysis(available: true, expanded: true, english: "Hello", state: .ready(greeting))
            layout(root, surface)
            let reopenedGreeting: StudyReadingTextView = try descendant(surface, "keyboard.analysisOriginal")
            try expect(reopenedGreeting === greetingOriginal && greetingOriginal.frame == greetingFrame &&
                       greetingOriginal.selectedRange.length == 0 && greetingSelection.isHidden &&
                       studyScroll.contentOffset == .zero && studyScroll.contentSize.height == studyScroll.bounds.height,
                       "\(prefix): repeated compact collapse/reopen restores the full viewport and clears selection without stale content")
        }
        try render(surface, name: prefix + "-study-greeting")
        surface.setHint(text: english, loading: false, isTranslation: true, canRetry: false)
        surface.setAnalysis(available: true, expanded: true, english: english, state: .ready(analysis))
        surface.setSpeech(available: true, state: .idle, text: nil, english: english)
        layout(root, surface)
        surface.onReadAnalysisText = nil
        surface.onAction = nil
        surface.onUseEnglish = nil
        surface.onUndoEnglish = nil
    }

    static func run() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width: CGFloat in [320, 393, 430] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let root = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 460))
                let controller = UIViewController()
                controller.view = root
                let window = UIWindow(frame: root.frame)
                window.rootViewController = controller
                window.overrideUserInterfaceStyle = style
                let surface = KeyboardSurface(frame: CGRect(x: 0, y: 0, width: width, height: 260))
                surface.overrideUserInterfaceStyle = style
                root.addSubview(surface)
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(100))
                surface.setHint(text: english, loading: false, isTranslation: true, canRetry: false)
                surface.setHintAction(.useEnglish)
                surface.setAnalysis(available: true, expanded: false, english: english, state: .ready(analysis))
                surface.setSpeech(available: true, state: .idle)
                layout(root, surface)

                let header: UIView = try descendant(surface, "keyboard.header")
                let speech: UIButton = try descendant(surface, "keyboard.speechToggle")
                let action: UIButton = try descendant(surface, "keyboard.hintAction")
                let expand: UIButton = try descendant(surface, "keyboard.analysisToggle")
                let scroll: UIScrollView = try descendant(surface, "keyboard.hintScroll")
                let label: UILabel = try descendant(surface, "keyboard.englishHint")
                let spinner: UIActivityIndicatorView = try descendant(surface, "keyboard.speechLoading")
                let toast: UIView = try descendant(surface, "keyboard.speechError")
                let panel: UIView = try descendant(surface, "keyboard.analysisPanel")
                let studyScroll: UIScrollView = try descendant(surface, "keyboard.analysisScroll")
                let prefix = "\(Int(width))-\(style == .dark ? "dark" : "light")"
                var taps = 0
                surface.onToggleSpeech = { taps += 1 }

                try expect(surface.window != nil, "\(prefix): native window attached")
                try expect(surface.bounds.height == 260 && header.bounds.height == 44, "\(prefix): initial bar and keyboard height")
                try expect(!speech.isHidden && speech.image(for: .normal) != nil, "\(prefix): ready translation has speaker")
                try expect(speech.backgroundColor == nil, "\(prefix): speaker has no filled background")
                try expect(label.font.pointSize == 16 && !label.font.fontDescriptor.symbolicTraits.contains(.traitBold), "\(prefix): original English16 regular")
                let paragraph = label.attributedText?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                try expect(paragraph?.minimumLineHeight == 20 && paragraph?.maximumLineHeight == 20, "\(prefix): original20pt line rhythm")
                try expect(!label.adjustsFontSizeToFitWidth && label.numberOfLines == 0, "\(prefix): unlimited content without font shrinking")
                try expect(scroll.bounds.height == 20 && scroll.isPagingEnabled, "\(prefix): one-line vertical paging")
                try expect(scroll.topEdgeEffect.isHidden && scroll.bottomEdgeEffect.isHidden,
                           "\(prefix): system edge blur cannot cover the single English line")
                try expect(scroll.contentSize.height > 40 && scroll.contentSize.width == scroll.bounds.width, "\(prefix): long English remains reachable without horizontal overflow")
                try expect(scroll.frame.maxX + 4 == speech.frame.minX, "\(prefix): no unused width before controls")
                try expect(speech.frame.maxX == action.frame.minX && action.frame.maxX == expand.frame.minX, "\(prefix): no extra control gaps")
                try expect(scroll.bounds.width >= 154, "\(prefix): useful English viewport remains")
                for (control, expectedWidth) in [(speech, CGFloat(44)), (action, 56), (expand, 44)] {
                    try expect(control.bounds.width == expectedWidth && control.bounds.height == 44, "\(prefix): preserved touch target")
                    try expect(control.frame.minX >= 0 && control.frame.maxX <= header.bounds.width, "\(prefix): controls stay inside header")
                    let hit = header.hitTest(CGPoint(x: control.frame.minX + 1, y: 22), with: nil)
                    try expect(hit === control || hit?.isDescendant(of: control) == true, "\(prefix): adjacent targets remain individually tappable")
                }
                let originalHintWidth = scroll.bounds.width
                let originalKeyboardHeight = surface.bounds.height
                let idleTint = speech.tintColor.resolvedColor(with: surface.traitCollection)
                speech.sendActions(for: .touchUpInside)
                try expect(taps == 1, "\(prefix): idle tap dispatches")
                try render(surface, name: prefix + "-idle")

                surface.setSpeech(available: true, state: .loading)
                layout(root, surface)
                try expect(spinner.isAnimating && speech.image(for: .normal) == nil, "\(prefix): loading uses one compact spinner")
                try expect(speech.accessibilityLabel == "取消朗读", "\(prefix): loading communicates cancellation")
                try expect(scroll.bounds.width == originalHintWidth && surface.bounds.height == originalKeyboardHeight, "\(prefix): loading never moves text or keys")
                let loadingHit = header.hitTest(CGPoint(x: speech.frame.midX, y: 22), with: nil)
                try expect(loadingHit === speech, "\(prefix): spinner does not swallow cancel tap")
                speech.sendActions(for: .touchUpInside)
                try expect(taps == 2, "\(prefix): loading tap can cancel")
                if width == 320 {
                    try await Task.sleep(for: .milliseconds(200))
                    try render(surface, name: prefix + "-loading")
                }

                surface.setSpeech(available: true, state: .playing)
                layout(root, surface)
                try expect(!spinner.isAnimating && speech.accessibilityLabel == "停止朗读", "\(prefix): playing communicates stop")
                try expect(speech.tintColor.resolvedColor(with: surface.traitCollection) == UIColor.systemBlue.resolvedColor(with: surface.traitCollection), "\(prefix): playing is blue")
                try expect(speech.tintColor.resolvedColor(with: surface.traitCollection) != idleTint, "\(prefix): visible active state")
                speech.sendActions(for: .touchUpInside)
                try expect(taps == 3, "\(prefix): playing tap can stop")
                try expect(scroll.bounds.width == originalHintWidth && header.bounds.height == 44, "\(prefix): playing does not change reading geometry")

                surface.frame.size.height = 440
                surface.setAnalysis(available: true, expanded: true, english: english, state: .ready(analysis))
                layout(root, surface)
                try expect(!panel.isHidden && scroll.isHidden && !speech.isHidden, "\(prefix): same speaker works in learning header")
                try expect(header.bounds.height == 44 && surface.bounds.height == 440, "\(prefix): learning retains independent half-screen size")
                let learningTitle: UILabel = try descendant(surface, "keyboard.analysisTitle")
                try expect(learningTitle.frame.maxX <= speech.frame.minX && learningTitle.bounds.width > 100, "\(prefix): learning title stays clear of all controls")
                studyScroll.setContentOffset(CGPoint(x: 0, y: 25), animated: false)
                surface.setSpeech(available: true, state: .idle)
                layout(root, surface)
                try expect(studyScroll.contentOffset.y == 25, "\(prefix): changing playback state preserves study position")
                surface.setSpeech(available: true, state: .playing)
                studyScroll.setContentOffset(.zero, animated: false)
                try render(surface, name: prefix + "-learning")
                try checkStudyReading(root: root, surface: surface, prefix: prefix)

                let message = "暂时无法使用千问语音，请检查模型权限与账户余额。"
                surface.setSpeech(available: true, state: .failed(message))
                layout(root, surface)
                try expect(!toast.isHidden && !toast.isUserInteractionEnabled, "\(prefix): visible failure never blocks keyboard taps")
                try expect(speech.accessibilityValue == message && speech.accessibilityLabel == "重试朗读", "\(prefix): failure readable and retryable")
                try expect(toast.frame.minY > header.frame.maxY && toast.frame.maxX < surface.bounds.width, "\(prefix): failure stays below header within surface")
                try expect(header.bounds.height == 44 && surface.bounds.height == 440, "\(prefix): failure leaves layout unchanged")
                if width == 393 { try render(surface, name: prefix + "-error") }
                speech.sendActions(for: .touchUpInside)
                try expect(taps == 4 && toast.isHidden, "\(prefix): retry dismisses old error immediately")

                surface.setSpeech(available: false, state: .idle)
                layout(root, surface)
                try expect(speech.isHidden && speech.frame.isEmpty, "\(prefix): unavailable provider reserves no speaker width")
                let count = taps
                speech.sendActions(for: .touchUpInside)
                try expect(taps == count, "\(prefix): hidden speaker cannot dispatch")
                surface.frame.size.height = 260
                surface.setAnalysis(available: true, expanded: false, english: english, state: .ready(analysis))
                layout(root, surface)
                try expect(scroll.bounds.width == originalHintWidth + 44, "\(prefix): unavailable speech returns all its width to English")

                surface.setSpeech(available: true, state: .loading)
                surface.setInputLanguage(isChinese: true)
                surface.setComposition("ni", candidates: ["你"], isChinese: true, onSelect: { _ in })
                layout(root, surface)
                try expect(speech.isHidden && !spinner.isAnimating && scroll.isHidden, "\(prefix): composition owns header without speech controls")
                let candidates: UIView = try descendant(surface, "keyboard.candidates")
                let candidate: UICollectionViewCell = try descendant(surface, "keyboard.candidates.0")
                try expect(candidate.bounds.height <= candidates.bounds.height && candidate.bounds.height == 31,
                           "\(prefix): candidate height follows the composition viewport")
                let candidateCollection = candidates.subviews.compactMap { $0 as? UICollectionView }.first
                try expect(candidateCollection?.adjustedContentInset == .zero,
                           "\(prefix): candidate row does not inherit host window safe-area insets")
                surface.setComposition("", candidates: [], isChinese: true, onSelect: { _ in })
                layout(root, surface)
                try expect(!speech.isHidden && spinner.isAnimating, "\(prefix): restored translation reflects current loading state")
                surface.setHint(text: "", loading: true, isTranslation: false, canRetry: false)
                layout(root, surface)
                try expect(speech.isHidden && !spinner.isAnimating, "\(prefix): translation loading cannot expose old speech")
                surface.setHint(text: english, loading: false, isTranslation: true, canRetry: false)
                surface.setSpeech(available: true, state: .failed("语音连接失败，请检查网络后重试。"))
                layout(root, surface)
                try expect(!toast.isHidden, "\(prefix): later failure has visible feedback")
                surface.removeFromSuperview()
                try expect(toast.isHidden, "\(prefix): detaching keyboard dismisses stale feedback")
                window.isHidden = true
                try await Task.sleep(for: .milliseconds(100))
                print("Speech surface geometry: \(prefix) passed")
            }
        }

        // Repeated controller refreshes must not keep an error floating forever.
        let surface = KeyboardSurface(frame: CGRect(x: 0, y: 0, width: 393, height: 260))
        surface.setHint(text: english, loading: false, isTranslation: true, canRetry: false)
        let error = "语音连接失败，请检查网络后重试。"
        surface.setSpeech(available: true, state: .failed(error))
        let toast: UIView = try descendant(surface, "keyboard.speechError")
        try expect(!toast.isHidden, "failure toast is initially visible")
        try await Task.sleep(for: .seconds(2))
        surface.setSpeech(available: true, state: .failed(error))
        try await Task.sleep(for: .milliseconds(1200))
        try expect(toast.isHidden, "repeated identical state does not restart failure timeout")
        let report: [String: Any] = [
            "assertions": assertions,
            "viewports": [320, 393, 430],
            "styles": ["light", "dark"],
            "renderer": "Native Mac Catalyst UIKit. Not an iPhone playback test.",
            "wordHitTesting": "Laid-out UIKit character coordinates through the production point-reading method; no synthesized touch events.",
            "networkRequests": 0,
            "audioPlayback": false
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("verification.json"))
        print("Keyboard speech surface: \(assertions) checks passed")
    }
}

@main
@MainActor
final class SpeechSurfaceHarnessApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Task {
            do { try await SpeechSurfaceChecks.run(); exit(0) }
            catch { print("Keyboard speech surface FAILED: \(error)"); exit(1) }
        }
        return true
    }
}
