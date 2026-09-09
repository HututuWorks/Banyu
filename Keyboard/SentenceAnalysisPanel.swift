import UIKit

/// One reading surface: actual English, selected usage, reusable expressions.
/// Height, network requests and host edits remain owned by the controller.
@MainActor
final class SentenceAnalysisPanel: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    static let learningBackground = AnalysisPalette.background
    static let learningText = AnalysisPalette.text
    var onRetry: (() -> Void)?
    var onRead: ((String) -> Void)?
    var onLookupChanged: ((String?, String?) -> Void)?
    var onScrollChanged: ((Bool) -> Void)?
    var isScrolled: Bool { scroll.contentOffset.y > 2 }
    private let scroll = UIScrollView()
    private let content = UIView()
    private var english = ""
    private var presentation: KeyboardSurface.AnalysisPresentation = .idle
    private var pendingOffset: CGFloat?
    private var blocks: [(view: UIView, top: CGFloat)] = []
    private var readingText: StudyReadingTextView?
    private var readingHint: AnalysisReadingHint?
    private var expressionHeaders: [AnalysisExpressionHeader] = []
    private var speechAvailable = false
    private var speechState: SpeechPlaybackSession.State = .idle
    private var speechText: String?
    private var lookupRange: NSRange?
    private var expressionLookup: (source: String, meaning: String)?
    private var focusedCore = false
    private var structureHeader: AnalysisStructureHeader?
    private var returnOffset: CGFloat?
    private let returnBar = UIView()
    private let returnButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "keyboard.analysisPanel"
        backgroundColor = Self.learningBackground
        isOpaque = true
        clipsToBounds = true
        scroll.accessibilityIdentifier = "keyboard.analysisScroll"
        scroll.accessibilityLabel = "英文、关键用法和实用表达，可上下滑动"
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = true
        scroll.alwaysBounceVertical = false
        scroll.isDirectionalLockEnabled = true
        scroll.delegate = self
        addSubview(scroll)
        scroll.addSubview(content)
        let blankTap = UITapGestureRecognizer(target: self, action: #selector(didTapBackground))
        blankTap.delegate = self
        blankTap.cancelsTouchesInView = false
        scroll.addGestureRecognizer(blankTap)
        returnBar.backgroundColor = AnalysisPalette.background
        returnBar.isHidden = true
        addSubview(returnBar)
        let returnLabel = AnalysisLabel("对应原文", size: 12, lineHeight: 18, color: AnalysisPalette.secondary)
        returnLabel.tag = 71
        returnBar.addSubview(returnLabel)
        returnButton.setTitle("回到讲解", for: .normal)
        returnButton.setImage(UIImage(systemName: "arrow.uturn.backward", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12)), for: .normal)
        returnButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        returnButton.tintColor = AnalysisPalette.blue
        returnButton.accessibilityIdentifier = "keyboard.analysisReturnToExplanation"
        returnButton.accessibilityLabel = "回到讲解，恢复刚才的阅读位置"
        returnButton.addAction(UIAction { [weak self] _ in self?.returnToExplanation() }, for: .touchUpInside)
        returnBar.addSubview(returnButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Only explicit reopening resets reading; ordinary refreshes keep position.
    func beginPresentation() {
        clearLookup()
        returnOffset = nil
        returnBar.isHidden = true
        scroll.setContentOffset(.zero, animated: false)
        pendingOffset = 0
        setNeedsLayout()
    }
    func endPresentation() {
        // Native selection belongs only to the visible learning surface. The
        // shared speech session can continue independently of this view.
        clearLookup()
        returnOffset = nil
        returnBar.isHidden = true
        setNeedsLayout()
    }
    func set(english: String, presentation: KeyboardSurface.AnalysisPresentation) {
        guard self.english != english || self.presentation != presentation else { return }
        let sameEnglish = self.english == english
        pendingOffset = sameEnglish ? scroll.contentOffset.y : 0
        if !sameEnglish {
            clearLookup()
            focusedCore = false
            returnOffset = nil
            returnBar.isHidden = true
        }
        self.english = english
        self.presentation = presentation
        rebuildContent(preservingReading: sameEnglish)
        refreshLookup()
    }
    /// Playback only changes decoration. It must not replace the text view,
    /// native selection or the outer scroll view's reading position.
    func setSpeech(available: Bool, state: SpeechPlaybackSession.State, text: String?) {
        let availabilityChanged = speechAvailable != available
        speechAvailable = available
        speechState = state
        speechText = text
        refreshSpeech()
        if availabilityChanged { setNeedsLayout() }
    }
    private func refreshSpeech() {
        readingText?.readingEnabled = speechAvailable
        readingHint?.available = speechAvailable
        readingHint?.lookupAvailable = true
        readingHint?.hasSelection = readingText?.hasReadableSelection == true
        // Highlights follow explicit word/source actions, not delayed playback
        // callbacks. Clearing a selection must stay cleared while audio finishes.
        for header in expressionHeaders {
            header.setSpeech(available: speechAvailable,
                             state: header.source == speechText ? speechState : .idle)
        }
    }
    private func read(_ text: String) {
        guard speechAvailable, !isHidden, english.range(of: text, options: .literal) != nil else { return }
        onRead?(text)
    }
    private func rebuildContent(preservingReading: Bool) {
        if !preservingReading {
            readingText?.onSelectionChanged = nil
            readingText?.readingEnabled = false
            readingText?.onRead = nil
            readingText?.onWordTapped = nil
            readingText?.onBlankTapped = nil
            readingText?.clearSelection()
            readingHint?.onReadSelection = nil
            readingHint?.onHeightChanged = nil
            readingText = nil
            readingHint = nil
        }
        // An analysis may finish while a reader selects a phrase. Keep the
        // exact original view attached so its responder/selection survives.
        content.subviews.filter { $0 !== readingText && $0 !== readingHint }.forEach { $0.removeFromSuperview() }
        blocks.removeAll(keepingCapacity: true)
        expressionHeaders.forEach { $0.onRead = nil }
        expressionHeaders.removeAll(keepingCapacity: true)
        // Never reconstruct the original from model snippets: punctuation,
        // contractions and order remain exactly as translated.
        if !english.isEmpty {
            let original = readingText ?? StudyReadingTextView(english, color: AnalysisPalette.text,
                                                              highlightColor: AnalysisPalette.selectionFill)
            original.accessibilityIdentifier = "keyboard.analysisOriginal"
            original.onRead = { [weak self] text in self?.read(text) }
            original.onWordTapped = { [weak self] range in
                guard let self, !self.isHidden else { return }
                self.expressionLookup = nil
                self.lookupRange = range
                self.refreshLookup()
            }
            original.onBlankTapped = { [weak self] in self?.clearLookup() }
            original.lookupEnabled = true
            readingText = original
            let ranges: [(range: NSRange, role: SentenceAnalysis.StructureSpan.Role)]
            if case let .ready(analysis) = presentation { ranges = analysis.structureRanges(in: english) }
            else { ranges = [] }
            original.setStructure(ranges, focused: focusedCore)
            let showsReadingHeader = SentenceAnalysis.tokens(in: english).count > 3
            if showsReadingHeader {
                let header = AnalysisStructureHeader()
                header.configure(hasStructure: !ranges.isEmpty, canFocus: ranges.contains { $0.role == .core })
                header.setFocused(focusedCore)
                header.onToggle = { [weak self] in self?.toggleCore() }
                structureHeader = header
                append(header)
            } else { structureHeader = nil }
            append(original, top: showsReadingHeader ? 8 : 0)
            let hint = readingHint ?? AnalysisReadingHint()
            readingHint = hint
            original.onSelectionChanged = { [weak self, weak original] selected in
                guard let self, let original, self.readingText === original else { return }
                self.readingHint?.hasSelection = selected
                if selected {
                    self.lookupRange = nil
                    self.expressionLookup = nil
                    self.onLookupChanged?(nil, nil)
                }
            }
            hint.onReadSelection = { [weak self] in
                guard let self, self.speechAvailable, !self.isHidden else { return }
                self.readingText?.readSelectedText()
            }
            hint.onHeightChanged = { [weak self] in self?.setNeedsLayout() }
        }
        switch presentation {
        case .idle, .loading:
            appendReadingHint()
            append(AnalysisLoadingView(), top: english.isEmpty ? 0 : 18)
        case let .failure(message):
            appendReadingHint()
            append(AnalysisLabel(message, size: 14, lineHeight: 23, color: AnalysisPalette.secondary),
                   top: english.isEmpty ? 0 : 18)
            let retry = UIButton(type: .system)
            retry.setTitle("重新解析", for: .normal)
            retry.titleLabel?.font = .systemFont(ofSize: 14)
            retry.setTitleColor(AnalysisPalette.blue, for: .normal)
            retry.contentHorizontalAlignment = .leading
            retry.accessibilityIdentifier = "keyboard.analysisRetry"
            retry.addAction(UIAction { [weak self] _ in
                guard let self, !self.isHidden, case .failure = self.presentation else { return }
                self.onRetry?()
            }, for: .touchUpInside)
            append(retry, top: 8)
        case let .ready(analysis):
            buildAnalysis(analysis)
        }
        refreshSpeech()
        setNeedsLayout()
    }
    private func buildAnalysis(_ analysis: SentenceAnalysis) {
        if let overview = analysis.overview, !overview.isEmpty {
            let sentence = analysis.kind == "sentence"
            let label = AnalysisLabel(overview, size: 15,
                                      lineHeight: 23,
                                      color: sentence ? AnalysisPalette.secondary : AnalysisPalette.text)
            label.accessibilityIdentifier = "keyboard.analysisOverview"
            append(label, top: 10)
        }
        appendReadingHint()
        if !analysis.insights.isEmpty {
            let section = AnalysisReadingSection(title: analysis.kind == "word" ? "怎么用" : "这句怎么连起来",
                                                  identifier: "keyboard.analysisInsightHeading")
            for (index, insight) in analysis.insights.enumerated() {
                let group = AnalysisVerticalGroup()
                group.accessibilityIdentifier = "keyboard.analysisInsight.\(index)"
                let title = AnalysisInsightButton(insight.title, explanation: insight.explanation, index: index)
                title.accessibilityIdentifier = "keyboard.analysisInsightTitle.\(index)"
                title.onShowSource = { [weak self] in self?.revealSource(insight.source) }
                title.addAction(UIAction { [weak self] _ in
                    guard let self, !self.isHidden else { return }
                    self.clearLookup()
                    self.readingText?.highlight(source: insight.source)
                }, for: .touchUpInside)
                group.append(title)
                section.append(group, top: index == 0 ? 10 : 14)
            }
            append(section, top: 22)
        }
        if !analysis.expressions.isEmpty {
            let section = AnalysisReadingSection(title: "可以这样说", identifier: "keyboard.analysisExpressionHeading")
            section.accessibilityIdentifier = "keyboard.analysisExpressions"
            var visibleCount = 0
            for (index, expression) in analysis.expressions.enumerated() {
                let group = AnalysisVerticalGroup()
                group.backgroundColor = AnalysisPalette.greenFill
                group.layer.cornerRadius = 14
                group.contentInsets = UIEdgeInsets(top: 10, left: 14, bottom: 12, right: 10)
                let repeatsOriginal = expression.text.caseInsensitiveCompare(
                    english.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                let repeatsMeaning = expression.meaning == analysis.overview
                // A standalone word/phrase already has its heading above.
                if !repeatsOriginal {
                    let header = AnalysisExpressionHeader(expression: expression, index: index)
                    header.onRead = { [weak self] source in
                        guard let self, !self.isHidden else { return }
                        self.lookupRange = nil
                        self.expressionLookup = (source, expression.meaning)
                        self.readingText?.highlight(source: source)
                        self.refreshLookup()
                        self.read(source)
                    }
                    expressionHeaders.append(header)
                    group.append(header)
                }
                if !repeatsMeaning {
                    let meaning = AnalysisLabel(expression.meaning, size: 14, lineHeight: 22,
                                                color: AnalysisPalette.secondary)
                    meaning.accessibilityIdentifier = "keyboard.analysisExpressionMeaning.\(index)"
                    group.append(meaning)
                }
                if let usage = expression.usage, !usage.isEmpty,
                   usage != analysis.overview, usage != expression.meaning {
                    let note = AnalysisLabel(usage, size: 14, lineHeight: 22, color: AnalysisPalette.secondary)
                    note.accessibilityIdentifier = "keyboard.analysisExpressionUsage.\(index)"
                    group.append(note, top: repeatsOriginal && repeatsMeaning ? 0 : 3)
                }
                if !group.subviews.isEmpty {
                    section.append(group, top: visibleCount == 0 ? 10 : 8)
                    visibleCount += 1
                }
            }
            if visibleCount > 0 { append(section, top: 22) }
        }
    }
    private func toggleCore() {
        guard case let .ready(analysis) = presentation,
              analysis.structureRanges(in: english).contains(where: { $0.role == .core }) else { return }
        focusedCore.toggle()
        structureHeader?.setFocused(focusedCore)
        readingText?.setStructure(analysis.structureRanges(in: english), focused: focusedCore)
    }
    private func refreshLookup() {
        if let expressionLookup {
            onLookupChanged?(expressionLookup.source, expressionLookup.meaning)
            return
        }
        guard let range = lookupRange, range.location != NSNotFound,
              NSMaxRange(range) <= (english as NSString).length else {
            onLookupChanged?(nil, nil)
            return
        }
        let word = (english as NSString).substring(with: range)
        let meaning: String
        switch presentation {
        case .idle, .loading: meaning = "词义准备中"
        case .failure: meaning = "词义暂不可用"
        case let .ready(analysis): meaning = analysis.meaning(for: range, in: english) ?? "暂无本句词义"
        }
        onLookupChanged?(word, meaning)
    }
    private func clearLookup() {
        lookupRange = nil
        expressionLookup = nil
        readingText?.clearSelection()
        readingText?.clearHighlight()
        onLookupChanged?(nil, nil)
    }
    @objc private func didTapBackground() { clearLookup() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view, current !== scroll {
            if current is UIControl || current is UITextView { return false }
            view = current.superview
        }
        return true
    }
    private func revealSource(_ source: String) {
        guard !isHidden, let readingText, let swiftRange = english.range(of: source, options: .literal) else { return }
        if returnOffset == nil { returnOffset = scroll.contentOffset.y }
        clearLookup()
        readingText.highlight(source: source)
        returnBar.isHidden = false
        pendingOffset = nil
        setNeedsLayout()
        layoutIfNeeded()
        readingText.layoutManager.ensureLayout(for: readingText.textContainer)
        let glyphs = readingText.layoutManager.glyphRange(forCharacterRange: NSRange(swiftRange, in: english), actualCharacterRange: nil)
        let rect = readingText.layoutManager.boundingRect(forGlyphRange: glyphs, in: readingText.textContainer)
        let maximum = max(0, scroll.contentSize.height - scroll.bounds.height)
        scroll.setContentOffset(CGPoint(x: 0, y: min(maximum, max(0, readingText.frame.minY + rect.minY - 12))), animated: false)
    }
    private func returnToExplanation() {
        guard let offset = returnOffset else { return }
        returnOffset = nil
        returnBar.isHidden = true
        clearLookup()
        pendingOffset = offset
        setNeedsLayout()
        layoutIfNeeded()
    }
    private func appendReadingHint() {
        if let readingHint { append(readingHint, top: 12) }
    }
    private func append(_ view: UIView, top: CGFloat = 0) {
        blocks.append((view, top))
        if view.superview !== content { content.addSubview(view) }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep one readable column on a full-width iPad without changing the
        // established type or compact keyboard margins. All reading blocks
        // share this width so explanations remain aligned with their source.
        let minimumInset: CGFloat = bounds.width < 347 ? 10 : 14
        let width = min(680, max(1, bounds.width - minimumInset * 2))
        let inset = max(minimumInset, (bounds.width - width) / 2)
        let navigationHeight: CGFloat = returnBar.isHidden ? 0 : 44
        returnBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 44)
        returnBar.viewWithTag(71)?.frame = CGRect(x: inset, y: 13, width: max(0, width - 122), height: 18)
        returnButton.frame = CGRect(x: max(inset, inset + width - 112), y: 0, width: 112, height: 44)
        scroll.frame = CGRect(x: 0, y: navigationHeight, width: bounds.width, height: max(0, bounds.height - navigationHeight))
        var y: CGFloat = 18
        for block in blocks {
            var height = ceil(block.view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            if block.view is UIButton { height = max(44, height) }
            if height > 0 { y += block.top }
            block.view.frame = CGRect(x: inset, y: y, width: width, height: height)
            y += height
        }
        let contentHeight = max(scroll.bounds.height, y + 24)
        content.frame = CGRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        scroll.contentSize = content.bounds.size
        let maximumOffset = max(0, contentHeight - scroll.bounds.height)
        if let target = pendingOffset {
            scroll.setContentOffset(CGPoint(x: 0, y: min(max(0, target), maximumOffset)), animated: false)
            pendingOffset = nil
        } else if scroll.contentOffset.y > maximumOffset {
            scroll.setContentOffset(CGPoint(x: 0, y: maximumOffset), animated: false)
        }
        onScrollChanged?(isScrolled)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { onScrollChanged?(isScrolled) }
}

/// Read-only TextKit view. It owns only local hit testing and selection; the
/// keyboard controller validates the current host context before any playback.
@MainActor
final class StudyReadingTextView: UITextView, UITextViewDelegate, UIGestureRecognizerDelegate {
    var onRead: ((String) -> Void)?
    var onWordTapped: ((NSRange) -> Void)?
    var onBlankTapped: (() -> Void)?
    var lookupEnabled = false { didSet { updateInteraction() } }
    var onSelectionChanged: ((Bool) -> Void)?
    var hasReadableSelection: Bool { readingEnabled && selectedSource(in: selectedRange) != nil }
    var readingEnabled = false {
        didSet {
            guard readingEnabled != oldValue else { return }
            updateInteraction()
            if !readingEnabled { clearSelection(); if !lookupEnabled { highlight(range: nil) } }
            onSelectionChanged?(hasReadableSelection)
        }
    }
    private let wordTap = UITapGestureRecognizer()
    private let selectionColor: UIColor
    private let originalColor: UIColor
    private var structure: [(range: NSRange, role: SentenceAnalysis.StructureSpan.Role)] = []
    private var focusedCore = false
    private let wordRanges: [NSRange]
    private(set) var highlightedRange: NSRange?

    init(_ english: String, color: UIColor, highlightColor: UIColor) {
        selectionColor = highlightColor
        originalColor = color
        // English contractions and hyphenated compounds are one listening
        // unit; all ranges remain UTF-16, matching UIKit's TextKit coordinates.
        wordRanges = SentenceAnalysis.tokens(in: english).map(\.range)
        // Use TextKit 1 deliberately: the same layout manager is responsible
        // for natural wrapping, glyph hit testing and the rendered highlight.
        let container = NSTextContainer(size: .zero)
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(manager)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = false
        isScrollEnabled = false
        backgroundColor = .clear
        isOpaque = false
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        contentInset = .zero
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bounces = false
        textDragInteraction?.isEnabled = false
        writingToolsBehavior = .none
        delegate = self
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 28
        paragraph.maximumLineHeight = 28
        paragraph.lineBreakMode = .byWordWrapping
        attributedText = NSAttributedString(string: english, attributes: [
            .font: UIFont.systemFont(ofSize: 18, weight: .regular),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
        tintColor = AnalysisPalette.blue
        wordTap.addTarget(self, action: #selector(didTapWord(_:)))
        wordTap.delegate = self
        wordTap.cancelsTouchesInView = false
        wordTap.isEnabled = false
        addGestureRecognizer(wordTap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateInteraction() {
        isSelectable = readingEnabled
        wordTap.isEnabled = readingEnabled || lookupEnabled
        accessibilityHint = lookupEnabled
            ? (readingEnabled ? "轻点单词，听发音并在顶部看本句词义；长按选择短语。" : "轻点单词，在顶部看本句词义。")
            : (readingEnabled ? "轻点单词朗读一次；长按选择短语，然后选择朗读所选。" : nil)
    }

    /// UITextView remains selectable but never becomes an editable input or
    /// requests a keyboard of its own when its selection handles are used.
    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool { false }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool { false }
    func textViewDidChangeSelection(_ textView: UITextView) {
        // Selection only reveals a local control; generating speech requires
        // the user's subsequent explicit tap on that control or the menu.
        onSelectionChanged?(hasReadableSelection)
    }

    func readingRange(at point: CGPoint) -> NSRange? {
        guard bounds.contains(point), textStorage.length > 0 else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let local = CGPoint(x: point.x - textContainerInset.left,
                            y: point.y - textContainerInset.top)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        // glyphIndex returns the nearest glyph even outside the actual text.
        // Reject its empty trailing line space and vertical inter-line space.
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.contains(local) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return wordRanges.first { NSLocationInRange(character, $0) }
    }

    func readWord(at point: CGPoint) {
        guard readingEnabled || lookupEnabled else { return }
        guard let range = readingRange(at: point) else {
            clearSelection()
            clearHighlight()
            onBlankTapped?()
            return
        }
        // A tap on a word after a previous selection starts the new unit.
        selectedRange = NSRange(location: 0, length: 0)
        onSelectionChanged?(false)
        highlight(range: range)
        onWordTapped?(range)
        if readingEnabled { onRead?((text as NSString).substring(with: range)) }
    }

    @objc private func didTapWord(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        readWord(at: gesture.location(in: self))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Native long-press selection and outer vertical scrolling keep their
        // recognizers. A moving touch cannot complete our one-tap recognizer.
        gestureRecognizer === wordTap && otherGestureRecognizer is UITapGestureRecognizer
    }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard readingEnabled, selectedSource(in: range) != nil else { return UIMenu(children: suggestedActions) }
        let read = UIAction(title: "朗读所选", image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in
            self?.readSelectedText()
        }
        read.accessibilityIdentifier = "keyboard.analysisReadSelection"
        return UIMenu(children: [read] + suggestedActions)
    }

    /// Always read the current native selection, never a stale menu snapshot.
    func readSelectedText() {
        guard readingEnabled, let source = selectedSource(in: selectedRange) else { return }
        highlight(range: source.range)
        onRead?(source.text)
    }
    private func selectedSource(in range: NSRange) -> (text: String, range: NSRange)? {
        guard range.location != NSNotFound, range.length > 0,
              range.location <= textStorage.length, range.length <= textStorage.length - range.location,
              let swiftRange = Range(range, in: text) else { return nil }
        let source = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains),
              let exact = text.range(of: source, options: .literal, range: swiftRange) else { return nil }
        return (source, NSRange(exact, in: text))
    }

    func clearSelection() {
        selectedRange = NSRange(location: 0, length: 0)
        onSelectionChanged?(false)
        if isFirstResponder { resignFirstResponder() }
    }
    func highlight(source: String) {
        let original = text as NSString
        if let highlightedRange, NSMaxRange(highlightedRange) <= original.length,
           original.substring(with: highlightedRange) == source { return }
        let range = original.range(of: source, options: .literal)
        guard range.location != NSNotFound, range.length > 0 else { return }
        highlight(range: range)
    }
    func clearHighlight() { highlight(range: nil) }

    func setStructure(_ ranges: [(range: NSRange, role: SentenceAnalysis.StructureSpan.Role)], focused: Bool) {
        structure = ranges.filter { $0.range.location != NSNotFound && $0.range.length > 0 && NSMaxRange($0.range) <= textStorage.length }
        focusedCore = focused
        applyDecoration()
    }
    private func highlight(range: NSRange?) {
        guard range != highlightedRange else { return }
        highlightedRange = range
        applyDecoration()
    }
    private func applyDecoration() {
        // Only paint attributes change. Font, paragraph style, source string,
        // selection, line wrapping and character positions remain untouched.
        let whole = NSRange(location: 0, length: textStorage.length)
        guard whole.length > 0 else { return }
        textStorage.beginEditing()
        textStorage.removeAttribute(.backgroundColor, range: whole)
        textStorage.addAttribute(.foregroundColor, value: originalColor, range: whole)
        for span in structure {
            switch span.role {
            case .core:
                textStorage.addAttribute(.foregroundColor, value: AnalysisPalette.blue, range: span.range)
                if focusedCore { textStorage.addAttribute(.backgroundColor, value: AnalysisPalette.blueFill, range: span.range) }
            case .supplement:
                if focusedCore { textStorage.addAttribute(.foregroundColor, value: AnalysisPalette.secondary, range: span.range) }
                else { textStorage.addAttribute(.backgroundColor, value: AnalysisPalette.sandFill, range: span.range) }
            }
        }
        if let range = highlightedRange, NSMaxRange(range) <= textStorage.length {
            textStorage.addAttribute(.backgroundColor, value: selectionColor, range: range)
            textStorage.addAttribute(.foregroundColor, value: AnalysisPalette.selectionText, range: range)
        }
        textStorage.endEditing()
    }
}

@MainActor
private final class AnalysisReadingHint: UIView {
    var available = false { didSet { updateVisibility() } }
    var lookupAvailable = false { didSet { updateVisibility() } }
    var hasSelection = false { didSet { updateVisibility() } }
    var onReadSelection: (() -> Void)?
    var onHeightChanged: (() -> Void)?
    private var measuredHeight: CGFloat = 0
    private let label = AnalysisLabel("轻点听词、看词义 · 长按选择短语", size: 11, lineHeight: 18, color: AnalysisPalette.secondary)
    private let readSelection = UIButton(type: .system)
    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "keyboard.analysisReadingHint"
        addSubview(label)
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "speaker.wave.2", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13))
        configuration.imagePadding = 6
        var titleAttributes = AttributeContainer()
        titleAttributes.font = UIFont.systemFont(ofSize: 12)
        configuration.attributedTitle = AttributedString("朗读所选", attributes: titleAttributes)
        configuration.contentInsets = .zero
        configuration.baseForegroundColor = AnalysisPalette.blue
        readSelection.configuration = configuration
        readSelection.contentHorizontalAlignment = .leading
        readSelection.accessibilityIdentifier = "keyboard.analysisReadSelectionButton"
        readSelection.accessibilityLabel = "朗读所选"
        readSelection.accessibilityHint = "只朗读当前选中的英文，读一遍自动停止。"
        readSelection.addAction(UIAction { [weak self] _ in
            guard let self, self.available, self.hasSelection, !self.readSelection.isHidden else { return }
            self.onReadSelection?()
        }, for: .touchUpInside)
        addSubview(readSelection)
        updateVisibility()
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func updateVisibility() {
        label.text = available ? "轻点听词、看词义 · 长按选择短语" : "轻点单词，看本句词义"
        label.isHidden = (!available && !lookupAvailable) || hasSelection
        readSelection.isHidden = !available || !hasSelection
        readSelection.isEnabled = available && hasSelection
        let height: CGFloat = available && hasSelection ? 44 : (available || lookupAvailable ? 18 : 0)
        if height != measuredHeight {
            measuredHeight = height
            setNeedsLayout()
            onHeightChanged?()
        }
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: measuredHeight) }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 18)
        readSelection.frame = CGRect(x: 0, y: 0, width: min(120, bounds.width), height: 44)
    }
}

