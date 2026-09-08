// English Hint Keyboard — native input surface and live preview integration.
// Hints stay passive until the user explicitly chooses Use English. Replacement
// and its single undo are restricted to a verified suffix of the current field.

import UIKit
import Combine
import OSLog

@MainActor
final class KeyboardViewController: UIInputViewController {
    private let surface = KeyboardSurface()
    private let analysisSession = SentenceAnalysisSession()
    private var speechSession = SpeechPlaybackSession(player: KeyboardAudioPlayer())
    private var speechSettings: TranslationSettingsSnapshot?
    private struct SpeechContext: Equatable {
        let english: String
        let snapshot: HintDocumentSnapshot
        let configurationID: String
    }
    private var speechContext: SpeechContext?
    private var analysisExpanded = false
    private var hostActive = false
    private var analysisStartedAt: CFTimeInterval?
    private var analysisWasPrepared = false
    private var analysisEnglish = ""
    private var analysisSnapshot: HintDocumentSnapshot?
    private var analysisFailure: String?
    private lazy var hintModel = LiveHintModel(translator: SelectedHintTranslator(
        apple: AppleInstalledTranslator(),
        fullAccess: { [weak self] in self?.hasFullAccess ?? false },
        diagnostics: { HintDiagnostics.record(stage: $0) }))
    private var subscriptions = Set<AnyCancellable>()
    private var keyboardHeight: NSLayoutConstraint?
    private var lastLayoutWidth: CGFloat = 0
    private var lastHeightObservation = ""
    private var page: KeyboardSurface.Page = .letters
    private var shift: KeyboardSurface.Shift = .lower
    private var previousShiftTap: Date?
    private var deleteTask: Task<Void, Never>?
    private var isDeleting = false
    private var visible = false
    private var documentRevision: UInt64 = 0
    private var observedSnapshot: HintDocumentSnapshot?
    private var hintSnapshot: HintDocumentSnapshot?
    private var displayedHint: LiveHintState = .idle
    private var replacementUndo = HintReplacementUndo()
    private var undoSource = ""
    private var replacementTask: Task<Void, Never>?
    private var replacementID: UUID?
    private var appearanceCheck: Task<Void, Never>?
    private var manuallySetShift = false
    private var isChinese = true
    // Each system keyboard entry has its own fixed layout. Old per-keyboard
    // preferences must not turn the 26-key entry into the nine-key layout.
    private let chineseLayout: KeyboardSurface.ChineseLayout = {
        Bundle(for: KeyboardViewController.self).object(forInfoDictionaryKey: "EHKKeyboardLayout") as? String == "nineKey"
            ? .nineKey : .qwerty
    }()
    private var pinyinBuffer = ""
    private var pinyinResult: PinyinResult?
    private var pinyinDecoder: PinyinDecoder?
    private var nineKeyBuffer = ""
    private var nineKeyResult: NineKeyPinyinResult?
    private var nineKeyDecoder: NineKeyPinyinDecoder?
    private var usesNineKey: Bool { isChinese && chineseLayout == .nineKey }
    private var hasComposition: Bool { usesNineKey ? !nineKeyBuffer.isEmpty : !pinyinBuffer.isEmpty }
    private var currentCandidates: [String] { usesNineKey ? (nineKeyResult?.candidates ?? []) : (pinyinResult?.candidates ?? []) }
    private var literalComposition: String {
        if usesNineKey { return (nineKeyResult?.fixedText ?? "") + (nineKeyResult?.remainingDigits ?? nineKeyBuffer) }
        return (pinyinResult?.fixedText ?? "") + (pinyinResult?.remainingPinyin ?? pinyinBuffer)
    }
    private let pinyinLog = Logger(subsystem: "com.tutuhu.EnglishHintKeyboard.Keyboard", category: "PinyinLifecycle")
    private var lastPinyinInitializationFailure: String?
    private var actionDurations: [Double] = []
    private var actionCount = 0

