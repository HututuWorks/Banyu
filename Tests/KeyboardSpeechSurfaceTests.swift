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
    ], wordMeanings: [.init(token: 4, meaning: "与 set 连用，表示搭建")], structure: [
        .init(start: 0, end: 10, role: .core),
        .init(start: 10, end: 16, role: .supplement),
        .init(start: 16, end: 29, role: .core)
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

    static func lineBreaks(in textView: UITextView) -> [NSRange] {
        textView.layoutManager.ensureLayout(for: textView.textContainer)
        var ranges: [NSRange] = []
        textView.layoutManager.enumerateLineFragments(
            forGlyphRange: NSRange(location: 0, length: textView.layoutManager.numberOfGlyphs)
        ) { _, _, _, range, _ in ranges.append(range) }
        return ranges
    }

    static func isVisible(_ view: UIView) -> Bool {
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha == 0 { return false }
            ancestor = current.superview
        }
        return true
    }

    static func checkConnectedReading(root: UIView, surface: KeyboardSurface, prefix: String) throws {
        let repeated = "I can book a room, and this book is useful."
        let repeatedAnalysis = SentenceAnalysis(kind: "sentence", overview: "我可以预订房间，而且这本书很有用。", insights: [], expressions: [],
            wordMeanings: [.init(token: 2, meaning: "预订"), .init(token: 7, meaning: "书")],
            structure: [.init(start: 0, end: 5, role: .core), .init(start: 5, end: 10, role: .supplement)])
        let studyScroll: UIScrollView = try descendant(surface, "keyboard.analysisScroll")
        var spoken: [String] = []
        var hostActions = 0
        surface.onReadAnalysisText = { spoken.append($0) }
        surface.onAction = { _ in hostActions += 1 }
        surface.onUseEnglish = { hostActions += 1 }
        surface.onUndoEnglish = { hostActions += 1 }
        surface.setHint(text: repeated, loading: false, isTranslation: true, canRetry: false)
        surface.setAnalysis(available: true, expanded: true, english: repeated, state: .ready(repeatedAnalysis))
        surface.setSpeech(available: true, state: .idle, text: nil, english: repeated)
        layout(root, surface)
        let repeatedOriginal: StudyReadingTextView = try descendant(surface, "keyboard.analysisOriginal")
        let lookupWord: UILabel = try descendant(surface, "keyboard.analysisLookupWord")
        let lookupMeaning: UILabel = try descendant(surface, "keyboard.analysisLookupMeaning")
        let lookupMeaningScroll: UIScrollView = try descendant(surface, "keyboard.analysisLookupMeaningScroll")
        let header: UIView = try descendant(surface, "keyboard.header")
        let sentenceSpeaker: UIButton = try descendant(surface, "keyboard.speechToggle")
        let sentenceScope: UILabel = try descendant(surface, "keyboard.speechScope")
        try expect(!sentenceScope.isHidden && sentenceScope.text == "整句",
                   "\(prefix): a word lookup cannot make the header speaker's whole-sentence scope ambiguous")
        if let icon = sentenceSpeaker.imageView {
            try expect(icon.frame.maxX <= sentenceScope.frame.minX,
                       "\(prefix): sentence speaker icon \(icon.frame) and scope text \(sentenceScope.frame) do not overlap")
        }
        let stableFrame = repeatedOriginal.frame
        let stableSize = studyScroll.contentSize
        let stableOffset = studyScroll.contentOffset
        let books = SentenceAnalysis.tokens(in: repeated).filter { $0.text == "book" }
        try expect(books.count == 2, "\(prefix): fixture contains two independent occurrences of book")
        for (token, meaning) in zip(books, ["预订", "书"]) {
            repeatedOriginal.readWord(at: try characterPoint(in: repeatedOriginal, at: token.range.location))
            layout(root, surface)
            try expect(!lookupWord.isHidden && lookupWord.text == "book" && lookupMeaning.text == meaning,
                       "\(prefix): tapped occurrence selects its contextual meaning, not the first matching word")
            try expect(repeatedOriginal.highlightedRange == token.range && spoken.last == "book",
                       "\(prefix): word lookup highlights the exact occurrence and reads the actual original token")
            try expect(repeatedOriginal.frame == stableFrame && studyScroll.contentSize == stableSize && studyScroll.contentOffset == stableOffset,
                       "\(prefix): changing the fixed lookup header never moves or reflows reading content")
            try expect(header.bounds.height == 44 && lookupWord.frame.maxX <= sentenceSpeaker.frame.minX &&
                       lookupMeaningScroll.frame.maxX <= sentenceSpeaker.frame.minX && lookupWord.frame.maxY <= lookupMeaningScroll.frame.minY,
                       "\(prefix): both lookup lines fit the existing header without overlapping sentence controls")
        }
        try render(surface, name: prefix + "-study-word-meaning")
        repeatedOriginal.readWord(at: try characterPoint(in: repeatedOriginal, at: 1))
        surface.setSpeech(available: true, state: .playing, text: "book", english: repeated)
        layout(root, surface)
        try expect(lookupWord.isHidden && lookupMeaning.isHidden && repeatedOriginal.highlightedRange == nil,
                   "\(prefix): blank tap clears word lookup and late playback state cannot restore a discarded selection")
        try expect(repeatedOriginal.attributedText.attribute(.backgroundColor, at: books[1].range.location, effectiveRange: nil) != nil,
                   "\(prefix): clearing a transient selection preserves the underlying structural annotation")
        surface.setSpeech(available: true, state: .idle, text: nil, english: repeated)

        // Structure emphasis must change only presentation: preserve every
        // actual TextKit line boundary, font and the reader's place.
        let focus: UIButton = try descendant(surface, "keyboard.analysisStructureFocus")
        let lineRanges = lineBreaks(in: repeatedOriginal)
        let originalAttributes = repeatedOriginal.attributedText
        for _ in 0 ..< 3 {
            let previousStyle = NSAttributedString(attributedString: repeatedOriginal.attributedText)
            focus.sendActions(for: .touchUpInside)
            layout(root, surface)
            try expect(!repeatedOriginal.attributedText.isEqual(to: previousStyle),
                       "\(prefix): core emphasis visibly changes the source presentation")
            try expect(lineBreaks(in: repeatedOriginal) == lineRanges && repeatedOriginal.frame == stableFrame &&
                       studyScroll.contentSize == stableSize && studyScroll.contentOffset == stableOffset,
                       "\(prefix): emphasis toggles preserve line breaks, content dimensions and reading offset")
            for token in SentenceAnalysis.tokens(in: repeated) {
                let before = originalAttributes?.attribute(.font, at: token.range.location, effectiveRange: nil) as? UIFont
                let after = repeatedOriginal.attributedText.attribute(.font, at: token.range.location, effectiveRange: nil) as? UIFont
                try expect(before == after && after?.pointSize == 18,
                           "\(prefix): structure emphasis leaves token \(token.index)'s reading font unchanged")
            }
        }
        try render(surface, name: prefix + "-study-core-emphasis")

        // Reuse the same long original while analysis is pending. Lookup can
        // acquire its meaning without rebuilding a text view or losing position.
        let pendingEnglish = repeated + "\n\n" + Array(repeating: english, count: 3).joined(separator: "\n\n")
        surface.setHint(text: pendingEnglish, loading: false, isTranslation: true, canRetry: false)
        surface.setAnalysis(available: true, expanded: true, english: pendingEnglish, state: .loading)
        surface.setSpeech(available: true, state: .idle, text: nil, english: pendingEnglish)
        layout(root, surface)
        let pendingOriginal: StudyReadingTextView = try descendant(surface, "keyboard.analysisOriginal")
        pendingOriginal.readWord(at: try characterPoint(in: pendingOriginal, at: books[1].range.location))
        studyScroll.setContentOffset(CGPoint(x: 0, y: 24), animated: false)
        let pendingSpokenCount = spoken.count
        surface.setAnalysis(available: true, expanded: true, english: pendingEnglish, state: .ready(repeatedAnalysis))
        layout(root, surface)
        let completedOriginal: StudyReadingTextView = try descendant(surface, "keyboard.analysisOriginal")
        try expect(completedOriginal === pendingOriginal && lookupWord.text == "book" && lookupMeaning.text == "书",
                   "\(prefix): late analysis fills the already-selected occurrence's meaning in place")
        try expect(studyScroll.contentOffset.y == 24 && spoken.count == pendingSpokenCount && hostActions == 0,
                   "\(prefix): arriving meanings cannot replay audio, move reading position or touch host input")
        surface.setSpeech(available: true, state: .playing, text: "book", english: pendingEnglish)
        layout(root, surface)
        try expect(completedOriginal.highlightedRange == books[1].range && lookupMeaning.text == "书" && studyScroll.contentOffset.y == 24,
                   "\(prefix): playback refresh preserves the second book's occurrence and contextual meaning")

        // A new sentence removes former lookup context. A stale word view can
        // neither overwrite the header nor dispatch a reading in the new one.
        let greeting = SentenceAnalysis(kind: "word", overview: "你好。", insights: [], expressions: [],
                                       wordMeanings: [.init(token: 0, meaning: "你好")])
        surface.setHint(text: "Hello", loading: false, isTranslation: true, canRetry: false)
        surface.setAnalysis(available: true, expanded: true, english: "Hello", state: .ready(greeting))
        surface.setSpeech(available: true, state: .idle, text: nil, english: "Hello")
        layout(root, surface)
        let afterChangeCount = spoken.count
        pendingOriginal.readWord(at: try characterPoint(in: pendingOriginal, at: books[1].range.location))
        try expect(lookupWord.isHidden && lookupMeaning.isHidden && spoken.count == afterChangeCount,
                   "\(prefix): discarded original cannot leak a former word or meaning into a new sentence")
        let greetingOriginal: StudyReadingTextView = try descendant(surface, "keyboard.analysisOriginal")
        try expect((try? descendant(surface, "keyboard.analysisStructureFocus", as: UIButton.self)) == nil,
                   "\(prefix): a greeting without structure does not acquire a meaningless emphasis control")
        surface.setSpeech(available: false, state: .idle, text: nil, english: "Hello")
        greetingOriginal.readWord(at: try characterPoint(in: greetingOriginal, at: 0))
        layout(root, surface)
        try expect(lookupWord.text == "Hello" && lookupMeaning.text == "你好" && spoken.count == afterChangeCount,
                   "\(prefix): contextual word lookup remains available when speech is unavailable")

        let longMeaning = "资源密集型的；这里指运行平台需要较多计算能力、时间或资金。"
        let compound = SentenceAnalysis(kind: "word", overview: "资源密集型的。", insights: [], expressions: [],
                                       wordMeanings: [.init(token: 0, meaning: longMeaning)])
        surface.setHint(text: "resource-intensive", loading: false, isTranslation: true, canRetry: false)
        surface.setAnalysis(available: true, expanded: true, english: "resource-intensive", state: .ready(compound))
        layout(root, surface)
        let compoundOriginal: StudyReadingTextView = try descendant(surface, "keyboard.analysisOriginal")
        compoundOriginal.readWord(at: try characterPoint(in: compoundOriginal, at: 0))
        layout(root, surface)
        try expect(lookupWord.text == "resource-intensive" && lookupMeaning.text == longMeaning &&
                   lookupMeaningScroll.isScrollEnabled && lookupMeaningScroll.contentSize.width > lookupMeaningScroll.bounds.width,
                   "\(prefix): a longer contextual meaning remains fully reachable in the fixed lookup viewport")
        try expect(!lookupWord.adjustsFontSizeToFitWidth && !lookupMeaning.adjustsFontSizeToFitWidth && header.bounds.height == 44,
                   "\(prefix): long lookup content cannot shrink its fonts or increase keyboard header height")
        lookupMeaningScroll.setContentOffset(CGPoint(x: lookupMeaningScroll.contentSize.width - lookupMeaningScroll.bounds.width, y: 0), animated: false)
        surface.setHint(text: "Hello", loading: false, isTranslation: true, canRetry: false)
        surface.setAnalysis(available: true, expanded: true, english: "Hello", state: .ready(greeting))
        layout(root, surface)
        let restoredGreeting: StudyReadingTextView = try descendant(surface, "keyboard.analysisOriginal")
        restoredGreeting.readWord(at: try characterPoint(in: restoredGreeting, at: 0))
        layout(root, surface)
        try expect(lookupMeaning.text == "你好" && lookupMeaningScroll.contentOffset == .zero,
                   "\(prefix): selecting a new word resets only the lookup's own horizontal position")

        // Native 26-key and nine-key canvases must both return after closing
        // the study surface; lookup is local state, not a keyboard-mode change.
        surface.setInputLanguage(isChinese: true)
        for (mode, keyID) in [(KeyboardSurface.ChineseLayout.qwerty, "keyboard.key.q"), (.nineKey, "keyboard.t9.2")] {
            surface.setChineseLayout(mode)
            surface.frame.size.height = 260
            surface.setAnalysis(available: true, expanded: false, english: "Hello", state: .ready(greeting))
            layout(root, surface)
            let key: UIButton = try descendant(surface, keyID)
            let keyPoint = key.convert(CGPoint(x: key.bounds.midX, y: key.bounds.midY), to: surface)
            let hit = surface.hitTest(keyPoint, with: nil)
            try expect(key.bounds.width > 0 && key.bounds.height >= 40 &&
                       (hit === key || hit?.isDescendant(of: key) == true),
                       "\(prefix): closing study restores the \(keyID) touch surface")
            surface.frame.size.height = 440
            surface.setAnalysis(available: true, expanded: true, english: "Hello", state: .ready(greeting))
            layout(root, surface)
            try expect(lookupWord.isHidden && lookupMeaning.isHidden && studyScroll.contentOffset == .zero,
                       "\(prefix): reopening study clears transient lookup and starts from the beginning")
        }
        surface.setChineseLayout(.qwerty)
        surface.setInputLanguage(isChinese: false)
        surface.setHint(text: english, loading: false, isTranslation: true, canRetry: false)
        surface.setAnalysis(available: true, expanded: true, english: english, state: .ready(analysis))
        surface.setSpeech(available: true, state: .idle, text: nil, english: english)
        layout(root, surface)
        surface.onReadAnalysisText = nil
        surface.onAction = nil
        surface.onUseEnglish = nil
        surface.onUndoEnglish = nil
    }

    static func checkParagraphReading(root: UIView, surface: KeyboardSurface, prefix: String) throws {
        let draft = "Hello.\n\nThis is Banyu, a keyboard that lets you learn English as you type. 😊\n\nYou can type in Chinese as usual. Banyu shows the English translation; tap a word or the speaker to hear its pronunciation."
        let originalString = draft as NSString
        let tokens = SentenceAnalysis.tokens(in: draft)
        let lookupFixtures = [("Hello", "你好"), ("keyboard", "键盘"), ("pronunciation", "发音")]
        let meanings = try lookupFixtures.map { word, meaning -> SentenceAnalysis.WordMeaning in
            guard let token = tokens.first(where: { $0.text == word }) else {
                throw SpeechSurfaceFailure(message: "Missing paragraph lookup fixture")
            }
            return .init(token: token.index, meaning: meaning)
        }
        let paragraphAnalysis = SentenceAnalysis(kind: "sentence", overview: "你好。这是伴语，可以边打字边学英语；输入中文就能查看英文表达，并轻点听发音。", insights: [
            .init(source: "as you type", title: "一边打字，一边学习", explanation: "as you type 表示打字的同时，说明学习与输入一起进行。"),
            .init(source: "to hear its pronunciation", title: "说明点击的目的", explanation: "to hear its pronunciation 表示为了听发音；its 指前面选中的单词或表达。")
        ], expressions: [.init(text: "as usual", source: "as usual", meaning: "像平常一样")],
           wordMeanings: meanings, structure: [.init(start: 0, end: 1, role: .core)])
        var spoken: [String] = []
        var hostActions = 0
        surface.onReadAnalysisText = { spoken.append($0) }
        surface.onAction = { _ in hostActions += 1 }
        surface.onUseEnglish = { hostActions += 1 }
        surface.onUndoEnglish = { hostActions += 1 }
        surface.setHint(text: draft, loading: false, isTranslation: true, canRetry: false)
        surface.setAnalysis(available: true, expanded: true, english: draft, state: .ready(paragraphAnalysis))
        surface.setSpeech(available: true, state: .idle, text: nil, english: draft)
        layout(root, surface)
        let original: StudyReadingTextView = try descendant(surface, "keyboard.analysisOriginal")
        let studyScroll: UIScrollView = try descendant(surface, "keyboard.analysisScroll")
        let lookupWord: UILabel = try descendant(surface, "keyboard.analysisLookupWord")
        let lookupMeaning: UILabel = try descendant(surface, "keyboard.analysisLookupMeaning")
        try expect(original.text == draft && original.attributedText.string == draft,
                   "\(prefix): all three paragraphs, punctuation, blank lines and emoji survive expanded reading unchanged")
        try expect(original.textStorage.length == originalString.length && originalString.length > draft.count,
                   "\(prefix): source coordinates use UTF16 even after a supplementary-plane emoji")
        let firstLine = try characterPoint(in: original, at: 0)
        let secondLine = try characterPoint(in: original, at: originalString.range(of: "This").location)
        try expect(secondLine.y - firstLine.y >= 55,
                   "\(prefix): an intentional empty line remains a visible paragraph gap")
        for token in tokens {
            let font = original.attributedText.attribute(.font, at: token.range.location, effectiveRange: nil) as? UIFont
            let paragraph = original.attributedText.attribute(.paragraphStyle, at: token.range.location, effectiveRange: nil) as? NSParagraphStyle
            try expect(font == UIFont.systemFont(ofSize: 18, weight: .regular) &&
                       paragraph?.minimumLineHeight == 28 && paragraph?.maximumLineHeight == 28,
                       "\(prefix): multi-paragraph token \(token.index) retains 18pt regular text and 28pt line rhythm")
        }
        try render(surface, name: prefix + "-study-paragraphs-top")
        for (word, meaning) in lookupFixtures {
            let range = originalString.range(of: word)
            let point = try characterPoint(in: original, at: range.location)
            let maximum = max(0, studyScroll.contentSize.height - studyScroll.bounds.height)
            studyScroll.setContentOffset(CGPoint(x: 0, y: min(maximum, max(0, original.frame.minY + point.y - 80))), animated: false)
            let offset = studyScroll.contentOffset
            original.readWord(at: point)
            layout(root, surface)
            try expect(original.readingRange(at: point) == range && original.highlightedRange == range &&
                       lookupWord.text == word && lookupMeaning.text == meaning && spoken.last == word,
                       "\(prefix): exact word lookup and reading work in each paragraph, including after emoji")
            try expect(studyScroll.contentOffset == offset && hostActions == 0,
                       "\(prefix): paragraph lookup cannot reposition the reader or alter host text")
        }
        let breaks = lineBreaks(in: original)
        let originalFrame = original.frame
        let originalSize = studyScroll.contentSize
        let focus: UIButton = try descendant(surface, "keyboard.analysisStructureFocus")
        focus.sendActions(for: .touchUpInside)
        layout(root, surface)
        try expect(original.text == draft && lineBreaks(in: original) == breaks &&
                   original.frame == originalFrame && studyScroll.contentSize == originalSize,
                   "\(prefix): structure emphasis preserves paragraph boundaries and layout")

        let acrossParagraphs = "as you type. 😊\n\nYou can"
        original.selectedRange = originalString.range(of: acrossParagraphs)
        original.readSelectedText()
        layout(root, surface)
        try expect(spoken.last == acrossParagraphs && original.highlightedRange == originalString.range(of: acrossParagraphs),
                   "\(prefix): arbitrary selection preserves the exact text across paragraph and UTF16 boundaries")
        original.clearSelection()
        layout(root, surface)

        studyScroll.setContentOffset(CGPoint(x: 0, y: max(0, studyScroll.contentSize.height - studyScroll.bounds.height)), animated: false)
        let explanationOffset = studyScroll.contentOffset
        let sourceButton: UIButton = try descendant(surface, "keyboard.analysisSource.1")
        let returnButton: UIButton = try descendant(surface, "keyboard.analysisReturnToExplanation")
        let spokenCount = spoken.count
        sourceButton.sendActions(for: .touchUpInside)
        layout(root, surface)
        let sourceRange = originalString.range(of: "to hear its pronunciation")
        let sourcePoint = try characterPoint(in: original, at: sourceRange.location)
        try expect(original.highlightedRange == sourceRange &&
                   studyScroll.bounds.contains(original.convert(sourcePoint, to: studyScroll)) && isVisible(returnButton),
                   "\(prefix): explicit source lookup locates the final paragraph without earlier-paragraph offset drift")
        try render(surface, name: prefix + "-study-paragraphs")
        returnButton.sendActions(for: .touchUpInside)
        layout(root, surface)
        try expect(studyScroll.contentOffset == explanationOffset && spoken.count == spokenCount && hostActions == 0,
                   "\(prefix): returning from final-paragraph source restores the exact explanation position without audio or edits")
        surface.setAnalysis(available: true, expanded: false, english: draft, state: .ready(paragraphAnalysis))
        surface.frame.size.height = 260
        layout(root, surface)
        surface.frame.size.height = 440
        surface.setAnalysis(available: true, expanded: true, english: draft, state: .ready(paragraphAnalysis))
        layout(root, surface)
        try expect(studyScroll.contentOffset == .zero && original.text == draft && lineBreaks(in: original) == breaks,
                   "\(prefix): reopening a multi-paragraph draft returns to its greeting with all paragraphs intact")
        surface.setHint(text: english, loading: false, isTranslation: true, canRetry: false)
        surface.setAnalysis(available: true, expanded: true, english: english, state: .ready(analysis))
        surface.setSpeech(available: true, state: .idle, text: nil, english: english)
        layout(root, surface)
        surface.onReadAnalysisText = nil
        surface.onAction = nil
        surface.onUseEnglish = nil
        surface.onUndoEnglish = nil
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
        let lookupWord: UILabel = try descendant(surface, "keyboard.analysisLookupWord")
        let lookupMeaning: UILabel = try descendant(surface, "keyboard.analysisLookupMeaning")
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
        let contextualUp = SentenceAnalysis.tokens(in: english)[4]
        original.readWord(at: try characterPoint(in: original, at: contextualUp.range.location))
        layout(root, surface)
        try expect(lookupWord.text == "up" && lookupMeaning.text == "与 set 连用，表示搭建" && snippets.last == "up",
                   "\(prefix): a phrase-dependent word shows its contextual meaning while reading the exact tapped word")
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
        let beforeAccessibleExpression = snippets.count
        try expect(expressionLabel.accessibilityActivate() && snippets.count == beforeAccessibleExpression + 1 &&
                   snippets.last == "make it up to you" && lookupWord.text == "make it up to you" && lookupMeaning.text == "补偿某人",
                   "\(prefix): accessible phrase title activates its actual source and current contextual meaning")
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
        let sourceButton: UIButton = try descendant(surface, "keyboard.analysisSource.0")
        let returnButton: UIButton = try descendant(surface, "keyboard.analysisReturnToExplanation")
        let explanationOffset = studyScroll.contentOffset
        let explanationSize = studyScroll.contentSize
        let beforeSourceCount = snippets.count
        sourceButton.sendActions(for: .touchUpInside)
        layout(root, surface)
        try expect(isVisible(returnButton) && returnButton.bounds.height >= 44 &&
                   original.highlightedRange == originalText.range(of: "I’d like to"),
                   "\(prefix): explicit source action reveals its exact original excerpt and a usable return control")
        let sourcePoint = try characterPoint(in: original, at: 0)
        let sourceInScroll = original.convert(sourcePoint, to: studyScroll)
        try expect(studyScroll.bounds.contains(sourceInScroll) && snippets.count == beforeSourceCount && hostActions == 0,
                   "\(prefix): looking at source actually brings it into view without reading audio or changing host input")
        try render(surface, name: prefix + "-study-source-focus")
        returnButton.sendActions(for: .touchUpInside)
        layout(root, surface)
        try expect(!isVisible(returnButton) && studyScroll.contentOffset == explanationOffset && studyScroll.contentSize == explanationSize,
                   "\(prefix): return to explanation restores the precise saved offset and full reading geometry")
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

    /// One live surface traverses iPad portrait, landscape, a narrow multitasking
    /// column and back again. This exercises resizing separately from the phone
    /// fixtures, whose intentional overflow assertions require phone widths.
    static func checkPadResizing() async throws {
        let viewports: [(name: String, size: CGSize, normal: CGFloat, study: CGFloat)] = [
            ("portrait", CGSize(width: 810, height: 1080), 314, 540),
            ("landscape", CGSize(width: 1080, height: 810), 314, 405),
            ("split", CGSize(width: 320, height: 810), 263, 360),
            ("portrait-return", CGSize(width: 810, height: 1080), 314, 540)
        ]
        for style in [UIUserInterfaceStyle.light, .dark] {
            let root = UIView(frame: CGRect(origin: .zero, size: viewports[0].size))
            let controller = UIViewController()
            controller.view = root
            let window = UIWindow(frame: root.frame)
            window.rootViewController = controller
            window.overrideUserInterfaceStyle = style
            let surface = KeyboardSurface(frame: CGRect(x: 0, y: 0, width: 810, height: 314))
            surface.overrideUserInterfaceStyle = style
            root.addSubview(surface)
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(100))
            var spoken: [String] = []
            var hostActions = 0
            surface.onReadAnalysisText = { spoken.append($0) }
            surface.onAction = { _ in hostActions += 1 }
            surface.onUseEnglish = { hostActions += 1 }
            surface.onUndoEnglish = { hostActions += 1 }
            surface.setInputLanguage(isChinese: true)
            surface.setHint(text: english, loading: false, isTranslation: true, canRetry: false)
            surface.setHintAction(.useEnglish)
            surface.setSpeech(available: true, state: .idle, text: nil, english: english)
            surface.setAnalysis(available: true, expanded: true, english: english, state: .ready(analysis))
            var wideLineBreaks: [NSRange]?
            for viewport in viewports {
                let prefix = "ipad-\(viewport.name)-\(style == .dark ? "dark" : "light")"
                root.frame.size = viewport.size
                // Resize while learning is still open before checking the
                // collapsed keys: no presentation rebuild may be required.
                surface.frame.size = CGSize(width: viewport.size.width, height: viewport.study)
                layout(root, surface)
                let liveOriginal: StudyReadingTextView = try descendant(surface, "keyboard.analysisOriginal")
                let liveScroll: UIScrollView = try descendant(surface, "keyboard.analysisScroll")
                try expect(liveOriginal.text == english && liveOriginal.bounds.width <= min(680, viewport.size.width) &&
                           liveScroll.contentOffset.y >= 0 &&
                           liveScroll.contentOffset.y <= max(0, liveScroll.contentSize.height - liveScroll.bounds.height),
                           "\(prefix): open learning reflows and clamps its existing scroll position during a live resize")
                surface.frame.size = CGSize(width: viewport.size.width, height: viewport.normal)
                surface.setAnalysis(available: true, expanded: false, english: english, state: .ready(analysis))
                surface.configure(page: .letters, shift: .lower, returnTitle: "发送", showGlobe: false, compact: false)
                for chineseLayout in [KeyboardSurface.ChineseLayout.qwerty, .nineKey] {
                    surface.frame.size.height = viewport.name == "split" && chineseLayout == .nineKey ? 268 : viewport.normal
                    surface.setChineseLayout(chineseLayout)
                    layout(root, surface)
                    let identifiers = chineseLayout == .qwerty
                        ? Array("abcdefghijklmnopqrstuvwxyz").map { "keyboard.key.\($0)" }
                        : (2...9).map { "keyboard.t9.\($0)" }
                    for identifier in identifiers + ["keyboard.space", "keyboard.return", "keyboard.delete"] {
                        let key: UIButton = try descendant(surface, identifier)
                        guard let canvas = key.superview else { throw SpeechSurfaceFailure(message: "Missing key canvas") }
                        try expect(isVisible(key) && key.bounds.width > 0 && key.bounds.height >= 40 &&
                                   canvas.bounds.insetBy(dx: -0.01, dy: -0.01).contains(key.frame),
                                   "\(prefix): \(identifier) remains visible and inside the resized key canvas")
                        let hit = canvas.hitTest(CGPoint(x: key.frame.midX, y: key.frame.midY), with: nil)
                        try expect(hit === key || hit?.isDescendant(of: key) == true,
                                   "\(prefix): \(identifier) retains its own touch target after layout changes")
                    }
                    let typingKey: UIButton = try descendant(surface, chineseLayout == .qwerty ? "keyboard.key.q" : "keyboard.t9.2")
                    let before = hostActions
                    typingKey.sendActions(for: .touchUpInside)
                    try expect(hostActions == before + 1, "\(prefix): each keyboard layout still dispatches typing")
                    if viewport.name != "portrait-return" {
                        try render(surface, name: prefix + (chineseLayout == .qwerty ? "-26keys" : "-9keys"))
                    }
                }
                surface.setChineseLayout(.qwerty)
                surface.frame.size.height = viewport.study
                surface.setAnalysis(available: true, expanded: true, english: english, state: .ready(analysis))
                layout(root, surface)
                let original: StudyReadingTextView = try descendant(surface, "keyboard.analysisOriginal")
                let panel: UIView = try descendant(surface, "keyboard.analysisPanel")
                let studyScroll: UIScrollView = try descendant(surface, "keyboard.analysisScroll")
                let header: UIView = try descendant(surface, "keyboard.header")
                let sourceString = english as NSString
                let hostActionsBeforeReading = hostActions
                try expect(original.text == english && original.attributedText.string == english,
                           "\(prefix): the original survives portrait/landscape/split resizing exactly")
                try expect(original.bounds.width <= 680 && abs(original.frame.midX - panel.bounds.midX) < 0.5 &&
                           studyScroll.contentSize.width == studyScroll.bounds.width,
                           "\(prefix): all reading stays in one centered column without horizontal scrolling")
                if viewport.size.width >= 810 {
                    try expect(original.bounds.width == 680, "\(prefix): wide layouts retain a comfortable 680pt reading measure")
                    let currentBreaks = lineBreaks(in: original)
                    if let wideLineBreaks {
                        try expect(currentBreaks == wideLineBreaks, "\(prefix): returning to a wide layout restores identical line breaks")
                    } else { wideLineBreaks = currentBreaks }
                }
                let font = original.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
                let paragraph = original.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                try expect(font == UIFont.systemFont(ofSize: 18, weight: .regular) &&
                           paragraph?.minimumLineHeight == 28 && paragraph?.maximumLineHeight == 28,
                           "\(prefix): resizing keeps the original 18pt/28pt typography")
                for identifier in ["keyboard.speechToggle", "keyboard.hintAction", "keyboard.analysisToggle"] {
                    let button: UIButton = try descendant(surface, identifier)
                    try expect(isVisible(button) && button.bounds.height == 44 && header.bounds.contains(button.frame),
                               "\(prefix): sentence controls remain visible in the fixed 44pt toolbar")
                }
                let up = sourceString.range(of: "up")
                original.readWord(at: try characterPoint(in: original, at: up.location))
                layout(root, surface)
                let word: UILabel = try descendant(surface, "keyboard.analysisLookupWord")
                let meaning: UILabel = try descendant(surface, "keyboard.analysisLookupMeaning")
                try expect(spoken.last == "up" && original.highlightedRange == up && word.text == "up" &&
                           meaning.text == "与 set 连用，表示搭建",
                           "\(prefix): resized TextKit coordinates still select, read and explain the exact word")
                original.selectedRange = sourceString.range(of: "set up an agent platform")
                original.readSelectedText()
                layout(root, surface)
                try expect(spoken.last == "set up an agent platform", "\(prefix): exact phrase reading survives width changes")
                original.clearSelection()
                layout(root, surface)
                let maximum = max(0, studyScroll.contentSize.height - studyScroll.bounds.height)
                let offset = min(25, maximum)
                studyScroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                let frameBeforeRefresh = original.frame
                surface.setAnalysis(available: true, expanded: true, english: english, state: .ready(analysis))
                surface.setSpeech(available: true, state: .playing, text: "set up an agent platform", english: english)
                layout(root, surface)
                try expect(studyScroll.contentOffset.y == offset && original.frame == frameBeforeRefresh,
                           "\(prefix): repeated analysis and playback updates preserve reading position and layout")
                let explanationOffset = studyScroll.contentOffset
                let showSource: UIButton = try descendant(surface, "keyboard.analysisSource.0")
                let returnToExplanation: UIButton = try descendant(surface, "keyboard.analysisReturnToExplanation")
                showSource.sendActions(for: .touchUpInside)
                layout(root, surface)
                let sourceRange = sourceString.range(of: "I’d like to")
                let sourcePoint = try characterPoint(in: original, at: sourceRange.location)
                try expect(isVisible(returnToExplanation) && original.highlightedRange == sourceRange &&
                           studyScroll.bounds.contains(original.convert(sourcePoint, to: studyScroll)) &&
                           abs(returnToExplanation.frame.maxX - original.frame.maxX) < 0.5,
                           "\(prefix): source focus and its return control stay aligned with the centered reading column")
                returnToExplanation.sendActions(for: .touchUpInside)
                layout(root, surface)
                try expect(studyScroll.contentOffset == explanationOffset,
                           "\(prefix): returning from source restores the explanation's reading position")
                studyScroll.setContentOffset(.zero, animated: false)
                try render(surface, name: prefix + "-study")
                surface.setAnalysis(available: true, expanded: false, english: english, state: .ready(analysis))
                surface.frame.size.height = viewport.normal
                layout(root, surface)
                surface.frame.size.height = viewport.study
                surface.setAnalysis(available: true, expanded: true, english: english, state: .ready(analysis))
                surface.setSpeech(available: true, state: .idle, text: nil, english: english)
                layout(root, surface)
                try expect(studyScroll.contentOffset == .zero && original.frame == frameBeforeRefresh &&
                           original.text == english && original.highlightedRange == nil && hostActions == hostActionsBeforeReading,
                           "\(prefix): collapse/reopen starts at the complete original without blank geometry or host edits")
                studyScroll.setContentOffset(CGPoint(x: 0, y: min(40, max(0, studyScroll.contentSize.height - studyScroll.bounds.height))), animated: false)
            }
            surface.removeFromSuperview()
            window.isHidden = true
            print("iPad resize surface: \(style == .dark ? "dark" : "light") passed")
        }
    }

    static func run() async throws {
        // Snapshot settled native states instead of UIKit's transient button
        // title crossfades while this harness performs several immediate taps.
        let wereAnimationsEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(wereAnimationsEnabled) }
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
                try checkConnectedReading(root: root, surface: surface, prefix: prefix)
                try checkParagraphReading(root: root, surface: surface, prefix: prefix)

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

        try await checkPadResizing()

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
            "iPadResizeViewports": ["810x1080", "1080x810", "320x810", "810x1080"],
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