@MainActor
private final class AnalysisStructureHeader: UIView {
    var onToggle: (() -> Void)?
    private let title = AnalysisLabel("原句 · 结构", size: 12, lineHeight: 18, color: AnalysisPalette.secondary)
    private let legend = AnalysisLabel("● 主干  ● 补充", size: 11, lineHeight: 18, color: AnalysisPalette.secondary)
    private let focus = UIButton(type: .system)
    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(title)
        addSubview(legend)
        focus.titleLabel?.font = .systemFont(ofSize: 12)
        focus.tintColor = AnalysisPalette.blue
        focus.contentHorizontalAlignment = .trailing
        focus.accessibilityIdentifier = "keyboard.analysisStructureFocus"
        focus.addAction(UIAction { [weak self] _ in self?.onToggle?() }, for: .touchUpInside)
        addSubview(focus)
        let legendText = NSMutableAttributedString(attributedString: legend.attributedText!)
        legendText.addAttribute(.foregroundColor, value: AnalysisPalette.blue, range: NSRange(location: 0, length: 4))
        legendText.addAttribute(.foregroundColor, value: AnalysisPalette.sand, range: NSRange(location: 6, length: 4))
        legend.attributedText = legendText
        setFocused(false)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(hasStructure: Bool, canFocus: Bool) {
        focus.isHidden = !canFocus
        focus.isEnabled = canFocus
        legend.isHidden = !hasStructure
        title.isHidden = hasStructure
    }
    func setFocused(_ value: Bool) {
        focus.setTitle(value ? "显示完整结构" : "点亮主干", for: .normal)
        focus.accessibilityValue = value ? "已点亮主干" : "完整结构"
        focus.accessibilityTraits = value ? [.button, .selected] : [.button]
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: 44) }
    override func layoutSubviews() {
        super.layoutSubviews()
        title.frame = CGRect(x: 0, y: 11, width: max(0, bounds.width - 110), height: 18)
        focus.frame = CGRect(x: max(0, bounds.width - 110), y: 0, width: 110, height: 44)
        legend.frame = CGRect(x: 0, y: 11, width: max(0, bounds.width - 110), height: 18)
    }
}

