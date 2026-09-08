import Foundation

private struct AnalysisSessionTestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class AnalysisContextValidity {
    var isCurrent = true
}

/// Every completion is controlled by the test. No transport, credentials store,
/// default analyzer, real API or wall-clock network timeout is involved.
@MainActor
private final class ControlledSentenceAnalyzer: SentenceAnalyzing {
    struct Call: Equatable {
        let english: String
        let revision: String
    }

    private let respectsCancellation: Bool
    private var pending: [Int: CheckedContinuation<SentenceAnalysis, any Error>] = [:]
    private(set) var calls: [Call] = []
    private(set) var receivedSettings: [TranslationSettingsSnapshot] = []
    private(set) var cancelled: Set<Int> = []
    private(set) var finished: Set<Int> = []

    init(respectsCancellation: Bool = false) {
        self.respectsCancellation = respectsCancellation
    }

    func analyze(_ english: String, settings: TranslationSettingsSnapshot) async throws -> SentenceAnalysis {
        let id = calls.count
        calls.append(.init(english: english, revision: settings.revision))
        receivedSettings.append(settings)
        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending[id] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(id) }
            }
            finished.insert(id)
            return result
        } catch {
            finished.insert(id)
            throw error
        }
    }

    func complete(_ id: Int, with result: Result<SentenceAnalysis, any Error>) throws {
        guard let continuation = pending.removeValue(forKey: id) else {
            throw AnalysisSessionTestFailure(description: "No pending analyzer call \(id)")
        }
        continuation.resume(with: result)
    }

    private func cancel(_ id: Int) {
        cancelled.insert(id)
        if respectsCancellation {
            pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
        }
    }
}

@main
@MainActor
struct SentenceAnalysisSessionTests {
    private static var checkCount = 0
    private static let firstEnglish = "I am almost there."
    private static let secondEnglish = "We will arrive soon."
    private static let firstSettings = TranslationSettingsSnapshot(
        provider: .custom, apiKey: nil, revision: "synthetic-settings-a",
        custom: .init(baseURL: "https://analysis.example.invalid/v1/",
                      model: "synthetic-model", apiKey: "synthetic-test-only"))
    private static let secondSettings = TranslationSettingsSnapshot(
        provider: .custom, apiKey: nil, revision: "synthetic-settings-b",
        custom: .init(baseURL: "https://analysis.example.invalid/v1/",
                      model: "synthetic-model-b", apiKey: "synthetic-test-only"))

    static func main() async throws {
        try await explicitRequestAndDeduplication()
        try await prepareBeforeOpeningAndDeduplication()
        try await failureRequiresExplicitRetry()
        try await prepareFailureDoesNotAutomaticallyRetry()
        try await applePreparationNeverUsesRetainedKeys()
        try await loadingCallbackInvalidationPreventsDispatch()
        try await resetCancelsAndClearsCache()
        try await lateIgnoredCancellationCannotPublish()
        try await changedInputsDoNotReuseCache()
        try await sameRevisionConfigurationChangesInvalidateCache()
        try await currentContextGatesRequestAndCompletion()
        try await readingPayloadsRemainCacheable()
        try await ownerReleaseCancelsAnalysis()
        print("PASS: analysis session — 13 groups, \(checkCount) assertions; whole-text reading payloads, authorized preparation, shared pending/ready result, no paid auto-retry, Apple retained-key isolation, explicit retry, cancellation, late-result isolation, full-settings invalidation, current-host guards and owner-release cancellation; controlled analyzer only, no live API or Keychain access")
    }

    private static func expect(_ value: Bool, _ message: String) throws {
        checkCount += 1
        if !value { throw AnalysisSessionTestFailure(description: message) }
    }

