import AVFAudio
import Foundation

private struct PCMCheckFailure: Error { let message: String }

@MainActor
private final class PCMOutputStub: KeyboardPCMOutput {
    struct Buffer {
        let samples: [Float]
        let played: @MainActor @Sendable () -> Void
        var completed = false
    }
    var onConfigurationChange: (() -> Void)?
    var buffers: [Buffer] = []
    var starts = 0
    var stops = 0
    var startError: (any Error)?
    var outstanding: Int { buffers.filter { !$0.completed }.reduce(0) { $0 + $1.samples.count } }
    func start() throws { starts += 1; if let startError { throw startError } }
    func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @MainActor @Sendable () -> Void) {
        buffers.append(Buffer(samples: Array(UnsafeBufferPointer(start: buffer.floatChannelData![0],
                                                                 count: Int(buffer.frameLength))), played: played))
    }
    func stop() { stops += 1 }
    func complete(_ index: Int) {
        guard buffers.indices.contains(index), !buffers[index].completed else { return }
        buffers[index].completed = true
        buffers[index].played()
    }
    func completeNext() { if let index = buffers.firstIndex(where: { !$0.completed }) { complete(index) } }
}

@MainActor
private final class PCMStats {
    var outputs: [PCMOutputStub] = []
    var formats: [AVAudioFormat] = []
    var activations = 0
    var deactivations = 0
    var completions = 0
}

