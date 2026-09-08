import AVFAudio
import Foundation

/// Playback belongs to this keyboard's visible lifetime. No recording,
/// background mode, or automatic resume after an interruption is requested.
@MainActor
final class KeyboardAudioPlayer: NSObject, SpeechAudioPlaying, AVAudioPlayerDelegate {
    var onStop: (() -> Void)?
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private var hasActiveSession = false
    private var playbackToken: UUID?

    override init() {
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
        if hasActiveSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
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
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
            guard playbackToken == token else { throw SpeechPlaybackError.unavailable }
            try session.setActive(true)
            hasActiveSession = true
            // Activation can synchronously deliver an interruption notification.
            // A stop during startup must not resume when activation returns.
            guard playbackToken == token else { throw SpeechPlaybackError.unavailable }
            player = audio
            guard audio.play(), playbackToken == token else { throw SpeechPlaybackError.unavailable }
        } catch {
            stop()
            throw (error as? SpeechPlaybackError) ?? .unavailable
        }
    }

    func stop() {
        playbackToken = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        if hasActiveSession {
            hasActiveSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
