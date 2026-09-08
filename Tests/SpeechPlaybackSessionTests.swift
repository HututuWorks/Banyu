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
        try await loadingRenderCanCancelOrReplace()
        try await failuresAndRetry()
        try await invalidAudioIsNotPlayed()
        try await externalStopsCancelLoadingAndPlayback()
        try await playbackStartInterruption()
        try await ownerReleaseCancelsAndStops()
        try await emptyTextAndNoDuplicateIdleNotifications()
        print("Speech playback session: 13 cases, \(assertions) assertions passed.")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        guard condition() else { throw SpeechTestFailure(description: message) }
    }

    private static func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    private static func start(_ session: SpeechPlaybackSession, _ synth: ControlledSpeechSynthesizer,
                              text: String = "Hello.", configurationID: String = "qwen-a") async {
        session.toggle(text: text, configurationID: configurationID, synthesizer: synth)
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
}
