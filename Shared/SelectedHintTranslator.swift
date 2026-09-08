import Foundation

/// Reads the explicit choice for every request. The Apple branch never creates
/// a cloud provider or sends text over the network.
@MainActor
final class SelectedHintTranslator: HintTranslating {
    private let apple: any HintTranslating
    private let settings: @MainActor () throws -> TranslationSettingsSnapshot
    private let cloudFactory: @MainActor (String) -> any HintTranslating
    private let customFactory: @MainActor (CustomTranslationConfiguration) -> any HintTranslating
    private let fullAccess: @MainActor () -> Bool
    private let diagnostics: @MainActor (String) -> Void

    init(apple: any HintTranslating,
         settings: @escaping @MainActor () throws -> TranslationSettingsSnapshot = {
             try TranslationSettingsStore.shared.load()
         },
         cloudFactory: @escaping @MainActor (String) -> any HintTranslating = { QwenTranslator(apiKey: $0) },
         customFactory: @escaping @MainActor (CustomTranslationConfiguration) -> any HintTranslating = {
             OpenAICompatibleTranslator(configuration: $0)
         },
         fullAccess: @escaping @MainActor () -> Bool = { true },
         diagnostics: @escaping @MainActor (String) -> Void = { _ in }) {
        self.apple = apple
        self.settings = settings
        self.cloudFactory = cloudFactory
        self.customFactory = customFactory
        self.fullAccess = fullAccess
        self.diagnostics = diagnostics
    }

    func translate(_ source: String) async throws -> HintTranslationResult {
        try Task.checkCancellation()
        guard fullAccess() else { throw HintTranslationError.fullAccessRequired }
        let snapshot = try readSettings()
        let result: HintTranslationResult
        switch snapshot.provider {
        case .apple:
            result = try await apple.translate(source)
        case .qwen:
            guard let key = snapshot.apiKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HintTranslationError.cloudConfiguration
            }
            result = try await translateCloud(source, snapshot: snapshot, translator: cloudFactory(key))
        case .custom:
            guard let custom = snapshot.custom else {
                throw HintTranslationError.cloudConfiguration
            }
            result = try await translateCloud(source, snapshot: snapshot, translator: customFactory(custom))
        }
        try ensureCurrent(snapshot)
        return result
    }

    private func ensureCurrent(_ snapshot: TranslationSettingsSnapshot) throws {
        try Task.checkCancellation()
        guard fullAccess() else { throw HintTranslationError.fullAccessRequired }
        guard try readSettings() == snapshot else { throw HintTranslationError.settingsChanged }
    }

    private func readSettings() throws -> TranslationSettingsSnapshot {
        do { return try settings() }
        catch { throw HintTranslationError.settingsUnavailable }
    }

    private func translateCloud(_ source: String, snapshot: TranslationSettingsSnapshot,
                                translator: any HintTranslating) async throws -> HintTranslationResult {
        do {
            let result = try await translator.translate(source)
            try ensureCurrent(snapshot)
            diagnostics("cloud.success")
            return result
        } catch {
            try ensureCurrent(snapshot)
            if error is CancellationError { throw error }
            guard let cloudError = error as? QwenTranslationError else { throw Self.mapped(error) }
            guard cloudError.allowsAppleFallback else { throw Self.mapped(cloudError) }
            diagnostics("apple.fallback")
            do {
                let result = try await apple.translate(source)
                try ensureCurrent(snapshot)
                return result
            } catch {
                try ensureCurrent(snapshot)
                if error is CancellationError { throw error }
                // Do not let the model repeat a paid cloud request merely because
                // the optional on-device fallback has no usable language pack.
                throw HintTranslationError.cloudUnavailable
            }
        }
    }

    private static func mapped(_ error: Error) -> HintTranslationError {
        switch error {
        case QwenTranslationError.missingAPIKey, QwenTranslationError.invalidConfiguration:
            return .cloudConfiguration
        case QwenTranslationError.invalidAPIKey: return .cloudAuthentication
        case QwenTranslationError.accessDenied: return .cloudAccessDenied
        case let error as HintTranslationError: return error
        default: return .cloudUnavailable
        }
    }
}
