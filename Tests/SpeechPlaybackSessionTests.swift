import Foundation

private struct SpeechTestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class FakeSpeechPlayer: SpeechAudioPlaying {
    var onStop: (() -> Void)?
    var playbackError: SpeechPlaybackError?
    var onPlay: (() -> Void)?
    var played: [Data] = []
    var stops = 0
    func playOnce(_ data: Data) throws {
        if let playbackError { throw playbackError }
        played.append(data)
        onPlay?()
    }
    func stop() { stops += 1 }
    func interrupt() { onStop?() }
    func finish() { onStop?() }
}

@MainActor
private final class ControlledSpeechSynthesizer: SpeechSynthesizing {
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private(set) var calls: [String] = []
    private(set) var cancelled: Set<Int> = []

    func synthesize(_ text: String) async throws -> Data {
        let id = calls.count
        calls.append(text)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[id] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelled.insert(id) }
        }
    }

    func complete(_ id: Int, _ result: Result<Data, any Error>) throws {
        guard let continuation = pending.removeValue(forKey: id) else {
            throw SpeechTestFailure(description: "Missing synthesis request \(id)")
        }
        continuation.resume(with: result)
    }
}

/// Deliberately ignores cancellation until the test completes its request.
/// This models transports which can still deliver queued PCM or a late result.
@MainActor
private final class ControlledStreamingSpeechSynthesizer: SpeechStreamingSynthesizing {
    typealias PCMHandler = @MainActor @Sendable (Data) async throws -> Void
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var handlers: [Int: PCMHandler] = [:]
    private(set) var calls: [String] = []
    private(set) var regularCalls: [String] = []
    private(set) var cancelled: Set<Int> = []
    let regularAudio = Data([9, 8, 7])

    func synthesize(_ text: String) async throws -> Data {
        regularCalls.append(text)
        return regularAudio
    }

    func synthesizeStreaming(_ text: String, onPCM: @escaping PCMHandler) async throws -> Data {
        let id = calls.count
        calls.append(text)
        handlers[id] = onPCM
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[id] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelled.insert(id) }
        }
    }

    func emit(_ id: Int, _ data: Data) async throws {
        guard let handler = handlers[id] else {
            throw SpeechTestFailure(description: "Missing PCM handler \(id)")
        }
        try await handler(data)
    }

    func complete(_ id: Int, _ result: Result<Data, any Error>) throws {
        guard let continuation = pending.removeValue(forKey: id) else {
            throw SpeechTestFailure(description: "Missing streaming request \(id)")
        }
        continuation.resume(with: result)
    }
}

@MainActor
private final class FakeStreamingSpeechPlayer: SpeechStreamingAudioPlaying {
    var onStop: (() -> Void)?
    var onBegin: (() -> Void)?
    var onAppend: (() -> Void)?
    var onFinishStream: (() -> Void)?
    var beginError: SpeechPlaybackError?
    var appendError: SpeechPlaybackError?
    var finishError: SpeechPlaybackError?
    var holdsAppend = false
    private var pendingAppend: CheckedContinuation<Void, any Error>?
    private(set) var begins = 0
    private(set) var chunks: [Data] = []
    private(set) var inputFinishes = 0
    private(set) var played: [Data] = []
    private(set) var stops = 0
    var isAppendWaiting: Bool { pendingAppend != nil }

    func playOnce(_ data: Data) throws { played.append(data) }
    func beginStream() throws {
        begins += 1
        if let beginError { throw beginError }
        onBegin?()
    }
    func appendPCM(_ data: Data) async throws {
        if let appendError { throw appendError }
        chunks.append(data)
        onAppend?()
        if holdsAppend {
            try await withCheckedThrowingContinuation { pendingAppend = $0 }
        }
    }
    func finishStream() throws {
        inputFinishes += 1
        if let finishError { throw finishError }
        onFinishStream?()
    }
    func stop() { stops += 1 }
    func drain() { onStop?() }
    func resumeAppend() throws {
        guard let continuation = pendingAppend else {
            throw SpeechTestFailure(description: "No suspended PCM append")
        }
        pendingAppend = nil
        continuation.resume()
    }
}

@main
@MainActor
struct SpeechPlaybackSessionTests {
    private static var assertions = 0
    private static let audio = Data([0x52, 0x49, 0x46, 0x46])

    static func main() async throws {
        try await localReplayAndClear()
        try await naturalCompletionAndCachedReplay()
        try await completionDuringPlaybackStartup()
        try await cancelWhileLoading()
        try await replacementIgnoresStaleResults()
        try await configurationInvalidatesCache()
        try await sharedSentenceCacheAndActiveExcerpt()
        try await sharedScopeInvalidation()
        try await cancelledExcerptNeverEntersCache()
        try await clipCountEvictsLeastRecentlyUsed()
        try await byteBudgetEvictsLeastRecentlyUsed()
        try await invalidClipPreservesOtherClips()
        try await cachedPlaybackRetriesReportEachFailure()
        try await excerptChangesNotifyWhileStateMatches()
        try await reentrantCachedExcerptReplacement()
        try await loadingRenderCanCancelOrReplace()
        try await failuresAndRetry()
        try await invalidAudioIsNotPlayed()
        try await externalStopsCancelLoadingAndPlayback()
        try await playbackStartInterruption()
        try await ownerReleaseCancelsAndStops()
        try await emptyTextAndNoDuplicateIdleNotifications()
        try await firstPCMPlaysBeforeCompletionAndCachedReplay()
        try await cancelledStreamsRejectLatePCMAndCompletion()
        try await streamReplacementIsolatesOldChunks()
        try await streamingConfigurationChangeRejectsSameText()
        try await partialStreamFailureIsNeverCached()
        try await invalidStreamCompletionStopsPartialAudio()
        try await streamStartupAndAppendReentrancy()
        try await streamingStateObserverCanReplace()
        try await streamCompletionCanStopSynchronously()
        try await streamPlayerFailuresAndCompletedCache()
        try await replacementDuringSuspendedPCMAppend()
        try await streamingOwnerReleaseDuringSuspendedAppend()
        try await singleStreamingCapabilityUsesLegacyPath()
        print("Speech playback session: 35 cases, \(assertions) assertions passed.")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard condition() else { throw SpeechTestFailure(description: message) }
    }

