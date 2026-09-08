import Foundation

@MainActor
protocol SpeechSynthesizing {
    func synthesize(_ text: String) async throws -> Data
}

@MainActor
protocol SpeechStreamingSynthesizing: SpeechSynthesizing {
    /// Chunks are signed little-endian PCM, 24 kHz, mono, 16-bit. Completion
    /// returns the entire WAV for replay; incomplete streams never enter cache.
    func synthesizeStreaming(_ text: String,
                             onPCM: @escaping @MainActor @Sendable (Data) async throws -> Void) async throws -> Data
}

/// Errors intentionally contain no server response, signed URL, API key or text.
enum SpeechError: Error, Equatable, Sendable {
    case missingAPIKey
    case invalidAPIKey
    case accessDenied
    case rateLimited
    case textTooLong
    case invalidResponse
    case networkUnavailable
    case serviceUnavailable

    var userMessage: String {
        switch self {
        case .missingAPIKey: "请先在主 App 配置千问。"
        case .invalidAPIKey: "千问 API Key 无效，请在主 App 检查。"
        case .accessDenied: "暂时无法使用千问语音，请检查模型权限与账户余额。"
        case .rateLimited: "语音请求较多，请稍后再试。"
        case .textTooLong: "这段英文较长，暂时支持 600 字符以内的朗读。"
        case .invalidResponse: "暂时无法读取语音，请稍后再试。"
        case .networkUnavailable: "语音连接失败，请检查网络后重试。"
        case .serviceUnavailable: "千问语音暂时不可用，请稍后再试。"
        }
    }
}

struct QwenSpeechResponse: Sendable {
    let statusCode: Int
    let body: Data
}

@MainActor
protocol QwenSpeechTransport {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> QwenSpeechResponse
}

final class QwenSpeechSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // The authenticated generation request and unauthenticated signed audio
        // download both remain on their validated endpoint; never follow a redirect.
        completionHandler(nil)
    }
}

@MainActor
final class URLSessionQwenSpeechTransport: QwenSpeechTransport {
    func send(_ request: URLRequest, maximumBytes: Int) async throws -> QwenSpeechResponse {
        try await Self.load(request, maximumBytes: maximumBytes)
    }

    // A WAV can contain millions of bytes. Stream and bound it off the main actor
    // so download processing does not compete with keyboard input and layout.
    private nonisolated static func load(_ request: URLRequest,
                                        maximumBytes: Int) async throws -> QwenSpeechResponse {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration,
                                 delegate: QwenSpeechSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw SpeechError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            return QwenSpeechResponse(statusCode: response.statusCode, body: Data())
        }
        guard maximumBytes > 0, response.expectedContentLength <= Int64(maximumBytes) else {
            throw SpeechError.invalidResponse
        }
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < maximumBytes else { throw SpeechError.invalidResponse }
            body.append(byte)
        }
        try Task.checkCancellation()
        return QwenSpeechResponse(statusCode: response.statusCode, body: body)
    }
}

/// Beijing Qwen TTS uses the existing Beijing API key, not the translation API
/// schema. Each explicit request generates one WAV; replay is owned by the player.
@MainActor
final class QwenSpeechSynthesizer: SpeechStreamingSynthesizing {
    static let endpoint = URL(string: "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")!
    static let model = "qwen3-tts-flash"
    static let voice = "Cherry"
    static let maximumCharacters = 600
    static let maximumJSONBytes = 32_768
    static let maximumAudioBytes = 4 * 1_024 * 1_024
    static let generationTimeout: TimeInterval = 20
    static let downloadTimeout: TimeInterval = 15

    private let apiKey: String
    private let transport: any QwenSpeechTransport
    private let streamTransport: any QwenSpeechStreamTransport

