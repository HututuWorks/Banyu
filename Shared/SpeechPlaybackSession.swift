import Foundation

/// A temporary audio route failure must not charge for another synthesis.
enum SpeechPlaybackError: Error, Equatable, Sendable {
    case invalidAudio
    case unavailable
}

@MainActor
protocol SpeechAudioPlaying: AnyObject {
    /// Natural completion or external stops, such as a phone call or disconnected headphones.
    var onStop: (() -> Void)? { get set }
    func playOnce(_ data: Data) throws
    func stop()
}

/// A tap starts or stops the current sentence. Audio exists only in memory and
/// is reused when the user taps to replay after completion or a manual stop.
@MainActor
final class SpeechPlaybackSession {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case failed(String)
    }

    private struct Context: Equatable {
        let text: String
        let configurationID: String
    }

    static let maximumAudioBytes = 4 * 1_024 * 1_024
    private let player: any SpeechAudioPlaying
    private var task: Task<Void, Never>?
    private var token: UUID?
    private var context: Context?
    private var cachedAudio: Data?
    private(set) var state: State = .idle
    var onChange: (() -> Void)?

    init(player: any SpeechAudioPlaying) {
        self.player = player
        player.onStop = { [weak self] in self?.stop() }
    }

    isolated deinit {
        task?.cancel()
        player.onStop = nil
        player.stop()
    }

    func toggle(text: String, configurationID: String,
                synthesizer: any SpeechSynthesizing) {
        let next = Context(text: text, configurationID: configurationID)
        if context == next, state == .loading || state == .playing {
            stop()
            return
        }
        task?.cancel()
        task = nil
        token = nil
        player.stop()
        if context != next { cachedAudio = nil }
        context = next
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stop(clearCache: true)
            return
        }

        let requestID = UUID()
        token = requestID
        if let cachedAudio {
            beginPlayback(cachedAudio, requestID: requestID)
            return
        }
        update(.loading)
        // Rendering may synchronously stop playback or select another sentence.
        guard token == requestID else { return }
        task = Task { [weak self, synthesizer] in
            do {
                try Task.checkCancellation()
                guard self?.token == requestID else { return }
                let audio = try await synthesizer.synthesize(text)
                try Task.checkCancellation()
                guard let self, self.token == requestID else { return }
                self.task = nil
                guard !audio.isEmpty, audio.count <= Self.maximumAudioBytes else {
                    self.token = nil
                    self.update(.failed("语音内容暂时无法播放，请重试。"))
                    return
                }
                self.cachedAudio = audio
                self.beginPlayback(audio, requestID: requestID)
            } catch {
                guard let self, self.token == requestID else { return }
                self.task = nil
                self.token = nil
                guard !Task.isCancelled, !(error is CancellationError) else {
                    self.update(.idle)
                    return
                }
                self.update(.failed((error as? SpeechError)?.userMessage
                                    ?? "暂时无法生成语音，请稍后重试。"))
            }
        }
    }

    /// Keep one sentence for a stop/replay tap; discard it when input, provider,
    /// credentials, or the visible keyboard context changes.
    func stop(clearCache: Bool = false) {
        token = nil
        task?.cancel()
        task = nil
        player.stop()
        if clearCache {
            cachedAudio = nil
            context = nil
        }
        update(.idle)
    }

    private func beginPlayback(_ audio: Data, requestID: UUID) {
        guard token == requestID else { return }
        do {
            try player.playOnce(audio)
            // A route interruption can arrive while the player is starting.
            guard token == requestID else { return }
            update(.playing)
        } catch {
            guard token == requestID else { return }
            token = nil
            if (error as? SpeechPlaybackError) == .invalidAudio { cachedAudio = nil }
            player.stop()
            update(.failed("暂时无法播放语音，请稍后重试。"))
        }
    }

    private func update(_ next: State) {
        guard state != next else { return }
        state = next
        onChange?()
    }
}