@MainActor
private final class AnalysisInsightButton: UIControl {
    var onShowSource: (() -> Void)?
    private let label: AnalysisLabel
    private let explanation: AnalysisLabel
    private let accent = UIView()
    private let sourceButton = UIButton(type: .system)
    init(_ title: String, explanation: String, index: Int) {
        label = AnalysisLabel(title, size: 15, lineHeight: 23, color: AnalysisPalette.text, weight: .medium)
        self.explanation = AnalysisLabel(explanation, size: 14, lineHeight: 22, color: AnalysisPalette.secondary)
        super.init(frame: .zero)
        backgroundColor = AnalysisPalette.paper
        layer.cornerRadius = 14
        accent.backgroundColor = AnalysisPalette.blueFill
        accent.layer.cornerRadius = 2
        addSubview(accent)
        addSubview(label)
        self.explanation.accessibilityIdentifier = "keyboard.analysisInsightExplanation.\(index)"
        addSubview(self.explanation)
        sourceButton.setTitle("看原文", for: .normal)
        sourceButton.titleLabel?.font = .systemFont(ofSize: 12)
        sourceButton.tintColor = AnalysisPalette.blue
        sourceButton.contentHorizontalAlignment = .trailing
        sourceButton.accessibilityIdentifier = "keyboard.analysisSource.\(index)"
        sourceButton.accessibilityLabel = "看原文，\(title)"
        sourceButton.addAction(UIAction { [weak self] _ in self?.onShowSource?() }, for: .touchUpInside)
        addSubview(sourceButton)
        isAccessibilityElement = false
        label.isAccessibilityElement = true
        label.accessibilityHint = "\(explanation)"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = max(1, size.width - 36)
        let heading = max(44, ceil(label.sizeThatFits(CGSize(width: max(1, width - 64), height: .greatestFiniteMagnitude)).height))
        let body = ceil(explanation.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        return CGSize(width: size.width, height: 10 + heading + body + 15)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(1, bounds.width - 36)
        let titleHeight = ceil(label.sizeThatFits(CGSize(width: max(1, width - 64), height: .greatestFiniteMagnitude)).height)
        let heading = max(44, titleHeight)
        accent.frame = CGRect(x: 10, y: 17, width: 3, height: max(0, bounds.height - 34))
        label.frame = CGRect(x: 22, y: 10 + (heading - titleHeight) / 2, width: max(1, width - 64), height: titleHeight)
        sourceButton.frame = CGRect(x: bounds.width - 76, y: 10, width: 62, height: 44)
        explanation.frame = CGRect(x: 22, y: 10 + heading, width: width, height: max(0, bounds.height - 25 - heading))
    }
}

@MainActor
private final class AnalysisExpressionHeader: UIControl {
    let source: String
    var onRead: ((String) -> Void)?
    private let label: AnalysisActionLabel
    private let speaker = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    init(expression: SentenceAnalysis.Expression, index: Int) {
        source = expression.source
        label = AnalysisActionLabel(expression.text, size: 16, lineHeight: 24,
                              color: AnalysisPalette.teal, weight: .medium)
        super.init(frame: .zero)
        label.accessibilityIdentifier = "keyboard.analysisExpressionText.\(index)"
        label.onActivate = { [weak self] in
            guard let self else { return }
            self.onRead?(self.source)
        }
        label.isUserInteractionEnabled = true
        label.accessibilityTraits = .button
        label.accessibilityHint = "查看本句意思，并朗读原句中的表达。"
        label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapExpression)))
        speaker.accessibilityIdentifier = "keyboard.analysisExpressionSpeaker.\(index)"
        speaker.accessibilityHint = "读一遍自动停止，再点可停止当前朗读。"
        speaker.addAction(UIAction { [weak self] _ in
            guard let self, !self.speaker.isHidden, self.speaker.isEnabled else { return }
            self.onRead?(self.source)
        }, for: .touchUpInside)
        spinner.isUserInteractionEnabled = false
        spinner.hidesWhenStopped = true
        spinner.color = AnalysisPalette.blue
        spinner.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
        addSubview(label)
        addSubview(speaker)
        speaker.addSubview(spinner)
        setSpeech(available: false, state: .idle)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func tapExpression() { onRead?(source) }
    func setSpeech(available: Bool, state: SpeechPlaybackSession.State) {
        label.accessibilityHint = available ? "查看本句意思，并朗读原句中的表达。" : "查看本句意思。"
        speaker.isHidden = !available
        speaker.isEnabled = available
        let loading = available && state == .loading
        let playing = available && state == .playing
        speaker.setImage(loading ? nil : UIImage(systemName: "speaker.wave.2",
                                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)), for: .normal)
        speaker.tintColor = playing ? AnalysisPalette.blue : AnalysisPalette.secondary
        speaker.accessibilityLabel = loading ? "取消朗读 \(source)" : playing ? "停止朗读 \(source)" : "朗读 \(source)"
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        setNeedsLayout()
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = max(1, size.width - (speaker.isHidden ? 0 : 48))
        return CGSize(width: size.width, height: max(44, ceil(label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(1, bounds.width - (speaker.isHidden ? 0 : 48))
        label.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        speaker.frame = speaker.isHidden ? .zero : CGRect(x: bounds.width - 44, y: 0, width: 44, height: 44)
        spinner.center = CGPoint(x: 22, y: 22)
    }
}

@MainActor
private enum AnalysisPalette {
    static let background = color(light: 0xEEF3F6, dark: 0x19232B)
    static let text = color(light: 0x202631, dark: 0xEDF0F6)
    static let secondary = color(light: 0x626D7C, dark: 0xABB5C4)
    static let blue = color(light: 0x3669AA, dark: 0x9EBEF0)
    static let teal = color(light: 0x26766D, dark: 0x8DC8BC)
    static let paper = color(light: 0xF8FAFB, dark: 0x222E37)
    static let blueFill = color(light: 0xDCE8F0, dark: 0x2B465B)
    static let sandFill = color(light: 0xEAE3D7, dark: 0x403D36)
    static let sand = color(light: 0x927A54, dark: 0xC7B493)
    static let greenFill = color(light: 0xE5EFEB, dark: 0x223C37)
    static let selectionFill = color(light: 0x456B86, dark: 0xB8D4E8)
    static let selectionText = color(light: 0xF7FAFC, dark: 0x162B3B)
    private static func color(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        }
    }
}

