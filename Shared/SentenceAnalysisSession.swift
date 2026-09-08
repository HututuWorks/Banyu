import Foundation

enum SentenceAnalysisLoadState: Equatable {
    case idle
    case loading
    case ready(SentenceAnalysis)
    case failure(String)
}

/// One in-memory result for the current sentence, prepared as soon as a stable
/// translation arrives. Opening the panel uses the same request or ready result.
@MainActor
final class SentenceAnalysisSession {
    private let analyzer: any SentenceAnalyzing
    private var task: Task<Void, Never>?
    private var token: UUID?
    private var english = ""
    private var requestedSettings: TranslationSettingsSnapshot?
    private(set) var state: SentenceAnalysisLoadState = .idle
    var onChange: (() -> Void)?

    init(analyzer: any SentenceAnalyzing = SentenceAnalyzer()) {
        self.analyzer = analyzer
    }

    deinit { task?.cancel() }

    func reset() {
        task?.cancel()
        task = nil
        token = nil
        english = ""
        requestedSettings = nil
        if state != .idle { state = .idle; onChange?() }
    }

    /// Apple remains device-only: retained keys never authorize background work.
    func prepare(english: String, settings: TranslationSettingsSnapshot,
                 isCurrent: @escaping @MainActor () -> Bool) {
        guard settings.provider != .apple else { reset(); return }
        request(english: english, settings: settings, isCurrent: isCurrent)
    }

    func request(english: String, settings: TranslationSettingsSnapshot,
                 retry: Bool = false, isCurrent: @escaping @MainActor () -> Bool) {
        guard isCurrent() else { reset(); return }
        if self.english == english, requestedSettings == settings {
            switch state {
            case .loading, .ready: return
            case .failure where !retry: return
            default: break
            }
        }
        reset()
        self.english = english
        requestedSettings = settings
        let requestID = UUID()
        token = requestID
        state = .loading
        onChange?()
        // Rendering may synchronously invalidate this request or replace it.
        guard token == requestID else { return }
        task = Task { [weak self, analyzer] in
            do {
                try Task.checkCancellation()
                guard self?.token == requestID else { return }
                guard isCurrent() else { self?.reset(); return }
                let result = try await analyzer.analyze(english, settings: settings)
                try Task.checkCancellation()
                guard let self, self.token == requestID else { return }
                guard isCurrent() else { self.reset(); return }
                self.task = nil
                self.state = .ready(result)
                self.onChange?()
            } catch {
                guard let self, self.token == requestID else { return }
                guard !Task.isCancelled, !(error is CancellationError), isCurrent() else {
                    self.reset()
                    return
                }
                self.task = nil
                self.state = .failure((error as? SentenceAnalysisError)?.message
                                     ?? "暂时无法分析，请稍后重试。")
                self.onChange?()
            }
        }
    }
}
