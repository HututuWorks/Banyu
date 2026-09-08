import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Deliberately contains no server response body or request details. Neither the
/// API key nor typed text should reach diagnostics through an Error description.
enum QwenTranslationError: Error, Equatable, Sendable {
    case missingAPIKey
    case invalidConfiguration
    case invalidAPIKey
    case accessDenied
    case rateLimited
    case serviceUnavailable
    case invalidResponse
    case networkUnavailable

    var allowsAppleFallback: Bool {
        switch self {
        case .rateLimited, .serviceUnavailable, .networkUnavailable: return true
        default: return false
        }
    }
}

struct QwenTransportResponse: Sendable {
    let statusCode: Int
    let body: Data
}

@MainActor
protocol QwenTransport {
    func send(_ request: URLRequest) async throws -> QwenTransportResponse
}

/// A redirect must never forward the Authorization header to a second endpoint.
private final class QwenSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class URLSessionQwenTransport: QwenTransport {
    static let maximumResponseBytes = 32_768
    static let timeout: TimeInterval = 3

    func send(_ request: URLRequest) async throws -> QwenTransportResponse {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: QwenSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        // AsyncBytes lets us stop at the bound instead of first buffering an
        // arbitrarily large or chunked server response inside the keyboard.
        let (bytes, response) = try await session.bytes(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw QwenTranslationError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            return QwenTransportResponse(statusCode: response.statusCode, body: Data())
        }
        guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
            throw QwenTranslationError.invalidResponse
        }
        var body = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard body.count < Self.maximumResponseBytes else {
                throw QwenTranslationError.invalidResponse
            }
            body.append(byte)
        }
        try Task.checkCancellation()
        return QwenTransportResponse(statusCode: response.statusCode, body: body)
    }
}

@MainActor
final class QwenTranslator: HintTranslating {
    static let endpoint = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
    static let model = "qwen-mt-flash"
    private let apiKey: String
    private let transport: any QwenTransport

    init(apiKey: String, transport: any QwenTransport = URLSessionQwenTransport()) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
    }

    func translate(_ source: String) async throws -> HintTranslationResult {
        var request = try CloudTranslationRequest.make(endpoint: Self.endpoint, apiKey: apiKey, source: source)
        request.httpBody = try JSONEncoder().encode(RequestBody(
            model: Self.model, messages: [.init(role: "user", content: source)],
            translation_options: .init(source_lang: "auto", target_lang: "English")))
        return try await CloudTranslationRequest.perform(request, source: source, transport: transport)
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
        let translation_options: TranslationOptions
        struct Message: Encodable { let role: String; let content: String }
        struct TranslationOptions: Encodable { let source_lang: String; let target_lang: String }
    }
}

/// Common bounded JSON transport. Each provider builds only its documented body.
@MainActor
enum CloudTranslationRequest {
    static func make(endpoint: URL, apiKey: String, source: String) throws -> URLRequest {
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw QwenTranslationError.missingAPIKey }
        guard apiKey.utf8.count <= 4_096,
              apiKey.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw QwenTranslationError.invalidAPIKey
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.count <= HintContextExtractor.maximumCharacters else {
            throw QwenTranslationError.invalidResponse
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: URLSessionQwenTransport.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func perform(_ request: URLRequest, source: String,
                        transport: any QwenTransport) async throws -> HintTranslationResult {
        try Task.checkCancellation()
        let response: QwenTransportResponse
        do {
            response = try await transport.send(request)
            try Task.checkCancellation()
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            if let error = error as? QwenTranslationError { throw error }
            if let error = error as? URLError {
                if error.code == .cancelled { throw CancellationError() }
                throw QwenTranslationError.networkUnavailable
            }
            throw QwenTranslationError.serviceUnavailable
        }
        switch response.statusCode {
        case 200..<300: break
        case 401: throw QwenTranslationError.invalidAPIKey
        case 403: throw QwenTranslationError.accessDenied
        case 429: throw QwenTranslationError.rateLimited
        case 408, 500...599: throw QwenTranslationError.serviceUnavailable
        default: throw QwenTranslationError.invalidResponse
        }
        guard response.body.count <= URLSessionQwenTransport.maximumResponseBytes,
              let decoded = try? JSONDecoder().decode(ResponseBody.self, from: response.body),
              let choice = decoded.choices.first,
              choice.finish_reason == "stop",
              let output = choice.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty, output.count <= 4_096 else {
            throw QwenTranslationError.invalidResponse
        }
        try Task.checkCancellation()
        return HintTranslationResult(text: output, sourceLanguageCode: Self.sourceLanguageCode(source))
    }

    private static func sourceLanguageCode(_ source: String) -> String {
        #if canImport(NaturalLanguage)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(source)
        return recognizer.dominantLanguage?.rawValue ?? "und"
        #else
        return "und"
        #endif
    }

    private struct ResponseBody: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let finish_reason: String?
            let message: Message
        }
        struct Message: Decodable { let content: String? }
    }
}
