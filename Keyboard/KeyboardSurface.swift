// Keyboard row/key organization was informed by:
// https://github.com/aminbenarieb/translatekb/blob/main/Keyboard/Sources/Views/KeyboardLayoutView.swift
// https://github.com/aminbenarieb/translatekb/blob/main/Keyboard/Sources/Views/KeyView.swift
// Copyright (c) 2026 Amin Benarieb, MIT License; see THIRD_PARTY_NOTICES.md.
// This UIKit implementation adds reusable candidates, Chinese nine-key input,
// proportional QWERTY geometry, touch expansion and native input-mode switching.

import UIKit

/// A one-line viewport with the toolbar's full 44 pt vertical swipe target.
/// Horizontal hit bounds stay inside the English area, clear of its actions.
@MainActor
private final class KeyboardHintScrollView: UIScrollView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let extra = max(0, (44 - bounds.height) / 2)
        return bounds.insetBy(dx: 0, dy: -extra).contains(point)
    }
}

@MainActor
final class KeyboardSurface: UIView {
    enum Page { case letters, numbers, symbols }
    enum Shift { case lower, upper, locked }
    enum ChineseLayout { case qwerty, nineKey }
    enum HintAction { case none, useEnglish, undoEnglish }
    enum AnalysisPresentation: Equatable {
        case idle, loading, ready(SentenceAnalysis), failure(String)
    }
    enum Action {
        case insert(String), delete, shift, numbers, symbols, letters, toggleLanguage, space, `return`
        case t9Digit(String), separator
    }

