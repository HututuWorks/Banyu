import Foundation

private struct CloudTestFailure: Error, CustomStringConvertible { let description: String }

@MainActor
private final class CloudTestSettings {
    var snapshot: TranslationSettingsSnapshot
    var fullAccess = true
    init(_ snapshot: TranslationSettingsSnapshot) { self.snapshot = snapshot }
}

@MainActor
private final class StubCloudTransport: QwenTransport {
    var requests: [URLRequest] = []
    var handler: @MainActor () async throws -> QwenTransportResponse

    init(status: Int = 200, body: String = #"{"choices":[{"finish_reason":"stop","message":{"content":"I'm almost there."}}]}"#) {
        handler = { QwenTransportResponse(statusCode: status, body: Data(body.utf8)) }
    }

    func send(_ request: URLRequest) async throws -> QwenTransportResponse {
        requests.append(request)
        return try await handler()
    }
}

@MainActor
private final class StubHintTranslator: HintTranslating {
    var calls: [String] = []
    var handler: @MainActor () async throws -> HintTranslationResult

    init(text: String = "Apple result") {
        handler = { HintTranslationResult(text: text, sourceLanguageCode: "zh-Hans") }
    }

    func translate(_ source: String) async throws -> HintTranslationResult {
        calls.append(source)
        return try await handler()
    }
}

@main
@MainActor
struct QwenTranslatorTests {
    private static let fixtureKey = "sk-synthetic-test-only"
    private static let fixture = "我快到了。"
    private static let custom = CustomTranslationConfiguration(
        baseURL: "https://translation.example.invalid/v1/", model: "example-model", apiKey: "custom-synthetic-only")