    /// A failed initialization is temporary: another host may still be releasing
    /// its controller, or the extension container may not have been ready yet.
    @discardableResult
    private func ensurePinyinDecoder() -> PinyinDecoder? {
        if let pinyinDecoder { return pinyinDecoder }
        let bundle = Bundle(for: KeyboardViewController.self)
        guard let dictionary = bundle.url(forResource: "dict_pinyin", withExtension: "dat") else {
            recordPinyinInitializationFailure("dictionary_missing_from_extension_bundle")
            return nil
        }
        let fileManager = FileManager.default
        guard fileManager.isReadableFile(atPath: dictionary.path) else {
            recordPinyinInitializationFailure("dictionary_path_unreadable")
            return nil
        }
        guard let documents = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            recordPinyinInitializationFailure("application_support_path_unavailable")
            return nil
        }
        do {
            try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        } catch {
            recordPinyinInitializationFailure("application_support_directory_io", code: (error as NSError).code)
            return nil
        }
        let userDictionary = documents.appendingPathComponent("pinyin-user.dict")
        guard fileManager.isWritableFile(atPath: documents.path),
              !fileManager.fileExists(atPath: userDictionary.path) || fileManager.isWritableFile(atPath: userDictionary.path) else {
            recordPinyinInitializationFailure("user_dictionary_path_not_writable")
            return nil
        }
        guard let decoder = PinyinDecoder(dictionaryPath: dictionary.path, userDictionaryPath: userDictionary.path) else {
            recordPinyinInitializationFailure("bridge_initialization_failed")
            return nil
        }
        pinyinDecoder = decoder
        nineKeyDecoder = NineKeyPinyinDecoder(pinyinDecoder: decoder)
        lastPinyinInitializationFailure = nil
        pinyinLog.info("Pinyin decoder initialized from extension resources")
        HintDiagnostics.record(stage: "pinyin.initialized")
        return decoder
    }

    private func recordPinyinInitializationFailure(_ reason: String, code: Int = 0) {
        // Fixed diagnostic categories and numeric errors only. Never log text,
        // candidates, document identifiers, filesystem paths or host app details.
        let key = "\(reason):\(code)"
        guard key != lastPinyinInitializationFailure else { return }
        lastPinyinInitializationFailure = key
        HintDiagnostics.record(stage: "pinyin.failure", details: ["reason": reason, "code": String(code)])
        pinyinLog.error("Pinyin initialization failed: \(reason, privacy: .public); code=\(code, privacy: .public)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        surface.configureGlobe = { [weak self] button in
            guard let self else { return }
            button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        surface.onAction = { [weak self] action in self?.perform(action) }
        surface.onDeletePressed = { [weak self] in self?.beginDeleting() }
        surface.onDeleteReleased = { [weak self] in self?.stopDeleting() }
        surface.onRetry = { [weak self] in
            guard let self, self.visible, self.hostActive else { return }
            self.updateHint()
            self.recordTranslationAccess(stage: "keyboard.retry")
            self.hintModel.retry()
        }
        surface.onUseEnglish = { [weak self] in self?.useEnglish() }
        surface.onUndoEnglish = { [weak self] in self?.undoEnglish() }
        surface.onToggleAnalysis = { [weak self] in self?.toggleAnalysis() }
        surface.onRetryAnalysis = { [weak self] in self?.requestAnalysis(retry: true) }
        surface.onToggleSpeech = { [weak self] in self?.toggleSpeech() }
        speechSession.onChange = { [weak self] in self?.renderSpeech() }
        analysisSession.onChange = { [weak self] in self?.analysisDidChange() }
        for notification in [NSNotification.Name.NSExtensionHostWillResignActive,
                             NSNotification.Name.NSExtensionHostDidEnterBackground] {
            NotificationCenter.default.publisher(for: notification)
                .sink { [weak self] _ in
                    self?.suspendHostWork()
                }
                .store(in: &subscriptions)
        }
        NotificationCenter.default.publisher(for: NSNotification.Name.NSExtensionHostDidBecomeActive)
            .sink { [weak self] _ in
                guard let self, self.visible else { return }
                self.hostActive = true
                self.reloadSpeechSettings()
                self.synchronizeAfterHostChange()
                self.prepareAnalysis()
            }
            .store(in: &subscriptions)
        surface.setInputLanguage(isChinese: isChinese)
        surface.setChineseLayout(chineseLayout)
        hintModel.$state.sink { [weak self] state in
            self?.displayedHint = state
            self?.renderHint()
            if state.status == .ready { self?.prepareAnalysis() }
        }.store(in: &subscriptions)
        refreshSurface()
        refreshComposition()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        visible = true
        hostActive = true
        reloadSpeechSettings()
        // Settings may have changed in the containing app while this extension
        // was retained. Re-read the provider even for an unchanged host sentence.
        hintModel.reset()
        invalidateReplacement()
        recordTranslationAccess(stage: "keyboard.willAppear")
        if isChinese { ensurePinyinDecoder() }
        refreshComposition()
        updateHeight(for: view.bounds.width)
        synchronizeAfterHostChange()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        recordTranslationAccess(stage: "keyboard.didAppear")
        synchronizeAfterHostChange()
        // Some hosts attach their proxy after willAppear. One bounded re-read
        // catches that first context without polling while the user types.
        appearanceCheck?.cancel()
        appearanceCheck = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self, self.visible, self.hostActive else { return }
            self.synchronizeAfterHostChange()
        }
    }

    private func recordTranslationAccess(stage: String) {
        let bundle = Bundle(for: KeyboardViewController.self)
        let ext = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any]
        let attributes = ext?["NSExtensionAttributes"] as? [String: Any]
        HintDiagnostics.record(stage: stage, details: [
            "fullAccess": String(hasFullAccess),
            "declaredOpenAccess": String(attributes?["RequestsOpenAccess"] as? Bool ?? false),
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "layout": chineseLayout == .nineKey ? "nineKey" : "qwerty"
        ])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        suspendHostWork()
        resetComposition()
        // A hidden controller must not keep the process-global AOSP decoder busy.
        pinyinDecoder = nil
        nineKeyDecoder = nil
        pinyinLog.info("Pinyin decoder released while keyboard is hidden")
        manuallySetShift = false
        previousShiftTap = nil
    }

    /// A retained keyboard can lose its host without disappearing first, and
    /// touch-up may never arrive. Stop all pending work on either lifecycle path.
    /// Preserve composing text during temporary inactivity; a document change or
    /// disappearance still clears it through the existing composition lifecycle.
    private func suspendHostWork() {
        hostActive = false
        stopDeleting()
        appearanceCheck?.cancel()
        appearanceCheck = nil
        replacementTask?.cancel()
        // The executor briefly owns cancellation cleanup. Keep its token until
        // it has either restored an exact partial edit or refused unsafe writes.
        invalidateReplacement()
        observedSnapshot = nil
        hintModel.reset()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        stopDeleting()
        super.viewWillTransition(to: size, with: coordinator)
        updateHeight(for: size.width)
        surface.configure(page: page, shift: shift, returnTitle: returnLabel,
                          showGlobe: needsInputModeSwitchKey, compact: size.width > 600,
                          returnIsActive: returnIsActive)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Observe the host-negotiated size separately from our requested height.
        // Dimensions only: no draft, translation, host identifier or API data.
        if visible, let requested = keyboardHeight?.constant, view.bounds.height > 0 {
            let observation = "\(analysisExpanded):\(Int(requested)):\(Int(view.bounds.height)):\(Int(view.bounds.width))"
            if observation != lastHeightObservation {
                lastHeightObservation = observation
                HintDiagnostics.record(stage: "keyboard.height.actual", details: [
                    "study": String(analysisExpanded), "requested": String(Int(requested)),
                    "actual": String(Int(view.bounds.height)), "width": String(Int(view.bounds.width)),
                    "layout": chineseLayout == .nineKey ? "nineKey" : "qwerty"
                ])
            }
        }
        let width = view.bounds.width
        guard width > 0, abs(width - lastLayoutWidth) > 1 else { return }
        lastLayoutWidth = width
        updateHeight(for: width)
        refreshSurface()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateHeight(for: view.bounds.width)
    }

    override func textWillChange(_ textInput: (any UITextInput)?) {
        super.textWillChange(textInput)
        invalidateSpeech()
        invalidateAnalysis()
        guard replacementID == nil else { return }
        // Stop an in-flight result from appearing while another document is being activated.
        hintModel.reset()
        hintSnapshot = nil
        surface.setHintAction(.none)
        stopDeleting()
        resetComposition()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        manuallySetShift = false
        synchronizeAfterHostChange()
    }

    override func selectionWillChange(_ textInput: (any UITextInput)?) {
        super.selectionWillChange(textInput)
        invalidateSpeech()
        invalidateAnalysis()
        guard replacementID == nil else { return }
        hintModel.reset()
        hintSnapshot = nil
        surface.setHintAction(.none)
        stopDeleting()
        resetComposition()
    }

    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        manuallySetShift = false
        synchronizeAfterHostChange()
    }

    private func synchronizeAfterHostChange() {
        guard visible, hostActive, replacementID == nil else { return }
        updateAutomaticCapitalization()
        refreshSurface()
        updateHint()
    }

    private func perform(_ action: KeyboardSurface.Action) {
        guard visible, hostActive, replacementID == nil else { return }
        // Changing keycaps does not edit the host. Keep the verified hint,
        // prepared analysis and one-step undo available across those switches.
        switch action {
        case .numbers, .symbols, .letters: break
        case .shift where !isChinese: break
        default: invalidateReplacement()
        }
        let started = CACurrentMediaTime()
        defer { recordActionDuration((CACurrentMediaTime() - started) * 1_000) }
        switch action {
        case .t9Digit(let digit):
            guard usesNineKey, page == .letters, ensurePinyinDecoder() != nil else { return }
            if nineKeyBuffer.count < 64 {
                nineKeyBuffer += digit
                updateComposition()
            } else { refreshComposition(notice: "拼音较长，请先选词再继续") }
            return
        case .separator:
            guard isChinese, page == .letters, hasComposition else { return }
            if usesNineKey {
                guard nineKeyBuffer.count < 64 else {
                    refreshComposition(notice: "拼音较长，请先选词再继续")
                    return
                }
                if nineKeyBuffer.last != "'" { nineKeyBuffer += "'" }
            } else {
                guard pinyinBuffer.count < 128 else {
                    refreshComposition(notice: "拼音较长，请先选词再继续")
                    return
                }
                if pinyinBuffer.last != "'" { pinyinBuffer += "'" }
            }
            updateComposition()
            return
        case .insert(let text):
            if isChinese, page == .letters, text.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
                guard ensurePinyinDecoder() != nil else { refreshComposition(); return }
                if pinyinBuffer.count < 128 {
                    pinyinBuffer += text.lowercased()
                    updateComposition()
                } else { refreshComposition(notice: "拼音较长，请先选词再继续") }
                return
            }
            commitCompositionIfNeeded()
            textDocumentProxy.insertText(text)
            if shift == .upper { shift = .lower }
            manuallySetShift = false
            previousShiftTap = nil
        case .space:
            if hasComposition {
                if !currentCandidates.isEmpty { chooseCandidate(at: 0) }
                else {
                    commitCompositionIfNeeded()
                    textDocumentProxy.insertText(" ")
                    updateHint()
                }
                return
            }
            textDocumentProxy.insertText(" ")
            manuallySetShift = false
            previousShiftTap = nil
        case .return:
            if hasComposition {
                if usesNineKey, !currentCandidates.isEmpty {
                    commitCompositionIfNeeded()
                    updateHint()
                    return
                }
                // Return commits exactly the typed spelling, without submitting the host field.
                let spelling = literalComposition
                resetComposition()
                textDocumentProxy.insertText(spelling)
                updateHint()
                return
            }
            textDocumentProxy.insertText("\n")
            manuallySetShift = false
            previousShiftTap = nil
        case .delete:
            if hasComposition {
                if usesNineKey { nineKeyBuffer.removeLast() }
                else { pinyinBuffer.removeLast() }
                updateComposition()
                return
            }
            textDocumentProxy.deleteBackward()
            manuallySetShift = false
            previousShiftTap = nil
        case .shift:
            stopDeleting()
            if isChinese {
                commitCompositionIfNeeded()
                isChinese = false
                shift = .upper
                manuallySetShift = true
                surface.setInputLanguage(isChinese: false)
                updateHeight(for: view.bounds.width)
                refreshComposition()
                refreshSurface()
                updateHint()
                return
            }
            let now = Date()
            if let last = previousShiftTap, now.timeIntervalSince(last) < 0.35, shift != .locked {
                shift = .locked
                previousShiftTap = nil
            } else {
                shift = shift == .lower ? .upper : .lower
                previousShiftTap = now
            }
            manuallySetShift = true
            refreshSurface()
            return
        case .numbers:
            stopDeleting()
            page = .numbers
            previousShiftTap = nil
            refreshSurface()
            return
        case .symbols:
            stopDeleting()
            page = .symbols
            previousShiftTap = nil
            refreshSurface()
            return
        case .letters:
            stopDeleting()
            page = .letters
            previousShiftTap = nil
            refreshSurface()
            return
        case .toggleLanguage:
            stopDeleting()
            commitCompositionIfNeeded()
            isChinese.toggle()
            if isChinese { ensurePinyinDecoder() }
            page = .letters
            shift = .lower
            manuallySetShift = false
            previousShiftTap = nil
            surface.setInputLanguage(isChinese: isChinese)
            updateHeight(for: view.bounds.width)
            updateAutomaticCapitalization()
            refreshComposition()
            refreshSurface()
            updateHint()
            return
        }
        updateAutomaticCapitalization()
        refreshSurface()
        updateHint()
    }

    private func recordActionDuration(_ milliseconds: Double) {
        // Measures only this synchronous handler, not rendering latency. No keys,
        // composing text, candidates or host data are collected.
        actionDurations.append(milliseconds)
        if actionDurations.count > 120 { actionDurations.removeFirst() }
        actionCount += 1
        guard actionCount % 20 == 0 else { return }
        let sorted = actionDurations.sorted()
        HintDiagnostics.record(stage: "keyboard.actionTiming", details: [
            "samples": String(sorted.count),
            "p50ms": String(format: "%.3f", sorted[sorted.count / 2]),
            "p95ms": String(format: "%.3f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]),
            "maxms": String(format: "%.3f", sorted.last ?? 0)
        ])
    }

    private func updateHint() {
        guard visible, hostActive, replacementID == nil else { return }
        if hasComposition {
            hintSnapshot = nil
            hintModel.pauseForComposition()
            return
        }
        let snapshot = documentSnapshot()
        if let observedSnapshot, observedSnapshot != snapshot {
            invalidateReplacement()
        }
        let current = documentSnapshot()
        observedSnapshot = current
        if replacementUndo.isAvailable(currentSnapshot: current) {
            renderHint()
            return
        }
        // Cursor movement may leave the extracted sentence unchanged. Bind the
        // result to the exact context as well so it cannot replace an older range.
        if hintSnapshot != current {
            hintModel.reset()
            hintSnapshot = current
        }
        // The host only exposes a bounded context. Never read or walk the whole document.
        hintModel.update(before: current.before,
                         after: current.after,
                         documentID: current.documentID,
                         isComposing: hasComposition)
        renderHint()
    }

    private func documentSnapshot(revision: UInt64? = nil) -> HintDocumentSnapshot {
        let proxy = textDocumentProxy
        let before = proxy.documentContextBeforeInput
        let after = proxy.documentContextAfterInput
        let selection = proxy.selectedText
        // iOS may use nil or an empty string for an empty field/selection. Only
        // normalize a missing left context when the host also says it has no text.
        // A non-empty field with unavailable left context remains ineligible.
        return HintDocumentSnapshot(documentID: proxy.documentIdentifier, revision: revision ?? documentRevision,
                                    before: before ?? (proxy.hasText ? nil : ""),
                                    after: after?.isEmpty == false ? after : nil,
                                    selectedText: selection?.isEmpty == false ? selection : nil)
    }

    private func invalidateReplacement() {
        invalidateSpeech()
        invalidateAnalysis()
        documentRevision &+= 1
        replacementUndo.invalidate()
        undoSource = ""
        hintSnapshot = nil
        surface.setHintAction(.none)
    }

    private func availableReplacement() -> HintReplacementPlan? {
        guard visible, hostActive, replacementID == nil, !hasComposition,
              displayedHint.status == .ready,
              let hintSnapshot else { return nil }
        // Mixed Chinese/English can be classified as English locally. The
        // planner rejects unchanged text and checks the exact replaceable suffix;
        // language detection must not hide a valid user-triggered replacement.
        return HintReplacementPlanner.plan(readySource: displayedHint.source,
                                           translation: displayedHint.displayText,
                                           readySnapshot: hintSnapshot,
                                           currentSnapshot: documentSnapshot())
    }

    private func renderHint() {
        guard replacementID == nil else { return }
        defer { refreshAnalysis(); refreshSpeech() }
        if visible, !hasComposition, replacementUndo.isAvailable(currentSnapshot: documentSnapshot()) {
            surface.setHint(text: undoSource, loading: false, isTranslation: true, canRetry: false)
            surface.setHintAction(.undoEnglish)
            return
        }
        surface.setHint(text: displayedHint.displayText,
                        loading: displayedHint.status == .translating,
                        isTranslation: displayedHint.status == .ready,
                        canRetry: displayedHint.status == .error || displayedHint.status == .needsLanguagePack)
        surface.setHintAction(availableReplacement() == nil ? .none : .useEnglish)
    }

    private func availableAnalysisText() -> String? {
        guard visible, hostActive, hasFullAccess, replacementID == nil, !hasComposition,
              displayedHint.status == .ready,
              let hintSnapshot, hintSnapshot == documentSnapshot(),
              !replacementUndo.isAvailable(currentSnapshot: documentSnapshot()) else { return nil }
        let text = displayedHint.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // Speech shares only the active Beijing Qwen configuration. Retained Qwen
    // keys in Apple/custom mode never authorize a cloud speech request.
    private func reloadSpeechSettings() {
        let settings = try? TranslationSettingsStore.shared.load()
        if speechSettings != settings { invalidateSpeech() }
        speechSettings = settings
    }

    private func availableSpeechContext() -> SpeechContext? {
        guard let settings = speechSettings, settings.provider == .qwen,
              let key = settings.apiKey, !key.isEmpty,
              let english = availableAnalysisText() else { return nil }
        return SpeechContext(english: english, snapshot: documentSnapshot(),
                             configurationID: settings.revision)
    }

    private func refreshSpeech() {
        let context = availableSpeechContext()
        if speechContext != context {
            speechContext = context
            speechSession.stop(clearCache: true)
        }
        renderSpeech()
    }

    private func renderSpeech() {
        surface.setSpeech(available: speechContext != nil, state: speechSession.state)
    }

    private func invalidateSpeech() {
        speechContext = nil
        speechSession.stop(clearCache: true)
        renderSpeech()
    }

    private func toggleSpeech() {
        // Revalidate current settings and host snapshot at the actual tap. The
        // service is created only here, never by translation/analysis prefetch.
        reloadSpeechSettings()
        refreshSpeech()
        guard let context = speechContext, let key = speechSettings?.apiKey else { return }
        speechSession.toggle(text: context.english, configurationID: context.configurationID,
                             synthesizer: QwenSpeechSynthesizer(apiKey: key))
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        invalidateSpeech()
    }

    private func invalidateAnalysis() {
        let wasExpanded = analysisExpanded
        analysisExpanded = false
        analysisEnglish = ""
        analysisSnapshot = nil
        analysisFailure = nil
        analysisSession.reset()
        surface.setAnalysis(available: false, expanded: false, english: "", state: .idle)
        if wasExpanded { updateHeight(for: view.bounds.width) }
    }

    private func analysisDidChange() {
        switch analysisSession.state {
        case .loading:
            analysisStartedAt = CACurrentMediaTime()
            HintDiagnostics.record(stage: "analysis.started", details: ["prepared": String(analysisWasPrepared)])
        case .ready:
            if let started = analysisStartedAt {
                HintDiagnostics.record(stage: "analysis.ready", details: [
                    "milliseconds": String(Int((CACurrentMediaTime() - started) * 1_000)),
                    "expanded": String(analysisExpanded)
                ])
            }
            analysisStartedAt = nil
        case .failure:
            HintDiagnostics.record(stage: "analysis.failure")
            analysisStartedAt = nil
        case .idle:
            analysisStartedAt = nil
        }
        refreshAnalysis()
    }

    private func refreshAnalysis() {
        let text = availableAnalysisText()
        if !analysisEnglish.isEmpty,
           text != analysisEnglish || analysisSnapshot != documentSnapshot() {
            invalidateAnalysis()
        }
        let presentation: KeyboardSurface.AnalysisPresentation
        if let analysisFailure { presentation = .failure(analysisFailure) }
        else {
            switch analysisSession.state {
            case .idle: presentation = .idle
            case .loading: presentation = .loading
            case .ready(let result): presentation = .ready(result)
            case .failure(let message): presentation = .failure(message)
            }
        }
        surface.setAnalysis(available: text != nil, expanded: analysisExpanded,
                            english: text ?? "", state: presentation)
    }

    private func toggleAnalysis() {
        if analysisExpanded {
            analysisExpanded = false
            refreshAnalysis()
            updateHeight(for: view.bounds.width)
            HintDiagnostics.record(stage: "analysis.collapsed")
            return
        }
        guard availableAnalysisText() != nil else { refreshAnalysis(); return }
        stopDeleting()
        analysisExpanded = true
        if case .ready = analysisSession.state {
            HintDiagnostics.record(stage: "analysis.openedReady")
        }
        requestAnalysis()
        updateHeight(for: view.bounds.width)
    }

    private func prepareAnalysis() {
        // Translation already debounces typing. Prepare each accepted result
        // immediately so opening the study view can reuse completed work.
        guard availableAnalysisText() != nil else { return }
        requestAnalysis(automatic: true)
    }

    private func requestAnalysis(retry: Bool = false, automatic: Bool = false) {
        guard let english = availableAnalysisText() else {
            invalidateAnalysis()
            return
        }
        let snapshot = documentSnapshot()
        analysisEnglish = english
        analysisSnapshot = snapshot
        analysisFailure = nil
        do {
            let settings = try TranslationSettingsStore.shared.load()
            let isCurrent: @MainActor () -> Bool = { [weak self] in
                guard let self, self.availableAnalysisText() == english,
                      self.documentSnapshot() == snapshot,
                      let current = try? TranslationSettingsStore.shared.load() else { return false }
                return current == settings
            }
            if automatic {
                if settings.provider != .apple {
                    analysisWasPrepared = true
                    analysisSession.prepare(english: english, settings: settings, isCurrent: isCurrent)
                }
            } else {
                analysisWasPrepared = false
                analysisSession.request(english: english, settings: settings, retry: retry, isCurrent: isCurrent)
            }
        } catch {
            analysisSession.reset()
            analysisFailure = "暂时无法读取服务设置，请回伴语检查后重试。"
        }
        refreshAnalysis()
    }

    private func useEnglish() {
        guard let plan = availableReplacement() else { updateHint(); return }
        executeReplacement(plan, original: displayedHint.source, isUndo: false)
    }

    private func undoEnglish() {
        guard visible, hostActive, replacementID == nil, !hasComposition,
              let plan = replacementUndo.takePlan(currentSnapshot: documentSnapshot()) else { return }
        executeReplacement(plan, original: "", isUndo: true)
    }

    private func executeReplacement(_ plan: HintReplacementPlan, original: String, isUndo: Bool) {
        invalidateSpeech()
        invalidateAnalysis()
        stopDeleting()
        let token = UUID()
        replacementID = token
        hintModel.reset()
        hintSnapshot = nil
        surface.setHintAction(.none)
        surface.setHint(text: isUndo ? "正在恢复原文…" : "正在替换…", loading: true,
                        isTranslation: false, canRetry: false)
        replacementTask = Task { [weak self] in
            guard let self else { return }
            // An operation has a stable revision even if dismissal invalidates
            // the UI's next interaction. Actual document/text/selection checks
            // still apply to cancellation rollback, including after a host switch.
            let executionRevision = plan.originalSnapshot.revision
            let result = await HintReplacementExecutor.execute(
                plan: plan,
                snapshot: { self.documentSnapshot(revision: executionRevision) },
                deleteBackward: { self.textDocumentProxy.deleteBackward() },
                insertText: { self.textDocumentProxy.insertText($0) })
            guard self.replacementID == token else { return }
            self.replacementID = nil
            self.replacementTask = nil
            self.replacementUndo.invalidate()
            self.undoSource = ""
            guard self.visible else { return }
            if Task.isCancelled {
                self.observedSnapshot = nil
                self.synchronizeAfterHostChange()
                return
            }
            switch result {
            case .completed(let completed):
                self.observedSnapshot = completed
                if !isUndo {
                    self.replacementUndo.record(plan, currentSnapshot: completed)
                    self.undoSource = original
                }
                HintDiagnostics.record(stage: isUndo ? "replacement.undo" : "replacement.success")
                self.synchronizeAfterHostChange()
            case .restored:
                HintDiagnostics.record(stage: "replacement.restored")
                self.observedSnapshot = self.documentSnapshot()
                self.synchronizeAfterHostChange()
            case .aborted:
                HintDiagnostics.record(stage: "replacement.aborted")
                self.observedSnapshot = self.documentSnapshot()
                self.displayedHint = LiveHintState(status: .error, source: "",
                                                 displayText: "输入内容已变化，请检查后重试")
                self.refreshSurface()
                self.renderHint()
            }
        }
    }

    private func updateComposition() {
        if !hasComposition { resetComposition(refresh: false) }
        else if usesNineKey {
            ensurePinyinDecoder()
            nineKeyResult = nineKeyDecoder?.update(digits: nineKeyBuffer)
        } else { pinyinResult = ensurePinyinDecoder()?.update(pinyin: pinyinBuffer) }
        refreshComposition()
        refreshSurface()
        updateHint()
    }

    private func chooseCandidate(at index: Int) {
        guard visible, hostActive, replacementID == nil else { return }
        invalidateReplacement()
        if usesNineKey {
            guard let decoder = nineKeyDecoder, currentCandidates.indices.contains(index) else { return }
            let result = decoder.selectCandidate(at: index)
            if result.isComplete, !result.commitText.isEmpty {
                let text = result.commitText
                let remaining = result.remainingDigits
                resetComposition(refresh: false)
                textDocumentProxy.insertText(text)
                if !remaining.isEmpty {
                    nineKeyBuffer = remaining
                    nineKeyResult = decoder.update(digits: remaining)
                }
            } else { nineKeyResult = result }
            refreshComposition()
            refreshSurface()
            updateHint()
            return
        }
        guard let decoder = pinyinDecoder, let current = pinyinResult,
              current.candidates.indices.contains(index) else { return }
        let result = decoder.selectCandidate(at: index)
        if result.isComplete, !result.commitText.isEmpty {
            let text = result.commitText
            let remaining = result.remainingPinyin
            resetComposition(refresh: false)
            textDocumentProxy.insertText(text)
            if !remaining.isEmpty {
                pinyinBuffer = remaining
                pinyinResult = decoder.update(pinyin: remaining)
            }
        } else {
            pinyinResult = result
        }
        refreshComposition()
        refreshSurface()
        updateHint()
    }

    private func commitCompositionIfNeeded() {
        guard hasComposition else { return }
        // The decoder handles a bounded number of syllables at a time. Preserve and
        // decode any unconsumed suffix before committing punctuation or changing mode.
        for _ in 0..<128 {
            guard hasComposition, !currentCandidates.isEmpty else { break }
            let previous = literalComposition
            chooseCandidate(at: 0)
            if literalComposition == previous { break }
        }
        if hasComposition {
            let spelling = literalComposition
            resetComposition()
            textDocumentProxy.insertText(spelling)
        }
    }

    private func resetComposition(refresh: Bool = true) {
        pinyinBuffer = ""
        pinyinResult = nil
        pinyinDecoder?.reset()
        nineKeyBuffer = ""
        nineKeyResult = nil
        nineKeyDecoder?.reset()
        if refresh {
            refreshComposition()
            refreshSurface()
        }
    }

    private func refreshComposition(notice: String? = nil) {
        let result = pinyinResult
        let display = usesNineKey ? (nineKeyResult?.displayPinyin ?? nineKeyBuffer) :
            (result?.fixedText ?? "") + (result?.remainingPinyin ?? pinyinBuffer)
        surface.setComposition(notice ?? display, candidates: currentCandidates, isChinese: isChinese,
                               unavailable: pinyinDecoder == nil) { [weak self] index in
            self?.chooseCandidate(at: index)
        }
        surface.setSpellingOptions(usesNineKey ? (nineKeyResult?.spellingOptions ?? []) : []) { [weak self] index in
            guard let self, self.visible, self.hostActive, self.usesNineKey,
                  self.replacementID == nil else { return }
            self.invalidateReplacement()
            self.nineKeyResult = self.nineKeyDecoder?.selectSpelling(at: index)
            self.refreshComposition()
            self.refreshSurface()
            self.updateHint()
        }
    }

    private func beginDeleting() {
        guard visible, hostActive, replacementID == nil else { return }
        stopDeleting()
        isDeleting = true
        perform(.delete)
        deleteTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 420_000_000)
                while !Task.isCancelled {
                    guard let self, self.visible, self.hostActive else { return }
                    self.perform(.delete)
                    try await Task.sleep(nanoseconds: 85_000_000)
                }
            } catch { /* Releasing the key, changing field or hiding the keyboard cancels repeat. */ }
        }
    }

    private func stopDeleting() {
        deleteTask?.cancel()
        deleteTask = nil
        let wasDeleting = isDeleting
        isDeleting = false
        if wasDeleting { refreshSurface() }
    }

    private func updateAutomaticCapitalization() {
        if isChinese { shift = .lower; return }
        guard shift != .locked, !manuallySetShift else { return }
        let context = textDocumentProxy.documentContextBeforeInput ?? ""
        let shouldCapitalize: Bool
        switch textDocumentProxy.autocapitalizationType ?? .sentences {
        case .none: shouldCapitalize = false
        case .allCharacters: shouldCapitalize = true
        case .words: shouldCapitalize = context.isEmpty || context.last?.isWhitespace == true
        case .sentences:
            let trimmed = context.trimmingCharacters(in: .whitespaces)
            shouldCapitalize = context.isEmpty || trimmed.isEmpty || trimmed.last == "\n"
                || (context.last?.isWhitespace == true && trimmed.last.map { ".!?。！？".contains($0) } == true)
        @unknown default: shouldCapitalize = false
        }
        shift = shouldCapitalize ? .upper : .lower
    }

    private func refreshSurface() {
        // Keep the pressed delete button alive until touch-up can end repetition.
        guard !isDeleting else { return }
        surface.configure(page: page, shift: shift, returnTitle: returnLabel,
                          showGlobe: needsInputModeSwitchKey, compact: view.bounds.width > 600,
                          returnIsActive: returnIsActive)
    }

    private var returnIsActive: Bool {
        if hasComposition || textDocumentProxy.hasText { return true }
        // Empty chat drafts cannot be sent. Other fields may still use Done or
        // Next with no text, unless the host explicitly requests automatic disabling.
        return textDocumentProxy.returnKeyType != .send
            && textDocumentProxy.enablesReturnKeyAutomatically != true
    }

    private func updateHeight(for width: CGFloat) {
        let landscape = width > 600
        let normalHeight: CGFloat = isChinese
            ? (usesNineKey ? (landscape ? 211 : 268) : (landscape ? 214 : 263))
            : (landscape ? 214 : 263)
        // A keyboard's window grows with this constraint. Derive the learning
        // space from its screen, otherwise each layout could grow it again.
        let screenBounds = view.window?.windowScene?.screen.bounds
        let screenHeight = screenBounds.map { landscape ? min($0.width, $0.height) : max($0.width, $0.height) }
            ?? (landscape ? 393 : 852)
        let contentHeight = KeyboardStudyLayout.contentHeight(
            normal: normalHeight, expanded: analysisExpanded,
            screenHeight: screenHeight, landscape: landscape,
            bottomInset: view.safeAreaInsets.bottom)
        let height = contentHeight + view.safeAreaInsets.bottom
        if let keyboardHeight {
            if abs(keyboardHeight.constant - height) > 1 {
                HintDiagnostics.record(stage: "keyboard.height", details: [
                    "study": String(analysisExpanded), "requested": String(Int(height))
                ])
            }
            keyboardHeight.constant = height
        }
        else {
            let constraint = view.heightAnchor.constraint(equalToConstant: height)
            constraint.priority = .init(999)
            constraint.isActive = true
            keyboardHeight = constraint
        }
    }

    private var returnLabel: String {
        if hasComposition { return usesNineKey ? "确定" : "原文" }
        switch textDocumentProxy.returnKeyType ?? .default {
        case .go: return "前往"
        case .google, .yahoo, .search: return "搜索"
        case .join: return "加入"
        case .next: return "下一项"
        case .route: return "路线"
        case .send: return "发送"
        case .done: return "完成"
        case .continue: return "继续"
        case .emergencyCall: return "呼叫"
        default: return "换行"
        }
    }
}
