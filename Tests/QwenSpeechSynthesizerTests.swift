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
        print("PASS: Qwen speech service — \(assertions) checks; official request schema, isolated audio download, bounded text/JSON/WAV, HTTPS allowlist, safe errors, cancellation and no paid retries; fixtures only, no live API requests")
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