    private static func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    private static func start(_ session: SpeechPlaybackSession, _ synth: ControlledSpeechSynthesizer,
                              text: String = "Hello.", configurationID: String = "qwen-a",
                              scopeID: String? = nil) async {
        session.toggle(text: text, configurationID: configurationID, scopeID: scopeID, synthesizer: synth)
        await settle()
    }

    private static func localReplayAndClear() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        try check(synth.calls.isEmpty, "No automatic synthesis")
        await start(session, synth)
        try check(session.state == .loading && synth.calls == ["Hello."], "One tap starts synthesis")
        try synth.complete(0, .success(audio)); await settle()
        try check(session.state == .playing && player.played == [audio], "Audio plays after generation")
        await start(session, synth)
        try check(session.state == .idle, "Second tap stops")
        await start(session, synth)
        try check(session.state == .playing && synth.calls.count == 1 && player.played.count == 2,
                  "Replay uses the same cached audio without another synthesis")
        session.stop(clearCache: true)
        await start(session, synth)
        try check(synth.calls.count == 2 && session.state == .loading, "Explicit clear removes cached audio")
        try synth.complete(1, .success(audio)); await settle()
        session.stop()
    }

    private static func naturalCompletionAndCachedReplay() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        var states: [SpeechPlaybackSession.State] = []
        session.onChange = { [weak session] in
            if let state = session?.state { states.append(state) }
        }
        await start(session, synth)
        try synth.complete(0, .success(audio)); await settle()
        player.finish(); await settle()
        try check(session.state == .idle && states == [.loading, .playing, .idle],
                  "Natural completion restores the idle speaker without another tap")
        try check(player.played.count == 1 && synth.calls.count == 1,
                  "Natural completion neither repeats playback nor generates more audio")

        await start(session, synth)
        try check(session.state == .playing && player.played == [audio, audio] && synth.calls.count == 1,
                  "A tap after natural completion immediately replays the cached sentence")
        player.finish(); await settle()
        try check(session.state == .idle && player.played.count == 2 && synth.calls.count == 1,
                  "Replayed audio also finishes once without a new synthesis")
        let changesAfterCompletion = states.count
        player.finish(); await settle()
        try check(states.count == changesAfterCompletion,
                  "Repeated completion while idle does not trigger duplicate UI updates")
    }

    private static func completionDuringPlaybackStartup() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        player.onPlay = { [weak player] in player?.finish() }
        await start(session, synth)
        try synth.complete(0, .success(audio)); await settle()
        try check(session.state == .idle,
                  "A completion delivered during startup cannot leave the speaker playing")
        player.onPlay = nil
        await start(session, synth)
        try check(session.state == .playing && synth.calls.count == 1 && player.played.count == 2,
                  "Early completion preserves audio for a later explicit replay")
        session.stop()
    }

    private static func cancelWhileLoading() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        await start(session, synth)
        await start(session, synth)
        try check(session.state == .idle && synth.cancelled.contains(0), "Loading tap cancels the request")
        try synth.complete(0, .success(audio)); await settle()
        try check(player.played.isEmpty && session.state == .idle, "Cancelled late audio is never played")
    }

    private static func replacementIgnoresStaleResults() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        await start(session, synth, text: "Old.")
        await start(session, synth, text: "New.")
        try check(synth.calls == ["Old.", "New."] && synth.cancelled.contains(0), "A new sentence cancels old synthesis")
        try synth.complete(1, .success(audio)); await settle()
        try synth.complete(0, .failure(SpeechError.accessDenied)); await settle()
        try check(session.state == .playing && player.played.count == 1, "Stale failure cannot overwrite current playback")
        session.stop()
        await start(session, synth, text: "Old.")
        try check(synth.calls.count == 3, "Cache never replays audio belonging to a different sentence")
        session.stop()
        try synth.complete(2, .success(audio)); await settle()
    }

    private static func configurationInvalidatesCache() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        await start(session, synth)
        try synth.complete(0, .success(audio)); await settle()
        await start(session, synth, configurationID: "qwen-b")
        try check(session.state == .loading && synth.calls.count == 2, "Changed configuration does not reuse audio")
        session.stop()
        try synth.complete(1, .success(audio)); await settle()
        try check(player.played.count == 1, "Stopped replacement request cannot play")
    }


    private static func sharedSentenceCacheAndActiveExcerpt() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        let sentence = "I want to set up a research platform."
        for (index, text) in [sentence, "research", "set up"].enumerated() {
            await start(session, synth, text: text, scopeID: sentence)
            try check(session.currentText == text && session.state == .loading,
                      "The active excerpt is visible during generation")
            try synth.complete(index, .success(Data([UInt8(index + 1)]))); await settle()
            try check(session.currentText == text && session.state == .playing,
                      "The active excerpt matches the playing audio")
            player.finish()
            try check(session.currentText == nil && session.state == .idle,
                      "Natural completion clears the active excerpt")
        }
        for (index, text) in [sentence, "research", "set up"].enumerated() {
            await start(session, synth, text: text, scopeID: sentence)
            try check(session.state == .playing && player.played.last == Data([UInt8(index + 1)]),
                      "Moving among the sentence and its excerpts reuses their own audio")
        }
        try check(synth.calls.count == 3, "Returning to any cached excerpt does not synthesize again")
        await start(session, synth, text: "set up", scopeID: sentence)
        try check(session.state == .idle && session.currentText == nil,
                  "Tapping the current excerpt stops instead of starting another playback")
        session.stop(clearCache: true)
        await start(session, synth, text: sentence, scopeID: sentence)
        try check(synth.calls.count == 4, "Clearing the session removes every excerpt in its scope")
        session.stop(); try synth.complete(3, .success(audio)); await settle()
    }

    private static func sharedScopeInvalidation() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        for (index, entry) in [("old sentence", "qwen-a"), ("new sentence", "qwen-a"),
                               ("old sentence", "qwen-a"), ("old sentence", "qwen-b")].enumerated() {
            await start(session, synth, text: "shared word", configurationID: entry.1, scopeID: entry.0)
            try check(synth.calls.count == index + 1 && session.state == .loading,
                      "Same excerpt never reuses audio after sentence or configuration changes")
            try synth.complete(index, .success(audio)); await settle(); player.finish()
        }
        session.stop(clearCache: true)
        await start(session, synth, text: "legacy")
        try synth.complete(4, .success(audio)); await settle(); player.finish()
        await start(session, synth, text: "legacy", scopeID: "legacy")
        try check(synth.calls.count == 6, "An explicit sentence scope cannot collide with a legacy text scope")
        session.stop(); try synth.complete(5, .success(audio)); await settle()
    }

    private static func cancelledExcerptNeverEntersCache() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        await start(session, synth, text: "old", scopeID: "old and new")
        await start(session, synth, text: "new", scopeID: "old and new")
        try check(synth.cancelled.contains(0) && session.currentText == "new",
                  "Changing excerpts cancels pending synthesis immediately")
        try synth.complete(1, .success(Data([2]))); await settle()
        try synth.complete(0, .success(Data([1]))); await settle()
        try check(player.played == [Data([2])] && session.currentText == "new",
                  "Late audio from another excerpt cannot replace current playback")
        await start(session, synth, text: "old", scopeID: "old and new")
        try check(synth.calls.count == 3 && session.state == .loading,
                  "A cancelled excerpt's late audio never enters the shared cache")
        await start(session, synth, text: "new", scopeID: "old and new")
        try synth.complete(2, .failure(SpeechError.accessDenied)); await settle()
        try check(session.state == .playing && session.currentText == "new" && synth.calls.count == 3,
                  "A stale excerpt failure cannot overwrite a cached replacement")
        session.stop()
    }

    private static func clipCountEvictsLeastRecentlyUsed() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        for index in 0..<SpeechPlaybackSession.maximumCachedClips {
            await start(session, synth, text: "clip\(index)", scopeID: "sentence")
            try synth.complete(index, .success(Data([UInt8(index)]))); await settle(); player.finish()
        }
        await start(session, synth, text: "clip0", scopeID: "sentence"); player.finish()
        await start(session, synth, text: "clip12", scopeID: "sentence")
        try synth.complete(12, .success(Data([12]))); await settle(); player.finish()
        await start(session, synth, text: "clip0", scopeID: "sentence")
        try check(synth.calls.count == 13 && player.played.last == Data([0]),
                  "Cache hits refresh recency, preserving a recently replayed clip")
        await start(session, synth, text: "clip1", scopeID: "sentence")
        try check(synth.calls.count == 14 && session.state == .loading,
                  "Adding the thirteenth clip evicts the least recently used clip")
        session.stop(); try synth.complete(13, .success(audio)); await settle()
    }

    private static func byteBudgetEvictsLeastRecentlyUsed() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        let halfBudget = Data(repeating: 1, count: SpeechPlaybackSession.maximumAudioBytes / 2)
        for (index, text) in ["first", "second"].enumerated() {
            await start(session, synth, text: text, scopeID: "sentence")
            try synth.complete(index, .success(halfBudget)); await settle(); player.finish()
        }
        await start(session, synth, text: "first", scopeID: "sentence"); player.finish()
        await start(session, synth, text: "one extra byte", scopeID: "sentence")
        try synth.complete(2, .success(Data([3]))); await settle(); player.finish()
        await start(session, synth, text: "first", scopeID: "sentence")
        try check(synth.calls.count == 3 && session.state == .playing,
                  "The byte budget preserves the most recently used clip")
        await start(session, synth, text: "second", scopeID: "sentence")
        try check(synth.calls.count == 4 && session.state == .loading,
                  "One byte over the four MiB total budget evicts the oldest clip")
        try synth.complete(3, .success(Data(repeating: 2, count: SpeechPlaybackSession.maximumAudioBytes)))
        await settle(); player.finish()
        await start(session, synth, text: "one extra byte", scopeID: "sentence")
        try check(synth.calls.count == 5,
                  "A clip at the single-entry limit evicts all previous clips to respect the total limit")
        session.stop(clearCache: true); try synth.complete(4, .success(audio)); await settle()
    }

    private static func invalidClipPreservesOtherClips() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        for (index, text) in ["good", "bad"].enumerated() {
            await start(session, synth, text: text, scopeID: "sentence")
            try synth.complete(index, .success(Data([UInt8(index)]))); await settle(); player.finish()
        }
        player.playbackError = .invalidAudio
        await start(session, synth, text: "bad", scopeID: "sentence")
        try check(session.currentText == "bad", "Playback failure identifies the failed excerpt")
        player.playbackError = nil
        await start(session, synth, text: "good", scopeID: "sentence")
        try check(synth.calls.count == 2 && player.played.last == Data([0]),
                  "Rejecting an invalid clip does not discard other valid excerpts")
        await start(session, synth, text: "bad", scopeID: "sentence")
        try check(synth.calls.count == 3, "Only the invalid excerpt is regenerated on the next explicit tap")
        player.playbackError = .unavailable
        try synth.complete(2, .success(Data([2]))); await settle()
        player.playbackError = nil
        await start(session, synth, text: "good", scopeID: "sentence")
        await start(session, synth, text: "bad", scopeID: "sentence")
        try check(synth.calls.count == 3 && session.state == .playing && player.played.last == Data([2]),
                  "A temporary route failure preserves that excerpt across visits to other clips")
        session.stop()
    }


    private static func cachedPlaybackRetriesReportEachFailure() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        for (index, text) in ["first", "second"].enumerated() {
            await start(session, synth, text: text, scopeID: "sentence")
            try synth.complete(index, .success(Data([UInt8(index)]))); await settle(); player.finish()
        }
        player.playbackError = .unavailable
        await start(session, synth, text: "first", scopeID: "sentence")
        let failure = SpeechPlaybackSession.State.failed("暂时无法播放语音，请稍后重试。")
        try check(session.state == failure, "Cached audio can encounter a temporary playback failure")
        var states: [SpeechPlaybackSession.State] = []
        var texts: [String?] = []
        session.onChange = { [weak session] in
            guard let session else { return }
            states.append(session.state)
            texts.append(session.currentText)
        }
        await start(session, synth, text: "first", scopeID: "sentence")
        try check(states == [.loading, failure] && texts == ["first", "first"],
                  "Retrying the same cached clip publishes a fresh failed attempt, even with the same message")
        states.removeAll(); texts.removeAll()
        await start(session, synth, text: "second", scopeID: "sentence")
        try check(states == [.loading, failure] && texts == ["second", "second"],
                  "Switching to another cached clip publishes its own failure rather than hiding it")
        try check(synth.calls.count == 2, "Repeated playback failures never regenerate valid cached audio")

        player.playbackError = nil
        session.onChange = { [weak session] in
            if session?.state == .loading { session?.stop() }
        }
        let playsBeforeRetry = player.played.count
        await start(session, synth, text: "second", scopeID: "sentence")
        try check(session.state == .idle && player.played.count == playsBeforeRetry,
                  "A reentrant cancellation of a cached retry cannot start playback")
        try check(synth.calls.count == 2, "Cancelling a cached retry performs no synthesis")
        session.onChange = nil
        session.stop(clearCache: true)
    }

    private static func excerptChangesNotifyWhileStateMatches() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        var observations: [String] = []
        session.onChange = { [weak session] in
            observations.append(session?.currentText ?? "idle")
        }
        await start(session, synth, text: "first", scopeID: "sentence")
        await start(session, synth, text: "second", scopeID: "sentence")
        try check(observations == ["first", "second"],
                  "Loading-to-loading excerpt changes still notify the view")
        try synth.complete(0, .success(audio)); try synth.complete(1, .success(audio)); await settle()
        await start(session, synth, text: "first", scopeID: "sentence")
        try synth.complete(2, .success(audio)); await settle()
        let previousCount = observations.count
        await start(session, synth, text: "second", scopeID: "sentence")
        try check(observations.count == previousCount + 1 && observations.last == "second",
                  "Playing-to-playing cached excerpt changes still notify the view")
        session.stop()
    }

    private static func reentrantCachedExcerptReplacement() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        for (index, text) in ["first", "second"].enumerated() {
            await start(session, synth, text: text, scopeID: "sentence")
            try synth.complete(index, .success(Data([UInt8(index)]))); await settle(); player.finish()
        }
        session.onChange = { [weak session] in
            guard let session, session.currentText == "first" else { return }
            session.toggle(text: "second", configurationID: "qwen-a", scopeID: "sentence", synthesizer: synth)
        }
        await start(session, synth, text: "first", scopeID: "sentence")
        try check(session.state == .playing && session.currentText == "second" && player.played.last == Data([1]),
                  "Reentrant view selection keeps only the replacement excerpt active")
        try check(synth.calls.count == 2, "Reentrant cached selection adds no synthesis request")
        session.onChange = nil; session.stop()
    }

    private static func loadingRenderCanCancelOrReplace() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        session.onChange = { [weak session] in
            if session?.state == .loading { session?.stop(clearCache: true) }
        }
        await start(session, synth)
        try check(session.state == .idle && synth.calls.isEmpty, "Synchronous render invalidation prevents request dispatch")
        var didReplace = false
        session.onChange = { [weak session] in
            if session?.state == .loading && !didReplace {
                didReplace = true
                session?.toggle(text: "Replacement.", configurationID: "qwen-b", synthesizer: synth)
            }
        }
        await start(session, synth)
        try check(synth.calls == ["Replacement."], "Reentrant replacement dispatches only the new request")
        try synth.complete(0, .success(audio)); await settle()
        try check(session.state == .playing, "Replacement can complete")
        session.onChange = nil
        session.stop()
    }

    private static func failuresAndRetry() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        await start(session, synth)
        try synth.complete(0, .failure(SpeechError.accessDenied)); await settle()
        try check(session.state == .failed(SpeechError.accessDenied.userMessage), "Known errors use sanitized user messages")
        await start(session, synth)
        try check(synth.calls.count == 2, "A failed request can be retried explicitly")
        try synth.complete(1, .failure(SpeechTestFailure(description: "private server response"))); await settle()
        try check(session.state == .failed("暂时无法生成语音，请稍后重试。"), "Unknown errors never expose private response text")
        player.playbackError = .unavailable
        await start(session, synth)
        try synth.complete(2, .success(audio)); await settle()
        try check(session.state == .failed("暂时无法播放语音，请稍后重试。"), "Playback errors are safe and recoverable")
        player.playbackError = nil
        await start(session, synth)
        try check(synth.calls.count == 3, "Temporary playback failure reuses audio without another paid generation")
        try check(session.state == .playing, "Playback retry recovers")
        session.stop()
        player.playbackError = .invalidAudio
        await start(session, synth)
        try check(session.state == .failed("暂时无法播放语音，请稍后重试。"), "Invalid cached audio fails safely")
        player.playbackError = nil
        await start(session, synth)
        try check(synth.calls.count == 4 && session.state == .loading, "Invalid audio is discarded and regenerated on explicit retry")
        try synth.complete(3, .success(audio)); await settle()
        try check(session.state == .playing, "A regenerated valid audio recovers")
        session.stop()
    }

    private static func invalidAudioIsNotPlayed() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        for (index, invalid) in [Data(), Data(repeating: 0, count: SpeechPlaybackSession.maximumAudioBytes + 1)].enumerated() {
            await start(session, synth)
            try synth.complete(index, .success(invalid)); await settle()
            try check(player.played.isEmpty, "Empty and oversized audio are rejected before playback")
            try check(session.state == .failed("语音内容暂时无法播放，请重试。"), "Invalid audio yields a bounded failure")
        }
        await start(session, synth)
        try synth.complete(2, .success(Data(repeating: 1, count: SpeechPlaybackSession.maximumAudioBytes)))
        await settle()
        try check(session.state == .playing, "The cache accepts its exact size limit")
        session.stop(clearCache: true)
    }

    private static func externalStopsCancelLoadingAndPlayback() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        await start(session, synth)
        player.interrupt(); await settle()
        try check(session.state == .idle && synth.cancelled.contains(0), "Interruption cancels pending generation")
        try synth.complete(0, .success(audio)); await settle()
        try check(player.played.isEmpty, "Generation never auto-resumes after interruption")
        await start(session, synth)
        try synth.complete(1, .success(audio)); await settle()
        player.interrupt(); await settle()
        try check(session.state == .idle && player.played.count == 1, "Interruption resets playback UI and never resumes")
        await start(session, synth)
        try check(session.state == .playing && synth.calls.count == 2, "Explicit replay after interruption uses cache")
        session.stop()
    }

    private static func playbackStartInterruption() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        player.onPlay = { [weak player] in player?.interrupt() }
        await start(session, synth)
        try synth.complete(0, .success(audio)); await settle()
        try check(session.state == .idle, "Interruption during player startup cannot publish playing")
    }

    private static func ownerReleaseCancelsAndStops() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        var session: SpeechPlaybackSession? = SpeechPlaybackSession(player: player)
        weak let weakSession = session
        await start(session!, synth)
        let previousStops = player.stops
        session = nil
        await settle()
        try check(weakSession == nil && synth.cancelled.contains(0), "An in-flight task does not retain its session")
        try check(player.stops > previousStops && player.onStop == nil, "Owner release stops player and detaches callbacks")
        try synth.complete(0, .success(audio)); await settle()
        try check(player.played.isEmpty, "Released owner cannot start playback later")
    }

    private static func emptyTextAndNoDuplicateIdleNotifications() async throws {
        let player = FakeSpeechPlayer(), synth = ControlledSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        var changes = 0
        session.onChange = { changes += 1 }
        session.stop(); session.stop(clearCache: true)
        await start(session, synth, text: " \n ")
        try check(synth.calls.isEmpty && session.state == .idle, "Empty input never starts synthesis")
        try check(changes == 0, "Repeated idle resets do not trigger recursive UI updates")
    }

    private static func startStreaming(_ session: SpeechPlaybackSession, _ synth: ControlledStreamingSpeechSynthesizer,
                                       text: String = "Hello.", configurationID: String = "qwen-a",
                                       scopeID: String? = nil) async {
        session.toggle(text: text, configurationID: configurationID, scopeID: scopeID, synthesizer: synth)
        await settle()
    }

    private static func emitAllowingCancellation(_ synth: ControlledStreamingSpeechSynthesizer,
                                                _ id: Int, _ pcm: Data) async throws {
        do { try await synth.emit(id, pcm) } catch is CancellationError { }
    }

    private static func firstPCMPlaysBeforeCompletionAndCachedReplay() async throws {
        let player = FakeStreamingSpeechPlayer(), synth = ControlledStreamingSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        var states: [SpeechPlaybackSession.State] = []
        session.onChange = { [weak session] in if let state = session?.state { states.append(state) } }
        await startStreaming(session, synth)
        try check(session.state == .loading && player.begins == 0,
                  "Streaming waits for real PCM before opening playback")
        let first = Data([0, 1]), second = Data([2, 3])
        try await synth.emit(0, first)
        try check(session.state == .playing && player.begins == 1 && player.chunks == [first],
                  "The first PCM is audible before the complete WAV exists")
        try await synth.emit(0, second)
        try check(player.begins == 1 && player.chunks == [first, second] && player.played.isEmpty,
                  "Later chunks append in order without restarting or replaying the WAV")
        try synth.complete(0, .success(audio)); await settle()
        try check(player.inputFinishes == 1 && session.state == .playing,
                  "Generation completion closes input but lets scheduled samples drain")
        player.drain(); await settle()
        try check(session.state == .idle && states == [.loading, .playing, .idle],
                  "Only natural drain ends streaming playback, once")
        player.drain()
        try check(states.count == 3 && synth.regularCalls.isEmpty,
                  "Duplicate drain cannot repeat playback or start fallback synthesis")
        await startStreaming(session, synth)
        try check(synth.calls.count == 1 && player.played == [audio] && player.begins == 1,
                  "A completed stream replays through playOnce using its cached WAV")
        player.drain()
        try check(session.state == .idle && synth.calls.count == 1,
                  "Cached streaming audio also plays only once")
    }

    private static func cancelledStreamsRejectLatePCMAndCompletion() async throws {
        for didStartPCM in [false, true] {
            let player = FakeStreamingSpeechPlayer(), synth = ControlledStreamingSpeechSynthesizer()
            let session = SpeechPlaybackSession(player: player)
            await startStreaming(session, synth)
            if didStartPCM { try await synth.emit(0, Data([0, 1])) }
            await startStreaming(session, synth)
            try check(session.state == .idle && synth.cancelled.contains(0),
                      "The second tap cancels streaming before or after its first chunk")
            let chunkCount = player.chunks.count
            try await emitAllowingCancellation(synth, 0, Data([2, 3]))
            try synth.complete(0, .success(audio)); await settle()
            try check(player.chunks.count == chunkCount && player.inputFinishes == 0 && session.state == .idle,
                      "Cancelled PCM and a late complete WAV cannot restart or finish playback")
            await startStreaming(session, synth)
            try check(synth.calls.count == 2 && player.played.isEmpty,
                      "An incomplete cancelled stream is never reused as a cached clip")
            session.stop(); try synth.complete(1, .success(audio)); await settle()
        }
    }

    private static func streamReplacementIsolatesOldChunks() async throws {
        let player = FakeStreamingSpeechPlayer(), synth = ControlledStreamingSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        await startStreaming(session, synth, text: "old", scopeID: "old and new")
        try await synth.emit(0, Data([0, 1]))
        await startStreaming(session, synth, text: "new", scopeID: "old and new")
        try check(synth.cancelled.contains(0) && session.currentText == "new" && session.state == .loading,
                  "Switching excerpts stops the previous stream before the new request")
        try await synth.emit(1, Data([2, 3]))
        try await emitAllowingCancellation(synth, 0, Data([4, 5]))
        try synth.complete(0, .failure(SpeechError.accessDenied)); await settle()
        try check(player.chunks == [Data([0, 1]), Data([2, 3])] && session.currentText == "new" && session.state == .playing,
                  "An old stream's chunk and failure cannot touch the replacement stream")
        try synth.complete(1, .success(Data([7]))); await settle(); player.drain()
        await startStreaming(session, synth, text: "old", scopeID: "old and new")
        try check(synth.calls.count == 3, "A replaced stream never leaves partial audio in the sentence cache")
        await startStreaming(session, synth, text: "new", scopeID: "old and new")
        try synth.complete(2, .success(Data([6]))); await settle()
        try check(player.played == [Data([7])] && session.currentText == "new" && synth.calls.count == 3,
                  "Complete replacement audio can replay while a stale stream finishes later")
        session.stop()
    }

    private static func streamingConfigurationChangeRejectsSameText() async throws {
        let player = FakeStreamingSpeechPlayer(), synth = ControlledStreamingSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        await startStreaming(session, synth, text: "shared", configurationID: "key-a", scopeID: "sentence")
        try await synth.emit(0, Data([0, 1]))
        await startStreaming(session, synth, text: "shared", configurationID: "key-b", scopeID: "sentence")
        try await emitAllowingCancellation(synth, 0, Data([2, 3]))
        try synth.complete(0, .success(audio)); await settle()
        try check(player.chunks == [Data([0, 1])] && session.state == .loading && synth.calls.count == 2,
                  "Matching excerpt text cannot bypass a changed configuration's stream token")
        try await synth.emit(1, Data([4, 5])); try synth.complete(1, .success(Data([8]))); await settle(); player.drain()
        await startStreaming(session, synth, text: "shared", configurationID: "key-b", scopeID: "new sentence")
        try check(synth.calls.count == 3 && player.played.isEmpty,
                  "A complete streaming clip still obeys sentence-scope cache isolation")
        session.stop(); try synth.complete(2, .success(audio)); await settle()
    }

    private static func partialStreamFailureIsNeverCached() async throws {
        let player = FakeStreamingSpeechPlayer(), synth = ControlledStreamingSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        await startStreaming(session, synth)
        try await synth.emit(0, Data([0, 1]))
        let previousStops = player.stops
        try synth.complete(0, .failure(SpeechError.networkUnavailable)); await settle()
        try check(session.state == .failed(SpeechError.networkUnavailable.userMessage) && player.stops > previousStops,
                  "A network failure after audible PCM stops the partial stream and reports a safe error")
        try check(player.inputFinishes == 0 && synth.calls.count == 1 && synth.regularCalls.isEmpty,
                  "Partial failure never pretends to drain successfully or performs a paid fallback")
        await startStreaming(session, synth)
        try check(synth.calls.count == 2 && player.played.isEmpty && session.state == .loading,
                  "Only an explicit retry starts a new synthesis after a partial failure")
        session.stop(); try synth.complete(1, .success(audio)); await settle()
    }

    private static func invalidStreamCompletionStopsPartialAudio() async throws {
        let invalidCompletions = [Data(), Data(repeating: 0, count: SpeechPlaybackSession.maximumAudioBytes + 1)]
        for completed in invalidCompletions {
            let player = FakeStreamingSpeechPlayer(), synth = ControlledStreamingSpeechSynthesizer()
            let session = SpeechPlaybackSession(player: player)
            await startStreaming(session, synth)
            try await synth.emit(0, Data([0, 1]))
            let previousStops = player.stops
            try synth.complete(0, .success(completed)); await settle()
            try check(session.state == .failed("语音内容暂时无法播放，请重试。") && player.stops > previousStops,
                      "Empty or oversized completed audio immediately stops already queued PCM")
            try check(player.inputFinishes == 0 && player.played.isEmpty,
                      "Invalid stream completion cannot finish normally or replay partial content")
            await startStreaming(session, synth)
            try check(synth.calls.count == 2, "Invalid completion is not admitted into the replay cache")
            session.stop(); try synth.complete(1, .success(audio)); await settle()
        }
        let player = FakeStreamingSpeechPlayer(), synth = ControlledStreamingSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        await startStreaming(session, synth)
        try synth.complete(0, .success(audio)); await settle()
        try check(session.state == .failed("暂时无法播放语音，请稍后重试。") && player.begins == 0 && player.played.isEmpty,
                  "A streaming result with no PCM cannot silently bypass stream validation")
        await startStreaming(session, synth)
        try check(synth.calls.count == 2, "The no-PCM result is removed from the cache")
        session.stop(); try synth.complete(1, .success(audio)); await settle()
    }

    private static func streamStartupAndAppendReentrancy() async throws {
        for interruptDuringBegin in [true, false] {
            let player = FakeStreamingSpeechPlayer(), synth = ControlledStreamingSpeechSynthesizer()
            let session = SpeechPlaybackSession(player: player)
            if interruptDuringBegin { player.onBegin = { [weak session] in session?.stop() } }
            else { player.onAppend = { [weak session] in session?.stop() } }
            await startStreaming(session, synth)
            try await emitAllowingCancellation(synth, 0, Data([0, 1]))
            try synth.complete(0, .success(audio)); await settle()
            try check(session.state == .idle && player.inputFinishes == 0,
                      "Synchronous interruption in stream startup or append cannot publish later playback")
            try check(player.chunks.count == (interruptDuringBegin ? 0 : 1),
                      "A startup interruption prevents even the first PCM from entering the player")
            player.onBegin = nil; player.onAppend = nil
            await startStreaming(session, synth)
            try check(synth.calls.count == 2 && player.played.isEmpty,
                      "Reentrant interruption never caches an incomplete stream")
            session.stop(); try synth.complete(1, .success(audio)); await settle()
        }
    }

    private static func streamingStateObserverCanReplace() async throws {
        let player = FakeStreamingSpeechPlayer(), synth = ControlledStreamingSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        var replaced = false
        session.onChange = { [weak session] in
            guard let session, session.state == .playing, session.currentText == "first", !replaced else { return }
            replaced = true
            session.toggle(text: "second", configurationID: "qwen-a", scopeID: "sentence", synthesizer: synth)
        }
        await startStreaming(session, synth, text: "first", scopeID: "sentence")
        try await emitAllowingCancellation(synth, 0, Data([0, 1])); await settle()
        try check(session.currentText == "second" && session.state == .loading && synth.calls == ["first", "second"],
                  "A rendering callback can replace the first playing chunk with another excerpt")
        try await emitAllowingCancellation(synth, 0, Data([2, 3]))
        try synth.complete(0, .success(audio)); await settle()
        try check(player.chunks == [Data([0, 1])] && session.currentText == "second",
                  "Reentrant replacement rejects every later old chunk and completed WAV")
        try await synth.emit(1, Data([4, 5])); try synth.complete(1, .success(audio)); await settle()
        try check(session.state == .playing && player.inputFinishes == 1,
                  "The replacement continues through the same streaming player normally")
        session.onChange = nil; player.drain()
    }

    private static func streamCompletionCanStopSynchronously() async throws {
        let player = FakeStreamingSpeechPlayer(), synth = ControlledStreamingSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        player.onFinishStream = { [weak player] in player?.drain() }
        await startStreaming(session, synth)
        try await synth.emit(0, Data([0, 1])); try synth.complete(0, .success(audio)); await settle()
        try check(session.state == .idle && session.currentText == nil && player.inputFinishes == 1,
                  "A very short stream can drain synchronously during finishStream without a stuck playing state")
        await startStreaming(session, synth)
        try check(synth.calls.count == 1 && player.played == [audio] && session.state == .playing,
                  "Synchronous drain still preserves the complete WAV for an explicit replay")
        player.drain()
    }

    private static func streamPlayerFailuresAndCompletedCache() async throws {
        for failureDuringBegin in [true, false] {
            let player = FakeStreamingSpeechPlayer(), synth = ControlledStreamingSpeechSynthesizer()
            let session = SpeechPlaybackSession(player: player)
            if failureDuringBegin { player.beginError = .unavailable } else { player.appendError = .unavailable }
            await startStreaming(session, synth)
            var callbackError: (any Error)?
            do { try await synth.emit(0, Data([0, 1])) } catch { callbackError = error }
            guard let callbackError else { throw SpeechTestFailure(description: "Expected the player error to propagate to synthesis") }
            // A real service propagates a failed onPCM callback out of its
            // synthesizeStreaming task, rather than continuing generation.
            try synth.complete(0, .failure(callbackError)); await settle()
            try check(session.state == .failed("暂时无法播放语音，请稍后重试。") && player.inputFinishes == 0,
                      "Stream begin/append failures stop and surface a playback error")
            player.beginError = nil; player.appendError = nil
            await startStreaming(session, synth)
            try check(synth.calls.count == 2 && synth.regularCalls.isEmpty && player.played.isEmpty,
                      "Failed stream startup is retried only explicitly, never cached or silently regenerated")
            session.stop(); try synth.complete(1, .success(audio)); await settle()
        }
        for finishError in [SpeechPlaybackError.unavailable, .invalidAudio] {
            let player = FakeStreamingSpeechPlayer(), synth = ControlledStreamingSpeechSynthesizer()
            let session = SpeechPlaybackSession(player: player)
            player.finishError = finishError
            await startStreaming(session, synth)
            try await synth.emit(0, Data([0, 1])); try synth.complete(0, .success(audio)); await settle()
            try check(session.state == .failed("暂时无法播放语音，请稍后重试。"),
                      "finishStream failure safely ends the active playback attempt")
            player.finishError = nil
            await startStreaming(session, synth)
            if finishError == .unavailable {
                try check(synth.calls.count == 1 && player.played == [audio] && session.state == .playing,
                          "A fully generated WAV survives a temporary finish/route failure without another paid call")
                player.drain()
            } else {
                try check(synth.calls.count == 2 && player.played.isEmpty,
                          "An invalid complete WAV is evicted and regenerated only after the next tap")
                session.stop(); try synth.complete(1, .success(audio)); await settle()
            }
        }
    }

    private static func replacementDuringSuspendedPCMAppend() async throws {
        let player = FakeStreamingSpeechPlayer(), synth = ControlledStreamingSpeechSynthesizer()
        let session = SpeechPlaybackSession(player: player)
        player.holdsAppend = true
        await startStreaming(session, synth, text: "first", scopeID: "sentence")
        let oldEmission = Task { try await synth.emit(0, Data([0, 1])) }
        await settle()
        try check(player.isAppendWaiting, "The old excerpt is suspended on playback backpressure")
        await startStreaming(session, synth, text: "second", scopeID: "sentence")
        player.holdsAppend = false
        try await synth.emit(1, Data([2, 3]))
        let stopsBeforeResume = player.stops
        try player.resumeAppend()
        do { try await oldEmission.value } catch is CancellationError { }
        try synth.complete(0, .success(audio)); await settle()
        try check(session.currentText == "second" && session.state == .playing && player.stops == stopsBeforeResume,
                  "A resumed old append cannot stop or publish state over the replacement excerpt")
        try check(player.begins == 2 && player.inputFinishes == 0,
                  "A resumed old callback cannot reopen or close the new stream's input")
        try synth.complete(1, .success(Data([6]))); await settle(); player.drain()
        await startStreaming(session, synth, text: "first", scopeID: "sentence")
        try check(synth.calls.count == 3 && player.played.isEmpty,
                  "The old blocked stream's late completion never enters the sentence cache")
        session.stop(); try synth.complete(2, .success(audio)); await settle()
    }

    private static func streamingOwnerReleaseDuringSuspendedAppend() async throws {
        let player = FakeStreamingSpeechPlayer(), synth = ControlledStreamingSpeechSynthesizer()
        var session: SpeechPlaybackSession? = SpeechPlaybackSession(player: player)
        weak let weakSession = session
        player.holdsAppend = true
        await startStreaming(session!, synth)
        let emission = Task { try await synth.emit(0, Data([0, 1])) }
        await settle()
        try check(player.isAppendWaiting, "The playback queue can apply asynchronous backpressure")
        let stopsBeforeRelease = player.stops
        session = nil; await settle()
        try check(weakSession == nil && player.stops > stopsBeforeRelease && player.onStop == nil,
                  "An awaited PCM append cannot retain the keyboard's session or its audio route")
        try check(synth.cancelled.contains(0), "Releasing the owner cancels the pending stream generation")
        try player.resumeAppend()
        do { try await emission.value } catch is CancellationError { }
        try synth.complete(0, .success(audio)); await settle()
        try check(player.inputFinishes == 0 && player.played.isEmpty,
                  "A queued chunk resuming after owner release cannot finish or restart audio")
    }

    private static func singleStreamingCapabilityUsesLegacyPath() async throws {
        let plainPlayer = FakeSpeechPlayer(), streamingSynth = ControlledStreamingSpeechSynthesizer()
        let plainSession = SpeechPlaybackSession(player: plainPlayer)
        await startStreaming(plainSession, streamingSynth)
        try check(streamingSynth.calls.isEmpty && streamingSynth.regularCalls == ["Hello."]
                    && plainPlayer.played == [streamingSynth.regularAudio],
                  "A streaming service with a legacy player uses the existing complete-audio path")
        plainSession.stop()
        let streamingPlayer = FakeStreamingSpeechPlayer(), plainSynth = ControlledSpeechSynthesizer()
        let streamingSession = SpeechPlaybackSession(player: streamingPlayer)
        await start(streamingSession, plainSynth)
        try plainSynth.complete(0, .success(audio)); await settle()
        try check(streamingPlayer.begins == 0 && streamingPlayer.played == [audio] && streamingSession.state == .playing,
                  "A streaming player with a legacy service preserves complete-audio playback")
        streamingSession.stop()
    }
}
