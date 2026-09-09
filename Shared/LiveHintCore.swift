import Foundation
import Combine

enum LiveHintStatus: String, Equatable, Sendable {
    case idle, waiting, translating, ready, inputLimited, needsLanguagePack, error
}

struct LiveHintState: Equatable, Sendable {
    var status: LiveHintStatus
    var source: String
    var displayText: String
    var sourceLanguageCode: String?

    static let idle = LiveHintState(status: .idle, source: "", displayText: "输入内容，查看英文提示")
}

struct HintTranslationResult: Equatable, Sendable {
    let text: String
    let sourceLanguageCode: String
}

enum HintTranslationError: Error, Equatable, Sendable {
    case needsLanguagePack(sourceLanguageCode: String)
    case unsupportedLanguage
    case serviceUnavailable
    case unableToIdentifyLanguage
    case unavailable
    case cloudConfiguration
    case cloudAuthentication
    case cloudAccessDenied
    case cloudUnavailable
    case fullAccessRequired
    case settingsUnavailable
    case settingsChanged
}

@MainActor
protocol HintTranslating {
    func translate(_ source: String) async throws -> HintTranslationResult
}

/// Preserves the draft context iOS supplies, including paragraph boundaries.
/// The proxy may truncate either side; this never implies access to the full document.
enum HintContextExtractor {
    static let maximumCharacters = 400

    enum Result: Equatable, Sendable {
        case empty
        case text(String)
        case inputLimited

        var source: String {
            guard case let .text(source) = self else { return "" }
            return source
        }
    }

    /// Compatibility convenience for consumers that only need usable source text.
    /// An overlong draft is deliberately never returned as a translated fragment.
    static func extract(before: String?, after: String?, selectedText: String? = nil,
                        maximumLength: Int = maximumCharacters) -> String {
        extractResult(before: before, after: after, selectedText: selectedText,
                      maximumLength: maximumLength).source
    }

    static func extractResult(before: String?, after: String?, selectedText: String? = nil,
                              maximumLength: Int = maximumCharacters) -> Result {
        guard maximumLength > 0 else { return .inputLimited }
        // A proxy's before/after values omit the selected range. Treat an explicit
        // selection as the requested scope instead of joining two disconnected ends.
        let parts: [String]
        if let selectedText, !selectedText.isEmpty {
            parts = [selectedText]
        } else {
            parts = [before ?? "", after ?? ""]
        }

        var source = ""
        var pendingWhitespace = ""
        var pendingCount = 0
        var sourceCount = 0
        let whitespace = CharacterSet.whitespacesAndNewlines
        for part in parts {
            for character in part {
                if character.unicodeScalars.allSatisfy({ whitespace.contains($0) }) {
                    guard !source.isEmpty else { continue }
                    // Trailing whitespace is trimmed, even when unusually large.
                    // Retain at most the budget plus one sentinel character until
                    // another non-whitespace character makes it internal whitespace.
                    if pendingCount <= maximumLength - sourceCount {
                        pendingWhitespace.append(character)
                        pendingCount += 1
                    }
                    continue
                }
                if sourceCount + pendingCount > maximumLength { return .inputLimited }
                source.append(contentsOf: pendingWhitespace)
                source.append(character)
                pendingWhitespace.removeAll(keepingCapacity: true)
                pendingCount = 0
                // Count the joined string so a grapheme split at the cursor is
                // treated the same as the original uninterrupted draft.
                sourceCount = source.count
                guard sourceCount <= maximumLength else { return .inputLimited }
            }
        }
        guard source.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return .empty }
        return .text(source)
    }
}

@MainActor
final class LiveHintModel: ObservableObject {
    @Published private(set) var state: LiveHintState = .idle

    private struct Input: Equatable {
        let extraction: HintContextExtractor.Result
        let documentID: UUID?
        let isComposing: Bool

        var source: String { extraction.source }
    }

