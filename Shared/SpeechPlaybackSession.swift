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

/// Incremental 24 kHz, signed 16-bit little-endian mono PCM. Appending applies
/// backpressure; onStop fires only after finished input has actually played.
@MainActor
protocol SpeechStreamingAudioPlaying: SpeechAudioPlaying {
    func beginStream() throws
    func appendPCM(_ data: Data) async throws
    func finishStream() throws
}

/// A tap plays a sentence or excerpt once. Audio stays in a bounded memory cache
/// for the current sentence and can be replayed without another generation.
@MainActor
final class SpeechPlaybackSession {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case failed(String)
    }

    private struct Scope: Equatable {
        enum Identity: Equatable {
            case sentence(String)
            case text(String)
        }
        let identity: Identity
        let configurationID: String
    }

    private struct Context: Equatable {
        let text: String
        let scope: Scope
    }

    static let maximumAudioBytes = 4 * 1_024 * 1_024
    static let maximumCachedClips = 12
    private let player: any SpeechAudioPlaying
    private var task: Task<Void, Never>?
    private var token: UUID?
    private var context: Context?
    private var cacheScope: Scope?
    private var cachedAudio: [String: Data] = [:]
    /// Oldest access first; the count is small and bounded.
    private var cacheOrder: [String] = []
    private var cachedByteCount = 0
    private var streamStarted = false
    private(set) var state: State = .idle
    /// The exact excerpt being generated, played, or reported as failed; nil after stop.
    private(set) var currentText: String?
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

    /// Pass the complete English sentence as scopeID when playing its words or
    /// phrases. Omitting it preserves the original one-text cache isolation.
    func toggle(text: String, configurationID: String, scopeID: String? = nil,
                synthesizer: any SpeechSynthesizing) {
        let scope = Scope(identity: scopeID.map(Scope.Identity.sentence) ?? .text(text),
                          configurationID: configurationID)
        let next = Context(text: text, scope: scope)
        if context == next, state == .loading || state == .playing {
            stop()
            return
        }
        task?.cancel()
        task = nil
        token = nil
        player.stop()
        streamStarted = false
        if cacheScope != scope {
            clearAudioCache()
            cacheScope = scope
        }
        context = next
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stop(clearCache: true)
            return
        }

        let requestID = UUID()
        token = requestID
        if let audio = cachedAudio[text] {
            touchCache(text)
            beginPlayback(audio, text: text, requestID: requestID)
            return
        }
        update(.loading)
        // Rendering may synchronously stop playback or select another excerpt.
        guard token == requestID else { return }
        task = Task { [weak self, synthesizer] in
            do {
                try Task.checkCancellation()
                guard self?.token == requestID else { return }
                let isStreaming = synthesizer is any SpeechStreamingSynthesizing
                    && self?.player is any SpeechStreamingAudioPlaying
                let audio: Data
                if isStreaming, let streaming = synthesizer as? any SpeechStreamingSynthesizing {
                    audio = try await streaming.synthesizeStreaming(text) { [weak self] pcm in
                        try Task.checkCancellation()
                        // Do not keep the session alive while a full playback
                        // queue suspends this callback. Deinit stops that queue.
                        guard let streamPlayer = try self?.prepareStream(requestID: requestID) else {
                            throw CancellationError()
                        }
                        try await streamPlayer.appendPCM(pcm)
                        try Task.checkCancellation()
                        guard let self, self.token == requestID else { throw CancellationError() }
                        self.update(.playing)
                    }
                } else {
                    audio = try await synthesizer.synthesize(text)
                }
                try Task.checkCancellation()
                guard let self, self.token == requestID else { return }
                self.task = nil
                guard !audio.isEmpty, audio.count <= Self.maximumAudioBytes else {
                    self.token = nil
                    self.player.stop()
                    self.update(.failed("语音内容暂时无法播放，请重试。"))
                    return
                }
                self.cache(audio, for: text)
                if isStreaming {
                    guard self.streamStarted,
                          let streamPlayer = self.player as? any SpeechStreamingAudioPlaying else {
                        self.removeCachedAudio(for: text)
                        throw SpeechPlaybackError.invalidAudio
                    }
                    // End of generation is not end of playback. The player
                    // notifies onStop after the final scheduled samples drain.
                    try streamPlayer.finishStream()
                } else {
                    self.beginPlayback(audio, text: text, requestID: requestID)
                }
            } catch {
                guard let self, self.token == requestID else { return }
                self.task = nil
                self.token = nil
                self.player.stop()
                self.streamStarted = false
                if (error as? SpeechPlaybackError) == .invalidAudio {
                    self.removeCachedAudio(for: text)
                }
                guard !Task.isCancelled, !(error is CancellationError) else {
                    self.update(.idle)
                    return
                }
                let message = error is SpeechPlaybackError
                    ? "暂时无法播放语音，请稍后重试。"
                    : (error as? SpeechError)?.userMessage ?? "暂时无法生成语音，请稍后重试。"
                self.update(.failed(message))
            }
        }
    }

    /// Keep the current sentence's clips for replay; discard them when input,
    /// provider, credentials, or the visible keyboard context changes.
    func stop(clearCache: Bool = false) {
        token = nil
        task?.cancel()
        task = nil
        player.stop()
        streamStarted = false
        if clearCache {
            clearAudioCache()
            cacheScope = nil
            context = nil
        }
        update(.idle)
    }

    private func prepareStream(requestID: UUID) throws -> any SpeechStreamingAudioPlaying {
        guard token == requestID,
              let streamPlayer = player as? any SpeechStreamingAudioPlaying else {
            throw CancellationError()
        }
        if !streamStarted {
            try streamPlayer.beginStream()
            guard token == requestID else { throw CancellationError() }
            streamStarted = true
        }
        return streamPlayer
    }

    private func beginPlayback(_ audio: Data, text: String, requestID: UUID) {
        guard token == requestID else { return }
        if case .failed = state {
            // A deliberate retry of valid cached audio is a fresh attempt even
            // if the route fails with the same message. Publish the transition
            // so the UI can show that attempt's error without another synthesis.
            update(.loading)
            guard token == requestID else { return }
        }
        do {
            try player.playOnce(audio)
            // A route interruption can arrive while the player is starting.
            guard token == requestID else { return }
            update(.playing)
        } catch {
            guard token == requestID else { return }
            token = nil
            if (error as? SpeechPlaybackError) == .invalidAudio { removeCachedAudio(for: text) }
            player.stop()
            update(.failed("暂时无法播放语音，请稍后重试。"))
        }
    }

    private func cache(_ audio: Data, for text: String) {
        removeCachedAudio(for: text)
        while cachedAudio.count >= Self.maximumCachedClips
                || cachedByteCount + audio.count > Self.maximumAudioBytes {
            guard let oldest = cacheOrder.first else { break }
            removeCachedAudio(for: oldest)
        }
        cachedAudio[text] = audio
        cachedByteCount += audio.count
        cacheOrder.append(text)
    }

    private func touchCache(_ text: String) {
        cacheOrder.removeAll { $0 == text }
        cacheOrder.append(text)
    }

    private func removeCachedAudio(for text: String) {
        if let removed = cachedAudio.removeValue(forKey: text) {
            cachedByteCount -= removed.count
        }
        cacheOrder.removeAll { $0 == text }
    }

    private func clearAudioCache() {
        cachedAudio.removeAll()
        cacheOrder.removeAll()
        cachedByteCount = 0
    }

    private func update(_ next: State) {
        let nextText = next == .idle ? nil : context?.text
        guard state != next || currentText != nextText else { return }
        state = next
        currentText = nextText
        onChange?()
    }
}