    init(apiKey: String, transport: any QwenSpeechTransport = URLSessionQwenSpeechTransport(),
         streamTransport: any QwenSpeechStreamTransport = URLSessionQwenSpeechStreamTransport()) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
        self.streamTransport = streamTransport
    }

    private func makeRequest(_ text: String, streaming: Bool) throws -> URLRequest {
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw SpeechError.missingAPIKey }
        guard apiKey.utf8.count <= 4_096,
              apiKey.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw SpeechError.invalidAPIKey
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechError.invalidResponse
        }
        // Do not silently truncate the sentence or fan out into several billable calls.
        guard text.unicodeScalars.count <= Self.maximumCharacters else { throw SpeechError.textTooLong }
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.generationTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        if streaming { request.setValue("enable", forHTTPHeaderField: "X-DashScope-SSE") }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: Self.model, input: .init(text: text, voice: Self.voice, language_type: "English")))
        return request
    }

    func synthesize(_ text: String) async throws -> Data {
        let request = try makeRequest(text, streaming: false)
        let generation = try await perform(request, maximumBytes: Self.maximumJSONBytes, authenticatesAPIKey: true)
        guard let result = try? JSONDecoder().decode(ResponseBody.self, from: generation),
              result.output.finish_reason == "stop",
              let audioURL = Self.validatedAudioURL(result.output.audio.url) else {
            throw SpeechError.invalidResponse
        }
        try Task.checkCancellation()
        // A fresh request deliberately carries neither the API key nor cookies.
        var download = URLRequest(url: audioURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                  timeoutInterval: Self.downloadTimeout)
        download.httpMethod = "GET"
        download.setValue("audio/wav, audio/x-wav, application/octet-stream", forHTTPHeaderField: "Accept")
        let audio = try await perform(download, maximumBytes: Self.maximumAudioBytes, authenticatesAPIKey: false)
        // Qwen3-TTS's documented non-streaming result is WAV. Catch an HTML/JSON
        // error body here; the audio player still validates the complete container.
        guard audio.count >= 12, audio.starts(with: Data("RIFF".utf8)),
              audio[8..<12] == Data("WAVE".utf8) else { throw SpeechError.invalidResponse }
        try Task.checkCancellation()
        return audio
    }

    func synthesizeStreaming(_ text: String,
                             onPCM: @escaping @MainActor @Sendable (Data) async throws -> Void) async throws -> Data {
        let request = try makeRequest(text, streaming: true)
        let decoder = QwenSpeechStreamDecoder(onPCM: onPCM)
        do {
            try await streamTransport.stream(request, maximumBytes: QwenSpeechStreamLimits.maximumWireBytes) { event in
                try await decoder.receive(event)
            }
            try Task.checkCancellation()
            return try await decoder.finish()
        } catch {
            try Task.checkCancellation()
            if let delivery = error as? QwenSpeechPCMDeliveryFailure { throw delivery.underlying }
            if error is CancellationError { throw CancellationError() }
            if let error = error as? SpeechError { throw error }
            if let error = error as? URLError {
                if error.code == .cancelled { throw CancellationError() }
                throw SpeechError.networkUnavailable
            }
            throw SpeechError.serviceUnavailable
        }
    }

    private func perform(_ request: URLRequest, maximumBytes: Int,
                         authenticatesAPIKey: Bool) async throws -> Data {
        try Task.checkCancellation()
        let response: QwenSpeechResponse
        do {
            response = try await transport.send(request, maximumBytes: maximumBytes)
            try Task.checkCancellation()
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            if let error = error as? SpeechError { throw error }
            if let error = error as? URLError {
                if error.code == .cancelled { throw CancellationError() }
                throw SpeechError.networkUnavailable
            }
            throw SpeechError.serviceUnavailable
        }
        switch response.statusCode {
        case 200..<300: break
        case 401: throw authenticatesAPIKey ? SpeechError.invalidAPIKey : SpeechError.invalidResponse
        case 402, 403: throw authenticatesAPIKey ? SpeechError.accessDenied : SpeechError.invalidResponse
        case 429: throw SpeechError.rateLimited
        case 408, 500...599: throw SpeechError.serviceUnavailable
        default: throw SpeechError.invalidResponse
        }
        guard !response.body.isEmpty, response.body.count <= maximumBytes else {
            throw SpeechError.invalidResponse
        }
        return response.body
    }

    private static func validatedAudioURL(_ string: String) -> URL? {
        guard string.utf8.count <= 8_192,
              string.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }),
              var components = URLComponents(string: string),
              components.user == nil, components.password == nil, components.fragment == nil,
              let host = components.host?.lowercased(),
              ["dashscope-result-bj.oss-cn-beijing.aliyuncs.com",
               "dashscope-result-wlcb.oss-cn-wulanchabu.aliyuncs.com"].contains(host),
              !components.path.isEmpty, components.path != "/" else { return nil }
        switch components.scheme?.lowercased() {
        case "https":
            guard components.port == nil || components.port == 443 else { return nil }
        case "http":
            guard components.port == nil || components.port == 80 else { return nil }
            // The official response examples use HTTP signed OSS URLs. OSS
            // signatures cover the resource, not the scheme: upgrade before use.
            components.scheme = "https"
            components.port = nil
        default: return nil
        }
        return components.url
    }

    private struct RequestBody: Encodable {
        let model: String
        let input: Input
        struct Input: Encodable { let text: String; let voice: String; let language_type: String }
    }

    private struct ResponseBody: Decodable {
        let output: Output
        struct Output: Decodable { let finish_reason: String; let audio: Audio }
        struct Audio: Decodable { let url: String }
    }
}