    private let translator: any HintTranslating
    private let debounceNanoseconds: UInt64
    private let retryDelaysNanoseconds: [UInt64]
    static let recoveryDelaysNanoseconds: [UInt64] = [600_000_000, 1_400_000_000, 2_500_000_000]
    private var task: Task<Void, Never>?
    private var revision: UInt64 = 0
    private var lastInput: Input?
    private var isPublishingState = false
    private var pendingState: LiveHintState?

    init(translator: any HintTranslating, debounceNanoseconds: UInt64 = 500_000_000,
         retryDelaysNanoseconds: [UInt64] = LiveHintModel.recoveryDelaysNanoseconds) {
        self.translator = translator
        self.debounceNanoseconds = debounceNanoseconds
        // An input gets at most four attempts, including its initial request.
        self.retryDelaysNanoseconds = Array(retryDelaysNanoseconds.prefix(3))
    }

    deinit { task?.cancel() }

    func update(before: String?, after: String?, selectedText: String? = nil,
                documentID: UUID? = nil, isComposing: Bool = false) {
        let input = Input(extraction: HintContextExtractor.extractResult(before: before, after: after,
                                                                         selectedText: selectedText),
                          documentID: documentID, isComposing: isComposing)
        guard input != lastInput else { return }
        lastInput = input
        schedule(input)
    }

    /// Call whenever the keyboard disappears or the host changes input documents.
    func reset() {
        invalidate()
        lastInput = nil
        publish(.idle)
    }

    /// Composing letters/digits do not change the host document. Avoid querying
    /// the host proxy again for every key while invalidating any previous hint.
    func pauseForComposition() {
        guard lastInput?.isComposing != true else { return }
        invalidate()
        lastInput = Input(extraction: .empty, documentID: nil, isComposing: true)
        publish(LiveHintState(status: .waiting, source: "", displayText: "选定输入内容后显示英文"))
    }

    func retry() {
        guard let lastInput, case .text = lastInput.extraction, !lastInput.isComposing else { return }
        schedule(lastInput)
    }

    private func invalidate() {
        revision &+= 1
        task?.cancel()
        task = nil
    }

    private func schedule(_ input: Input) {
        invalidate()
        let token = revision
        if input.isComposing {
            publish(LiveHintState(status: .waiting, source: input.source, displayText: "选定输入内容后显示英文"))
            return
        }
        switch input.extraction {
        case .empty:
            publish(.idle)
            return
        case .inputLimited:
            publish(LiveHintState(status: .inputLimited, source: "",
                                  displayText: "内容较长，请选中 400 字以内的内容翻译"))
            return
        case .text:
            break
        }
        publish(LiveHintState(status: .waiting, source: input.source,
                              displayText: "稍停一下，显示英文提示"))
        // Published subscribers run synchronously and may replace/reset input.
        guard revision == token, !input.isComposing else { return }
        let delay = debounceNanoseconds
        let translator = translator
        let retryDelays = retryDelaysNanoseconds
        task = Task { [weak self] in
            do {
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            } catch { return }
            var retryIndex = 0
            while true {
                guard !Task.isCancelled, self?.revision == token else { return }
                self?.publish(LiveHintState(status: .translating, source: input.source,
                                          displayText: retryIndex == 0 ? "正在生成英文提示…" : "正在恢复英文提示…"))
                guard !Task.isCancelled, self?.revision == token else { return }
                do {
                    let result = try await translator.translate(input.source)
                    // Providers may ignore cancellation. A previous input must never
                    // publish a result or start another recovery attempt.
                    guard !Task.isCancelled, self?.revision == token else { return }
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { throw HintTranslationError.unavailable }
                    self?.publish(LiveHintState(status: .ready, source: input.source, displayText: text,
                                              sourceLanguageCode: result.sourceLanguageCode))
                    return
                } catch {
                    guard !Task.isCancelled, self?.revision == token else { return }
                    guard Self.canRecover(from: error), retryIndex < retryDelays.count else {
                        self?.show(error: error, source: input.source)
                        return
                    }
                    // A cold system service can temporarily report installed models
                    // as missing. Keep the recovery visible without declaring a missing
                    // language pack until this bounded sequence has actually ended.
                    self?.publish(LiveHintState(status: .translating, source: input.source,
                                              displayText: "正在恢复英文提示…"))
                    let retryDelay = retryDelays[retryIndex]
                    retryIndex += 1
                    do { try await Task.sleep(nanoseconds: retryDelay) }
                    catch { return }
                }
            }
        }
    }