    var onAction: ((Action) -> Void)?
    var onDeletePressed: (() -> Void)?
    var onDeleteReleased: (() -> Void)?
    var onRetry: (() -> Void)?
    var onUseEnglish: (() -> Void)?
    var onUndoEnglish: (() -> Void)?
    var onToggleAnalysis: (() -> Void)?
    var onRetryAnalysis: (() -> Void)?
    var onToggleSpeech: (() -> Void)?
    var onReadAnalysisText: ((String) -> Void)?
    var configureGlobe: ((UIButton) -> Void)? {
        didSet { if let globeKey { configureGlobe?(globeKey) } }
    }
    private let mainStack = UIStackView()
    private let canvas = KeyboardCanvas()
    private let hintLabel = UILabel()
    private let hintScroll = KeyboardHintScrollView()
    private let header = UIView()
    private var hintIsTranslation = false
    private var hintIsLoading = false
    private var hintCanRetry = false
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private let hintActionButton = UIButton(type: .system)
    private var hintAction: HintAction = .none
    private let analysisButton = UIButton(type: .system)
    private let speechButton = UIButton(type: .system)
    private let sentenceSpeechLabel = UILabel()
    private let speechSpinner = UIActivityIndicatorView(style: .medium)
    private var speechAvailable = false
    private var speechIsLoading = false
    private let speechErrorToast = UIView()
    private let speechErrorLabel = UILabel()
    private var speechErrorDismissal: Task<Void, Never>?
    private var lastSpeechFailure: String?
    private var lastSpeechFailureText: String?
    private let analysisTitleLabel = UILabel()
    private let analysisLookupWordLabel = UILabel()
    private let analysisLookupMeaningLabel = UILabel()
    private let analysisLookupMeaningScroll = UIScrollView()
    private var lookupWord: String?
    private var lookupMeaning: String?
    private let analysisPanel = SentenceAnalysisPanel()
    private let headerDivider = UIView()
    private var analysisAvailable = false
    private var analysisExpanded = false
    private let preeditLabel = UILabel()
    private let emptyCandidatesLabel = UILabel()
    private let candidateList = KeyboardCandidateList(fontSize: 21, horizontalPadding: 12)
    private let spellingList = KeyboardCandidateList(fontSize: 15, horizontalPadding: 12)
    private var page: Page = .letters
    private var shift: Shift = .lower
    private var chineseLayout: ChineseLayout = .qwerty
    private var returnTitle = "换行"
    private var returnIsActive = true
    private var showGlobe = true
    private var compact = false
    private var isChinese = false
    private var letterKeys: [(KeyboardKey, String)] = []
    private var shiftKey: KeyboardKey?
    private var returnKey: KeyboardKey?
    private var languageKey: KeyboardKey?
    private var globeKey: KeyboardKey?
    private var chooseSpellingKey: KeyboardKey?
    private var compositionText = ""
    private var compositionUnavailable = false
    private var compositionCandidates: [String] = []
    private var spellingOptions: [String] = []
    private var showingSpellings = false
    private let surfaceColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.systemGray5.resolvedColor(with: traits)
            : UIColor(red: 209 / 255, green: 213 / 255, blue: 219 / 255, alpha: 1)
    }
    private let utilityColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.systemGray3.resolvedColor(with: traits)
            : UIColor(red: 173 / 255, green: 180 / 255, blue: 192 / 255, alpha: 1)
    }
    private let hintActionColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 164 / 255, green: 173 / 255, blue: 187 / 255, alpha: 1)
            : UIColor(red: 81 / 255, green: 91 / 255, blue: 104 / 255, alpha: 1)
    }
    private let translationTextColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 233 / 255, green: 236 / 255, blue: 240 / 255, alpha: 1)
            : UIColor(red: 41 / 255, green: 49 / 255, blue: 60 / 255, alpha: 1)
    }
    private let accent = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.67, green: 0.64, blue: 1, alpha: 1)
        : UIColor(red: 0.36, green: 0.34, blue: 0.81, alpha: 1) }
    private var usesNineKey: Bool { isChinese && chineseLayout == .nineKey && page == .letters }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "keyboard.surface"
        backgroundColor = surfaceColor
        mainStack.axis = .vertical
        mainStack.spacing = 4
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        buildHeader()
        mainStack.addArrangedSubview(canvas)
        analysisPanel.isHidden = true
        analysisPanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(analysisPanel)
        // The stack resolves the canvas after this view's own layout pass.
        // Anchors keep learning in the current key area during every resize.
        NSLayoutConstraint.activate([
            analysisPanel.topAnchor.constraint(equalTo: canvas.topAnchor),
            analysisPanel.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            analysisPanel.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            analysisPanel.bottomAnchor.constraint(equalTo: canvas.bottomAnchor)
        ])
        analysisPanel.onRetry = { [weak self] in self?.onRetryAnalysis?() }
        analysisPanel.onRead = { [weak self] text in
            guard let self, self.analysisExpanded, self.speechAvailable else { return }
            self.onReadAnalysisText?(text)
        }
        analysisPanel.onScrollChanged = { [weak self] scrolled in
            guard let self else { return }
            self.headerDivider.isHidden = self.analysisPanel.isHidden || !scrolled
        }
        analysisPanel.onLookupChanged = { [weak self] word, meaning in
            guard let self else { return }
            self.lookupWord = word
            self.lookupMeaning = meaning
            self.updateLookupPresentation()
            self.setNeedsLayout()
        }
        buildSpeechErrorToast()
        rebuildKeys()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildHeader() {
        header.accessibilityIdentifier = "keyboard.header"
        header.heightAnchor.constraint(equalToConstant: 44).isActive = true
        mainStack.addArrangedSubview(header)
        [hintScroll, preeditLabel, candidateList, spellingList, emptyCandidatesLabel,
         spinner, retryButton, hintActionButton, speechButton, analysisButton, analysisTitleLabel,
         analysisLookupWordLabel, analysisLookupMeaningScroll, headerDivider].forEach { header.addSubview($0) }
        headerDivider.backgroundColor = .separator
        headerDivider.isUserInteractionEnabled = false
        headerDivider.isHidden = true
        hintScroll.addSubview(hintLabel)
        hintScroll.showsVerticalScrollIndicator = true
        hintScroll.showsHorizontalScrollIndicator = false
        hintScroll.alwaysBounceVertical = false
        hintScroll.isDirectionalLockEnabled = true
        hintScroll.decelerationRate = .fast
        hintScroll.contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            // System scroll-edge blur can cover this entire one-line viewport.
            // The fixed toolbar needs crisp text even when more lines follow.
            hintScroll.topEdgeEffect.isHidden = true
            hintScroll.bottomEdgeEffect.isHidden = true
        }
        hintScroll.accessibilityIdentifier = "keyboard.hintScroll"
        hintLabel.numberOfLines = 0
        hintLabel.font = .systemFont(ofSize: 14, weight: .regular)
        hintLabel.textColor = .secondaryLabel
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.lineBreakStrategy = []
        hintLabel.adjustsFontSizeToFitWidth = false
        hintLabel.allowsDefaultTighteningForTruncation = false
        hintLabel.text = "输入后显示英文"
        hintLabel.accessibilityIdentifier = "keyboard.englishHint"
        hintLabel.accessibilityHint = "上下滑动可查看完整内容"
        spinner.hidesWhenStopped = true
        spinner.tintColor = accent
        retryButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        retryButton.accessibilityLabel = "重试英文提示"
        retryButton.tintColor = accent
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)
        hintActionButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .regular)
        hintActionButton.setTitleColor(hintActionColor, for: .normal)
        hintActionButton.tintColor = hintActionColor
        hintActionButton.accessibilityIdentifier = "keyboard.hintAction"
        hintActionButton.addAction(UIAction { [weak self] _ in
            guard let self, !self.hintActionButton.isHidden else { return }
            switch self.hintAction {
            case .none: break
            case .useEnglish: self.onUseEnglish?()
            case .undoEnglish: self.onUndoEnglish?()
            }
        }, for: .touchUpInside)
        speechButton.accessibilityIdentifier = "keyboard.speechToggle"
        speechButton.tintColor = hintActionColor
        sentenceSpeechLabel.text = "整句"
        sentenceSpeechLabel.font = .systemFont(ofSize: 11, weight: .regular)
        sentenceSpeechLabel.textColor = hintActionColor
        sentenceSpeechLabel.isUserInteractionEnabled = false
        sentenceSpeechLabel.isAccessibilityElement = false
        sentenceSpeechLabel.accessibilityIdentifier = "keyboard.speechScope"
        sentenceSpeechLabel.isHidden = true
        speechButton.addSubview(sentenceSpeechLabel)
        speechButton.addAction(UIAction { [weak self] _ in
            guard let self, !self.speechButton.isHidden else { return }
            self.dismissSpeechError()
            self.onToggleSpeech?()
        }, for: .touchUpInside)
        speechSpinner.accessibilityIdentifier = "keyboard.speechLoading"
        speechSpinner.isAccessibilityElement = false
        speechSpinner.isUserInteractionEnabled = false
        speechSpinner.hidesWhenStopped = true
        speechSpinner.color = hintActionColor
        speechSpinner.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
        speechButton.addSubview(speechSpinner)
        setSpeech(available: false, state: .idle)
        analysisButton.tintColor = hintActionColor
        analysisButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .regular)
        analysisButton.setTitleColor(hintActionColor, for: .normal)
        analysisButton.accessibilityIdentifier = "keyboard.analysisToggle"
        analysisButton.addAction(UIAction { [weak self] _ in
            guard let self, !self.analysisButton.isHidden else { return }
            self.onToggleAnalysis?()
        }, for: .touchUpInside)
        analysisTitleLabel.text = "英语学习"
        analysisTitleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        analysisTitleLabel.textColor = SentenceAnalysisPanel.learningText
        analysisTitleLabel.accessibilityIdentifier = "keyboard.analysisTitle"
        analysisLookupWordLabel.font = .systemFont(ofSize: 14, weight: .medium)
        analysisLookupWordLabel.textColor = SentenceAnalysisPanel.learningText
        // The full word remains in the original; a long title must never push
        // the sentence/replacement controls outside their fixed touch bounds.
        analysisLookupWordLabel.lineBreakMode = .byTruncatingTail
        analysisLookupWordLabel.adjustsFontSizeToFitWidth = false
        analysisLookupWordLabel.accessibilityIdentifier = "keyboard.analysisLookupWord"
        analysisLookupMeaningLabel.font = .systemFont(ofSize: 12, weight: .regular)
        analysisLookupMeaningLabel.textColor = hintActionColor
        analysisLookupMeaningLabel.numberOfLines = 1
        analysisLookupMeaningLabel.adjustsFontSizeToFitWidth = false
        analysisLookupMeaningLabel.accessibilityIdentifier = "keyboard.analysisLookupMeaning"
        analysisLookupMeaningScroll.addSubview(analysisLookupMeaningLabel)
        analysisLookupMeaningScroll.showsVerticalScrollIndicator = false
        analysisLookupMeaningScroll.showsHorizontalScrollIndicator = true
        analysisLookupMeaningScroll.alwaysBounceHorizontal = false
        analysisLookupMeaningScroll.contentInsetAdjustmentBehavior = .never
        analysisLookupMeaningScroll.accessibilityIdentifier = "keyboard.analysisLookupMeaningScroll"
        if #available(iOS 26.0, *) {
            analysisLookupMeaningScroll.topEdgeEffect.isHidden = true
            analysisLookupMeaningScroll.bottomEdgeEffect.isHidden = true
            analysisLookupMeaningScroll.leftEdgeEffect.isHidden = true
            analysisLookupMeaningScroll.rightEdgeEffect.isHidden = true
        }
        preeditLabel.font = .systemFont(ofSize: 11)
        preeditLabel.textColor = .secondaryLabel
        preeditLabel.lineBreakMode = .byTruncatingHead
        preeditLabel.accessibilityIdentifier = "keyboard.composition"
        emptyCandidatesLabel.font = .systemFont(ofSize: 14)
        emptyCandidatesLabel.textColor = .secondaryLabel
        emptyCandidatesLabel.isUserInteractionEnabled = false
        candidateList.accessibilityIdentifier = "keyboard.candidates"
        candidateList.accessibilityPrefix = "候选词"
        spellingList.accessibilityIdentifier = "keyboard.spellings"
        spellingList.accessibilityPrefix = "拼音"
        updateCompositionPresentation()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // One fixed header reserves independent space for every visible control.
        // Changing its content cannot move or rebuild the keys below it.
        // Match the stack's two 4 pt edge constraints without depending on
        // whether its arranged header has completed this layout pass yet.
        let headerWidth = max(0, bounds.width - 8)
        var trailing = headerWidth
        func place(_ control: UIView, width: CGFloat) {
            guard !control.isHidden else { control.frame = .zero; return }
            trailing -= width
            control.frame = CGRect(x: trailing, y: 0, width: width, height: 44)
        }
        place(analysisButton, width: 44)
        place(hintActionButton, width: 56)
        place(speechButton, width: analysisPanel.isHidden ? 44 : 52)
        place(retryButton, width: 32)
        place(spinner, width: 24)
        // Adjacent full-sized targets leave the maximum width for English.
        // Only the boundary between reading and controls needs a visual gap.
        if trailing < headerWidth { trailing -= 4 }
        speechSpinner.center = CGPoint(x: analysisPanel.isHidden ? speechButton.bounds.midX : 8,
                                       y: speechButton.bounds.midY)
        sentenceSpeechLabel.frame = CGRect(x: 27, y: 12, width: 24, height: 20)
        let contentWidth = max(0, trailing)
        analysisTitleLabel.frame = CGRect(x: 14, y: 0, width: max(0, contentWidth - 22), height: 44)
        let lookupWidth = max(0, contentWidth - 22)
        analysisLookupWordLabel.frame = CGRect(x: 14, y: 2, width: lookupWidth, height: 19)
        analysisLookupMeaningScroll.frame = CGRect(x: 14, y: 23, width: lookupWidth, height: 18)
        let meaningWidth = max(lookupWidth, ceil(analysisLookupMeaningLabel.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: 18)).width))
        analysisLookupMeaningLabel.frame = CGRect(x: 0, y: 0, width: meaningWidth, height: 16)
        analysisLookupMeaningScroll.contentSize = CGSize(width: meaningWidth, height: 18)
        analysisLookupMeaningScroll.isScrollEnabled = meaningWidth > lookupWidth
        analysisLookupMeaningLabel.accessibilityHint = meaningWidth > lookupWidth ? "左右滑动可查看完整词义" : nil
        headerDivider.frame = CGRect(x: 14, y: 43.5, width: max(0, headerWidth - 28), height: 0.5)
        let hintLeading: CGFloat = hintIsTranslation ? 10 : 8
        // The control placement already reserves a 4 pt gap. Do not deduct a
        // second right padding from the English's available reading width.
        let hintWidth = max(0, contentWidth - hintLeading - (hintIsTranslation ? 0 : 8))
        let lineHeight = hintIsTranslation ? max(20, hintLabel.font.lineHeight) : hintLabel.font.lineHeight
        let viewportHeight = hintIsTranslation ? ceil(lineHeight) : min(40, ceil(lineHeight * 2))
        hintScroll.frame = CGRect(x: hintLeading, y: (44 - viewportHeight) / 2,
                                  width: hintWidth, height: viewportHeight)
        // Keep the original single-line rhythm at the same font size. Text may
        // wrap into any number of lines, reached by vertical, line-sized paging.
        let measured = hintLabel.sizeThatFits(CGSize(width: hintWidth, height: .greatestFiniteMagnitude))
        let textHeight = hintIsTranslation
            ? max(viewportHeight, ceil(measured.height / viewportHeight) * viewportHeight)
            : max(viewportHeight, ceil(measured.height))
        hintLabel.frame = CGRect(x: 0, y: 0, width: hintWidth, height: textHeight)
        hintScroll.contentSize = CGSize(width: hintWidth, height: textHeight)
        let maximumOffset = max(0, textHeight - viewportHeight)
        if hintScroll.contentOffset.y > maximumOffset {
            hintScroll.setContentOffset(CGPoint(x: 0, y: maximumOffset), animated: false)
        }
        let preeditHeight: CGFloat = preeditLabel.isHidden ? 0 : 13
        preeditLabel.frame = CGRect(x: 8, y: 0, width: max(0, contentWidth - 12), height: preeditHeight)
        let listFrame = CGRect(x: 0, y: preeditHeight, width: contentWidth, height: 44 - preeditHeight)
        candidateList.frame = listFrame
        spellingList.frame = listFrame
        emptyCandidatesLabel.frame = listFrame.insetBy(dx: 8, dy: 0)
        let toastWidth = max(0, bounds.width - 24)
        let toastTextWidth = max(0, toastWidth - 24)
        let toastTextHeight = min(38, ceil(speechErrorLabel.sizeThatFits(
            CGSize(width: toastTextWidth, height: .greatestFiniteMagnitude)).height))
        speechErrorToast.frame = CGRect(x: 12, y: 52, width: toastWidth, height: toastTextHeight + 20)
        speechErrorLabel.frame = CGRect(x: 12, y: 10, width: toastTextWidth, height: toastTextHeight)
    }

    private func buildSpeechErrorToast() {
        speechErrorToast.accessibilityIdentifier = "keyboard.speechError"
        speechErrorToast.isUserInteractionEnabled = false
        speechErrorToast.backgroundColor = .secondarySystemGroupedBackground
        speechErrorToast.layer.cornerRadius = 10
        speechErrorToast.layer.shadowColor = UIColor.black.cgColor
        speechErrorToast.layer.shadowOpacity = 0.1
        speechErrorToast.layer.shadowRadius = 8
        speechErrorToast.layer.shadowOffset = CGSize(width: 0, height: 2)
        speechErrorToast.isHidden = true
        speechErrorLabel.numberOfLines = 2
        speechErrorLabel.font = .systemFont(ofSize: 13, weight: .regular)
        speechErrorLabel.textColor = .secondaryLabel
        speechErrorToast.addSubview(speechErrorLabel)
        addSubview(speechErrorToast)
    }

    private func showSpeechError(_ message: String) {
        dismissSpeechError()
        speechErrorLabel.text = message
        speechErrorToast.isHidden = false
        bringSubviewToFront(speechErrorToast)
        setNeedsLayout()
        if window != nil { UIAccessibility.post(notification: .announcement, argument: message) }
        speechErrorDismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            self?.dismissSpeechError()
        }
    }

    private func dismissSpeechError() {
        speechErrorDismissal?.cancel()
        speechErrorDismissal = nil
        speechErrorToast.isHidden = true
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { dismissSpeechError() }
    }

    /// Playback and credentials remain owned by the controller. Every visible
    /// state keeps the same 44 pt target, including cancel during loading.
    func setSpeech(available: Bool, state: SpeechPlaybackSession.State,
                   text: String? = nil, english: String? = nil) {
        speechAvailable = available
        analysisPanel.setSpeech(available: available, state: state, text: text)
        // The header always controls the whole sentence. A playing snippet has
        // its own highlight and speaker; tapping the header switches to the whole.
        let isSnippet = text != nil && english != nil && text != english
        let headerState: SpeechPlaybackSession.State = isSnippet ? .idle : state
        speechIsLoading = false
        let symbol: String
        speechButton.tintColor = hintActionColor
        speechButton.accessibilityValue = nil
        if case let .failed(message) = state {
            if available, lastSpeechFailure != message || lastSpeechFailureText != text {
                lastSpeechFailure = message
                lastSpeechFailureText = text
                showSpeechError(message)
            }
        } else { lastSpeechFailure = nil; lastSpeechFailureText = nil; dismissSpeechError() }
        switch headerState {
        case .idle:
            symbol = "speaker.wave.2"
            speechButton.accessibilityLabel = "朗读英文"
            speechButton.accessibilityHint = "正常语速朗读一遍，朗读中再次点按停止"
        case .loading:
            symbol = ""
            speechIsLoading = true
            speechButton.accessibilityLabel = "取消朗读"
            speechButton.accessibilityValue = "正在准备语音"
            speechButton.accessibilityHint = "再次点按取消"
        case .playing:
            symbol = "speaker.wave.2"
            speechButton.tintColor = .systemBlue
            speechButton.accessibilityLabel = "停止朗读"
            speechButton.accessibilityValue = "正在朗读"
            speechButton.accessibilityHint = "点按停止"
        case let .failed(message):
            symbol = "exclamationmark.circle"
            speechButton.accessibilityLabel = "重试朗读"
            speechButton.accessibilityValue = message
            speechButton.accessibilityHint = "点按重试朗读"
        }
        speechButton.setImage(symbol.isEmpty ? nil : UIImage(systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)), for: .normal)
        if !available { lastSpeechFailure = nil; lastSpeechFailureText = nil; dismissSpeechError() }
        updateCompositionPresentation()
    }

    func setHint(text: String, loading: Bool, isTranslation: Bool, canRetry: Bool) {
        let isPlaceholder = !isTranslation && ["输入内容，查看英文提示", "稍停一下，显示英文提示", "选定输入内容后显示英文"].contains(text)
        // Presentation only: a service's paragraph breaks must not force an
        // early line break here. The controller retains the exact translation
        // independently for replacement and analysis.
        let displayedTranslation = isTranslation ? text.split(whereSeparator: \.isWhitespace).joined(separator: " ") : text
        let text = isPlaceholder ? "输入后显示英文" : loading ? "翻译中…" : displayedTranslation
        let textChanged = hintLabel.text != text
        if textChanged {
            hintScroll.setContentOffset(.zero, animated: false)
        }
        hintIsTranslation = isTranslation
        hintScroll.isPagingEnabled = isTranslation
        hintLabel.font = .systemFont(ofSize: isTranslation ? 16 : isPlaceholder ? 14 : 15, weight: .regular)
        hintLabel.textColor = isTranslation ? translationTextColor : .secondaryLabel
        if isTranslation {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineBreakStrategy = []
            paragraph.allowsDefaultTighteningForTruncation = false
            paragraph.minimumLineHeight = max(20, hintLabel.font.lineHeight)
            paragraph.maximumLineHeight = paragraph.minimumLineHeight
            hintLabel.attributedText = NSAttributedString(string: text, attributes: [
                .font: hintLabel.font!, .paragraphStyle: paragraph
            ])
        } else {
            hintLabel.attributedText = nil
            hintLabel.text = text
        }
        // Preserve the same policy after assigning an attributed paragraph.
        hintLabel.adjustsFontSizeToFitWidth = false
        hintLabel.allowsDefaultTighteningForTruncation = false
        hintLabel.accessibilityLabel = isTranslation ? "英文提示：\(text)" : text
        hintIsLoading = loading
        hintCanRetry = canRetry
        updateCompositionPresentation()
        if isTranslation && textChanged {
            hintScroll.setNeedsLayout()
            hintScroll.flashScrollIndicators()
        }
    }

    /// The controller owns replacement eligibility and document mutations.
    /// This view only exposes the currently authorized action as a callback.
    func setHintAction(_ action: HintAction) {
        guard hintAction != action else { return }
        hintAction = action
        switch action {
        case .none:
            hintActionButton.setTitle(nil, for: .normal)
            hintActionButton.accessibilityLabel = nil
            hintActionButton.accessibilityHint = nil
        case .useEnglish:
            hintActionButton.setTitle("用英文", for: .normal)
            hintActionButton.accessibilityLabel = "用英文"
            hintActionButton.accessibilityHint = "用英文提示替换对应原文"
        case .undoEnglish:
            hintActionButton.setTitle("撤销", for: .normal)
            hintActionButton.accessibilityLabel = "撤销"
            hintActionButton.accessibilityHint = "恢复上一次替换前的原文"
        }
        updateCompositionPresentation()
    }

    /// Analysis is requested and validated by the controller. Redundant updates
    /// preserve the learning page's scroll position.
    func setAnalysis(available: Bool, expanded: Bool, english: String, state: AnalysisPresentation) {
        analysisAvailable = available
        analysisExpanded = available && expanded
        analysisPanel.set(english: english, presentation: state)
        updateCompositionPresentation()
    }

    private func updateLookupPresentation() {
        let hasLookup = !analysisPanel.isHidden && lookupWord?.isEmpty == false
        analysisTitleLabel.isHidden = analysisPanel.isHidden || hasLookup
        analysisLookupWordLabel.isHidden = !hasLookup
        analysisLookupMeaningScroll.isHidden = !hasLookup
        analysisLookupMeaningLabel.isHidden = !hasLookup
        let word = lookupWord ?? ""
        let meaning = lookupMeaning ?? "词义准备中"
        if analysisLookupWordLabel.text != word || analysisLookupMeaningLabel.text != meaning {
            analysisLookupMeaningScroll.setContentOffset(.zero, animated: false)
        }
        analysisLookupWordLabel.text = word
        analysisLookupWordLabel.accessibilityLabel = word
        analysisLookupMeaningLabel.text = meaning
        analysisLookupMeaningLabel.accessibilityLabel = "本句含义：\(meaning)"
    }

    func configure(page: Page, shift: Shift, returnTitle: String, showGlobe: Bool, compact: Bool,
                   returnIsActive: Bool = true) {
        let structureChanged = self.page != page || self.showGlobe != showGlobe
        let appearanceChanged = self.shift != shift || self.returnTitle != returnTitle || self.compact != compact
            || self.returnIsActive != returnIsActive
        self.page = page
        self.shift = shift
        self.returnTitle = returnTitle
        self.returnIsActive = returnIsActive
        self.showGlobe = showGlobe
        self.compact = compact
        if structureChanged {
            showingSpellings = false
            rebuildKeys()
            updateCompositionPresentation()
        }
        else if appearanceChanged { updateKeyAppearance() }
    }

    func setInputLanguage(isChinese: Bool) {
        guard self.isChinese != isChinese else { return }
        let oldNineKey = usesNineKey
        self.isChinese = isChinese
        resetSpellingSelection()
        // Number/symbol tables and their return label belong to the current
        // input language; a language change must not keep the previous table.
        if oldNineKey != usesNineKey || page != .letters { rebuildKeys() }
        else { updateKeyAppearance() }
    }

    func setChineseLayout(_ layout: ChineseLayout) {
        guard chineseLayout != layout else { return }
        chineseLayout = layout
        resetSpellingSelection()
        if isChinese && page == .letters { rebuildKeys() }
    }

    private func resetSpellingSelection() {
        showingSpellings = false
        updateCompositionPresentation()
    }

    private func updateCompositionPresentation() {
        if !usesNineKey { showingSpellings = false }
        let showsComposition = isChinese && (!compositionText.isEmpty || showingSpellings || compositionUnavailable)
        let showsAnalysis = analysisAvailable && analysisExpanded && !showsComposition && hintIsTranslation
        hintScroll.isHidden = showsComposition || showsAnalysis
        hintScroll.isScrollEnabled = !showsAnalysis
        hintLabel.numberOfLines = 0
        hintLabel.lineBreakMode = .byWordWrapping
        if showsAnalysis && analysisPanel.isHidden {
            analysisPanel.beginPresentation()
        }
        if !showsAnalysis && !analysisPanel.isHidden {
            analysisPanel.endPresentation()
        }
        analysisPanel.isHidden = !showsAnalysis
        backgroundColor = showsAnalysis ? SentenceAnalysisPanel.learningBackground : surfaceColor
        // Keep the arranged canvas alive while the controller gives learning
        // more height. Restoring the normal height restores the original keys.
        canvas.alpha = showsAnalysis ? 0 : 1
        canvas.isUserInteractionEnabled = !showsAnalysis
        canvas.accessibilityElementsHidden = showsAnalysis
        updateLookupPresentation()
        sentenceSpeechLabel.isHidden = !showsAnalysis
        sentenceSpeechLabel.textColor = speechButton.tintColor
        speechButton.contentHorizontalAlignment = showsAnalysis ? .left : .center
        speechButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: showsAnalysis ? 13 : 15, weight: .regular), forImageIn: .normal)
        headerDivider.isHidden = !showsAnalysis || !analysisPanel.isScrolled
        preeditLabel.text = compositionText
        preeditLabel.isHidden = !showsComposition || compositionText.isEmpty
        candidateList.isHidden = !showsComposition || showingSpellings
        spellingList.isHidden = !showsComposition || !showingSpellings
        let items = showingSpellings ? spellingOptions : compositionCandidates
        emptyCandidatesLabel.isHidden = !showsComposition || !items.isEmpty
        emptyCandidatesLabel.text = compositionUnavailable ? "拼音暂不可用" : showingSpellings ? "先输入拼音，再选读音" : "暂无候选"
        if !showsComposition && hintIsLoading { spinner.startAnimating() }
        else { spinner.stopAnimating() }
        retryButton.isHidden = showsComposition || !hintCanRetry
        hintActionButton.isHidden = showsComposition || hintIsLoading || hintCanRetry || hintAction == .none
        speechButton.isHidden = showsComposition || hintIsLoading || hintCanRetry || !hintIsTranslation || !speechAvailable
        if speechButton.isHidden { speechSpinner.stopAnimating(); dismissSpeechError() }
        else if speechIsLoading { speechSpinner.startAnimating() }
        else { speechSpinner.stopAnimating() }
        analysisButton.isHidden = showsComposition || hintIsLoading || hintCanRetry || !analysisAvailable || !hintIsTranslation
        analysisButton.setTitle(showsAnalysis ? "收起" : nil, for: .normal)
        analysisButton.setImage(showsAnalysis ? nil : UIImage(systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)), for: .normal)
        analysisButton.accessibilityLabel = showsAnalysis ? "收起学习，返回键盘" : "展开英文分析"
        analysisButton.accessibilityValue = showsAnalysis ? "已展开" : "已收起"
        chooseSpellingKey?.setTitle(showingSpellings ? "选词" : "选拼音", for: .normal)
        chooseSpellingKey?.accessibilityLabel = showingSpellings ? "返回汉字候选" : "选择拼音读音"
        chooseSpellingKey?.setTitleColor(showingSpellings ? .systemBlue : .secondaryLabel, for: .normal)
        setNeedsLayout()
    }

    /// Updating composition reuses visible cells and never recreates a touched key.
    func setComposition(_ text: String, candidates: [String], isChinese: Bool,
                        unavailable: Bool = false, onSelect: @escaping (Int) -> Void) {
        compositionText = text
        compositionCandidates = candidates
        compositionUnavailable = unavailable
        if text.isEmpty { showingSpellings = false }
        candidateList.update(candidates, onSelect: onSelect)
        updateCompositionPresentation()
    }

    func setSpellingOptions(_ options: [String], onSelect: @escaping (Int) -> Void) {
        spellingOptions = options
        spellingList.update(options) { [weak self] index in
            self?.showingSpellings = false
            self?.updateCompositionPresentation()
            onSelect(index)
        }
        updateCompositionPresentation()
    }

    private func rebuildKeys() {
        letterKeys.removeAll(keepingCapacity: true)
        shiftKey = nil
        returnKey = nil
        languageKey = nil
        globeKey = nil
        chooseSpellingKey = nil
        if usesNineKey { buildNineKeyGrid(); return }
        var rows: [[KeyboardKey]] = []
        var styles: [KeyboardGeometry.RowStyle] = []
        switch page {
        case .letters:
            rows.append(Array("qwertyuiop").map { letterKey(String($0)) })
            rows.append(Array("asdfghjkl").map { letterKey(String($0)) })
            let shiftButton = makeKey("", symbol: "shift", utility: true, action: .shift)
            shiftKey = shiftButton
            rows.append([shiftButton] + Array("zxcvbnm").map { letterKey(String($0)) } + [deleteKey()])
            styles = [.firstLetters, .secondLetters, .thirdLetters]
        case .numbers:
            rows.append(Array("1234567890").map { letterKey(String($0)) })
            let symbols = isChinese
                ? ["-", "/", "：", "；", "（", "）", "¥", "@", "“", "”"]
                : ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""]
            rows.append(symbols.map(letterKey))
            rows.append(symbolBottomRow())
            styles = [.equal, .equal, isChinese ? .chineseSymbols : .symbols]
        case .symbols:
            rows.append(["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map(letterKey))
            rows.append(["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"].map(letterKey))
            rows.append(symbolBottomRow())
            styles = [.equal, .equal, isChinese ? .chineseSymbols : .symbols]
        }
        let backTitle = isChinese ? "拼音" : "ABC"
        var bottom = [makeKey(page == .letters ? "123" : backTitle, utility: true,
                              action: page == .letters ? .numbers : .letters)]
        if showGlobe {
            let globe = makeKey("", symbol: "globe", utility: true, action: nil)
            globe.accessibilityLabel = "切换键盘"
            globe.accessibilityIdentifier = "keyboard.globe"
            globeKey = globe
            configureGlobe?(globe)
            bottom.append(globe)
        }
        let language = makeKey("", utility: true, action: .toggleLanguage)
        language.accessibilityIdentifier = "keyboard.language"
        languageKey = language
        bottom.append(language)
        let space = makeKey("空格", action: .space)
        space.fixedFontSize = 17
        space.accessibilityIdentifier = "keyboard.space"
        bottom.append(space)
        let enter = makeKey(returnTitle, utility: true, action: .return)
        enter.accessibilityIdentifier = "keyboard.return"
        returnKey = enter
        bottom.append(enter)
        rows.append(bottom)
        styles.append(.bottom(showGlobe: showGlobe))
        canvas.install(rows: rows, styles: styles)
        updateKeyAppearance()
    }

    private func buildNineKeyGrid() {
        var keys: [KeyboardKey] = []
        var positions: [KeyboardGeometry.GridPosition] = []
        func add(_ key: KeyboardKey, column: Int, row: Int, columns: Int = 1, rows: Int = 1) {
            if key.isUtility && key.fixedFontSize == nil { key.fixedFontSize = 17 }
            keys.append(key)
            positions.append(.init(column: column, row: row, columns: columns, rows: rows))
        }
        add(makeKey("123", utility: true, action: .numbers), column: 0, row: 0)
        let punctuation = makeKey("，。?!", action: nil)
        punctuation.fixedFontSize = 19
        punctuation.accessibilityLabel = "选择常用标点"
        punctuation.accessibilityIdentifier = "keyboard.punctuation"
        let punctuationActions = ["，", "。", "？", "！", "、", "…", "：", "；", "“", "”", "'"].map { mark in
            UIAction(title: mark) { [weak self] _ in self?.onAction?(.insert(mark)) }
        }
        punctuation.menu = UIMenu(children: punctuationActions + [
            UIAction(title: "分隔拼音") { [weak self] _ in self?.onAction?(.separator) }
        ])
        punctuation.showsMenuAsPrimaryAction = true
        add(punctuation, column: 1, row: 0)
        add(nineKey("2", letters: "ABC"), column: 2, row: 0)
        add(nineKey("3", letters: "DEF"), column: 3, row: 0)
        add(deleteKey(), column: 4, row: 0)
        add(makeKey("#@¥", utility: true, action: .symbols), column: 0, row: 1)
        add(nineKey("4", letters: "GHI"), column: 1, row: 1)
        add(nineKey("5", letters: "JKL"), column: 2, row: 1)
        add(nineKey("6", letters: "MNO"), column: 3, row: 1)
        add(makeTextFaceKey(), column: 4, row: 1)
        let language = makeKey("ABC", utility: true, action: .toggleLanguage)
        language.accessibilityIdentifier = "keyboard.language"
        languageKey = language
        add(language, column: 0, row: 2)
        add(nineKey("7", letters: "PQRS"), column: 1, row: 2)
        add(nineKey("8", letters: "TUV"), column: 2, row: 2)
        add(nineKey("9", letters: "WXYZ"), column: 3, row: 2)
        let enter = makeKey(returnTitle, utility: true, action: .return)
        enter.accessibilityIdentifier = "keyboard.return"
        returnKey = enter
        add(enter, column: 4, row: 2, rows: 2)
        if showGlobe {
            let globe = makeKey("", symbol: "globe", utility: true, action: nil)
            globe.accessibilityLabel = "切换键盘"
            globe.accessibilityIdentifier = "keyboard.globe"
            globeKey = globe
            configureGlobe?(globe)
            add(globe, column: 0, row: 3)
        } else {
            let emoji = makeKey("", utility: true, action: nil)
            configureEmojiKey(emoji)
            add(emoji, column: 0, row: 3)
        }
        let spelling = makeKey("选拼音", action: nil)
        spelling.fixedFontSize = 17
        spelling.accessibilityIdentifier = "keyboard.chooseSpelling"
        spelling.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.showingSpellings.toggle()
            self.updateCompositionPresentation()
        }, for: .touchUpInside)
        chooseSpellingKey = spelling
        add(spelling, column: 1, row: 3)
        let space = makeKey("空格", action: .space)
        space.fixedFontSize = 17
        space.accessibilityIdentifier = "keyboard.space"
        add(space, column: 2, row: 3, columns: 2)
        canvas.install(rows: [keys], styles: [], gridPositions: positions)
        updateKeyAppearance()
        updateCompositionPresentation()
    }

    private func updateKeyAppearance() {
        canvas.compact = compact
        let regularKeySize: CGFloat = isChinese && page != .letters
            ? (compact ? 20 : 23) : (compact ? 22 : 25)
        for key in canvas.keys {
            key.titleLabel?.font = .systemFont(ofSize: key.fixedFontSize ?? (key.isUtility ? 16 : regularKeySize))
            key.setPreferredSymbolConfiguration(.init(pointSize: compact ? 19 : 21), forImageIn: .normal)
        }
        for (key, raw) in letterKeys {
            let shown = page == .letters && shift != .lower ? raw.uppercased() : raw
            key.setTitle(shown, for: .normal)
            key.action = .insert(shown)
            key.previewText = shown.count == 1 ? shown : nil
            key.accessibilityLabel = shown
        }
        if let shiftKey {
            shiftKey.setTitle("", for: .normal)
            shiftKey.setImage(UIImage(systemName: shift == .locked ? "capslock.fill" : shift == .upper ? "shift.fill" : "shift"), for: .normal)
            shiftKey.accessibilityLabel = isChinese ? "切换英文大写" : shift == .locked ? "大写锁定" : "切换大小写，连按两次锁定大写"
            shiftKey.restingColor = shift == .lower || isChinese ? utilityColor : .systemBackground
            shiftKey.tintColor = shift == .lower ? .label : accent
        }
        if let languageKey {
            if isChinese && !usesNineKey {
                // Reconfigure the existing footer key in place. A QWERTY
                // language change must also change its menu/action, not only title.
                if languageKey.menu == nil { configureEmojiKey(languageKey) }
            } else {
                languageKey.menu = nil
                languageKey.showsMenuAsPrimaryAction = false
                languageKey.action = .toggleLanguage
                languageKey.setImage(nil, for: .normal)
                languageKey.setTitle(usesNineKey ? "ABC" : "中文", for: .normal)
                languageKey.titleLabel?.font = .systemFont(ofSize: 17)
                languageKey.accessibilityIdentifier = "keyboard.language"
                languageKey.accessibilityLabel = usesNineKey ? "切换英文键盘" : "返回中文键盘"
            }
        }
        returnKey?.setTitle(returnTitle, for: .normal)
        let isActionReturn = ["发送", "前往", "搜索", "完成", "继续", "加入", "连接", "确定"].contains(returnTitle)
        let prominentReturn = isActionReturn && returnIsActive
        returnKey?.isEnabled = !isActionReturn || returnIsActive
        returnKey?.restingColor = prominentReturn ? .systemBlue : utilityColor
        returnKey?.setTitleColor(prominentReturn ? .white : .label, for: .normal)
        returnKey?.setTitleColor(.secondaryLabel, for: .disabled)
        returnKey?.accessibilityLabel = returnTitle
        canvas.setNeedsLayout()
    }

    private func symbolBottomRow() -> [KeyboardKey] {
        let punctuation = isChinese ? ["。", "，", "、", "？", "！", "."] : [".", ",", "?", "!", "'"]
        return [makeKey(page == .numbers ? "#+=" : "123", utility: true, action: page == .numbers ? .symbols : .numbers)]
            + punctuation.map(letterKey) + [deleteKey()]
    }

    private func emojiActions() -> [UIAction] {
        ["😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "😊", "🥰",
         "😍", "😎", "🤔", "😭", "🥺", "👍", "👏", "🙏", "❤️", "🎉"].map { emoji in
            UIAction(title: emoji) { [weak self] _ in self?.onAction?(.insert(emoji)) }
        }
    }

    private func configureEmojiKey(_ key: KeyboardKey) {
        let image = UIImage(systemName: "face.smiling")
        key.setTitle(image == nil ? "表情" : "", for: .normal)
        key.setImage(image, for: .normal)
        key.action = nil
        key.menu = UIMenu(children: emojiActions())
        key.showsMenuAsPrimaryAction = true
        key.accessibilityLabel = "常用表情"
        key.accessibilityIdentifier = "keyboard.emoji"
    }

    private func makeTextFaceKey() -> KeyboardKey {
        let key = makeKey("^_^", utility: false, action: nil)
        key.fixedFontSize = 17
        let faces = ["^_^", "(≧▽≦)", "(๑•̀ㅂ•́)و✧", "(｡･ω･｡)", "(╥﹏╥)", "¯\\_(ツ)_/¯"]
        var items: [UIMenuElement] = faces.map { face in
            UIAction(title: face) { [weak self] _ in self?.onAction?(.insert(face)) }
        }
        if showGlobe { items.append(UIMenu(title: "常用表情", children: emojiActions())) }
        key.menu = UIMenu(children: items)
        key.showsMenuAsPrimaryAction = true
        key.accessibilityLabel = showGlobe ? "颜文字和常用表情" : "常用颜文字"
        key.accessibilityIdentifier = "keyboard.textFaces"
        return key
    }
    private func letterKey(_ text: String) -> KeyboardKey {
        let key = makeKey(text, action: .insert(text))
        letterKeys.append((key, text))
        return key
    }
    private func nineKey(_ digit: String, letters: String, action: Action? = nil) -> KeyboardKey {
        let key = makeKey(letters, action: action ?? .t9Digit(digit))
        key.fixedFontSize = 18
        key.setAttributedTitle(NSAttributedString(string: letters, attributes: [
            .font: UIFont.systemFont(ofSize: 18), .kern: 2
        ]), for: .normal)
        key.accessibilityLabel = "\(digit)，\(letters)"
        key.accessibilityIdentifier = "keyboard.t9.\(digit)"
        return key
    }
    private func makeKey(_ title: String, symbol: String? = nil, utility: Bool = false, action: Action?) -> KeyboardKey {
        let key = KeyboardKey(type: .custom)
        key.isUtility = utility
        if title == "，" || title == "。" { key.fixedFontSize = 20 }
        key.action = action
        key.setTitle(title, for: .normal)
        key.setTitleColor(.label, for: .normal)
        key.tintColor = .label
        key.titleLabel?.adjustsFontSizeToFitWidth = true
        key.titleLabel?.minimumScaleFactor = 0.75
        if let symbol { key.setImage(UIImage(systemName: symbol), for: .normal) }
        key.restingColor = utility ? utilityColor : .systemBackground
        key.layer.cornerRadius = 6
        key.layer.shadowColor = UIColor.black.cgColor
        key.layer.shadowOffset = CGSize(width: 0, height: 1)
        key.layer.shadowOpacity = 0.17
        key.layer.shadowRadius = 0
        key.accessibilityTraits.insert(.keyboardKey)
        key.accessibilityLabel = title
        key.accessibilityIdentifier = "keyboard.key.\(title)"
        key.addAction(UIAction { [weak self, weak key] _ in
            guard let action = key?.action else { return }
            self?.onAction?(action)
        }, for: .touchUpInside)
        return key
    }
    private func deleteKey() -> KeyboardKey {
        let key = makeKey("", symbol: "delete.left", utility: true, action: nil)
        key.accessibilityLabel = "删除，按住连续删除"
        key.accessibilityIdentifier = "keyboard.delete"
        key.addAction(UIAction { [weak self] _ in self?.onDeletePressed?() }, for: .touchDown)
        key.addAction(UIAction { [weak self] _ in self?.onDeleteReleased?() },
                      for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        key.accessibilityAction = { [weak self] in self?.onAction?(.delete) }
        return key
    }
}

