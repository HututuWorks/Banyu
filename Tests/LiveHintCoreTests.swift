import Foundation
import Combine

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

/// Deliberately ignores cancellation: this reproduces a late provider response.
@MainActor
private final class ControlledTranslator: HintTranslating {
    struct Request {
        let source: String
        let continuation: CheckedContinuation<HintTranslationResult, Error>
    }
    private(set) var requests: [Request] = []
    private(set) var cancelled: Set<Int> = []

    func translate(_ source: String) async throws -> HintTranslationResult {
        let index = requests.count
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requests.append(Request(source: source, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelled.insert(index) }
        }
    }

    func succeed(_ index: Int, text: String) {
        requests[index].continuation.resume(returning: HintTranslationResult(text: text, sourceLanguageCode: "zh-Hans"))
    }

    func fail(_ index: Int, error: Error) {
        requests[index].continuation.resume(throwing: error)
    }
}

@main
struct LiveHintCoreTests {
    @MainActor
    static func main() async throws {
        try contextTests()
        try await completeDraftTest()
        try await selectedDraftTest()
        try await inputLimitCancellationTest()
        try await inputLimitCompositionTest()
        try await debounceTest()
        try await staleResponseTest()
        try await clearingTest()
        try await resetTest()
        try await documentChangeTest()
        try await compositionTest()
        try await compositionPauseTest()
        try await retryTest()
        try await duplicateContextTest()
        try await automaticRecoveryTest()
        try await permanentMissingPackTest()
        try await recoveryCancellationTest()
        try await staleRecoveryResponseTest()
        try await nonrecoverableErrorTest()
        try await reentrantWaitingTest()
        try await reentrantResetTest()
        try await releasingModelCancelsRequestTest()
#if APPLE_PROVIDER_TESTS
        try chineseScriptCompatibilityTests()
        try installedTranslationPlanTests()
        try await englishPassthroughTest()
#endif
        print("PASS: complete draft/selection extraction, length-limit recovery and cancellation, asynchronous/recovery scenarios, synchronous publication invalidation and owner-release cancellation")
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw TestFailure(description: message) }
    }

    @MainActor
    private static func waitUntil(_ message: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw TestFailure(description: "Timed out: \(message)")
    }

    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private static let introduction = "你好。\n\n这是伴语，一款可以边打字边学英语的键盘。\n\n你可以照常输入中文，伴语会显示对应的英文表达，轻点单词或小喇叭就能听发音。"

    private static func contextTests() throws {
        try expect(HintContextExtractor.extract(before: nil, after: nil).isEmpty, "Unavailable proxy context must be empty")
        try expect(HintContextExtractor.extract(before: "上一句。明天我们", after: "去公园。后一句。") == "上一句。明天我们去公园。后一句。", "Keep both sides and all sentences supplied by the host")
        try expect(HintContextExtractor.extract(before: "上一句。明天见。", after: "") == "上一句。明天见。", "Sentence punctuation must not discard earlier draft text")
        try expect(HintContextExtractor.extract(before: "上一句！真的吗？！", after: nil) == "上一句！真的吗？！", "Keep adjacent final punctuation and preceding sentences")
        try expect(HintContextExtractor.extract(before: "上一句。她说：“明天见。”", after: nil) == "上一句。她说：“明天见。”", "Preserve quoted sentences verbatim")
        try expect(HintContextExtractor.extract(before: "上一句。明天见。😊", after: nil) == "上一句。明天见。😊", "Preserve trailing emoji and the full draft")
        try expect(HintContextExtractor.extract(before: "明天见！ 👍🏽 \t", after: nil) == "明天见！ 👍🏽", "Preserve an emoji suffix while trimming trailing whitespace")
        try expect(HintContextExtractor.extract(before: "当前草稿。\n😊", after: nil) == "当前草稿。\n😊", "A newline and emoji are still part of the current host draft")
        try expect(HintContextExtractor.extract(before: "你好，", after: nil) == "你好，", "Trailing nonterminal punctuation must retain the draft")
        try expect(HintContextExtractor.extract(before: "当前草稿\n", after: "") == "当前草稿", "A trailing blank line must not discard the current draft")
        try expect(HintContextExtractor.extract(before: "我买了3.14", after: "公斤苹果。") == "我买了3.14公斤苹果。", "Do not split a decimal number")
        try expect(HintContextExtractor.extract(before: "1234 😀？！", after: "").isEmpty, "Numbers and punctuation alone are not a translation request")
        try expect(HintContextExtractor.extract(before: "", after: "Bonjour. Next.") == "Bonjour. Next.", "Read the supplied draft when the cursor is at its start")
        try expect(HintContextExtractor.extract(before: "Hello ", after: "world!") == "Hello world!", "Preserve spaces across the cursor")
        try expect(HintContextExtractor.extract(before: "Cafe", after: "\u{301}", maximumLength: 4) == "Cafe\u{301}", "A grapheme split at the cursor must count once")
        try expect(HintContextExtractor.extract(before: " \n\n" + introduction + "\n ", after: nil) == introduction, "The user's three paragraphs retain all internal blank lines")
        let compact = introduction.replacingOccurrences(of: "\n\n", with: "")
        try expect(HintContextExtractor.extract(before: compact, after: nil) == compact, "Removing blank lines must not alter translation scope")
        let firstPart = "你好。\n\n这是伴语，"
        let remainingPart = "一款可以边打字边学英语的键盘。\n\n你可以照常输入中文，伴语会显示对应的英文表达，轻点单词或小喇叭就能听发音。"
        try expect(HintContextExtractor.extract(before: firstPart, after: remainingPart) == introduction, "A cursor in the middle of a paragraph preserves the entire supplied draft")
        try expect(HintContextExtractor.extract(before: "第一段。\r", after: "\n\r\n第二段。") == "第一段。\r\n\r\n第二段。", "Preserve Windows paragraph separators without normalization")
        try expect(HintContextExtractor.extract(before: "不应拼接", after: "这里", selectedText: " 选择这段。\n\n保留空行。 ") == "选择这段。\n\n保留空行。", "An explicit selection takes precedence over omitted before/after text")
        try expect(HintContextExtractor.extract(before: "仍有上下文", after: "内容", selectedText: " \n\n ").isEmpty, "A whitespace selection must not silently translate other text")
        try expect(HintContextExtractor.extract(before: "正常", after: "草稿", selectedText: "") == "正常草稿", "An empty selection uses the supplied cursor context")
        let boundary = String(repeating: "文", count: 400)
        try expect(HintContextExtractor.extractResult(before: "\n " + boundary, after: " \n") == .text(boundary), "Exactly 400 trimmed characters are allowed")
        try expect(HintContextExtractor.extractResult(before: boundary, after: "字") == .inputLimited, "The 401st character rejects the whole input instead of truncating it")
        try expect(HintContextExtractor.extractResult(before: String(repeating: "前", count: 800), after: String(repeating: "后", count: 800)) == .inputLimited, "Overlong context is never translated as a cursor-centred fragment")
        try expect(HintContextExtractor.extractResult(before: "上下文", after: "不重要", selectedText: boundary + "字") == .inputLimited, "An overlong selection cannot fall back to translating unrelated context")
        let largeWhitespace = String(repeating: " \n", count: 10_000)
        try expect(HintContextExtractor.extractResult(before: largeWhitespace + boundary, after: largeWhitespace) == .text(boundary), "Large outer whitespace is trimmed without reducing the content budget")
        try expect(HintContextExtractor.extractResult(before: "甲" + largeWhitespace, after: "乙") == .inputLimited, "Large internal whitespace counts toward the bounded complete draft")
        try expect(HintContextExtractor.extractResult(before: largeWhitespace, after: nil) == .empty, "Whitespace-only input has no translation request")
        try expect(HintContextExtractor.extract(before: "hi", after: nil, maximumLength: 0).isEmpty, "Reject an invalid character budget")
    }

    @MainActor
    private static func completeDraftTest() async throws {
        let translator = ControlledTranslator()
        let model = LiveHintModel(translator: translator, debounceNanoseconds: 0)
        let document = UUID()
        model.update(before: introduction, after: "", documentID: document)
        try await waitUntil("complete three-paragraph request") { translator.requests.count == 1 }
        try expect(translator.requests[0].source == introduction, "Translate all three supplied paragraphs in one request")
        model.update(before: "你好。\n\n", after: String(introduction.dropFirst(5)), documentID: document)
        await settle()
        try expect(translator.requests.count == 1, "Moving between paragraphs within the same draft does not restart translation")
        translator.succeed(0, text: "Hello.\n\nThis is Banyu, a keyboard for learning English as you type.\n\nType in Chinese as usual.")
        try await waitUntil("complete three-paragraph result") { model.state.status == .ready }
        try expect(model.state.source == introduction && model.state.displayText.contains("\n\nThis is Banyu"), "Preserve both source and returned translation paragraph boundaries")
    }

    @MainActor
    private static func selectedDraftTest() async throws {
        let translator = ControlledTranslator()
        let model = LiveHintModel(translator: translator, debounceNanoseconds: 0)
        model.update(before: "你好。\n\n", after: "\n\n第三段内容。", selectedText: "这是伴语。")
        try await waitUntil("explicit selected paragraph") { translator.requests.count == 1 }
        try expect(translator.requests[0].source == "这是伴语。", "The selection is the sole request source")
        model.update(before: "你好。\n\n", after: "\n\n第三段内容。", selectedText: "1234！")
        try expect(model.state == .idle, "A symbols/numbers selection clears the old hint without translating context")
        translator.succeed(0, text: "This is Banyu.")
        await settle()
        try expect(model.state == .idle && translator.requests.count == 1, "A late selected-text result cannot resurrect a cleared selection")
    }

    @MainActor
    private static func inputLimitCancellationTest() async throws {
        for lateFailure in [false, true] {
            let translator = ControlledTranslator()
            let model = LiveHintModel(translator: translator, debounceNanoseconds: 0,
                                      retryDelaysNanoseconds: [1_000_000])
            model.update(before: "原来的草稿。", after: "")
            try await waitUntil("request before exceeding length limit") { translator.requests.count == 1 }
            model.update(before: String(repeating: "长", count: 401), after: "")
            try expect(model.state.status == .inputLimited && model.state.source.isEmpty,
                       "Oversized input immediately clears old source and publishes a dedicated limit state")
            try expect(model.state.displayText.contains("400") && !model.state.displayText.contains("重试"),
                       "Length guidance explains how to select a smaller scope without suggesting retry")
            model.retry()
            if lateFailure { translator.fail(0, error: HintTranslationError.serviceUnavailable) }
            else { translator.succeed(0, text: "Old draft.") }
            await settle()
            try expect(model.state.status == .inputLimited && translator.requests.count == 1,
                       "Explicit retry and late success/failure cannot translate or overwrite an oversized input")
            model.update(before: "恢复到短内容。", after: "")
            try await waitUntil("short input resumes after length limit") { translator.requests.count == 2 }
            translator.succeed(1, text: "A shorter draft.")
            try await waitUntil("recovered shorter result") { model.state.status == .ready }
            try expect(model.state.source == "恢复到短内容。", "Editing below the budget restores normal translation automatically")
            model.update(before: String(repeating: "长", count: 401), after: "")
            model.update(before: nil, after: nil)
            try expect(model.state == .idle, "Clearing an oversized host field returns to idle")
        }
    }

    @MainActor
    private static func inputLimitCompositionTest() async throws {
        let translator = ControlledTranslator()
        let model = LiveHintModel(translator: translator, debounceNanoseconds: 0)
        let overlong = String(repeating: "长", count: 401)
        model.update(before: overlong, after: "", isComposing: true)
        model.retry()
        await settle()
        try expect(model.state.status == .waiting && translator.requests.isEmpty,
                   "Composition suppresses length guidance and all translation requests until committed")
        model.update(before: overlong, after: "", isComposing: false)
        try expect(model.state.status == .inputLimited && translator.requests.isEmpty,
                   "A committed oversized composition shows the limit without translating a fragment")
        model.update(before: "", after: "", isComposing: true)
        try expect(model.state.status == .waiting, "Empty host context during composition must remain waiting")
        model.update(before: "完成输入", after: "", isComposing: false)
        try await waitUntil("valid composition after limit") { translator.requests.count == 1 }
        translator.succeed(0, text: "Input complete.")
        try await waitUntil("valid composition result after limit") { model.state.status == .ready }
    }

    @MainActor
    private static func debounceTest() async throws {
        let translator = ControlledTranslator()
        let model = LiveHintModel(translator: translator, debounceNanoseconds: 40_000_000)
        model.update(before: "我想", after: "")
        model.update(before: "我想喝水", after: "")
        try expect(model.state.status == .waiting, "Input should enter waiting immediately")
        try await waitUntil("debounced request") { translator.requests.count == 1 }
        try expect(translator.requests[0].source == "我想喝水", "Debounce must discard superseded input")
        translator.succeed(0, text: "I want some water.")
        try await waitUntil("debounced result") { model.state.status == .ready }
    }

    @MainActor
    private static func staleResponseTest() async throws {
        let translator = ControlledTranslator()
        let model = LiveHintModel(translator: translator, debounceNanoseconds: 0)
        model.update(before: "我喜欢", after: "")
        try await waitUntil("old request") { translator.requests.count == 1 }
        model.update(before: "我不喜欢", after: "")
        try expect(model.state.displayText != "I like it.", "Old text is not retained for a changed input")
        try await waitUntil("new request") { translator.requests.count == 2 }
        translator.succeed(1, text: "I don't like it.")
        try await waitUntil("new result") { model.state.status == .ready }
        translator.succeed(0, text: "I like it.")
        await settle()
        try expect(model.state.source == "我不喜欢" && model.state.displayText == "I don't like it.", "A cancelled provider's late success must not overwrite the current result")
    }

    @MainActor
    private static func clearingTest() async throws {
        let translator = ControlledTranslator()
        let model = LiveHintModel(translator: translator, debounceNanoseconds: 0)
        model.update(before: "你好", after: "")
        try await waitUntil("request before clearing") { translator.requests.count == 1 }
        model.update(before: nil, after: nil)
        try expect(model.state == .idle, "Clearing must remove the previous sentence immediately")
        translator.succeed(0, text: "Hello.")
        await settle()
        try expect(model.state == .idle, "A late response must not resurrect cleared input")
    }

    @MainActor
    private static func resetTest() async throws {
        let translator = ControlledTranslator()
        let model = LiveHintModel(translator: translator, debounceNanoseconds: 0)
        model.update(before: "谢谢", after: "")
        try await waitUntil("request before reset") { translator.requests.count == 1 }
        model.reset()
        translator.fail(0, error: HintTranslationError.unavailable)
        await settle()
        try expect(model.state == .idle, "A late failure must not appear after keyboard dismissal")
    }

    @MainActor
    private static func documentChangeTest() async throws {
        let translator = ControlledTranslator()
        let model = LiveHintModel(translator: translator, debounceNanoseconds: 0)
        model.update(before: "今天", after: "", documentID: UUID())
        try await waitUntil("first document request") { translator.requests.count == 1 }
        model.update(before: "今天", after: "", documentID: UUID())
        try await waitUntil("second document request with identical text") { translator.requests.count == 2 }
        translator.succeed(0, text: "Previous field")
        await settle()
        try expect(model.state.status == .translating, "Switching fields must invalidate even identical text")
        translator.succeed(1, text: "Today")
        try await waitUntil("second document result") { model.state.status == .ready }
        try expect(model.state.displayText == "Today", "Only current document may update the hint")
    }

    @MainActor
    private static func compositionTest() async throws {
        let translator = ControlledTranslator()
        let model = LiveHintModel(translator: translator, debounceNanoseconds: 0)
        model.update(before: "未确定输入", after: "", isComposing: true)
        await settle()
        try expect(translator.requests.isEmpty && model.state.status == .waiting, "Uncommitted composition must not be translated")
        model.update(before: "未确定输入", after: "", isComposing: false)
        try await waitUntil("committed composition") { translator.requests.count == 1 }
        translator.succeed(0, text: "Committed input")
        try await waitUntil("composition result") { model.state.status == .ready }
    }

    @MainActor
    private static func compositionPauseTest() async throws {
        let translator = ControlledTranslator()
        let model = LiveHintModel(translator: translator, debounceNanoseconds: 0)
        model.update(before: "原来的句子", after: "")
        try await waitUntil("request before composing") { translator.requests.count == 1 }
        model.pauseForComposition()
        model.pauseForComposition()
        try expect(model.state.status == .waiting && model.state.source.isEmpty,
                   "Starting composition invalidates the prior document snapshot without querying the host")
        translator.succeed(0, text: "Stale translation")
        await settle()
        try expect(model.state.status == .waiting && translator.requests.count == 1,
                   "Composition never starts a translation or shows a late prior result")
        model.update(before: "选定的新句子", after: "")
        try await waitUntil("fresh context after composition") { translator.requests.count == 2 }
        translator.succeed(1, text: "New sentence")
        try await waitUntil("new hint after composition") { model.state.status == .ready }
    }

    @MainActor
    private static func retryTest() async throws {
        let translator = ControlledTranslator()
        let model = LiveHintModel(translator: translator, debounceNanoseconds: 0, retryDelaysNanoseconds: [])
        model.update(before: "早上好", after: "")
        try await waitUntil("language pack request") { translator.requests.count == 1 }
        translator.fail(0, error: HintTranslationError.needsLanguagePack(sourceLanguageCode: "zh-Hans"))
        try await waitUntil("language pack state") { model.state.status == .needsLanguagePack }
        try expect(model.state.sourceLanguageCode == "zh-Hans", "Expose the language that needs preparation")
        model.retry()
        try await waitUntil("explicit retry") { translator.requests.count == 2 }
        translator.succeed(1, text: "Good morning.")
        try await waitUntil("retry result") { model.state.status == .ready }
    }

    @MainActor
    private static func duplicateContextTest() async throws {
        let translator = ControlledTranslator()
        let model = LiveHintModel(translator: translator, debounceNanoseconds: 0)
        let document = UUID()
        model.update(before: "我想", after: "出去。", documentID: document)
        try await waitUntil("cursor context") { translator.requests.count == 1 }
        model.update(before: "我想出", after: "去。", documentID: document)
        await settle()
        try expect(translator.requests.count == 1, "Moving the cursor inside the same sentence should not duplicate translation")
        translator.succeed(0, text: "I want to go out.")
        try await waitUntil("cursor context result") { model.state.status == .ready }
    }

    @MainActor
    private static func automaticRecoveryTest() async throws {
        let translator = ControlledTranslator()
        let model = LiveHintModel(translator: translator, debounceNanoseconds: 0,
                                  retryDelaysNanoseconds: [1_000_000, 2_000_000, 3_000_000])
        model.update(before: "我快到了", after: "")
        try await waitUntil("first cold-service attempt") { translator.requests.count == 1 }
        translator.fail(0, error: HintTranslationError.needsLanguagePack(sourceLanguageCode: "zh-Hans"))
        try await waitUntil("automatic recovery after notInstalled") { translator.requests.count == 2 }
        try expect(model.state.status == .translating, "A transient notInstalled must not show a missing-pack warning")
        translator.fail(1, error: HintTranslationError.serviceUnavailable)
        try await waitUntil("automatic recovery after service failure") { translator.requests.count == 3 }
        try expect(model.state.status == .translating, "Remain in recovery while the system service returns")
        translator.succeed(2, text: "I'm almost there.")
        try await waitUntil("recovery without another edit") { model.state.status == .ready }
        try expect(translator.requests.allSatisfy { $0.source == "我快到了" }, "Retries must preserve the original source")
        try expect(model.state.displayText == "I'm almost there.", "Successful recovery must publish the actual result")
    }

    @MainActor
    private static func permanentMissingPackTest() async throws {
        try expect(LiveHintModel.recoveryDelaysNanoseconds == [600_000_000, 1_400_000_000, 2_500_000_000],
                   "Production recovery has three bounded backoff intervals")
        let translator = ControlledTranslator()
        let model = LiveHintModel(translator: translator, debounceNanoseconds: 0,
                                  retryDelaysNanoseconds: [1_000_000, 2_000_000, 3_000_000, 4_000_000])
        model.update(before: "没有语言包", after: "")
        for attempt in 0..<4 {
            try await waitUntil("bounded attempt \(attempt)") { translator.requests.count == attempt + 1 }
            try expect(model.state.status == .translating, "Do not declare a missing pack before all four attempts end")
            translator.fail(attempt, error: HintTranslationError.needsLanguagePack(sourceLanguageCode: "zh-Hans"))
        }
        try await waitUntil("final missing-pack guidance") { model.state.status == .needsLanguagePack }
        try expect(model.state.sourceLanguageCode == "zh-Hans", "Final guidance identifies the required pack")
        try await Task.sleep(nanoseconds: 20_000_000)
        model.update(before: "没有语言包", after: "")
        await settle()
        try expect(translator.requests.count == 4, "Exhausted identical input must not start an unbounded loop")
        model.retry()
        try await waitUntil("manual retry after bounded exhaustion") { translator.requests.count == 5 }
        translator.succeed(4, text: "The language pack is ready now.")
        try await waitUntil("manual retry completion") { model.state.status == .ready }
    }

    @MainActor
    private static func recoveryCancellationTest() async throws {
        for pauseComposition in [false, true] {
            let translator = ControlledTranslator()
            let model = LiveHintModel(translator: translator, debounceNanoseconds: 0,
                                      retryDelaysNanoseconds: [5_000_000])
            model.update(before: "待恢复的句子", after: "")
            try await waitUntil("request before hiding/composing") { translator.requests.count == 1 }
            translator.fail(0, error: HintTranslationError.needsLanguagePack(sourceLanguageCode: "zh-Hans"))
            try await waitUntil("recovery delay entered") { model.state.displayText == "正在恢复英文提示…" }
            if pauseComposition { model.pauseForComposition() }
            else { model.reset() }
            try await Task.sleep(nanoseconds: 20_000_000)
            try expect(translator.requests.count == 1, "Hiding or composing must cancel a pending automatic retry")
            try expect(model.state.status == (pauseComposition ? .waiting : .idle), "Recovery must not overwrite reset/composition state")
        }
    }

    @MainActor
    private static func staleRecoveryResponseTest() async throws {
        for lateFailure in [false, true] {
            let translator = ControlledTranslator()
            let model = LiveHintModel(translator: translator, debounceNanoseconds: 0,
                                      retryDelaysNanoseconds: [1_000_000, 2_000_000, 3_000_000])
            model.update(before: "旧句子", after: "", documentID: UUID())
            try await waitUntil("old initial request") { translator.requests.count == 1 }
            translator.fail(0, error: HintTranslationError.needsLanguagePack(sourceLanguageCode: "zh-Hant"))
            try await waitUntil("old recovery in flight") { translator.requests.count == 2 }
            model.update(before: "新句子", after: "", documentID: UUID())
            try await waitUntil("new input supersedes recovery") { translator.requests.count == 3 }
            translator.succeed(2, text: "New sentence.")
            try await waitUntil("current input ready") { model.state.status == .ready }
            if lateFailure { translator.fail(1, error: HintTranslationError.serviceUnavailable) }
            else { translator.succeed(1, text: "Stale sentence.") }
            try await Task.sleep(nanoseconds: 20_000_000)
            try expect(model.state.displayText == "New sentence." && model.state.source == "新句子",
                       "Late success/failure from a canceled recovery cannot overwrite the newer result")
            try expect(translator.requests.count == 3, "A stale failure must not schedule another retry")
        }
    }

    @MainActor
    private static func nonrecoverableErrorTest() async throws {
        for error in [HintTranslationError.unsupportedLanguage, .unableToIdentifyLanguage,
                      .cloudConfiguration, .cloudAuthentication, .cloudAccessDenied,
                      .cloudUnavailable, .fullAccessRequired, .settingsUnavailable, .settingsChanged] {
            let translator = ControlledTranslator()
            let model = LiveHintModel(translator: translator, debounceNanoseconds: 0,
                                      retryDelaysNanoseconds: [1_000_000])
            model.update(before: "无法识别的句子", after: "")
            try await waitUntil("unsupported input request") { translator.requests.count == 1 }
            translator.fail(0, error: error)
            try await waitUntil("nonrecoverable error visible") { model.state.status == .error }
            try await Task.sleep(nanoseconds: 10_000_000)
            try expect(translator.requests.count == 1, "Permanent, cloud and configuration errors must not trigger automatic paid retries")
        }
    }


    @MainActor
    private static func reentrantWaitingTest() async throws {
        let translator = ControlledTranslator()
        let model = LiveHintModel(translator: translator, debounceNanoseconds: 0)
        var replaced = false
        let observation = model.$state.sink { [weak model] state in
            guard state.status == .waiting, !replaced else { return }
            replaced = true
            model?.update(before: "最新输入", after: "")
        }
        model.update(before: "过时输入", after: "")
        await settle()
        let sources = translator.requests.map(\.source)
        for index in translator.requests.indices { translator.succeed(index, text: "Result") }
        await settle()
        withExtendedLifetime(observation) {}
        try expect(sources == ["最新输入"], "A synchronous waiting observer must not dispatch superseded input")
        try expect(model.state.source == "最新输入", "The newest state survives synchronous publication callbacks")
    }

    @MainActor
    private static func reentrantResetTest() async throws {
        for resetAt in [LiveHintStatus.waiting, .translating] {
            let translator = ControlledTranslator()
            let model = LiveHintModel(translator: translator, debounceNanoseconds: 0)
            let observation = model.$state.sink { [weak model] state in
                if state.status == resetAt { model?.reset() }
            }
            model.update(before: "已失活输入", after: "")
            await settle()
            let dispatched = translator.requests.count
            for index in translator.requests.indices { translator.succeed(index, text: "Obsolete") }
            await settle()
            withExtendedLifetime(observation) {}
            try expect(dispatched == 0, "Synchronous reset during waiting/translating prevents any provider call")
            try expect(model.state == .idle, "A reset cannot be overwritten by the enclosing Published assignment")
        }
    }

    @MainActor
    private static func releasingModelCancelsRequestTest() async throws {
        let translator = ControlledTranslator()
        var model: LiveHintModel? = LiveHintModel(translator: translator, debounceNanoseconds: 0)
        weak let observed = model
        model?.update(before: "即将离开的输入", after: "")
        try await waitUntil("request before owner release") { translator.requests.count == 1 }
        model = nil
        await settle()
        let released = observed == nil
        let cancelled = translator.cancelled.contains(0)
        translator.succeed(0, text: "Late result")
        await settle()
        try expect(released && cancelled, "Releasing the model cancels in-flight translation instead of retaining itself across await")
    }

