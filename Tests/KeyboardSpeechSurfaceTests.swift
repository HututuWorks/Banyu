// Real UIKit geometry and interaction checks; no credentials, transport calls,
// audio output or fabricated phone chrome are used by this harness.
import UIKit
import Darwin

private struct SpeechSurfaceFailure: Error { let message: String }

@MainActor
private enum SpeechSurfaceChecks {
    static var assertions = 0
    static let english = "I'd like to set up an agent platform for research, though it might be quite resource-intensive. I'll make it up to you later and throw in some extra perks."
    static let analysis = SentenceAnalysis(kind: "sentence", overview: "先表达计划，再说明顾虑与补偿。", insights: [
        .init(source: "I'd like to", title: "委婉地表达想法", explanation: "would like to 后接动词原形，用来表达想做的事。")
    ], expressions: [.init(text: "set up", source: "set up", meaning: "建立、搭建")])
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