/// The seven third-row letters retain the first row's width and pitch.
/// Utility keys are 1.3 letter widths, with symmetric gaps beside the letters.
enum KeyboardGeometry {
    enum RowStyle { case firstLetters, secondLetters, thirdLetters, equal, symbols, chineseSymbols, nineKey, bottom(showGlobe: Bool) }
    struct GridPosition {
        let column: Int
        let row: Int
        var columns = 1
        var rows = 1
    }

    /// Five equal columns; the return and space keys span cells without changing
    /// the neighbouring letter groups' centres or effective touch regions.
    static func gridFrame(width: CGFloat, height: CGFloat, position: GridPosition, gap: CGFloat = 6) -> CGRect {
        let columnWidth = max(1, (width - 4 * gap) / 5)
        let rowHeight = max(1, (height - 3 * gap) / 4)
        return CGRect(x: CGFloat(position.column) * (columnWidth + gap),
                      y: CGFloat(position.row) * (rowHeight + gap),
                      width: columnWidth * CGFloat(position.columns) + gap * CGFloat(position.columns - 1),
                      height: rowHeight * CGFloat(position.rows) + gap * CGFloat(position.rows - 1))
    }

    static func frames(width: CGFloat, height: CGFloat, count: Int, style: RowStyle, gap: CGFloat) -> [CGRect] {
        guard count > 0, width > 0, height > 0 else { return [] }
        let letter = max(1, (width - 9 * gap) / 10)
        func row(widths: [CGFloat], origin: CGFloat = 0) -> [CGRect] {
            var x = origin
            return widths.map { width in
                defer { x += width + gap }
                return CGRect(x: x, y: 0, width: width, height: height)
            }
        }
        switch style {
        case .firstLetters: return row(widths: Array(repeating: letter, count: 10))
        case .secondLetters:
            return row(widths: Array(repeating: letter, count: 9), origin: (width - 9 * letter - 8 * gap) / 2)
        case .thirdLetters:
            let utility = 1.3 * letter
            let middleWidth = 7 * letter + 6 * gap
            return [CGRect(x: 0, y: 0, width: utility, height: height)]
                + row(widths: Array(repeating: letter, count: 7), origin: (width - middleWidth) / 2)
                + [CGRect(x: width - utility, y: 0, width: utility, height: height)]
        case .nineKey:
            let utility = max(42, width * 0.14)
            let main = (width - utility - 3 * gap) / 3
            return row(widths: [main, main, main, utility])
        case .bottom(let showGlobe):
            if !showGlobe {
                // At 393 pt screen width: 43 / 43 / 190 / 91 pt, plus 6 pt gaps.
                let utility = width * 43 / 385
                let enter = width * 91 / 385
                let space = width - utility * 2 - enter - 3 * gap
                return row(widths: [utility, utility, space, enter])
            }
            let widths = showGlobe ? [width * 0.13, width * 0.11, width * 0.13] : [width * 0.13, width * 0.13]
            let enter = width * 0.19
            let space = width - widths.reduce(0, +) - enter - CGFloat(count - 1) * gap
            return row(widths: widths + [space, enter])
        case .symbols:
            let unit = (width - CGFloat(count - 1) * gap) / CGFloat(count + 1)
            return row(widths: [unit * 1.5] + Array(repeating: unit, count: count - 2) + [unit * 1.5])
        case .chineseSymbols:
            // Apple's Chinese number page has six punctuation keys. Keep the
            // utility width near the letter page rather than stretching it.
            let utility = 1.3 * letter
            let punctuation = max(1, (width - utility * 2 - CGFloat(count - 1) * gap) / CGFloat(count - 2))
            return row(widths: [utility] + Array(repeating: punctuation, count: count - 2) + [utility])
        case .equal:
            return row(widths: Array(repeating: (width - CGFloat(count - 1) * gap) / CGFloat(count), count: count))
        }
    }
}