/// The transport delivers response metadata before bytes, serially. Awaiting
/// each callback bounds buffering and lets playback backpressure reach the read.
enum QwenSpeechStreamEvent: Sendable {
    case response(statusCode: Int, contentType: String?)
    case bytes(Data)
}

protocol QwenSpeechStreamTransport: Sendable {
    func stream(_ request: URLRequest, maximumBytes: Int,
                receive: @escaping @Sendable (QwenSpeechStreamEvent) async throws -> Void) async throws
}

private enum QwenSpeechStreamLimits {
    static let maximumWireBytes = 8 * 1_024 * 1_024
    static let maximumEventBytes = 1_024 * 1_024
    static let maximumPCMBytes = 4 * 1_024 * 1_024 - 44
}

struct URLSessionQwenSpeechStreamTransport: QwenSpeechStreamTransport {
    static let resourceTimeout: TimeInterval = 120

    static func configuration(for request: URLRequest) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        // A consumer intentionally backpressures network reads while queued
        // audio plays. The 4 MiB PCM budget can last about 87 seconds; preserve
        // the 20-second idle timeout without killing a healthy long utterance.
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        return configuration
    }

    func stream(_ request: URLRequest, maximumBytes: Int,
                receive: @escaping @Sendable (QwenSpeechStreamEvent) async throws -> Void) async throws {
        try Task.checkCancellation()
        let session = URLSession(configuration: Self.configuration(for: request),
                                 delegate: QwenSpeechSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw SpeechError.invalidResponse }
        try await receive(.response(statusCode: response.statusCode,
                                    contentType: response.value(forHTTPHeaderField: "Content-Type")))
        guard maximumBytes > 0, response.expectedContentLength <= Int64(maximumBytes) else {
            throw SpeechError.invalidResponse
        }
        var count = 0
        var pending = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard count < maximumBytes else { throw SpeechError.invalidResponse }
            count += 1
            pending.append(byte)
            // Newlines deliver each SSE event immediately, even when shorter
            // than a network buffer. Long lines stay bounded during transport.
            if byte == 10 || byte == 13 || pending.count == 4_096 {
                try await receive(.bytes(pending))
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !pending.isEmpty { try await receive(.bytes(pending)) }
        try Task.checkCancellation()
    }
}

private struct QwenSpeechPCMDeliveryFailure: Error {
    let underlying: any Error
}

