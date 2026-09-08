import Foundation

// The lifecycle harness exercises the real controller, hint model and native
// views. Platform services are inert: no dictionary, Keychain or API access.
@MainActor
final class AppleInstalledTranslator: HintTranslating {
    func translate(_ source: String) async throws -> HintTranslationResult {
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return HintTranslationResult(text: "Test", sourceLanguageCode: "zh-Hans")
    }
}
@MainActor
final class SelectedHintTranslator: HintTranslating {
    let apple: any HintTranslating
    init(apple: any HintTranslating, fullAccess: @escaping () -> Bool,
         diagnostics: @escaping (String) -> Void) { self.apple = apple }
    func translate(_ source: String) async throws -> HintTranslationResult { try await apple.translate(source) }
}
@MainActor
enum HintDiagnostics {
    static func record(stage: String, language: String = "", details: [String: String] = [:]) {}
}
enum TranslationProvider { case apple, qwen }
struct TranslationSettingsSnapshot: Equatable { let provider: TranslationProvider }
@MainActor
final class TranslationSettingsStore {
    static let shared = TranslationSettingsStore()
    func load() throws -> TranslationSettingsSnapshot { .init(provider: .apple) }
}
@MainActor
protocol SentenceAnalyzing {
    func analyze(_ english: String, settings: TranslationSettingsSnapshot) async throws -> SentenceAnalysis
}
@MainActor
final class SentenceAnalyzer: SentenceAnalyzing {
    func analyze(_ english: String, settings: TranslationSettingsSnapshot) async throws -> SentenceAnalysis {
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return SentenceAnalysis(kind: "sentence", insights: [], expressions: [])
    }
}
struct PinyinResult {
    var candidates = [String]()
    var fixedText = ""
    var remainingPinyin = ""
    var isComplete = false
    var commitText = ""
}
struct PinyinSpelling { let text: String; let score: Double }
struct PinyinProbeCandidate { let text: String; let score: Double; let consumedPinyinLength: Int }
struct PinyinProbeResult { var candidates = [PinyinProbeCandidate](); var decodedLength = 0 }
@MainActor
final class PinyinDecoder {
    init?(dictionaryPath: String, userDictionaryPath: String) { return nil }
    func reset() {}
    func update(pinyin: String) -> PinyinResult { PinyinResult() }
    func selectCandidate(at index: Int) -> PinyinResult { PinyinResult() }
    func spellingTable() -> [PinyinSpelling] { [] }
    func probe(pinyin: String, candidateLimit: Int) -> PinyinProbeResult { PinyinProbeResult() }
}