@MainActor
private final class KeyboardCanvas: UIView {
    private var rows: [[KeyboardKey]] = []
    private var styles: [KeyboardGeometry.RowStyle] = []
    private var gridPositions: [KeyboardGeometry.GridPosition]?
    var keys: [KeyboardKey] { rows.flatMap { $0 } }
    var compact = false
    private let preview = UILabel()
    private weak var previewOwner: KeyboardKey?

    func install(rows: [[KeyboardKey]], styles: [KeyboardGeometry.RowStyle], gridPositions: [KeyboardGeometry.GridPosition]? = nil) {
        keys.forEach { $0.removeFromSuperview() }
        preview.isHidden = true
        previewOwner = nil
        self.rows = rows
        self.styles = styles
        self.gridPositions = gridPositions
        for key in keys {
            addSubview(key)
            key.onHighlight = { [weak self, weak key] highlighted in
                guard let self, let key else { return }
                self.updatePreview(for: key, highlighted: highlighted)
            }
        }
        if preview.superview == nil {
            preview.isUserInteractionEnabled = false
            preview.isAccessibilityElement = false
            preview.backgroundColor = .systemBackground
            preview.textColor = .label
            preview.font = .systemFont(ofSize: 31)
            preview.textAlignment = .center
            preview.layer.cornerRadius = 10
            preview.layer.masksToBounds = true
            addSubview(preview)
        }
        bringSubviewToFront(preview)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let gridPositions {
            for (key, position) in zip(keys, gridPositions) {
                key.frame = KeyboardGeometry.gridFrame(width: bounds.width, height: bounds.height, position: position)
                key.touchExpansion = CGSize(width: 3, height: 3)
            }
            return
        }
        let rowGap: CGFloat = compact ? 7 : 11
        let columnGap: CGFloat = 6
        let rowHeight = max(1, (bounds.height - rowGap * CGFloat(max(0, rows.count - 1))) / CGFloat(max(1, rows.count)))
        for (index, row) in rows.enumerated() {
            let frames = KeyboardGeometry.frames(width: bounds.width, height: rowHeight, count: row.count,
                                                  style: styles[index], gap: columnGap)
            for (key, frame) in zip(row, frames) {
                key.frame = frame.offsetBy(dx: 0, dy: CGFloat(index) * (rowHeight + rowGap))
                key.touchExpansion = CGSize(width: columnGap / 2, height: rowGap / 2)
            }
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled, bounds.contains(point) else { return nil }
        // Gap hits go to the nearest key only within half the normal gap. The
        // canvas boundary prevents keys from stealing candidate/hint-bar touches.
        let candidates = keys.filter {
            !$0.isHidden && $0.isEnabled && $0.frame.insetBy(dx: -$0.touchExpansion.width, dy: -$0.touchExpansion.height).contains(point)
        }
        return candidates.min {
            hypot($0.center.x - point.x, $0.center.y - point.y) < hypot($1.center.x - point.x, $1.center.y - point.y)
        } ?? super.hitTest(point, with: event)
    }

    private func updatePreview(for key: KeyboardKey, highlighted: Bool) {
        if !highlighted {
            if previewOwner === key { preview.isHidden = true; previewOwner = nil }
            return
        }
        guard let text = key.previewText, !compact, !UIAccessibility.isVoiceOverRunning else { return }
        previewOwner = key
        preview.text = text
        let width = max(48, key.bounds.width + 16)
        preview.frame = CGRect(x: min(max(0, key.frame.midX - width / 2), bounds.width - width),
                               y: key.frame.minY - 51, width: width, height: 55)
        preview.isHidden = false
        bringSubviewToFront(preview)
    }
}

@MainActor
private final class KeyboardKey: UIButton {
    var action: KeyboardSurface.Action?
    var isUtility = false
    var fixedFontSize: CGFloat?
    var previewText: String?
    var onHighlight: ((Bool) -> Void)?
    var accessibilityAction: (() -> Void)?
    var touchExpansion = CGSize.zero
    var restingColor: UIColor = .systemBackground {
        didSet { if !isHighlighted { backgroundColor = restingColor } }
    }
    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? .systemGray2 : restingColor
            onHighlight?(isHighlighted)
        }
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -touchExpansion.width, dy: -touchExpansion.height).contains(point)
    }
    override func accessibilityActivate() -> Bool {
        if let accessibilityAction { accessibilityAction(); return true }
        return super.accessibilityActivate()
    }
}

