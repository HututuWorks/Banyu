import AVFAudio
import Foundation

/// Small hardware boundary so scheduling, backpressure and cancellation can be
/// verified with PCM fixtures without activating an audio route or playing sound.
@MainActor
protocol KeyboardPCMOutput: AnyObject {
    var onConfigurationChange: (() -> Void)? { get set }
    func start() throws
    func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @MainActor @Sendable () -> Void)
    func stop()
}

@MainActor
private final class KeyboardEnginePCMOutput: KeyboardPCMOutput {
    var onConfigurationChange: (() -> Void)?
    private let format: AVAudioFormat
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var observer: NSObjectProtocol?
    private var startToken: UUID?

    init(format: AVAudioFormat) { self.format = format }
    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        node?.stop()
        engine?.stop()
    }
    func start() throws {
        let token = UUID()
        startToken = token
        // Build the graph only after the caller activates the spoken-audio
        // route. Initial route negotiation must not cancel its own stream.
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        self.engine = engine
        self.node = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        guard startToken == token else {
            engine.stop()
            throw SpeechPlaybackError.unavailable
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onConfigurationChange?() }
        }
    }
    func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @MainActor @Sendable () -> Void) {
        guard let engine, let node, engine.isRunning else { onConfigurationChange?(); return }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            // Render callbacks are not on the UI executor. The outer player
            // checks its token again before touching queue state or finishing.
            Task { @MainActor in played() }
        }
        if !node.isPlaying { node.play() }
    }
    func stop() {
        startToken = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        node?.stop()
        engine?.stop()
    }
}

/// Playback belongs to this keyboard's visible lifetime. No recording,
/// background mode, or automatic resume after an interruption is requested.
@MainActor
final class KeyboardAudioPlayer: NSObject, SpeechStreamingAudioPlaying, AVAudioPlayerDelegate {
    static let sampleRate = 24_000.0
    static let maximumQueuedFrames = 24_000
    static let maximumBufferFrames = 4_096
    var onStop: (() -> Void)?
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private var hasActiveSession = false
    private var playbackToken: UUID?
    private let outputFactory: (AVAudioFormat) -> any KeyboardPCMOutput
    private let activateSession: () throws -> Void
    private let deactivateSession: () -> Void
    private var streamOutput: (any KeyboardPCMOutput)?
    private var streamFormat: AVAudioFormat?
    private var streamStarted = false
    private var streamFinished = false
    private var appending = false
    private var pendingByte: UInt8?
    private var queuedFrames = 0
    private var scheduledFrames: [UUID: Int] = [:]
    private struct QueueWaiter {
        let id: UUID
        let token: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var queueWaiters: [QueueWaiter] = []

    override convenience init() {
        self.init(outputFactory: { KeyboardEnginePCMOutput(format: $0) }, activateSession: {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            try session.setActive(true)
        }, deactivateSession: {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        })
    }

