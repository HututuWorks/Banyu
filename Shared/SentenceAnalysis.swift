import Foundation

/// The original English is rendered once by the reading surface. Learning notes
/// reference exact source excerpts without rebuilding or fully parsing the text.
struct SentenceAnalysis: Codable, Equatable, Sendable {
    struct Insight: Codable, Equatable, Sendable {
        let source: String
        let title: String
        let explanation: String
    }

    struct Expression: Codable, Equatable, Sendable {
        let text: String
        let source: String
        let meaning: String
        let usage: String?

        init(text: String, source: String, meaning: String, usage: String? = nil) {
            self.text = text; self.source = source; self.meaning = meaning; self.usage = usage
        }
    }

    let kind: String
    let overview: String?
    let insights: [Insight]
    let expressions: [Expression]

    init(kind: String, overview: String? = nil, insights: [Insight], expressions: [Expression]) {
        self.kind = kind; self.overview = overview
        self.insights = insights; self.expressions = expressions
    }

    /// Validation proves bounded shape and source provenance, not linguistic
    /// truth. Never invent a replacement lesson when a model response is invalid.
    func validated(for english: String) throws -> Self {
        guard ["word", "phrase", "sentence"].contains(kind),
              insights.count <= 3, expressions.count <= 3,
              Self.validOptional(overview, maximum: 160),
              kind == "sentence" || overview != nil else {
            throw SentenceAnalysisError.invalidResponse
        }
        let words = Self.lexicalRanges(in: english)
        guard !words.isEmpty else { throw SentenceAnalysisError.invalidResponse }
        var cleanedInsights: [Insight] = []
        for insight in insights {
            guard Self.validSource(insight.source, in: english, words: words),
                  Self.validText(insight.title, maximum: 60),
                  Self.validText(insight.explanation, maximum: 180, requiresChinese: true) else {
                throw SentenceAnalysisError.invalidResponse
            }
            // Only exact duplicates are removed. The same excerpt can support
            // distinct notes, and similar wording does not imply the same lesson.
            if !cleanedInsights.contains(insight), insight.explanation != overview {
                cleanedInsights.append(insight)
            }
        }
        var cleanedExpressions: [Expression] = []
        for expression in expressions {
            guard Self.validText(expression.text, maximum: 120),
                  Self.validSource(expression.source, in: english, words: words),
                  Self.validText(expression.meaning, maximum: 100, requiresChinese: true),
                  Self.validOptional(expression.usage, maximum: 140) else {
                throw SentenceAnalysisError.invalidResponse
            }
            let cleaned = Expression(text: expression.text, source: expression.source,
                                     meaning: expression.meaning,
                                     usage: expression.usage == expression.meaning ? nil : expression.usage)
            if kind != "sentence", cleaned.meaning == overview, cleaned.usage == nil { continue }
            if !cleanedExpressions.contains(cleaned) { cleanedExpressions.append(cleaned) }
        }
        return Self(kind: kind, overview: overview, insights: cleanedInsights, expressions: cleanedExpressions)
    }

    private static func validSource(_ source: String, in english: String,
                                    words: [Range<String.Index>]) -> Bool {
        validText(source, maximum: min(240, english.count), sourceText: true)
            && hasExactWholeWordOccurrence(source, in: english, words: words)
    }

    private static func hasExactWholeWordOccurrence(_ snippet: String, in english: String,
                                                    words: [Range<String.Index>]) -> Bool {
        var cursor = english.startIndex
        while cursor < english.endIndex,
              let range = english.range(of: snippet, options: .literal, range: cursor..<english.endIndex) {
            if isWholeLexicalRange(range, in: english, words: words) { return true }
            cursor = range.upperBound
        }
        return false
    }

    private static func isWholeLexicalRange(_ range: Range<String.Index>, in english: String,
                                            words: [Range<String.Index>]) -> Bool {
        english[range].unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
            && !words.contains {
                ($0.lowerBound < range.lowerBound && range.lowerBound < $0.upperBound) ||
                ($0.lowerBound < range.upperBound && range.upperBound < $0.upperBound)
            }
    }

    private static func lexicalRanges(in english: String) -> [Range<String.Index>] {
        let pattern = #"[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: english, range: NSRange(english.startIndex..., in: english))
            .compactMap { Range($0.range, in: english) }
    }

    private static func validOptional(_ value: String?, maximum: Int) -> Bool {
        value.map { validText($0, maximum: maximum, requiresChinese: true) } ?? true
    }

    private static func validText(_ value: String, maximum: Int, requiresChinese: Bool = false,
                                  sourceText: Bool = false) -> Bool {
        guard !value.isEmpty, value.count <= maximum,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) &&
                  !(sourceText && [9, 10, 13].contains($0.value))
              }),
              !value.unicodeScalars.contains(where: {
                  (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
              }) else { return false }
        if !sourceText {
            guard !value.contains("`"), !value.contains("**"), !value.contains("__"),
                  !value.contains("]("), !value.hasPrefix("#"), !value.hasPrefix("- "),
                  !value.hasPrefix("> ") else { return false }
        }
        return !requiresChinese || value.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        }
    }
}

/// Only fixed, user-readable messages leave the service. Never surface raw server
/// bodies, URLs, credentials, request text or underlying localizedDescription.
enum SentenceAnalysisError: Error, Equatable, Sendable, LocalizedError {
    case analysisUnavailable
    case invalidInput
    case missingAPIKey
    case invalidConfiguration
    case invalidAPIKey
    case accessDenied
    case rateLimited
    case serviceUnavailable
    case invalidResponse
    case networkUnavailable
    case timedOut

    var message: String {
        switch self {
        case .analysisUnavailable: return "苹果翻译暂不支持分析，可在主 App 选择千问或兼容接口。"
        case .invalidInput: return "这段英文暂时无法分析，请换一句较短的表达。"
        case .missingAPIKey, .invalidAPIKey: return "请在主 App 检查翻译服务的 API Key。"
        case .invalidConfiguration: return "请在主 App 检查接口和模型配置。"
        case .accessDenied: return "当前服务没有分析模型的访问权限。"
        case .rateLimited: return "服务繁忙，请稍后再试。"
        case .serviceUnavailable: return "暂时无法分析，请稍后再试。"
        case .invalidResponse: return "暂时未获得完整分析，请稍后再试。"
        case .networkUnavailable: return "网络连接不可用，请稍后再试。"
        case .timedOut: return "分析超时，请稍后再试。"
        }
    }

    var errorDescription: String? { message }
}