    /// @Published sends from willSet. Queue a synchronous observer's newer
    /// state until the enclosing assignment finishes, so it cannot be clobbered.
    private func publish(_ next: LiveHintState) {
        pendingState = next
        guard !isPublishingState else { return }
        isPublishingState = true
        defer { isPublishingState = false }
        while let next = pendingState {
            pendingState = nil
            state = next
        }
    }

    private static func canRecover(from error: Error) -> Bool {
        switch error {
        case is CancellationError,
             HintTranslationError.unsupportedLanguage,
             HintTranslationError.unableToIdentifyLanguage,
             HintTranslationError.cloudConfiguration,
             HintTranslationError.cloudAuthentication,
             HintTranslationError.cloudAccessDenied,
             HintTranslationError.cloudUnavailable,
             HintTranslationError.fullAccessRequired,
             HintTranslationError.settingsUnavailable,
             HintTranslationError.settingsChanged:
            return false
        default:
            // Includes notInstalled mapped to needsLanguagePack and transient XPC
            // errors whose domain is not part of the public Translation API.
            return true
        }
    }

    private func show(error: Error, source: String) {
        switch error {
        case HintTranslationError.needsLanguagePack(let code):
            let message: String
            switch code {
            case "zh-Hans": message = "请在主 App 准备「简体中文 → 英文」"
            case "zh-Hant": message = "请在主 App 准备「繁体中文 → 英文」"
            default: message = "请打开主 App，准备翻译语言包"
            }
            publish(LiveHintState(status: .needsLanguagePack, source: source,
                                  displayText: message, sourceLanguageCode: code))
        case HintTranslationError.unsupportedLanguage:
            publish(LiveHintState(status: .error, source: source, displayText: "暂不支持这种语言"))
        case HintTranslationError.serviceUnavailable:
            publish(LiveHintState(status: .error, source: source, displayText: "系统翻译服务暂不可用，轻点重试"))
        case HintTranslationError.unableToIdentifyLanguage:
            publish(LiveHintState(status: .error, source: source, displayText: "再输入几个字，帮助识别语言"))
        case HintTranslationError.cloudConfiguration:
            publish(LiveHintState(status: .error, source: source, displayText: "请在伴语中配置翻译接口"))
        case HintTranslationError.cloudAuthentication:
            publish(LiveHintState(status: .error, source: source, displayText: "API Key 无效，请在伴语中检查"))
        case HintTranslationError.cloudAccessDenied:
            publish(LiveHintState(status: .error, source: source, displayText: "接口未授权，请检查模型权限与账户"))
        case HintTranslationError.cloudUnavailable:
            publish(LiveHintState(status: .error, source: source, displayText: "翻译暂不可用，请检查网络后重试"))
        case HintTranslationError.fullAccessRequired:
            publish(LiveHintState(status: .error, source: source, displayText: "请为此键盘开启「允许完全访问」"))
        case HintTranslationError.settingsUnavailable:
            publish(LiveHintState(status: .error, source: source, displayText: "翻译设置暂不可用，请打开伴语检查"))
        case HintTranslationError.settingsChanged:
            publish(LiveHintState(status: .error, source: source, displayText: "翻译设置已更新，轻点重试"))
        default:
            publish(LiveHintState(status: .error, source: source, displayText: "翻译暂不可用，轻点重试"))
        }
    }
}
