#if canImport(Translation) && canImport(NaturalLanguage)
import Foundation
import NaturalLanguage
import Translation
#if DEBUG
import OSLog
#endif

/// Shared Han characters can be classified as either Chinese script. An alternate
/// model is safe only when its script conversion leaves the entire input unchanged.
enum ChineseScriptCompatibility {
    static func alternateModelLanguage(for source: String, detectedLanguageCode: String) -> String? {
        let alternate: String
        let transform: StringTransform
        switch detectedLanguageCode {
        case "zh-Hant":
            alternate = "zh-Hans"
            transform = StringTransform("Traditional-Simplified")
        case "zh-Hans":
            alternate = "zh-Hant"
            transform = StringTransform("Simplified-Traditional")
        default:
            return nil
        }
        // Kana is evidence of Japanese/mixed text, even if recognition chose Chinese.
        guard !source.unicodeScalars.contains(where: {
            (0x3040...0x30FF).contains($0.value) || (0x31F0...0x31FF).contains($0.value)
                || (0xFF66...0xFF9F).contains($0.value) || (0x1B000...0x1B16F).contains($0.value)
        }), source.applyingTransform(transform, reverse: false) == source else { return nil }
        return alternate
    }
}

/// Availability can lag behind a cold service. This plan only chooses installed-only
/// probes; a successful translation, never a supported status, proves a model usable.
@available(iOS 26.0, macOS 26.0, *)
enum InstalledTranslationPlan {
    static func languageCodes(source: String, detectedCode: String,
                              status: LanguageAvailability.Status,
                              alternateStatus: LanguageAvailability.Status?) -> [String] {
        guard status == .supported,
              let alternate = ChineseScriptCompatibility.alternateModelLanguage(for: source, detectedLanguageCode: detectedCode)
        else { return [detectedCode] }
        if alternateStatus == .installed { return [alternate] }
        // Only try the unchanged-script alternate if the original installed-only
        // session reports notInstalled. Other service failures must propagate.
        if alternateStatus == .supported { return [detectedCode, alternate] }
        return [detectedCode]
    }
}

/// Uses only models already installed by the containing App. No download UI in the keyboard.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
final class AppleInstalledTranslator: HintTranslating {
    @concurrent
    nonisolated private static func recognizedLanguageCode(_ source: String) async throws -> String? {
        try Task.checkCancellation()
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(source)
        try Task.checkCancellation()
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue
    }