/// Parsing and Base64 decoding stay on this actor rather than the UI actor.
/// Neither server messages nor final signed URLs escape into errors or logs.
private actor QwenSpeechStreamDecoder {
    private let onPCM: @MainActor @Sendable (Data) async throws -> Void
    private var receivedResponse = false
    private var wireBytes = 0
    private var line = Data()
    private var eventData = Data()
    private var previousWasCR = false
    private var firstLine = true
    private var sawStop = false
    private var sawDone = false
    private var pcm = Data()
    private var trailingPCMByte: UInt8?

    init(onPCM: @escaping @MainActor @Sendable (Data) async throws -> Void) { self.onPCM = onPCM }

    func receive(_ event: QwenSpeechStreamEvent) async throws {
        try Task.checkCancellation()
        switch event {
        case let .response(statusCode, contentType):
            guard !receivedResponse else { throw SpeechError.invalidResponse }
            try Self.validateStatus(statusCode)
            guard contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "text/event-stream" else { throw SpeechError.invalidResponse }
            receivedResponse = true
        case let .bytes(bytes):
            guard receivedResponse, bytes.count <= QwenSpeechStreamLimits.maximumWireBytes - wireBytes else {
                throw SpeechError.invalidResponse
            }
            wireBytes += bytes.count
            for byte in bytes {
                try Task.checkCancellation()
                if byte == 10, previousWasCR { previousWasCR = false; continue }
                if byte == 10 || byte == 13 {
                    previousWasCR = byte == 13
                    try await consumeLine()
                } else {
                    previousWasCR = false
                    guard line.count < QwenSpeechStreamLimits.maximumEventBytes else { throw SpeechError.invalidResponse }
                    line.append(byte)
                }
            }
        }
    }

    func finish() async throws -> Data {
        try Task.checkCancellation()
        if !line.isEmpty { try await consumeLine() }
        if !eventData.isEmpty { try await consumeEvent() }
        guard receivedResponse, sawStop, !pcm.isEmpty, trailingPCMByte == nil else { throw SpeechError.invalidResponse }
        var wave = Data("RIFF".utf8)
        Self.appendLittleEndian(UInt32(pcm.count + 36), to: &wave)
        wave.append(Data("WAVEfmt ".utf8))
        Self.appendLittleEndian(UInt32(16), to: &wave)
        Self.appendLittleEndian(UInt16(1), to: &wave) // PCM
        Self.appendLittleEndian(UInt16(1), to: &wave) // mono
        Self.appendLittleEndian(UInt32(24_000), to: &wave)
        Self.appendLittleEndian(UInt32(48_000), to: &wave)
        Self.appendLittleEndian(UInt16(2), to: &wave)
        Self.appendLittleEndian(UInt16(16), to: &wave)
        wave.append(Data("data".utf8))
        Self.appendLittleEndian(UInt32(pcm.count), to: &wave)
        wave.append(pcm)
        return wave
    }

    private func consumeLine() async throws {
        var current = line
        line = Data()
        if firstLine {
            firstLine = false
            if current.starts(with: [0xEF, 0xBB, 0xBF]) { current = Data(current.dropFirst(3)) }
        }
        if current.isEmpty { try await consumeEvent(); return }
        guard !current.starts(with: [58]) else { return } // SSE comment/keepalive
        let separator = current.firstIndex(of: 58)
        let field = separator.map { current[..<$0] } ?? current[...]
        guard field.elementsEqual("data".utf8) else { return }
        var value = separator.map { Data(current[current.index(after: $0)...]) } ?? Data()
        if value.first == 32 { value.removeFirst() }
        let extra = value.count + (eventData.isEmpty ? 0 : 1)
        guard extra <= QwenSpeechStreamLimits.maximumEventBytes - eventData.count else { throw SpeechError.invalidResponse }
        if !eventData.isEmpty { eventData.append(10) }
        eventData.append(value)
    }

    private func consumeEvent() async throws {
        guard !eventData.isEmpty else { return }
        let data = eventData
        eventData.removeAll(keepingCapacity: true)
        if data.elementsEqual("[DONE]".utf8) {
            guard sawStop, !sawDone else { throw SpeechError.invalidResponse }
            sawDone = true
            return
        }
        guard !sawStop, !sawDone,
              let event = try? JSONDecoder().decode(Envelope.self, from: data) else { throw SpeechError.invalidResponse }
        if let status = event.status_code { try Self.validateStatus(status) }
        if let code = event.code, !code.isEmpty { throw Self.error(for: code) }
        guard let output = event.output, let audio = output.audio,
              output.finish_reason == nil || ["", "null", "stop"].contains(output.finish_reason!) else {
            throw SpeechError.invalidResponse
        }
        if let encoded = audio.data, !encoded.isEmpty {
            guard let decoded = Data(base64Encoded: encoded), !decoded.isEmpty,
                  decoded.count <= QwenSpeechStreamLimits.maximumPCMBytes - pcm.count else {
                throw SpeechError.invalidResponse
            }
            pcm.append(decoded)
            var aligned = Data()
            if let trailingPCMByte { aligned.append(trailingPCMByte) }
            aligned.append(decoded)
            trailingPCMByte = aligned.count.isMultiple(of: 2) ? nil : aligned.removeLast()
            // Bounded delivery lets playback publish its first queued audio
            // promptly even if the service puts many seconds in one SSE event.
            for offset in stride(from: 0, to: aligned.count, by: 8_192) {
                try Task.checkCancellation()
                let packet = Data(aligned[offset..<min(offset + 8_192, aligned.count)])
                do { try await onPCM(packet) }
                catch { throw QwenSpeechPCMDeliveryFailure(underlying: error) }
                try Task.checkCancellation()
            }
        }
        if output.finish_reason == "stop" { sawStop = true }
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ number: T, to data: inout Data) {
        var value = number.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func validateStatus(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401: throw SpeechError.invalidAPIKey
        case 402, 403: throw SpeechError.accessDenied
        case 429: throw SpeechError.rateLimited
        case 408, 500...599: throw SpeechError.serviceUnavailable
        default: throw SpeechError.invalidResponse
        }
    }

    private static func error(for code: String) -> SpeechError {
        switch code {
        case "InvalidApiKey", "InvalidAPIKey": .invalidAPIKey
        case "AccessDenied", "Arrearage", "AccessDenied.Unpurchased": .accessDenied
        case "Throttling", "Throttling.RateQuota", "Throttling.AllocationQuota": .rateLimited
        default: .serviceUnavailable
        }
    }

    private struct Envelope: Decodable {
        let status_code: Int?
        let code: String?
        let output: Output?
        struct Output: Decodable { let finish_reason: String?; let audio: Audio? }
        struct Audio: Decodable { let data: String? }
    }
}