@MainActor
private final class KeyboardCandidateFlowLayout: UICollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        // The composition line changes the list from 44 to 31 pt. Invalidate
        // cached cell heights as the collection resizes, before its next layout.
        newBounds.size != collectionView?.bounds.size || super.shouldInvalidateLayout(forBoundsChange: newBounds)
    }

    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forBoundsChange: newBounds)
        if newBounds.size != collectionView?.bounds.size,
           let flowContext = context as? UICollectionViewFlowLayoutInvalidationContext {
            flowContext.invalidateFlowLayoutDelegateMetrics = true
        }
        return context
    }
}

@MainActor
private final class KeyboardCandidateList: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    private let font: UIFont
    private let horizontalPadding: CGFloat
    private let collection: UICollectionView
    private var items: [String] = []
    private var widths: [CGFloat] = []
    private var onSelect: ((Int) -> Void)?
    var accessibilityPrefix = ""

    init(fontSize: CGFloat, horizontalPadding: CGFloat) {
        font = .systemFont(ofSize: fontSize)
        self.horizontalPadding = horizontalPadding
        let layout = KeyboardCandidateFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        collection.backgroundColor = .clear
        collection.showsHorizontalScrollIndicator = false
        collection.alwaysBounceHorizontal = false
        // The keyboard already owns its safe-area budget; the candidate row
        // must not inherit a host navigation bar or window title-bar inset.
        collection.contentInsetAdjustmentBehavior = .never
        collection.dataSource = self
        collection.delegate = self
        collection.register(KeyboardCandidateCell.self, forCellWithReuseIdentifier: "candidate")
        collection.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collection)
        NSLayoutConstraint.activate([
            collection.leadingAnchor.constraint(equalTo: leadingAnchor), collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            collection.topAnchor.constraint(equalTo: topAnchor), collection.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ items: [String], onSelect: @escaping (Int) -> Void) {
        self.onSelect = onSelect
        guard items != self.items else { return }
        self.items = items
        widths = items.map { max(40, ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + horizontalPadding * 2) }
        collection.setContentOffset(.zero, animated: false)
        collection.reloadData()
    }

    override func layoutSubviews() {
        let oldSize = collection.bounds.size
        super.layoutSubviews()
        if oldSize != collection.bounds.size { collection.collectionViewLayout.invalidateLayout() }
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "candidate", for: indexPath) as! KeyboardCandidateCell
        cell.label.text = items[indexPath.item]
        cell.label.font = font
        cell.accessibilityLabel = "\(accessibilityPrefix)：\(items[indexPath.item])"
        cell.accessibilityIdentifier = "\(accessibilityIdentifier ?? "keyboard.candidates").\(indexPath.item)"
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        CGSize(width: widths[indexPath.item], height: max(1, collectionView.bounds.height))
    }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard items.indices.contains(indexPath.item) else { return }
        onSelect?(indexPath.item)
    }
}

@MainActor
private final class KeyboardCandidateCell: UICollectionViewCell {
    let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        label.textColor = .label
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: contentView.topAnchor),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        contentView.layer.cornerRadius = 5
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isHighlighted: Bool {
        didSet { contentView.backgroundColor = isHighlighted ? .systemGray3 : .clear }
    }
}