    private static func until(_ message: String, _ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < deadline else { throw AnalysisSessionTestFailure(description: message) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private static func settle() async throws {
        // Give already-enqueued actor work a bounded chance to run. All analyzer
        // responses are manually resumed, so this never waits for a paid service.
        for _ in 0..<4 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(5))
    }

    private static func analysis(_ english: String) -> SentenceAnalysis {
        .init(kind: "sentence", insights: [
            .init(source: english, title: "会话测试", explanation: "只用于检验会话状态。")
        ], expressions: [])
    }

    private static func readingPayloadsRemainCacheable() async throws {
        let analyzer = ControlledSentenceAnalyzer()
        let session = SentenceAnalysisSession(analyzer: analyzer)
        let fixtures: [(String, SentenceAnalysis)] = [
            ("It rains.", .init(kind: "sentence", insights: [], expressions: [])),
            ("Hello", .init(kind: "word", overview: "你好；用于打招呼。", insights: [], expressions: [])),
            ("almost there", .init(kind: "phrase", overview: "快到了。", insights: [], expressions: []))
        ]
        for (index, fixture) in fixtures.enumerated() {
            let (english, payload) = fixture
            let validated = try payload.validated(for: english)
            session.prepare(english: english, settings: firstSettings, isCurrent: { true })
            try await until("Reading payload preparation did not start") { analyzer.calls.count == index + 1 }
            try analyzer.complete(index, with: .success(validated))
            try await until("Empty or phrase reading payload did not become ready") { session.state == .ready(validated) }
            session.request(english: english, settings: firstSettings, isCurrent: { true })
            session.prepare(english: english, settings: firstSettings, isCurrent: { true })
            try await settle()
            try expect(analyzer.calls.count == index + 1 && session.state == .ready(validated),
                       "Empty notes and word/phrase meanings are valid ready cache entries, not missing results")
        }
        print("PASS: zero-insight sentences and word/phrase meanings remain ready and reuse prepared results")
    }

    private static func explicitRequestAndDeduplication() async throws {
        let analyzer = ControlledSentenceAnalyzer()
        let session = SentenceAnalysisSession(analyzer: analyzer)
        try await settle()
        try expect(session.state == .idle && analyzer.calls.isEmpty, "Construction must not request analysis")

        session.request(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        try expect(session.state == .loading, "Explicit request immediately enters loading")
        try await until("Initial request did not start") { analyzer.calls.count == 1 }
        session.request(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        session.request(english: firstEnglish, settings: firstSettings, retry: true, isCurrent: { true })
        try await settle()
        try expect(analyzer.calls.count == 1, "Repeated expansion during loading must not pay twice")

        let result = analysis(firstEnglish)
        try analyzer.complete(0, with: .success(result))
        try await until("Initial result did not publish") { session.state == .ready(result) }
        session.request(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        session.request(english: firstEnglish, settings: firstSettings, retry: true, isCurrent: { true })
        try await settle()
        try expect(analyzer.calls.count == 1 && session.state == .ready(result),
                   "Ready result must survive collapse/reopen without another paid call")
        print("PASS: construction makes no request; explicit requests deduplicate loading and ready results")
    }

    private static func prepareBeforeOpeningAndDeduplication() async throws {
        let analyzer = ControlledSentenceAnalyzer()
        let session = SentenceAnalysisSession(analyzer: analyzer)
        session.prepare(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        try await until("Preparation must start without opening the panel") { analyzer.calls.count == 1 }
        session.prepare(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        let firstResult = analysis(firstEnglish)
        try analyzer.complete(0, with: .success(firstResult))
        try await until("Prepared result must be ready before the panel opens") { session.state == .ready(firstResult) }
        session.request(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        session.prepare(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        try await settle()
        try expect(analyzer.calls.count == 1 && session.state == .ready(firstResult),
                   "Opening a prepared result must neither reload nor pay again")

        session.prepare(english: secondEnglish, settings: firstSettings, isCurrent: { true })
        try await until("Second preparation must start") { analyzer.calls.count == 2 }
        session.request(english: secondEnglish, settings: firstSettings, isCurrent: { true })
        session.prepare(english: secondEnglish, settings: firstSettings, isCurrent: { true })
        try await settle()
        try expect(analyzer.calls.count == 2 && session.state == .loading,
                   "Opening during preparation must use the same in-flight request")
        let secondResult = analysis(secondEnglish)
        try analyzer.complete(1, with: .success(secondResult))
        try await until("Shared in-flight result did not publish") { session.state == .ready(secondResult) }
        print("PASS: prepare runs before opening; opening uses the same ready or in-flight result with one paid call per input")
    }

    private static func prepareFailureDoesNotAutomaticallyRetry() async throws {
        let analyzer = ControlledSentenceAnalyzer()
        let session = SentenceAnalysisSession(analyzer: analyzer)
        session.prepare(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        try await until("Preparation failure fixture did not start") { analyzer.calls.count == 1 }
        try analyzer.complete(0, with: .failure(SentenceAnalysisError.timedOut))
        try await until("Preparation failure must remain visible") {
            session.state == .failure(SentenceAnalysisError.timedOut.message)
        }
        for _ in 0..<3 {
            session.prepare(english: firstEnglish, settings: firstSettings, isCurrent: { true })
            session.request(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        }
        try await settle()
        try expect(analyzer.calls.count == 1, "Failed preparation must not automatically retry or retry on expansion")
        session.request(english: firstEnglish, settings: firstSettings, retry: true, isCurrent: { true })
        try await until("Explicit retry should recover failed preparation") { analyzer.calls.count == 2 }
        let result = analysis(firstEnglish)
        try analyzer.complete(1, with: .success(result))
        try await until("Retried preparation did not publish") { session.state == .ready(result) }
        print("PASS: failed prepare stays cached through repeated ready events and opening until explicit retry")
    }

    private static func applePreparationNeverUsesRetainedKeys() async throws {
        let analyzer = ControlledSentenceAnalyzer(respectsCancellation: true)
        let session = SentenceAnalysisSession(analyzer: analyzer)
        let appleWithRetainedKeys = TranslationSettingsSnapshot(
            provider: .apple, apiKey: "synthetic-retained-qwen-key", revision: "synthetic-apple",
            custom: firstSettings.custom)
        for _ in 0..<3 {
            session.prepare(english: firstEnglish, settings: appleWithRetainedKeys, isCurrent: { true })
        }
        try await settle()
        try expect(analyzer.calls.isEmpty && session.state == .idle,
                   "Apple preparation must not call any analyzer even with retained Qwen and custom keys")

        session.prepare(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        try await until("Cloud preparation fixture did not start") { analyzer.calls.count == 1 }
        session.prepare(english: firstEnglish, settings: appleWithRetainedKeys, isCurrent: { true })
        try await until("Switching to Apple must cancel pending cloud preparation") {
            analyzer.cancelled.contains(0) && analyzer.finished.contains(0)
        }
        try expect(analyzer.calls.count == 1 && session.state == .idle,
                   "Switching to Apple must clear cloud state without a fallback paid request")
        print("PASS: Apple preparation makes zero calls with retained keys and cancels previous cloud preparation")
    }

    private static func failureRequiresExplicitRetry() async throws {
        let analyzer = ControlledSentenceAnalyzer()
        let session = SentenceAnalysisSession(analyzer: analyzer)
        session.request(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        try await until("Failure fixture did not start") { analyzer.calls.count == 1 }
        try analyzer.complete(0, with: .failure(SentenceAnalysisError.rateLimited))
        try await until("Failure did not publish") {
            session.state == .failure(SentenceAnalysisError.rateLimited.message)
        }
        for _ in 0..<3 {
            session.request(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        }
        try await settle()
        try expect(analyzer.calls.count == 1, "Failure must not auto-retry or retry merely on reopening")

        session.request(english: firstEnglish, settings: firstSettings, retry: true, isCurrent: { true })
        try await until("Explicit retry did not start") { analyzer.calls.count == 2 }
        session.request(english: firstEnglish, settings: firstSettings, retry: true, isCurrent: { true })
        try await settle()
        try expect(analyzer.calls.count == 2, "Repeated retry taps during loading must still be deduplicated")
        let result = analysis(firstEnglish)
        try analyzer.complete(1, with: .success(result))
        try await until("Explicit retry result did not publish") { session.state == .ready(result) }
        print("PASS: failure remains cached until explicit retry; retry taps do not duplicate a running call")
    }

    private static func resetCancelsAndClearsCache() async throws {
        let analyzer = ControlledSentenceAnalyzer(respectsCancellation: true)
        let session = SentenceAnalysisSession(analyzer: analyzer)
        session.request(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        try await until("Reset fixture did not start") { analyzer.calls.count == 1 }
        session.reset()
        try expect(session.state == .idle, "Reset must immediately clear loading")
        try await until("Reset did not cancel the active analyzer") {
            analyzer.cancelled.contains(0) && analyzer.finished.contains(0)
        }
        try await settle()
        try expect(session.state == .idle && analyzer.calls.count == 1,
                   "Cancelled request must neither publish nor restart itself")

        session.request(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        try await until("Reset should allow a later explicit request") { analyzer.calls.count == 2 }
        let result = analysis(firstEnglish)
        try analyzer.complete(1, with: .success(result))
        try await until("Post-reset result did not publish") { session.state == .ready(result) }
        session.reset()
        try expect(session.state == .idle, "Reset must clear a cached ready result too")
        print("PASS: reset cancels active work and clears both loading and ready cache")
    }

    private static func loadingCallbackInvalidationPreventsDispatch() async throws {
        // onChange runs synchronously before the request's Task is installed.
        // Reset here must prevent dispatch, not merely reject a later response.
        let resetAnalyzer = ControlledSentenceAnalyzer(respectsCancellation: true)
        let resetSession = SentenceAnalysisSession(analyzer: resetAnalyzer)
        resetSession.onChange = { [weak resetSession] in
            guard let resetSession, resetSession.state == .loading else { return }
            resetSession.reset()
        }
        resetSession.prepare(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        try await settle()
        let callsAfterReset = resetAnalyzer.calls.count
        resetSession.reset()
        try await settle()
        try expect(callsAfterReset == 0 && resetSession.state == .idle,
                   "A synchronous reset during loading must prevent any stale paid dispatch")

        let staleAnalyzer = ControlledSentenceAnalyzer(respectsCancellation: true)
        let staleSession = SentenceAnalysisSession(analyzer: staleAnalyzer)
        let context = AnalysisContextValidity()
        staleSession.onChange = { [weak staleSession] in
            if staleSession?.state == .loading { context.isCurrent = false }
        }
        staleSession.prepare(english: firstEnglish, settings: firstSettings,
                             isCurrent: { context.isCurrent })
        try await settle()
        let callsAfterContextChange = staleAnalyzer.calls.count
        staleSession.reset()
        try await settle()
        try expect(callsAfterContextChange == 0,
                   "Context invalidated synchronously by loading must be rechecked before paid dispatch")
        print("PASS: loading callbacks that immediately reset or invalidate current context prevent analyzer dispatch entirely")
    }

    private static func lateIgnoredCancellationCannotPublish() async throws {
        let analyzer = ControlledSentenceAnalyzer()
        let session = SentenceAnalysisSession(analyzer: analyzer)
        var published: [SentenceAnalysisLoadState] = []
        session.onChange = { [weak session] in
            if let state = session?.state { published.append(state) }
        }
        session.request(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        try await until("Old request did not start") { analyzer.calls.count == 1 }
        session.request(english: secondEnglish, settings: firstSettings, isCurrent: { true })
        try await until("New request did not replace old request") {
            analyzer.calls.count == 2 && analyzer.cancelled.contains(0)
        }
        let currentResult = analysis(secondEnglish)
        try analyzer.complete(1, with: .success(currentResult))
        try await until("Current result did not publish") { session.state == .ready(currentResult) }
        let oldResult = analysis(firstEnglish)
        try analyzer.complete(0, with: .success(oldResult))
        try await until("Ignoring-cancellation analyzer did not return its late result") { analyzer.finished.contains(0) }
        try await settle()
        try expect(session.state == .ready(currentResult) && !published.contains(.ready(oldResult)),
                   "A late cancellation-ignoring response must never publish or clear the new result")
        print("PASS: cancellation-ignoring old result cannot overwrite or briefly publish over the current sentence")
    }

    private static func changedInputsDoNotReuseCache() async throws {
        let analyzer = ControlledSentenceAnalyzer()
        let session = SentenceAnalysisSession(analyzer: analyzer)
        for (id, english, settings) in [(0, firstEnglish, firstSettings),
                                       (1, firstEnglish, secondSettings),
                                       (2, secondEnglish, secondSettings)] {
            session.request(english: english, settings: settings, isCurrent: { true })
            try expect(session.state == .loading, "Changed English or settings must not show cached ready state")
            try await until("Changed input did not create a distinct analysis") { analyzer.calls.count == id + 1 }
            try expect(analyzer.calls[id] == .init(english: english, revision: settings.revision),
                       "New request must use exact current English and settings revision")
            let result = analysis(english)
            try analyzer.complete(id, with: .success(result))
            try await until("Changed-input result did not publish") { session.state == .ready(result) }
        }
        print("PASS: changed settings revision or English invalidates cached analysis")
    }

    private static func sameRevisionConfigurationChangesInvalidateCache() async throws {
        let analyzer = ControlledSentenceAnalyzer()
        let session = SentenceAnalysisSession(analyzer: analyzer)
        let sameRevisionChanges = [
            firstSettings,
            TranslationSettingsSnapshot(
                provider: .custom, apiKey: nil, revision: firstSettings.revision,
                custom: .init(baseURL: "https://analysis.example.invalid/v1/",
                              model: "different-model", apiKey: "synthetic-test-only")),
            TranslationSettingsSnapshot(
                provider: .custom, apiKey: nil, revision: firstSettings.revision,
                custom: .init(baseURL: "https://analysis.example.invalid/v1/",
                              model: "different-model", apiKey: "synthetic-replaced-key")),
            TranslationSettingsSnapshot(
                provider: .custom, apiKey: nil, revision: firstSettings.revision,
                custom: .init(baseURL: "https://other-analysis.example.invalid/v1/",
                              model: "different-model", apiKey: "synthetic-replaced-key"))
        ]
        for (id, settings) in sameRevisionChanges.enumerated() {
            session.prepare(english: firstEnglish, settings: settings, isCurrent: { true })
            try expect(session.state == .loading, "Changed configuration with the same revision must invalidate ready cache")
            try await until("Same-revision configuration change did not start a fresh request") { analyzer.calls.count == id + 1 }
            try expect(analyzer.receivedSettings[id] == settings, "Analyzer must receive the new full configuration")
            let result = analysis(firstEnglish)
            try analyzer.complete(id, with: .success(result))
            try await until("Updated-configuration result did not publish") { session.state == .ready(result) }
        }
        print("PASS: model, key and endpoint changes invalidate prepared cache even when settings revision is unchanged")
    }


    private static func ownerReleaseCancelsAnalysis() async throws {
        let analyzer = ControlledSentenceAnalyzer(respectsCancellation: true)
        var session: SentenceAnalysisSession? = SentenceAnalysisSession(analyzer: analyzer)
        weak let observed = session
        session?.request(english: firstEnglish, settings: firstSettings, isCurrent: { true })
        try await until("Owner-release fixture did not start") { analyzer.calls.count == 1 }
        session = nil
        try await settle()
        let released = observed == nil
        let cancelled = analyzer.cancelled.contains(0)
        if !analyzer.finished.contains(0) {
            try analyzer.complete(0, with: .success(analysis(firstEnglish)))
        }
        try expect(released && cancelled,
                   "Releasing the reading session must cancel its pending analysis request")
    }

    private static func currentContextGatesRequestAndCompletion() async throws {
        let analyzer = ControlledSentenceAnalyzer()
        let session = SentenceAnalysisSession(analyzer: analyzer)
        session.prepare(english: firstEnglish, settings: firstSettings, isCurrent: { false })
        session.request(english: firstEnglish, settings: firstSettings, isCurrent: { false })
        try await settle()
        try expect(session.state == .idle && analyzer.calls.isEmpty,
                   "An already-stale context must not start an analysis request")

        let context = AnalysisContextValidity()
        session.prepare(english: firstEnglish, settings: firstSettings, isCurrent: { context.isCurrent })
        try await until("Context fixture did not start") { analyzer.calls.count == 1 }
        context.isCurrent = false
        try analyzer.complete(0, with: .success(analysis(firstEnglish)))
        try await until("Success in an invalid context should reset to idle") { session.state == .idle }

        context.isCurrent = true
        session.request(english: firstEnglish, settings: firstSettings, isCurrent: { context.isCurrent })
        try await until("Second context fixture did not start") { analyzer.calls.count == 2 }
        context.isCurrent = false
        try analyzer.complete(1, with: .failure(SentenceAnalysisError.serviceUnavailable))
        try await until("Failure in an invalid context should reset to idle") { session.state == .idle }
        try expect(analyzer.calls.count == 2, "Invalid context must not trigger a replacement paid request")
        print("PASS: stale host blocks prepare/request and suppresses both prepared success and requested error publication")
    }
}