    nonisolated private static func supportedLanguageCount() async -> Int {
        let probe: LanguageAvailability
        if #available(iOS 26.4, macOS 26.4, *) {
            probe = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            probe = LanguageAvailability()
        }
        return await probe.supportedLanguages.count
    }

    func translate(_ source: String) async throws -> HintTranslationResult {
        try Task.checkCancellation()
        guard let detectedCode = try await Self.recognizedLanguageCode(source) else {
            throw HintTranslationError.unableToIdentifyLanguage
        }
        let code = detectedCode
        HintDiagnostics.record(stage: "language", language: code)
        // English input already supplies the desired hint; never invoke a same-language session.
        if code == "en" {
            return HintTranslationResult(text: source, sourceLanguageCode: code)
        }

        let sourceLanguage = Locale.Language(identifier: code)
        let targetLanguage = Locale.Language(identifier: "en")
        let availability: LanguageAvailability
        if #available(iOS 26.4, macOS 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: .lowLatency)
        } else {
            availability = LanguageAvailability()
        }
        let status = await availability.status(from: sourceLanguage, to: targetLanguage)
        HintDiagnostics.record(stage: "availability", language: code,
                               details: ["status": String(describing: status)])
        var alternateStatus: LanguageAvailability.Status?
        if case .supported = status,
           let alternate = ChineseScriptCompatibility.alternateModelLanguage(for: source, detectedLanguageCode: code) {
            try Task.checkCancellation()
            let alternateLanguage = Locale.Language(identifier: alternate)
            let probedStatus = await availability.status(from: alternateLanguage, to: targetLanguage)
            alternateStatus = probedStatus
            HintDiagnostics.record(stage: "availability.sameScriptText", language: alternate,
                                   details: ["detectedLanguage": code, "status": String(describing: probedStatus)])

        }
        switch status {
        case .installed, .supported:
            // installedSource never requests downloads. A supported status alone
            // is insufficient evidence of a missing pack after the service idles.
            break
        case .unsupported:
            let supportedCount = await Self.supportedLanguageCount()
            let fixedChineseStatus = await availability.status(from: .init(identifier: "zh-Hans"), to: targetLanguage)
            HintDiagnostics.record(stage: "availability.unsupported", language: code,
                                   details: ["supportedCount": String(supportedCount),
                                             "fixedChineseStatus": String(describing: fixedChineseStatus)])
            // A missing system service can make the availability probe inconclusive.
            // An installed-only session cannot download models; let it produce a
            // concrete error before claiming that a supported language is unsupported.
            if supportedCount > 0 { throw HintTranslationError.unsupportedLanguage }
        @unknown default: throw HintTranslationError.unavailable
        }
        try Task.checkCancellation()

        let languages = InstalledTranslationPlan.languageCodes(source: source, detectedCode: code,
                                                               status: status, alternateStatus: alternateStatus)
        var missingPack: HintTranslationError?
        for languageCode in languages {
            try Task.checkCancellation()
            do {
                return try await translateInstalled(source, code: languageCode, status: status)
            } catch let error as HintTranslationError {
                try Task.checkCancellation()
                guard case .needsLanguagePack = error else { throw error }
                if missingPack == nil { missingPack = error }
            }
        }
        throw missingPack ?? HintTranslationError.unavailable
    }

    private func translateInstalled(_ source: String, code: String,
                                    status: LanguageAvailability.Status) async throws -> HintTranslationResult {
        let sourceLanguage = Locale.Language(identifier: code)
        let targetLanguage = Locale.Language(identifier: "en")
        HintDiagnostics.record(stage: "translation.installedProbe", language: code)
        let session: TranslationSession
        if #available(iOS 26.4, macOS 26.4, *) {
            session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage,
                                         preferredStrategy: .lowLatency)
        } else {
            session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        }
        // Keep a session local to this request. TranslationSession is not Sendable;
        // do not share it with a cancellation callback on another executor.
        // The model cancels the task and independently rejects obsolete results.
        defer { session.cancel() }
        do {
            let response = try await session.translate(source)
            try Task.checkCancellation()
            HintDiagnostics.record(stage: "translation.success", language: code)
            return HintTranslationResult(text: response.targetText, sourceLanguageCode: code)
        } catch {
            let failure = error as NSError
            let errorKind: String
            switch error {
            case TranslationError.notInstalled: errorKind = "notInstalled"
            case TranslationError.unsupportedSourceLanguage: errorKind = "unsupportedSource"
            case TranslationError.unsupportedLanguagePairing: errorKind = "unsupportedPairing"
            case TranslationError.unableToIdentifyLanguage: errorKind = "unableToIdentify"
            case is CancellationError: errorKind = "cancelled"
            default: errorKind = "other"
            }
            HintDiagnostics.record(stage: "translation.failure", language: code,
                                   details: ["domain": failure.domain, "code": String(failure.code), "kind": errorKind])
            switch error {
            case TranslationError.notInstalled:
                throw HintTranslationError.needsLanguagePack(sourceLanguageCode: code)
            case TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedLanguagePairing:
                // Keep a runtime service failure distinct from a recognized but
                // unsupported language when the earlier availability probe was empty.
                if case .unsupported = status { throw HintTranslationError.serviceUnavailable }
                throw HintTranslationError.unsupportedLanguage
            case TranslationError.unableToIdentifyLanguage:
                throw HintTranslationError.unableToIdentifyLanguage
            default: throw error
            }
        }
    }
}

/// Debug builds keep bounded diagnostic metadata for development. Release
/// records nothing and performs no diagnostic cache/file work. Neither build
/// records source text, translations, candidates or host app identifiers.
@MainActor
enum HintDiagnostics {
    #if DEBUG
    private static let logger = Logger(subsystem: "com.tutuhu.EnglishHintKeyboard", category: "TranslationDiagnostics")
    private static var events: [[String: String]] = []
    private static var scheduledWrite: Task<Void, Never>?
    #endif

    static func record(stage: String, language: String = "", details: [String: String] = [:]) {
        #if DEBUG
        var event = details
        event["stage"] = stage
        event["language"] = language
        event["time"] = ISO8601DateFormatter().string(from: Date())
        logger.notice("stage=\(stage, privacy: .public) language=\(language, privacy: .public) metadata=\(details.description, privacy: .public)")
        events.append(event)
        if events.count > 32 { events.removeFirst(events.count - 32) }
        // Coalesce metadata and move JSON/file I/O off the key event executor.
        // The first event schedules a flush; continued activity does not delay it.
        guard scheduledWrite == nil else { return }
        scheduledWrite = Task {
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return }
            let snapshot = events
            scheduledWrite = nil
            await HintDiagnosticWriter.shared.write(snapshot)
        }
        #endif
    }
}

#if DEBUG
private actor HintDiagnosticWriter {
    static let shared = HintDiagnosticWriter()
    private var cacheURL: URL?
    private let logger = Logger(subsystem: "com.tutuhu.EnglishHintKeyboard", category: "TranslationDiagnostics")

    func write(_ events: [[String: String]]) {
        do {
            if cacheURL == nil {
                guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
                try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
                cacheURL = caches.appendingPathComponent("EnglishHintDiagnostics.json")
            }
            guard let cacheURL else { return }
            let data = try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            logger.error("Diagnostic cache unavailable")
        }
    }
}
#endif
#endif