@MainActor
private enum PCMChecks {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw PCMCheckFailure(message: message) }
        assertions += 1
    }
    static func fixture() -> (KeyboardAudioPlayer, PCMStats) {
        let stats = PCMStats()
        let player = KeyboardAudioPlayer(outputFactory: { format in
            let output = PCMOutputStub()
            stats.formats.append(format)
            stats.outputs.append(output)
            return output
        }, activateSession: { stats.activations += 1 }, deactivateSession: { stats.deactivations += 1 })
        player.onStop = { stats.completions += 1 }
        return (player, stats)
    }
    static func settle(until predicate: () -> Bool) async throws {
        for _ in 0 ..< 1_000 {
            if predicate() { return }
            await Task.yield()
        }
        throw PCMCheckFailure(message: "Asynchronous PCM operation did not settle")
    }
    static func run() async throws {
        // Sample boundaries can cross transport chunks, including a one-byte
        // first chunk. Real hardware remains behind the injected adapter.
        do {
            let (player, stats) = fixture()
            try player.beginStream()
            let output = stats.outputs[0]
            try expect(stats.activations == 0 && output.starts == 0, "begin does not activate audio while waiting for first sample")
            try await player.appendPCM(Data([0]))
            try expect(stats.activations == 0 && output.buffers.isEmpty, "partial first sample waits without starting a route")
            try await player.appendPCM(Data([0, 255, 127, 0, 128, 255, 255]))
            try expect(stats.activations == 1 && output.starts == 1 && output.buffers.count == 1,
                       "first complete PCM chunk schedules immediately")
            try expect(stats.formats[0].sampleRate == 24_000 && stats.formats[0].channelCount == 1
                       && stats.formats[0].commonFormat == .pcmFormatFloat32, "render format is24kHzFloat32 mono")
            try expect(output.buffers[0].samples == [0, Float(32767) / 32768, -1, -Float(1) / 32768],
                       "unaligned Int16LE samples decode correctly, including negative extrema")
            output.completeNext()
            try expect(stats.completions == 0 && stats.deactivations == 0, "temporary queue underflow is not natural completion")
            try await player.appendPCM(Data([0, 64]))
            try expect(output.starts == 1 && output.buffers[1].samples == [0.5], "a later chunk resumes the same playback graph")
            try player.finishStream()
            try expect(stats.completions == 0, "EOS waits until its last scheduled audio is actually played")
            output.completeNext()
            try expect(stats.completions == 1 && stats.deactivations == 1, "final dataPlayedBack ends once and releases session")
            output.buffers[1].played()
            try expect(stats.completions == 1, "duplicate or late completion cannot finish twice")
        }

        // A much larger transport delta still produces a bounded render queue.
        do {
            let (player, stats) = fixture()
            try player.beginStream()
            let output = stats.outputs[0]
            var done = false
            let append = Task { defer { done = true }; try await player.appendPCM(Data(repeating: 0, count: 100_000)) }
            try await settle { output.buffers.count >= 5 }
            try expect(!done && output.outstanding <= KeyboardAudioPlayer.maximumQueuedFrames,
                       "producer suspends instead of buffering the full generation")
            try expect(output.buffers.allSatisfy { $0.samples.count <= KeyboardAudioPlayer.maximumBufferFrames },
                       "individual scheduled buffers remain small")
            for _ in 0 ..< 30 {
                if done { break }
                output.completeNext()
                await Task.yield()
                try expect(output.outstanding <= KeyboardAudioPlayer.maximumQueuedFrames, "queue stays bounded while backpressure resumes")
            }
            try await settle { done }
            try await append.value
            try expect(output.buffers.reduce(0) { $0 + $1.samples.count } == 50_000, "backpressure does not lose PCM samples")
            try player.finishStream()
            while output.outstanding > 0 { output.completeNext() }
            try expect(stats.completions == 1, "large stream completes exactly once")
        }

        for cancelTask in [false, true] {
            let (player, stats) = fixture()
            try player.beginStream()
            let output = stats.outputs[0]
            let append = Task { try await player.appendPCM(Data(repeating: 0, count: 100_000)) }
            try await settle { output.buffers.count >= 5 }
            if cancelTask { append.cancel() } else { player.stop() }
            do { try await append.value; throw PCMCheckFailure(message: "cancelled queued producer unexpectedly succeeded") }
            catch is CancellationError {}
            try expect(output.stops == 1 && stats.deactivations == 1 && stats.completions == 0,
                       "cancel/stop releases suspended append exactly once without a natural-finish callback")
            try player.beginStream()
            try await player.appendPCM(Data([0, 0]))
            let next = stats.outputs[1]
            output.completeNext()
            try expect(next.stops == 0 && stats.completions == 0, "old buffer callback cannot stop a newer stream")
            try player.finishStream()
            next.completeNext()
            try expect(stats.completions == 1, "new stream still completes normally after cancellation")
        }

        do {
            let (player, stats) = fixture()
            try player.beginStream()
            try await player.appendPCM(Data([1, 0]))
            stats.outputs[0].onConfigurationChange?()
            try expect(stats.completions == 1 && stats.deactivations == 1, "hardware configuration change stops without auto resume")
            try player.beginStream()
            try await player.appendPCM(Data([1, 0]))
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                                            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            try expect(stats.completions == 2 && stats.deactivations == 2, "audio interruption also stops a stream")
        }

        for tail in [Data(), Data([1])] {
            let (player, stats) = fixture()
            try player.beginStream()
            try await player.appendPCM(tail)
            do { try player.finishStream(); throw PCMCheckFailure(message: "empty or half-sample PCM accepted") }
            catch SpeechPlaybackError.invalidAudio {}
            try expect(stats.activations == 0 && stats.outputs[0].stops == 1, "invalid empty/odd stream fails without activating audio")
        }

        do {
            let (player, stats) = fixture()
            try player.beginStream()
            stats.outputs[0].startError = NSError(domain: "FixtureAudioEngine", code: -50)
            do { try await player.appendPCM(Data([0, 0])); throw PCMCheckFailure(message: "failed audio engine was accepted") }
            catch SpeechPlaybackError.unavailable {}
            try expect(stats.outputs[0].buffers.isEmpty && stats.deactivations == 1,
                       "hardware start error becomes playback-unavailable and releases its route")
        }

        // An interruption delivered from within activation cannot reactivate
        // the cancelled request when activation returns to the caller.
        do {
            let stats = PCMStats()
            weak var current: KeyboardAudioPlayer?
            let player = KeyboardAudioPlayer(outputFactory: { _ in
                let output = PCMOutputStub(); stats.outputs.append(output); return output
            }, activateSession: { stats.activations += 1; current?.stop() },
               deactivateSession: { stats.deactivations += 1 })
            current = player
            try player.beginStream()
            do { try await player.appendPCM(Data([0, 0])); throw PCMCheckFailure(message: "cancelled activation scheduled audio") }
            catch SpeechPlaybackError.unavailable {}
            try expect(stats.outputs[0].starts == 0 && stats.outputs[0].buffers.isEmpty && stats.deactivations == 1,
                       "startup cancellation never resumes playback and returns the activated route")
        }
        print("Keyboard audio streaming: \(assertions) checks passed (stub output; no audio or network)")
    }
}

@main
private struct KeyboardAudioPlayerTests {
    @MainActor static func main() async {
        do { try await PCMChecks.run() }
        catch { print("Keyboard audio streaming FAILED: \(error)"); exit(1) }
    }
}