    init(outputFactory: @escaping (AVAudioFormat) -> any KeyboardPCMOutput,
         activateSession: @escaping () throws -> Void,
         deactivateSession: @escaping () -> Void) {
        self.outputFactory = outputFactory
        self.activateSession = activateSession
        self.deactivateSession = deactivateSession
        super.init()
        let notifications = NotificationCenter.default
        // These observers run on the main queue. Handle the event immediately:
        // enqueuing a Task could let an old stop event cancel a later user tap.
        observers.append(notifications.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: value) == .began else { return }
            MainActor.assumeIsolated { self?.stopExternally() }
        })
        observers.append(notifications.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: value) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.stopExternally() }
        })
        for name in [AVAudioSession.mediaServicesWereLostNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopExternally() }
            })
        }
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        player?.delegate = nil
        player?.stop()
        streamOutput?.onConfigurationChange = nil
        streamOutput?.stop()
        queueWaiters.forEach { $0.continuation.resume(throwing: CancellationError()) }
        if hasActiveSession { deactivateSession() }
    }

    func playOnce(_ data: Data) throws {
        stop()
        let token = UUID()
        playbackToken = token
        do {
            let audio: AVAudioPlayer
            do {
                audio = try AVAudioPlayer(data: data)
            } catch {
                throw SpeechPlaybackError.invalidAudio
            }
            audio.delegate = self
            audio.numberOfLoops = 0
            audio.enableRate = false
            audio.rate = 1
            guard audio.prepareToPlay() else { throw SpeechPlaybackError.invalidAudio }
            guard playbackToken == token else { throw SpeechPlaybackError.unavailable }
            try activateSession(for: token)
            // Activation can synchronously deliver an interruption notification.
            // A stop during startup must not resume when activation returns.
            guard playbackToken == token else { throw SpeechPlaybackError.unavailable }
            player = audio
            guard audio.play(), playbackToken == token else { throw SpeechPlaybackError.unavailable }
        } catch {
            if playbackToken == token { stop() }
            throw (error as? SpeechPlaybackError) ?? .unavailable
        }
    }

    /// Prepare a fresh stream without ducking other audio while its first
    /// network chunk is still pending. PCM arrives as 24 kHz, 16-bit little-endian mono.
    func beginStream() throws {
        stop()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.sampleRate, channels: 1,
                                         interleaved: false) else { throw SpeechPlaybackError.unavailable }
        let token = UUID()
        playbackToken = token
        streamFormat = format
        let output = outputFactory(format)
        output.onConfigurationChange = { [weak self] in
            guard let self, self.playbackToken == token else { return }
            self.stopExternally()
        }
        streamOutput = output
    }

    /// Call serially in transport order. Backpressure bounds the render queue
    /// to about one second; the producer can await rather than collect audio.
    func appendPCM(_ data: Data) async throws {
        guard let token = playbackToken, let output = streamOutput, let format = streamFormat,
              !streamFinished, !appending else { throw SpeechPlaybackError.unavailable }
        appending = true
        defer { if playbackToken == token { appending = false } }
        do {
            try Task.checkCancellation()
            guard data.count <= SpeechPlaybackSession.maximumAudioBytes else { throw SpeechPlaybackError.invalidAudio }
            var bytes = data
            if let pendingByte {
                bytes.insert(pendingByte, at: bytes.startIndex)
                self.pendingByte = nil
            }
            if bytes.count % 2 != 0 { pendingByte = bytes.removeLast() }
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                guard playbackToken == token else { throw CancellationError() }
                let frames = min(Self.maximumBufferFrames, (bytes.count - offset) / 2)
                while queuedFrames + frames > Self.maximumQueuedFrames {
                    try await waitForQueueSpace(token: token)
                    try Task.checkCancellation()
                    guard playbackToken == token else { throw CancellationError() }
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                      let channel = buffer.floatChannelData?[0] else { throw SpeechPlaybackError.unavailable }
                buffer.frameLength = AVAudioFrameCount(frames)
                // Explicit byte assembly accepts unaligned Data and splits in
                // the middle of an Int16 sample without platform-endian casts.
                bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    for index in 0 ..< frames {
                        let position = offset + index * 2
                        let value = Int16(bitPattern: UInt16(raw[position]) | UInt16(raw[position + 1]) << 8)
                        channel[index] = Float(value) / 32_768
                    }
                }
                if !streamStarted {
                    try activateSession(for: token)
                    guard playbackToken == token else { throw SpeechPlaybackError.unavailable }
                    try output.start()
                    guard playbackToken == token else { throw SpeechPlaybackError.unavailable }
                    streamStarted = true
                }
                let identifier = UUID()
                queuedFrames += frames
                scheduledFrames[identifier] = frames
                output.schedule(buffer) { [weak self] in self?.bufferPlayed(identifier, token: token) }
                offset += frames * 2
            }
        } catch {
            if playbackToken == token { stop() }
            if error is CancellationError { throw error }
            throw (error as? SpeechPlaybackError) ?? .unavailable
        }
    }

    func finishStream() throws {
        guard streamOutput != nil, !streamFinished else { throw SpeechPlaybackError.unavailable }
        guard pendingByte == nil, streamStarted, !appending else {
            stop()
            throw SpeechPlaybackError.invalidAudio
        }
        streamFinished = true
        if scheduledFrames.isEmpty { stopExternally() }
    }

    private func waitForQueueSpace(token: UUID) async throws {
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard playbackToken == token, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                queueWaiters.append(QueueWaiter(id: identifier, token: token, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelQueueWaiter(identifier, token: token) }
        }
    }

    private func cancelQueueWaiter(_ identifier: UUID, token: UUID) {
        guard let index = queueWaiters.firstIndex(where: { $0.id == identifier && $0.token == token }) else { return }
        let waiter = queueWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func bufferPlayed(_ identifier: UUID, token: UUID) {
        guard playbackToken == token, let frames = scheduledFrames.removeValue(forKey: identifier) else { return }
        queuedFrames -= frames
        let waiters = queueWaiters
        queueWaiters.removeAll()
        waiters.forEach { $0.continuation.resume() }
        // A network gap may drain the queue before synthesis ends. Only EOS
        // plus the final dataPlayedBack callback constitutes natural finish.
        if streamFinished, scheduledFrames.isEmpty { stopExternally() }
    }

    private func activateSession(for token: UUID) throws {
        try activateSession()
        // Activation can synchronously stop this request. If a newer request
        // already owns an active route, its session must not be deactivated.
        guard playbackToken == token else {
            if !hasActiveSession { deactivateSession() }
            throw SpeechPlaybackError.unavailable
        }
        hasActiveSession = true
    }

    func stop() {
        playbackToken = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        let output = streamOutput
        streamOutput = nil
        output?.onConfigurationChange = nil
        output?.stop()
        streamFormat = nil
        streamStarted = false
        streamFinished = false
        appending = false
        pendingByte = nil
        queuedFrames = 0
        scheduledFrames.removeAll()
        let waiters = queueWaiters
        queueWaiters.removeAll()
        waiters.forEach { $0.continuation.resume(throwing: CancellationError()) }
        if hasActiveSession {
            hasActiveSession = false
            deactivateSession()
        }
    }

    private func stopExternally() {
        stop()
        // The session also cancels an in-flight synthesis request, even when
        // there is not yet an AVAudioPlayer to stop.
        onStop?()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.stopIfCurrent(identity) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.stopIfCurrent(identity) }
    }

    private func stopIfCurrent(_ identity: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == identity else { return }
        stopExternally()
    }

}