@MainActor
private class AnalysisLabel: UILabel {
    init(_ text: String, size: CGFloat, lineHeight: CGFloat, color: UIColor = AnalysisPalette.text,
         weight: UIFont.Weight = .regular) {
        super.init(frame: .zero)
        font = .systemFont(ofSize: size, weight: weight)
        textColor = color
        numberOfLines = 0
        lineBreakMode = .byWordWrapping
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.lineBreakMode = .byWordWrapping
        attributedText = NSAttributedString(string: text, attributes: [.font: font!, .paragraphStyle: paragraph])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Explicit activation keeps VoiceOver and touch on the same source action.
@MainActor
private final class AnalysisActionLabel: AnalysisLabel {
    var onActivate: (() -> Void)?
    override func accessibilityActivate() -> Bool {
        guard !isHidden, isUserInteractionEnabled, let onActivate else { return false }
        onActivate()
        return true
    }
}

@MainActor
private class AnalysisVerticalGroup: UIView {
    private var rows: [(view: UIView, top: CGFloat)] = []
    var contentInsets: UIEdgeInsets = .zero
    func append(_ view: UIView, top: CGFloat = 0) { rows.append((view, top)); addSubview(view) }
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let innerWidth = max(1, width - contentInsets.left - contentInsets.right)
        var y: CGFloat = contentInsets.top
        for row in rows {
            y += row.top
            let height = ceil(row.view.sizeThatFits(CGSize(width: innerWidth, height: .greatestFiniteMagnitude)).height)
            if apply { row.view.frame = CGRect(x: contentInsets.left, y: y, width: innerWidth, height: height) }
            y += height
        }
        return y + contentInsets.bottom
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: arrange(width: size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = arrange(width: bounds.width, apply: true) }
}

@MainActor
private final class AnalysisReadingSection: AnalysisVerticalGroup {
    init(title: String, identifier: String) {
        super.init(frame: .zero)
        let heading = AnalysisLabel(title, size: 12, lineHeight: 18, color: AnalysisPalette.secondary, weight: .medium)
        heading.accessibilityIdentifier = identifier
        append(heading)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class AnalysisLoadingView: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = AnalysisLabel("正在整理用法…", size: 14, lineHeight: 23, color: AnalysisPalette.secondary)
    override init(frame: CGRect) {
        super.init(frame: frame)
        spinner.startAnimating()
        addSubview(spinner)
        addSubview(label)
        accessibilityIdentifier = "keyboard.analysisLoading"
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: 44) }
    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.frame = CGRect(x: 0, y: 11, width: 22, height: 22)
        label.frame = CGRect(x: 30, y: 0, width: max(0, bounds.width - 30), height: 44)
    }
}
