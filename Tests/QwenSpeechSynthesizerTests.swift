import Foundation

private struct SpeechServiceTestFailure: Error, CustomStringConvertible { let description: String }

private final class RedirectTestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = false
    func record(_ request: URLRequest?) { lock.withLock { rejected = request == nil } }
    var wasRejected: Bool { lock.withLock { rejected } }
}

@MainActor
private final class StubSpeechTransport: QwenSpeechTransport {
    var requests: [URLRequest] = []
    var limits: [Int] = []
    var handler: @MainActor (Int) async throws -> QwenSpeechResponse

    init(handler: @escaping @MainActor (Int) async throws -> QwenSpeechResponse) { self.handler = handler }

    func send(_ request: URLRequest, maximumBytes: Int) async throws -> QwenSpeechResponse {
        let index = requests.count
        requests.append(request)
        limits.append(maximumBytes)
        return try await handler(index)
    }
}


private typealias SpeechStreamReceiver = @Sendable (QwenSpeechStreamEvent) async throws -> Void

private actor StubSpeechStreamTransport: QwenSpeechStreamTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var limits: [Int] = []
    private let handler: @Sendable (@escaping SpeechStreamReceiver) async throws -> Void
    init(handler: @escaping @Sendable (@escaping SpeechStreamReceiver) async throws -> Void) { self.handler = handler }
    func stream(_ request: URLRequest, maximumBytes: Int,
                receive: @escaping SpeechStreamReceiver) async throws {
        requests.append(request)
        limits.append(maximumBytes)
        try await handler(receive)
    }
}

private actor SpeechStreamGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@main
@MainActor
struct QwenSpeechSynthesizerTests {
    private static let fixtureKey = "sk-synthetic-speech-test-only"
    private static let text = "I'd like to set up a research platform."
    private static let audioURL = "https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/test.wav?Expires=123&Signature=synthetic"
    private static let wave = Data("RIFF\u{04}\0\0\0WAVEfmt ".utf8)
    private static var assertions = 0

    static func main() async throws {
        try await payloadAndDownloadTests()
        try await inputValidationTests()
        try await responseValidationTests()
        try await audioURLTests()
        try await errorAndNoRetryTests()
        try await cancellationTests()
        try redirectPolicyTests()
        try await streamingPayloadAndEarlyAudioTests()
        try await streamingNetworkBoundaryTests()
        try await streamingValidationTests()
        try await streamingBoundsTests()
        try await streamingErrorAndCancellationTests()
        print("PASS: Qwen speech service — \(assertions) checks; official request schema, isolated audio download, bounded text/JSON/WAV, HTTPS allowlist, safe errors, incremental PCM/SSE before EOF, bounded replay WAV, cancellation and no paid retries; fixtures only, no live API requests")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        assertions += 1
        if !condition { throw SpeechServiceTestFailure(description: message) }
    }

    private static func expectError(_ expected: SpeechError, action: () async throws -> Void) async throws {
        do { try await action(); throw SpeechServiceTestFailure(description: "Expected typed speech failure: \(expected)") }
        catch let error as SpeechError { try expect(error == expected, "Speech failure classification") }
    }

    private static func generation(_ url: String = audioURL, finish: String = "stop") -> Data {
        // Data fixtures deliberately use JSONSerialization so signed query strings,
        // quotes and Unicode exercise the real decoder, not test-side escaping.
        try! JSONSerialization.data(withJSONObject: ["output": [
            "finish_reason": finish, "audio": ["url": url, "data": ""]
        ]])
    }

    private static func transport(url: String = audioURL, audio: Data = wave) -> StubSpeechTransport {
        StubSpeechTransport { index in
            QwenSpeechResponse(statusCode: 200, body: index == 0 ? generation(url) : audio)
        }
    }