#if APPLE_PROVIDER_TESTS
    private static func chineseScriptCompatibilityTests() throws {
        for source in ["你好", "我快到了", "你好😊", "下午三点开会。", "你好，Alex！"] {
            try expect(ChineseScriptCompatibility.alternateModelLanguage(for: source, detectedLanguageCode: "zh-Hant") == "zh-Hans",
                       "Unchanged Chinese text may use an installed simplified model: \(source)")
        }
        for source in ["我想預訂明天的會議室。", "髮型", "這個問題需要重新討論。", "我愛學習英語。"] {
            try expect(ChineseScriptCompatibility.alternateModelLanguage(for: source, detectedLanguageCode: "zh-Hant") == nil,
                       "Distinct traditional text must not be relabeled or rewritten: \(source)")
        }
        for source in ["こんにちは", "明日の会議室を予約したいです。", "你好カナ", "你好ｶﾅ"] {
            try expect(ChineseScriptCompatibility.alternateModelLanguage(for: source, detectedLanguageCode: "zh-Hant") == nil,
                       "Kana must prevent a Chinese-script fallback even if recognition is wrong")
        }
        try expect(ChineseScriptCompatibility.alternateModelLanguage(for: "你好", detectedLanguageCode: "ja") == nil,
                   "The fallback must not override a non-Chinese language decision")
        try expect(ChineseScriptCompatibility.alternateModelLanguage(for: "Hello", detectedLanguageCode: "en") == nil,
                   "English must not enter Chinese model selection")
        try expect(ChineseScriptCompatibility.alternateModelLanguage(for: "你好", detectedLanguageCode: "zh-Hans") == "zh-Hant",
                   "Shared characters can also use an installed traditional model")
        try expect(ChineseScriptCompatibility.alternateModelLanguage(for: "我想预订明天的会议室。", detectedLanguageCode: "zh-Hans") == nil,
                   "Distinct simplified text must not be relabeled traditional")
        print("PASS: real ICU Chinese script compatibility, distinct scripts and Japanese safeguards")
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func installedTranslationPlanTests() throws {
        try expect(InstalledTranslationPlan.languageCodes(source: "你好", detectedCode: "zh-Hant", status: .supported,
                                                          alternateStatus: .supported) == ["zh-Hant", "zh-Hans"],
                   "Cold supported/supported availability must still permit installed-only verification")
        try expect(InstalledTranslationPlan.languageCodes(source: "你好", detectedCode: "zh-Hant", status: .supported,
                                                          alternateStatus: .installed) == ["zh-Hans"],
                   "A later supported/installed reading uses the compatible installed model directly")
        try expect(InstalledTranslationPlan.languageCodes(source: "你好", detectedCode: "zh-Hant", status: .installed,
                                                          alternateStatus: .supported) == ["zh-Hant"],
                   "The detected installed model stays preferred")
        for source in ["這個問題", "你好カナ", "你好ｶﾅ"] {
            try expect(InstalledTranslationPlan.languageCodes(source: source, detectedCode: "zh-Hant", status: .supported,
                                                              alternateStatus: .supported) == ["zh-Hant"],
                       "Recovery never relabels distinct traditional or Japanese text")
        }
        try expect(InstalledTranslationPlan.languageCodes(source: "你好", detectedCode: "zh-Hans", status: .supported,
                                                          alternateStatus: .supported) == ["zh-Hans", "zh-Hant"],
                   "Unchanged-script recovery is symmetric")
        try expect(InstalledTranslationPlan.languageCodes(source: "你好", detectedCode: "zh-Hant", status: .supported,
                                                          alternateStatus: .unsupported) == ["zh-Hant"],
                   "An unsupported alternate is never probed")
        print("PASS: pure installed-only probe plan, supported-to-installed transition and unchanged-script limits")
    }

    @available(macOS 26.0, iOS 26.0, *)
    @MainActor
    private static func englishPassthroughTest() async throws {
        let source = "I would like a glass of water, please."
        let result = try await AppleInstalledTranslator().translate(source)
        try expect(result.text == source && result.sourceLanguageCode == "en", "English must pass through without a translation session")
        print("PASS: real NaturalLanguage English detection and same-language bypass")
    }
#endif
}