    static func main() async throws {
        try await payloadTests()
        try await failureTests()
        try await cancellationTests()
        try await routingTests()
        try await staleAndPermissionTests()
        try await customRevisionAndCancellationTests()
        try await noPaidRetryTests()
        print("PASS: cloud translation — exact Qwen/custom payloads, secret-safe errors, bounded output, cancellation, explicit routing, fallback, permission/revision invalidation and no paid recovery loop; stub transport only, no live API requests")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw CloudTestFailure(description: message) }
    }

    private static func expectError(_ expected: QwenTranslationError,
                                    action: () async throws -> Void) async throws {
        do { try await action(); throw CloudTestFailure(description: "Expected typed cloud failure") }
        catch let error as QwenTranslationError { try expect(error == expected, "Cloud failure classification") }
    }

    private static func expectHintError(_ expected: HintTranslationError,
                                        action: () async throws -> Void) async throws {
        do { try await action(); throw CloudTestFailure(description: "Expected typed hint failure") }
        catch let error as HintTranslationError { try expect(error == expected, "Hint failure classification") }
    }

    private static func dictionary(_ request: URLRequest) throws -> [String: Any] {
        guard let body = request.httpBody,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw CloudTestFailure(description: "Expected JSON request body")
        }
        return object
    }

    private static func payloadTests() async throws {
        let transport = StubCloudTransport()
        let translator = QwenTranslator(apiKey: fixtureKey, transport: transport)
        let result = try await translator.translate(fixture)
        try expect(result.text == "I'm almost there.", "Decode completed translation")
        try expect(transport.requests.count == 1, "One request per source")
        let request = transport.requests[0]
        try expect(request.url?.absoluteString == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", "Only official fixed endpoint")
        try expect(request.httpMethod == "POST", "POST request")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + fixtureKey, "Bearer auth header")
        try expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "JSON content type")
        try expect(request.timeoutInterval == 3, "Bounded latency timeout")
        try expect(request.cachePolicy == .reloadIgnoringLocalCacheData, "No cached private requests")
        let body = try dictionary(request)
        try expect(Set(body.keys) == ["model", "messages", "translation_options"], "Qwen dedicated schema only")
        try expect(body["model"] as? String == "qwen-mt-flash", "Exact MT model")
        let messages = body["messages"] as? [[String: String]]
        try expect(messages == [["role": "user", "content": fixture]], "Only current exact sentence, no history or prompt")
        try expect(body["translation_options"] as? [String: String] == ["source_lang": "auto", "target_lang": "English"], "Auto to English options")

        let customTransport = StubCloudTransport()
        _ = try await OpenAICompatibleTranslator(configuration: custom, transport: customTransport).translate(fixture)
        let customRequest = customTransport.requests[0]
        try expect(customRequest.url?.absoluteString == "https://translation.example.invalid/v1/chat/completions", "Custom path appends once")
        try expect(customRequest.value(forHTTPHeaderField: "Authorization") == "Bearer custom-synthetic-only", "Custom service receives only its own key")
        let customBody = try dictionary(customRequest)
        try expect(customBody["model"] as? String == custom.model, "Configured model")
        let customMessages = customBody["messages"] as? [[String: String]] ?? []
        try expect(customMessages.count == 2 && customMessages[0]["role"] == "system", "Translation instruction precedes data")
        try expect(customMessages.last == ["role": "user", "content": fixture], "Custom sends only current user data")
        try expect(customBody["translation_options"] == nil && customBody["enable_thinking"] == nil, "No private Qwen params in generic API")
        try expect(customBody["max_tokens"] as? Int == 1_024 && customBody["stream"] as? Bool == false, "Bounded complete response")

        for endpoint in ["http://example.invalid/v1", "https://key@example.invalid/v1", "https://example.invalid/v1?key=x", "https://example.invalid/v1/chat/completions"] {
            let forbidden = CustomTranslationConfiguration(baseURL: endpoint, model: custom.model, apiKey: custom.apiKey)
            let emptyTransport = StubCloudTransport()
            try await expectError(.invalidConfiguration) {
                _ = try await OpenAICompatibleTranslator(configuration: forbidden, transport: emptyTransport).translate(fixture)
            }
            try expect(emptyTransport.requests.isEmpty, "Invalid endpoint never sends key")
        }
    }

    private static func failureTests() async throws {
        let cases: [(Int, QwenTranslationError)] = [
            (401, .invalidAPIKey), (403, .accessDenied), (429, .rateLimited),
            (408, .serviceUnavailable), (500, .serviceUnavailable), (503, .serviceUnavailable),
            (302, .invalidResponse), (400, .invalidResponse)
        ]
        for (status, expected) in cases {
            let transport = StubCloudTransport(status: status, body: "SENSITIVE_SERVER_ECHO_SHOULD_NOT_APPEAR")
            try await expectError(expected) { _ = try await QwenTranslator(apiKey: fixtureKey, transport: transport).translate(fixture) }
            try expect(!String(reflecting: expected).contains("SENSITIVE"), "Do not include server body in error")
        }
        for response in ["not json", #"{"choices":[]}"#,
                         #"{"choices":[{"finish_reason":"stop","message":{"content":"  "}}]}"#,
                         #"{"choices":[{"finish_reason":"length","message":{"content":"truncated text"}}]}"#,
                         String(repeating: "x", count: URLSessionQwenTransport.maximumResponseBytes + 1)] {
            try await expectError(.invalidResponse) {
                _ = try await QwenTranslator(apiKey: fixtureKey, transport: StubCloudTransport(body: response)).translate(fixture)
            }
        }
        let transport = StubCloudTransport()
        try await expectError(.missingAPIKey) { _ = try await QwenTranslator(apiKey: " ", transport: transport).translate(fixture) }
        try await expectError(.invalidAPIKey) { _ = try await QwenTranslator(apiKey: "test\r\nInjected: value", transport: transport).translate(fixture) }
        try await expectError(.invalidResponse) { _ = try await QwenTranslator(apiKey: fixtureKey, transport: transport).translate(String(repeating: "你", count: 401)) }
        try expect(transport.requests.isEmpty, "Invalid input/key rejected before transport")
        transport.handler = { throw URLError(.timedOut) }
        try await expectError(.networkUnavailable) { _ = try await QwenTranslator(apiKey: fixtureKey, transport: transport).translate(fixture) }
    }

    private static func cancellationTests() async throws {
        for ignoresCancellation in [false, true] {
            let transport = StubCloudTransport()
            transport.handler = {
                if ignoresCancellation { try? await Task.sleep(for: .seconds(1)) }
                else { try await Task.sleep(for: .seconds(1)) }
                return QwenTransportResponse(statusCode: 200, body: Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"obsolete"}}]}"#.utf8))
            }
            let task = Task { try await QwenTranslator(apiKey: fixtureKey, transport: transport).translate(fixture) }
            while transport.requests.isEmpty { await Task.yield() }
            task.cancel()
            do { _ = try await task.value; throw CloudTestFailure(description: "Cancelled output must not publish") }
            catch is CancellationError {}
        }
        let cancelledTransport = StubCloudTransport()
        cancelledTransport.handler = { throw URLError(.cancelled) }
        do {
            _ = try await QwenTranslator(apiKey: fixtureKey, transport: cancelledTransport).translate(fixture)
            throw CloudTestFailure(description: "URL cancellation must stay cancellation")
        } catch is CancellationError {}
    }

    private static func routingTests() async throws {
        let settings = CloudTestSettings(.init(provider: .apple, apiKey: fixtureKey, revision: "a", custom: custom))
        let apple = StubHintTranslator()
        let cloud = StubHintTranslator(text: "Cloud result")
        let customProvider = StubHintTranslator(text: "Custom result")
        var cloudCreations = 0
        var customCreations = 0
        var events: [String] = []
        let router = SelectedHintTranslator(apple: apple, settings: { settings.snapshot }, cloudFactory: { key in
            cloudCreations += 1
            precondition(key == fixtureKey)
            return cloud
        }, customFactory: { config in
            customCreations += 1
            precondition(config == custom)
            return customProvider
        }, diagnostics: { events.append($0) })
        try expect(try await router.translate(fixture).text == "Apple result", "Explicit Apple result")
        try expect(cloudCreations == 0 && customCreations == 0, "Apple never instantiates network providers even with saved keys")
        settings.snapshot = .init(provider: .qwen, apiKey: fixtureKey, revision: "b")
        try expect(try await router.translate(fixture).text == "Cloud result", "Explicit Qwen")
        settings.snapshot = .init(provider: .custom, apiKey: fixtureKey, revision: "c", custom: custom)
        try expect(try await router.translate(fixture).text == "Custom result", "Explicit custom")
        try expect(events == ["cloud.success", "cloud.success"], "Diagnostics include no source/key/URL")
        settings.snapshot = .init(provider: .qwen, apiKey: fixtureKey, revision: "d")
        for error in [QwenTranslationError.networkUnavailable, .rateLimited, .serviceUnavailable] {
            let previousCalls = apple.calls.count
            cloud.handler = { throw error }
            try expect(try await router.translate(fixture).text == "Apple result", "Transient cloud failure uses Apple")
            try expect(apple.calls.count == previousCalls + 1, "One Apple fallback")
        }
        let priorAppleCalls = apple.calls.count
        for (cloudError, expected) in [(QwenTranslationError.invalidAPIKey, HintTranslationError.cloudAuthentication),
                                       (.accessDenied, .cloudAccessDenied), (.invalidResponse, .cloudUnavailable)] {
            cloud.handler = { throw cloudError }
            try await expectHintError(expected) { _ = try await router.translate(fixture) }
        }
        try expect(apple.calls.count == priorAppleCalls, "Do not hide key/access/response errors through fallback")
        cloud.handler = { throw QwenTranslationError.networkUnavailable }
        apple.handler = { throw HintTranslationError.needsLanguagePack(sourceLanguageCode: "zh-Hans") }
        try await expectHintError(.cloudUnavailable) { _ = try await router.translate(fixture) }
    }

    private static func staleAndPermissionTests() async throws {
        let settings = CloudTestSettings(.init(provider: .qwen, apiKey: fixtureKey, revision: "before"))
        settings.fullAccess = false
        let apple = StubHintTranslator()
        let cloud = StubHintTranslator()
        var factories = 0
        let router = SelectedHintTranslator(apple: apple, settings: { settings.snapshot }, cloudFactory: { _ in
            factories += 1; return cloud
        }, fullAccess: { settings.fullAccess })
        try await expectHintError(.fullAccessRequired) { _ = try await router.translate(fixture) }
        try expect(factories == 0 && apple.calls.isEmpty, "Permission gate before providers")
        settings.fullAccess = true
        cloud.handler = {
            settings.snapshot = .init(provider: .apple, apiKey: nil, revision: "after")
            return .init(text: "stale", sourceLanguageCode: "zh-Hans")
        }
        try await expectHintError(.settingsChanged) { _ = try await router.translate(fixture) }
        settings.snapshot = .init(provider: .qwen, apiKey: fixtureKey, revision: "next")
        cloud.handler = {
            settings.snapshot = .init(provider: .apple, apiKey: nil, revision: "changed")
            throw QwenTranslationError.networkUnavailable
        }
        try await expectHintError(.settingsChanged) { _ = try await router.translate(fixture) }
        try expect(apple.calls.isEmpty, "Changed provider must not trigger obsolete fallback")
        settings.snapshot = .init(provider: .qwen, apiKey: fixtureKey, revision: "permission")
        cloud.handler = { settings.fullAccess = false; return .init(text: "obsolete", sourceLanguageCode: "zh-Hans") }
        try await expectHintError(.fullAccessRequired) { _ = try await router.translate(fixture) }

        let brokenStoreRouter = SelectedHintTranslator(apple: apple, settings: { throw TranslationSettingsError.unavailable })
        try await expectHintError(.settingsUnavailable) { _ = try await brokenStoreRouter.translate(fixture) }
    }

    private static func customRevisionAndCancellationTests() async throws {
        let settings = CloudTestSettings(.init(provider: .custom, apiKey: nil, revision: "custom-before", custom: custom))
        let apple = StubHintTranslator()
        let cloud = StubHintTranslator()
        let router = SelectedHintTranslator(apple: apple, settings: { settings.snapshot }, customFactory: { _ in cloud })
        cloud.handler = {
            // Even an incorrectly unchanged revision cannot allow a changed URL
            // or key to publish the obsolete provider's result.
            settings.snapshot = .init(provider: .custom, apiKey: nil, revision: "custom-before",
                custom: .init(baseURL: "https://changed.example.invalid/v1", model: custom.model, apiKey: "different-synthetic-key"))
            return .init(text: "obsolete", sourceLanguageCode: "zh-Hans")
        }
        try await expectHintError(.settingsChanged) { _ = try await router.translate(fixture) }
        try expect(apple.calls.isEmpty, "Changing custom destination does not start fallback")

        let transport = StubCloudTransport()
        transport.handler = {
            try await Task.sleep(for: .seconds(2))
            throw QwenTranslationError.networkUnavailable
        }
        let task = Task { try await OpenAICompatibleTranslator(configuration: custom, transport: transport).translate(fixture) }
        while transport.requests.isEmpty { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; throw CloudTestFailure(description: "Cancelled custom request cannot publish") }
        catch is CancellationError {}
        try expect(transport.requests.count == 1, "Custom cancellation does not retry")
    }

    private static func noPaidRetryTests() async throws {
        let apple = StubHintTranslator()
        apple.handler = { throw HintTranslationError.needsLanguagePack(sourceLanguageCode: "zh-Hans") }
        let cloud = StubHintTranslator()
        cloud.handler = { throw QwenTranslationError.networkUnavailable }
        let router = SelectedHintTranslator(apple: apple,
            settings: { .init(provider: .qwen, apiKey: fixtureKey, revision: "test") }, cloudFactory: { _ in cloud })
        let model = LiveHintModel(translator: router, debounceNanoseconds: 0, retryDelaysNanoseconds: [0, 0, 0])
        model.update(before: fixture, after: "")
        for _ in 0..<100 where model.state.status != .error { await Task.yield() }
        try expect(model.state.status == .error, "Cloud plus fallback failure terminates visibly")
        try expect(cloud.calls.count == 1 && apple.calls.count == 1, "No automatic repeat of paid request")
    }
}