    private static func payloadAndDownloadTests() async throws {
        let stub = transport()
        let result = try await QwenSpeechSynthesizer(apiKey: " \(fixtureKey)\n", transport: stub).synthesize(text)
        try expect(result == wave, "Return exact downloaded WAV")
        try expect(stub.requests.count == 2, "Exactly one generation and one download")
        let request = stub.requests[0]
        try expect(request.url == QwenSpeechSynthesizer.endpoint, "Fixed official Beijing endpoint")
        try expect(request.httpMethod == "POST", "Generation uses POST")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + fixtureKey, "Only generation receives key")
        try expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "JSON request")
        try expect(request.timeoutInterval == 20, "Generation has finite timeout")
        try expect(request.cachePolicy == .reloadIgnoringLocalCacheData, "Private request bypasses persistent cache")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        try expect(Set(body.keys) == ["model", "input"], "No translation schema or unverified parameters")
        try expect(body["model"] as? String == "qwen3-tts-flash", "Documented TTS model")
        try expect(body["input"] as? [String: String] == [
            "text": text, "voice": "Cherry", "language_type": "English"
        ], "Exact current sentence and documented English voice settings")
        let download = stub.requests[1]
        try expect(download.url?.absoluteString == audioURL, "Preserve signed URL query")
        try expect(download.httpMethod == "GET" && download.httpBody == nil, "Audio GET has no text body")
        try expect(download.value(forHTTPHeaderField: "Authorization") == nil, "Never forward API key to OSS")
        try expect(download.value(forHTTPHeaderField: "Cookie") == nil, "Never forward cookies to OSS")
        try expect(download.timeoutInterval == 15, "Download has finite timeout")
        try expect(stub.limits == [32_768, 4 * 1_024 * 1_024], "Different bounds for JSON and WAV")
    }

    private static func inputValidationTests() async throws {
        for (key, input, error) in [
            ("  ", text, SpeechError.missingAPIKey),
            ("synthetic\r\nInjected: value", text, .invalidAPIKey),
            ("synthetic中文", text, .invalidAPIKey),
            (String(repeating: "x", count: 4_097), text, .invalidAPIKey),
            (fixtureKey, " \n", .invalidResponse),
            (fixtureKey, String(repeating: "a", count: 601), .textTooLong),
            (fixtureKey, String(repeating: "e\u{0301}", count: 301), .textTooLong)
        ] {
            let stub = transport()
            try await expectError(error) {
                _ = try await QwenSpeechSynthesizer(apiKey: key, transport: stub).synthesize(input)
            }
            try expect(stub.requests.isEmpty, "Invalid text/key must not create a billable request")
        }
        let stub = transport()
        let maximum = String(repeating: "a", count: 600)
        _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, transport: stub).synthesize(maximum)
        let json = try JSONSerialization.jsonObject(with: stub.requests[0].httpBody!) as! [String: Any]
        try expect((json["input"] as? [String: String])?["text"] == maximum, "Boundary text retained without truncation")
    }

    private static func responseValidationTests() async throws {
        for body in [Data(), Data("not json".utf8), Data("{}".utf8),
                     Data(#"{"output":{"audio":{"url":"test"}}}"#.utf8),
                     generation(finish: "length"), generation(finish: "null"),
                     Data(repeating: 0x41, count: QwenSpeechSynthesizer.maximumJSONBytes + 1)] {
            let stub = StubSpeechTransport { _ in .init(statusCode: 200, body: body) }
            try await expectError(.invalidResponse) {
                _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, transport: stub).synthesize(text)
            }
            try expect(stub.requests.count == 1, "Malformed/incomplete JSON must not start audio download")
        }
        for body in [Data(), Data("<html>server error</html>".utf8), Data("RIFFshort".utf8),
                     Data("RIFFxxxxNOPE".utf8), Data(repeating: 0, count: QwenSpeechSynthesizer.maximumAudioBytes + 1)] {
            let stub = transport(audio: body)
            try await expectError(.invalidResponse) {
                _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, transport: stub).synthesize(text)
            }
            try expect(stub.requests.count == 2, "Bad audio never triggers regeneration")
        }
        var maximum = wave
        maximum.append(Data(repeating: 0, count: QwenSpeechSynthesizer.maximumAudioBytes - maximum.count))
        let stub = transport(audio: maximum)
        let result = try await QwenSpeechSynthesizer(apiKey: fixtureKey, transport: stub).synthesize(text)
        try expect(result.count == QwenSpeechSynthesizer.maximumAudioBytes, "Allow exact WAV memory bound")
    }

    private static func audioURLTests() async throws {
        let host = "dashscope-result-bj.oss-cn-beijing.aliyuncs.com"
        for url in ["https://example.invalid/audio.wav", "http://127.0.0.1/private.wav",
                    "file:///private.wav", "data:audio/wav;base64,AAAA", "//\(host)/x.wav",
                    "https://\(host).example.invalid/x.wav", "https://key@\(host)/x.wav",
                    "https://user:secret@\(host)/x.wav", "https://\(host):444/x.wav",
                    "http://\(host):81/x.wav", "https://\(host)/x.wav#fragment",
                    "https://\(host)/", "https://\(host)/x.wav\n",
                    "https://other-bucket.oss-cn-beijing.aliyuncs.com/x.wav",
                    "https://\(host)/" + String(repeating: "a", count: 8_193)] {
            let stub = transport(url: url)
            try await expectError(.invalidResponse) {
                _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, transport: stub).synthesize(text)
            }
            try expect(stub.requests.count == 1, "Untrusted URL must not be requested")
        }
        for url in ["http://\(host)/x.wav?Signature=A%2BB%3D", "http://\(host):80/x.wav",
                    "https://\(host):443/x.wav", "https://dashscope-result-wlcb.oss-cn-wulanchabu.aliyuncs.com/x.wav"] {
            let stub = transport(url: url)
            _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, transport: stub).synthesize(text)
            try expect(stub.requests[1].url?.scheme == "https", "Official HTTP example upgraded before any network request")
            try expect(stub.requests[1].value(forHTTPHeaderField: "Authorization") == nil, "Upgrade never introduces Authorization")
            try expect(stub.requests[1].url?.query == URL(string: url)?.query, "HTTP upgrade preserves signed query bytes")
        }
    }

    private static func errorAndNoRetryTests() async throws {
        for (status, expected) in [(401, SpeechError.invalidAPIKey), (402, .accessDenied), (403, .accessDenied),
                                   (429, .rateLimited), (408, .serviceUnavailable), (500, .serviceUnavailable),
                                   (302, .invalidResponse), (307, .invalidResponse), (400, .invalidResponse)] {
            let stub = StubSpeechTransport { _ in .init(statusCode: status, body: Data("sensitive-server-echo".utf8)) }
            try await expectError(expected) {
                _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, transport: stub).synthesize(text)
            }
            try expect(stub.requests.count == 1, "Error/redirect never triggers retries or a new endpoint")
            try expect(!expected.userMessage.contains("sensitive") && !String(reflecting: expected).contains(fixtureKey), "Errors cannot echo response or key")
        }
        for failure in [URLError(.timedOut), URLError(.notConnectedToInternet)] {
            let stub = StubSpeechTransport { _ in throw failure }
            try await expectError(.networkUnavailable) {
                _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, transport: stub).synthesize(text)
            }
            try expect(stub.requests.count == 1, "Transient generation failure has no automatic billable retry")
        }
        let downloadFailure = StubSpeechTransport { index in
            if index == 0 { return .init(statusCode: 200, body: generation()) }
            throw URLError(.networkConnectionLost)
        }
        try await expectError(.networkUnavailable) {
            _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, transport: downloadFailure).synthesize(text)
        }
        try expect(downloadFailure.requests.count == 2, "Download failure does not regenerate charged audio")
        for status in [401, 403, 302] {
            let stub = StubSpeechTransport { index in
                .init(statusCode: index == 0 ? 200 : status, body: index == 0 ? generation() : Data())
            }
            try await expectError(.invalidResponse) {
                _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, transport: stub).synthesize(text)
            }
            try expect(stub.requests.count == 2, "An expired/redirected audio URL cannot retry generation or mislabel API-key permission")
        }
    }

    private static func cancellationTests() async throws {
        for phase in [0, 1] {
            for ignoresCancellation in [false, true] {
                let stub = StubSpeechTransport { index in
                    if index == phase {
                        if ignoresCancellation { try? await Task.sleep(for: .seconds(5)) }
                        else { try await Task.sleep(for: .seconds(5)) }
                    }
                    return .init(statusCode: 200, body: index == 0 ? generation() : wave)
                }
                let task = Task { try await QwenSpeechSynthesizer(apiKey: fixtureKey, transport: stub).synthesize(text) }
                while stub.requests.count <= phase { await Task.yield() }
                task.cancel()
                do { _ = try await task.value; throw SpeechServiceTestFailure(description: "Cancelled audio must not publish") }
                catch is CancellationError { try expect(true, "Cancellation preserved") }
                try expect(stub.requests.count == phase + 1, "Cancelled generation/download cannot trigger next work")
            }
        }
        let cancelled = StubSpeechTransport { _ in throw URLError(.cancelled) }
        do {
            _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, transport: cancelled).synthesize(text)
            throw SpeechServiceTestFailure(description: "URL cancellation must stay cancellation")
        } catch is CancellationError { try expect(true, "URL cancellation preserved") }

        let stub = transport()
        let task = Task { try await QwenSpeechSynthesizer(apiKey: fixtureKey, transport: stub).synthesize(text) }
        task.cancel()
        do { _ = try await task.value; throw SpeechServiceTestFailure(description: "Pre-cancelled request must stop") }
        catch is CancellationError { try expect(stub.requests.isEmpty, "Cancellation checked before any billable request") }
    }


    private static func sse(_ pcm: Data? = nil, finish: String? = nil) -> Data {
        let body = try! JSONSerialization.data(withJSONObject: [
            "request_id": "fixture-语音",
            "output": ["finish_reason": finish as Any? ?? NSNull(),
                       "audio": ["data": pcm?.base64EncodedString() ?? "", "url": finish == "stop" ? audioURL : ""]]
        ])
        return Data("data: ".utf8) + body + Data("\n\n".utf8)
    }

    private static func streamTransport(_ data: Data, split: Int? = nil) -> StubSpeechStreamTransport {
        StubSpeechStreamTransport { receive in
            try await receive(.response(statusCode: 200, contentType: "text/event-stream; charset=utf-8"))
            if let split {
                for offset in stride(from: 0, to: data.count, by: split) {
                    try await receive(.bytes(Data(data[offset..<min(data.count, offset + split)])))
                }
            } else { try await receive(.bytes(data)) }
        }
    }

    private static func streamingPayloadAndEarlyAudioTests() async throws {
        let first = Data([0x00, 0x01, 0xFE, 0x7F])
        let second = Data([0xFF, 0x7F, 0x00, 0x80])
        let firstEvent = sse(first), lastEvents = sse(second) + sse(finish: "stop")
        let gate = SpeechStreamGate()
        let stub = StubSpeechStreamTransport { receive in
            try await receive(.response(statusCode: 200, contentType: "text/event-stream"))
            try await receive(.bytes(firstEvent))
            await gate.wait()
            try await receive(.bytes(lastEvents))
        }
        let noDownload = transport()
        var delivered: [Data] = []
        var completed = false
        let task = Task {
            let result = try await QwenSpeechSynthesizer(apiKey: fixtureKey, transport: noDownload,
                                                       streamTransport: stub).synthesizeStreaming(text) { delivered.append($0) }
            completed = true
            return result
        }
        for _ in 0..<10_000 where delivered.isEmpty { await Task.yield() }
        try expect(delivered == [first] && !completed, "PCM is delivered before the stream finishes or its WAV URL arrives")
        await gate.release()
        let wave = try await task.value
        try expect(delivered == [first, second], "Stream callbacks preserve the exact PCM ordering")
        try expect(wave.count == first.count + second.count + 44 && wave.suffix(8) == first + second,
                   "Completed stream wraps exact PCM in a 44-byte WAV header")
        try expect(wave.prefix(4) == Data("RIFF".utf8) && wave[8..<12] == Data("WAVE".utf8), "Streaming result is a replayable RIFF/WAVE")
        try expect(Array(wave[20..<36]) == [1, 0, 1, 0, 0xC0, 0x5D, 0, 0, 0x80, 0xBB, 0, 0, 2, 0, 16, 0],
                   "WAV declares signed PCM24kHz mono16bit with correct byte rate/alignment")
        let requests = await stub.requests
        try expect(requests.count == 1 && noDownload.requests.isEmpty, "Streaming makes one generation request and no URL download")
        let request = requests[0]
        try expect(request.url == QwenSpeechSynthesizer.endpoint && request.httpMethod == "POST", "Streaming retains the existing Beijing endpoint")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + fixtureKey,
                   "Streaming uses the existing key only on the official endpoint")
        try expect(request.value(forHTTPHeaderField: "X-DashScope-SSE") == "enable"
                   && request.value(forHTTPHeaderField: "Accept") == "text/event-stream", "Documented header enables SSE")
        let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        try expect(Set(json.keys) == ["model", "input"] && json["model"] as? String == "qwen3-tts-flash",
                   "SSE does not silently switch models or add a Realtime schema")
        try expect(json["input"] as? [String: String] == ["text": text, "voice": "Cherry", "language_type": "English"],
                   "SSE preserves the exact text, voice and language")
        let configuration = URLSessionQwenSpeechStreamTransport.configuration(for: request)
        try expect(configuration.timeoutIntervalForRequest == 20 && configuration.timeoutIntervalForResource == 120,
                   "Twenty-second idle timeout permits up to120seconds of healthy stream/playback backpressure")
        try expect(configuration.urlCache == nil && configuration.httpCookieStorage == nil
                   && configuration.urlCredentialStorage == nil && !configuration.httpShouldSetCookies,
                   "Streaming keeps cache, cookies and credential persistence disabled")
        try expect(await stub.limits == [8 * 1_024 * 1_024], "SSE wire bytes have an independent Base64/metadata budget")
    }

    private static func streamingNetworkBoundaryTests() async throws {
        let sample = Data([1, 2, 3, 4, 5, 6, 7, 8])
        let base = sse(sample) + sse(finish: "stop")
        for separator in ["\n", "\r\n", "\r"] {
            let framed = Data([0xEF, 0xBB, 0xBF]) + Data(": keepalive\n\nid: test\nevent: result\n".utf8)
                + base + Data("data: [DONE]\n\n".utf8)
            let replaced = Data(String(decoding: framed, as: UTF8.self).replacingOccurrences(of: "\n", with: separator).utf8)
            for split in [1, 7, 4_096] {
                let stub = streamTransport(replaced, split: split)
                var delivered = Data()
                let result = try await QwenSpeechSynthesizer(apiKey: fixtureKey, streamTransport: stub)
                    .synthesizeStreaming(text) { delivered.append($0) }
                try expect(delivered == sample && result.suffix(sample.count) == sample,
                           "SSE delimiters, UTF-8 and Base64 survive arbitrary transport boundaries")
            }
        }
        let multiline = Data("data: {\ndata: \"output\": {\"audio\": {\"data\": \"AQIDBA==\"},\ndata: \"finish_reason\": null}}\n\n".utf8)
        let unterminatedFinal = Data(sse(finish: "stop").dropLast(2))
        let stub = streamTransport(multiline + unterminatedFinal)
        let result = try await QwenSpeechSynthesizer(apiKey: fixtureKey, streamTransport: stub).synthesizeStreaming(text) { _ in }
        try expect(result.suffix(4) == Data([1, 2, 3, 4]), "Multiline SSE data and final event without blank-line terminator parse correctly")

        let large = Data(repeating: 4, count: 24_000)
        var delivered: [Data] = []
        let aligned = streamTransport(sse(Data([1])) + sse(Data([2, 3, 4])) + sse(large) + sse(finish: "stop"))
        _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, streamTransport: aligned)
            .synthesizeStreaming(text) { delivered.append($0) }
        try expect(delivered.allSatisfy { $0.count <= 8_192 && $0.count.isMultiple(of: 2) },
                   "Every playback callback is at most8192bytes and contains complete16bit frames")
        try expect(delivered.reduce(into: Data()) { $0.append($1) } == Data([1, 2, 3, 4]) + large,
                   "One-byte carries and bounded packet splitting preserve every PCM sample")
    }

    private static func streamingValidationTests() async throws {
        let pcm = Data([1, 2])
        let badJSON = Data("data: not-json\n\n".utf8)
        let badBase64 = Data("data: {\"output\":{\"audio\":{\"data\":\"invalid!\"},\"finish_reason\":null}}\n\n".utf8)
        for stream in [Data(), badJSON, badBase64, sse(pcm), sse(finish: "stop"),
                       sse(Data([1])) + sse(finish: "stop"), sse(pcm, finish: "length"),
                       sse(pcm) + Data("data: [DONE]\n\n".utf8),
                       sse(pcm) + sse(finish: "stop") + sse(pcm),
                       Data("data: {}\n\n".utf8)] {
            let stub = streamTransport(stream)
            try await expectError(.invalidResponse) {
                _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, streamTransport: stub).synthesizeStreaming(text) { _ in }
            }
            try expect(await stub.requests.count == 1, "Malformed or unfinished streaming never retries generation")
        }
        for type in ["application/json", "text/html", ""] {
            let stub = StubSpeechStreamTransport { receive in try await receive(.response(statusCode: 200, contentType: type)) }
            try await expectError(.invalidResponse) {
                _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, streamTransport: stub).synthesizeStreaming(text) { _ in }
            }
        }
        let noResponse = StubSpeechStreamTransport { receive in try await receive(.bytes(Data("data: {}\n\n".utf8))) }
        try await expectError(.invalidResponse) {
            _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, streamTransport: noResponse).synthesizeStreaming(text) { _ in }
        }
        for (key, input, expected) in [("", text, SpeechError.missingAPIKey), ("injected\r\nheader", text, .invalidAPIKey),
                                        (fixtureKey, " ", .invalidResponse), (fixtureKey, String(repeating: "a", count: 601), .textTooLong)] {
            let stub = streamTransport(sse(pcm, finish: "stop"))
            try await expectError(expected) {
                _ = try await QwenSpeechSynthesizer(apiKey: key, streamTransport: stub).synthesizeStreaming(input) { _ in }
            }
            try expect(await stub.requests.isEmpty, "Streaming validates key and full text before a paid request")
        }
    }

    private static func streamingBoundsTests() async throws {
        for stream in [Data(repeating: 0x41, count: 1_024 * 1_024 + 1),
                       Data(repeating: 0x41, count: 8 * 1_024 * 1_024 + 1),
                       (0..<4).reduce(into: Data()) { data, _ in
                           data.append(Data("data: ".utf8) + Data(repeating: 0x41, count: 300_000) + Data("\n".utf8))
                       }] {
            let stub = streamTransport(stream)
            try await expectError(.invalidResponse) {
                _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, streamTransport: stub).synthesizeStreaming(text) { _ in }
            }
        }
        let maximum = QwenSpeechSynthesizer.maximumAudioBytes - 44
        var valid = Data()
        for offset in stride(from: 0, to: maximum, by: 512 * 1_024) {
            valid.append(sse(Data(repeating: 0, count: min(512 * 1_024, maximum - offset))))
        }
        let stub = streamTransport(valid + sse(finish: "stop"))
        var deliveredBytes = 0
        let wave = try await QwenSpeechSynthesizer(apiKey: fixtureKey, streamTransport: stub)
            .synthesizeStreaming(text) { deliveredBytes += $0.count }
        try expect(wave.count == QwenSpeechSynthesizer.maximumAudioBytes && deliveredBytes == maximum,
                   "The exact4MiB cache bound includes the generated WAV header")
        let oversized = streamTransport(valid + sse(Data([1, 2])) + sse(finish: "stop"))
        try await expectError(.invalidResponse) {
            _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, streamTransport: oversized).synthesizeStreaming(text) { _ in }
        }
    }

    private static func streamingErrorAndCancellationTests() async throws {
        for (status, expected) in [(401, SpeechError.invalidAPIKey), (403, .accessDenied), (429, .rateLimited),
                                   (500, .serviceUnavailable), (302, .invalidResponse)] {
            let stub = StubSpeechStreamTransport { receive in try await receive(.response(statusCode: status, contentType: "text/event-stream")) }
            var delivered = false
            try await expectError(expected) {
                _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, streamTransport: stub)
                    .synthesizeStreaming(text) { _ in delivered = true }
            }
            try expect(await stub.requests.count == 1 && !delivered, "HTTP errors and redirects never play or retry")
        }
        for (code, expected) in [("InvalidApiKey", SpeechError.invalidAPIKey), ("Throttling", .rateLimited),
                                 ("sensitive-server-error", .serviceUnavailable)] {
            let body = Data("data: {\"code\":\"\(code)\",\"message\":\"private text\"}\n\n".utf8)
            let stub = streamTransport(body)
            try await expectError(expected) {
                _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, streamTransport: stub).synthesizeStreaming(text) { _ in }
            }
        }
        let offline = StubSpeechStreamTransport { _ in throw URLError(.networkConnectionLost) }
        try await expectError(.networkUnavailable) {
            _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, streamTransport: offline).synthesizeStreaming(text) { _ in }
        }
        let first = sse(Data([1, 2])), tail = sse(Data([3, 4])) + sse(finish: "stop")
        let gate = SpeechStreamGate()
        let stub = StubSpeechStreamTransport { receive in
            try await receive(.response(statusCode: 200, contentType: "text/event-stream"))
            try await receive(.bytes(first))
            await gate.wait() // Deliberately ignores cancellation until resumed.
            try await receive(.bytes(tail))
        }
        var delivered = Data()
        let task = Task {
            try await QwenSpeechSynthesizer(apiKey: fixtureKey, streamTransport: stub)
                .synthesizeStreaming(text) { delivered.append($0) }
        }
        for _ in 0..<10_000 where delivered.isEmpty { await Task.yield() }
        task.cancel(); await gate.release()
        do { _ = try await task.value; throw SpeechServiceTestFailure(description: "Cancelled stream returned a cache entry") }
        catch is CancellationError { try expect(delivered == Data([1, 2]), "Cancelled stream rejects all later PCM and never returns partial WAV") }
        try expect(await stub.requests.count == 1, "Cancellation never creates a replacement paid request")
        let preCancelled = streamTransport(first + tail)
        let cancelledTask = Task {
            try await QwenSpeechSynthesizer(apiKey: fixtureKey, streamTransport: preCancelled).synthesizeStreaming(text) { _ in }
        }
        cancelledTask.cancel()
        do { _ = try await cancelledTask.value; throw SpeechServiceTestFailure(description: "Pre-cancelled stream was sent") }
        catch is CancellationError { try expect(await preCancelled.requests.isEmpty, "Cancellation is checked before streaming request dispatch") }
        let callbackFailure = streamTransport(first + tail)
        do {
            _ = try await QwenSpeechSynthesizer(apiKey: fixtureKey, streamTransport: callbackFailure).synthesizeStreaming(text) { _ in
                throw SpeechServiceTestFailure(description: "local-player-stopped")
            }
            throw SpeechServiceTestFailure(description: "Consumer failure was ignored")
        } catch let error as SpeechServiceTestFailure {
            try expect(error.description == "local-player-stopped", "Local playback failures reach the session unchanged")
        }
    }

    private static func redirectPolicyTests() throws {
        // Exercise the actual URLSession delegate without resuming a network task.
        // In particular, a proposed redirect already containing Authorization must
        // be rejected rather than merely removing the header and following it.
        let delegate = QwenSpeechSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for target in [QwenSpeechSynthesizer.endpoint, URL(string: "https://example.invalid/steal")!] {
            var request = URLRequest(url: target)
            request.setValue("Bearer " + fixtureKey, forHTTPHeaderField: "Authorization")
            let decision = RedirectTestResult()
            let task = session.dataTask(with: request)
            let response = HTTPURLResponse(url: QwenSpeechSynthesizer.endpoint, statusCode: 307,
                                           httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                newRequest: request) { decision.record($0) }
            try expect(decision.wasRejected, "Actual transport rejects both same-origin and cross-origin redirects")
            task.cancel()
        }
    }
}
