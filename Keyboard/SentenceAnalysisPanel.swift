import UIKit

/// One reading surface: actual English, selected usage, reusable expressions.
/// Height, network requests and host edits remain owned by the controller.
@MainActor
final class SentenceAnalysisPanel: UIView, UIScrollViewDelegate {
    static let learningBackground = AnalysisPalette.background
    var onRetry: (() -> Void)?
    var onScrollChanged: ((Bool) -> Void)?
    var isScrolled: Bool { scroll.contentOffset.y > 2 }
    private let scroll = UIScrollView()
    private let content = UIView()
    private var english = ""
    private var presentation: KeyboardSurface.AnalysisPresentation = .idle
    private var pendingOffset: CGFloat?
    private var blocks: [(view: UIView, top: CGFloat)] = []

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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Only explicit reopening resets reading; ordinary refreshes keep position.
    func beginPresentation() {
        scroll.setContentOffset(.zero, animated: false)
        pendingOffset = 0
        setNeedsLayout()
    }
    func set(english: String, presentation: KeyboardSurface.AnalysisPresentation) {
        guard self.english != english || self.presentation != presentation else { return }
        self.english = english
        self.presentation = presentation
        pendingOffset = 0
        rebuildContent()
    }
    private func rebuildContent() {
        content.subviews.forEach { $0.removeFromSuperview() }
        blocks.removeAll(keepingCapacity: true)
        // Never reconstruct the original from model snippets: punctuation,
        // contractions and order remain exactly as translated.
        if !english.isEmpty {
            let original = AnalysisLabel(english, size: 18, lineHeight: 28)
            original.accessibilityIdentifier = "keyboard.analysisOriginal"
            append(original)
        }
        switch presentation {
        case .idle, .loading:
            append(AnalysisLoadingView(), top: english.isEmpty ? 0 : 18)
        case let .failure(message):
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
        setNeedsLayout()
    }
    private func buildAnalysis(_ analysis: SentenceAnalysis) {
        if let overview = analysis.overview, !overview.isEmpty {
            let sentence = analysis.kind == "sentence"
            let label = AnalysisLabel(overview, size: sentence ? 13 : 15,
                                      lineHeight: sentence ? 21 : 24,
                                      color: sentence ? AnalysisPalette.secondary : AnalysisPalette.text)
            label.accessibilityIdentifier = "keyboard.analysisOverview"
            append(label, top: 8)
        }
        if !analysis.insights.isEmpty {
            let section = AnalysisReadingSection(title: analysis.kind == "word" ? "用法" : "关键用法",
                                                  identifier: "keyboard.analysisInsightHeading")
            for (index, insight) in analysis.insights.enumerated() {
                let group = AnalysisVerticalGroup()
                group.accessibilityIdentifier = "keyboard.analysisInsight.\(index)"
                let title = AnalysisLabel(insight.title, size: 17, lineHeight: 25,
                                          color: AnalysisPalette.blue, weight: .medium)
                title.accessibilityIdentifier = "keyboard.analysisInsightTitle.\(index)"
                group.append(title)
                let explanation = AnalysisLabel(insight.explanation, size: 14, lineHeight: 23)
                explanation.accessibilityIdentifier = "keyboard.analysisInsightExplanation.\(index)"
                group.append(explanation, top: 5)
                section.append(group, top: index == 0 ? 9 : 16)
            }
            append(section, top: 20)
        }
        if !analysis.expressions.isEmpty {
            let section = AnalysisReadingSection(title: "实用表达", identifier: "keyboard.analysisExpressionHeading")
            section.accessibilityIdentifier = "keyboard.analysisExpressions"
            var visibleCount = 0
            for (index, expression) in analysis.expressions.enumerated() {
                let group = AnalysisVerticalGroup()
                let repeatsOriginal = expression.text.caseInsensitiveCompare(
                    english.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
                let repeatsMeaning = expression.meaning == analysis.overview
                // A standalone word/phrase already has its heading above.
                if !repeatsOriginal {
                    let title = AnalysisLabel(expression.text, size: 16, lineHeight: 24,
                                              color: AnalysisPalette.teal, weight: .medium)
                    title.accessibilityIdentifier = "keyboard.analysisExpressionText.\(index)"
                    group.append(title)
                }
                if !repeatsMeaning {
                    let meaning = AnalysisLabel(expression.meaning, size: 14, lineHeight: 23)
                    meaning.accessibilityIdentifier = "keyboard.analysisExpressionMeaning.\(index)"
                    group.append(meaning, top: repeatsOriginal ? 0 : 3)
                }
                if let usage = expression.usage, !usage.isEmpty,
                   usage != analysis.overview, usage != expression.meaning {
                    let note = AnalysisLabel(usage, size: 13, lineHeight: 21, color: AnalysisPalette.secondary)
                    note.accessibilityIdentifier = "keyboard.analysisExpressionUsage.\(index)"
                    group.append(note, top: repeatsOriginal && repeatsMeaning ? 0 : 3)
                }
                if !group.subviews.isEmpty {
                    section.append(group, top: visibleCount == 0 ? 9 : 15)
                    visibleCount += 1
                }
            }
            if visibleCount > 0 { append(section, top: 20) }
        }
    }
    private func append(_ view: UIView, top: CGFloat = 0) {
        blocks.append((view, top))
        content.addSubview(view)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        scroll.frame = bounds
        // Canvas is already inset 4 pt, making 18 pt page margins.
        let inset: CGFloat = bounds.width < 347 ? 10 : 14
        let width = max(1, bounds.width - inset * 2)
        var y: CGFloat = 8
        for block in blocks {
            y += block.top
            var height = ceil(block.view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            if block.view is UIButton { height = max(44, height) }
            block.view.frame = CGRect(x: inset, y: y, width: width, height: height)
            y += height
        }
        let contentHeight = max(bounds.height, y + 24)
        content.frame = CGRect(x: 0, y: 0, width: bounds.width, height: contentHeight)
        scroll.contentSize = content.bounds.size
        let maximumOffset = max(0, contentHeight - bounds.height)
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

@MainActor
private enum AnalysisPalette {
    static let background = color(light: 0xF4F5F8, dark: 0x181A1F)
    static let text = color(light: 0x252C36, dark: 0xEBEFF6)
    static let secondary = color(light: 0x667180, dark: 0xAAB4C4)
    static let rule = color(light: 0xE5E8ED, dark: 0x383E48)
    static let blue = color(light: 0x3969AD, dark: 0x9EBEF1)
    static let teal = color(light: 0x277C6C, dark: 0x8BCBB8)
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
private final class AnalysisLabel: UILabel {
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

@MainActor
private class AnalysisVerticalGroup: UIView {
    private var rows: [(view: UIView, top: CGFloat)] = []
    func append(_ view: UIView, top: CGFloat = 0) { rows.append((view, top)); addSubview(view) }
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let innerWidth = max(1, width)
        var y: CGFloat = 0
        for row in rows {
            y += row.top
            let height = ceil(row.view.sizeThatFits(CGSize(width: innerWidth, height: .greatestFiniteMagnitude)).height)
            if apply { row.view.frame = CGRect(x: 0, y: y, width: innerWidth, height: height) }
            y += height
        }
        return y
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: arrange(width: size.width, apply: false)) }
    override func layoutSubviews() { super.layoutSubviews(); _ = arrange(width: bounds.width, apply: true) }
}

@MainActor
private final class AnalysisReadingSection: AnalysisVerticalGroup {
    init(title: String, identifier: String) {
        super.init(frame: .zero)
        append(AnalysisRule())
        let heading = AnalysisLabel(title, size: 12, lineHeight: 18, color: AnalysisPalette.secondary, weight: .medium)
        heading.accessibilityIdentifier = identifier
        append(heading, top: 14)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class AnalysisRule: UIView {
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = AnalysisPalette.rule }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: size.width, height: 0.5) }
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
