// The runner appends this extension to a copy of the controller, removing only
// its final modifier to supply a fake host proxy. No shipping test hooks.
import UIKit
import Darwin

@MainActor
private final class PendingTranslation: HintTranslating {
    var started = false
    var cancelled = false
    func translate(_ source: String) async throws -> HintTranslationResult {
        started = true
        do { try await Task.sleep(nanoseconds: 30_000_000_000) }
        catch { cancelled = Task.isCancelled; throw error }
        return HintTranslationResult(text: "Test", sourceLanguageCode: "zh-Hans")
    }
}
private struct LifecycleFailure: Error { let message: String }

@MainActor
private final class LifecycleDraftTranslation: HintTranslating {
    var requests: [String] = []
    let translation: String
    init(_ translation: String) { self.translation = translation }
    func translate(_ source: String) async throws -> HintTranslationResult {
        requests.append(source)
        return HintTranslationResult(text: translation, sourceLanguageCode: "zh-Hans")
    }
}

@MainActor
private final class LifecycleSpeechPlayer: SpeechAudioPlaying {
    var onStop: (() -> Void)?
    var plays = 0
    func playOnce(_ data: Data) throws { plays += 1 }
    func stop() {}
}

@MainActor
private final class LifecyclePendingSpeech: SpeechSynthesizing {
    var started = false
    var cancelled = false
    func synthesize(_ text: String) async throws -> Data {
        started = true
        do { try await Task.sleep(nanoseconds: 30_000_000_000) }
        catch { cancelled = Task.isCancelled; throw error }
        return Data()
    }
}

@MainActor
private final class LifecycleImmediateSpeech: SpeechSynthesizing {
    var requests: [String] = []
    func synthesize(_ text: String) async throws -> Data {
        requests.append(text)
        return Data([1, 2, 3])
    }
}

@MainActor
private final class LifecycleDocumentProxy: NSObject, UITextDocumentProxy {
    var text = ""
    var following: String?
    var selection: String?
    let documentIdentifier = UUID()
    var documentContextBeforeInput: String? { text }
    var documentContextAfterInput: String? { following }
    var selectedText: String? { selection }
    var documentInputMode: UITextInputMode? { nil }
    var hasText: Bool { !text.isEmpty }
    func insertText(_ value: String) { text += value }
    func deleteBackward() { if !text.isEmpty { text.removeLast() } }
    func adjustTextPosition(byCharacterOffset offset: Int) {}
    func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
    func unmarkText() {}
}
@MainActor
private final class LifecycleTestController: KeyboardViewController {
    let proxy = LifecycleDocumentProxy()
    override var textDocumentProxy: any UITextDocumentProxy { proxy }
    override var hasFullAccess: Bool { true }
}

extension KeyboardViewController {
    @MainActor
    static func verifyLifecycle() async throws {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw LifecycleFailure(message: message) }
            checks += 1
        }
        for notification in [NSNotification.Name.NSExtensionHostWillResignActive,
                             NSNotification.Name.NSExtensionHostDidEnterBackground] {
            let controller = LifecycleTestController()
            controller.loadViewIfNeeded()
            controller.viewWillAppear(false)
            controller.isChinese = false

            // Repeat deletion has no host in this harness. Count action handler
            // executions so losing a touch-up on deactivation is observable.
            controller.beginDeleting()
            try expect(controller.isDeleting && controller.deleteTask != nil, "deletion must be active before notification")
            let translator = PendingTranslation()
            controller.hintModel = LiveHintModel(translator: translator, debounceNanoseconds: 0)
            controller.hintModel.update(before: "生命周期测试", after: nil)
            for _ in 0..<10 where !translator.started { await Task.yield() }
            try expect(translator.started, "translation must be in flight before notification")

            let replacement = Task<Void, Never> {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch {}
            }
            let replacementToken = UUID()
            controller.replacementTask = replacement
            controller.replacementID = replacementToken
            controller.appearanceCheck = Task {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch {}
            }
            let appearance = controller.appearanceCheck!
            controller.pinyinBuffer = "nihao"

            NotificationCenter.default.post(name: notification, object: nil)
            try expect(!controller.hostActive, "host must become inactive")
            try expect(!controller.isDeleting && controller.deleteTask == nil, "inactive host must stop repeated deletion")
            try expect(replacement.isCancelled, "inactive host must cancel replacement execution")
            try expect(controller.replacementID == replacementToken, "executor must retain ownership of safe cancellation rollback")
            try expect(appearance.isCancelled && controller.appearanceCheck == nil, "inactive host must cancel appearance recheck")
            try expect(controller.hintModel.state == .idle, "inactive host must invalidate translation")
            try expect(controller.pinyinBuffer == "nihao", "temporary inactivity must preserve uncommitted composition")
            controller.replacementID = nil
            controller.replacementTask = nil
            let actionCount = controller.actionCount
            controller.beginDeleting()
            controller.perform(.space)
            controller.synchronizeAfterHostChange()
            controller.updateHint()
            try await Task.sleep(nanoseconds: 530_000_000)
            try expect(controller.actionCount == actionCount, "inactive host must reject new and delayed input actions")
            try expect(controller.hintModel.state == .idle && translator.cancelled, "inactive host must not restart cancelled translation")

            NotificationCenter.default.post(name: .NSExtensionHostDidBecomeActive, object: nil)
            try expect(controller.hostActive, "retained visible controller must reactivate")
            controller.beginDeleting()
            try expect(controller.isDeleting, "reactivated controller must accept input")
            controller.stopDeleting()
            controller.viewWillDisappear(false)
            NotificationCenter.default.post(name: .NSExtensionHostDidBecomeActive, object: nil)
            try expect(!controller.hostActive && !controller.visible, "hidden controller must not reactivate")
        }
        let controller = LifecycleTestController()
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        controller.proxy.text = "你好"
        controller.displayedHint = LiveHintState(status: .ready, source: "你好", displayText: "Hello")
        controller.hintSnapshot = controller.documentSnapshot()
        controller.observedSnapshot = controller.documentSnapshot()
        let readySnapshot = controller.hintSnapshot
        try expect(controller.availableReplacement() != nil, "translation action must be available before page switch")
        for page in [KeyboardSurface.Action.numbers, .symbols, .letters] {
            controller.perform(page)
            try expect(controller.hintSnapshot == readySnapshot && controller.availableReplacement() != nil,
                       "switching key pages must preserve the current translation action")
            try expect(controller.availableAnalysisText() == "Hello", "switching pages must preserve learning access")
        }
        controller.isChinese = false
        controller.perform(.shift)
        try expect(controller.hintSnapshot == readySnapshot && controller.availableReplacement() != nil,
                   "English shift must preserve the current translation action")
        if let plan = controller.availableReplacement() {
            controller.proxy.text = plan.expectedCompletedSnapshot.before ?? ""
            controller.replacementUndo.record(plan, currentSnapshot: controller.documentSnapshot())
            try expect(controller.replacementUndo.isAvailable(currentSnapshot: controller.documentSnapshot()),
                       "undo setup must match the resulting host text")
            controller.perform(.numbers)
            try expect(controller.replacementUndo.isAvailable(currentSnapshot: controller.documentSnapshot()),
                       "key page switching must preserve an exact available undo")
            controller.perform(.insert("!"))
            try expect(!controller.replacementUndo.isAvailable(currentSnapshot: controller.documentSnapshot()),
                       "actual editing must still invalidate undo")
        } else { throw LifecycleFailure(message: "test needs an eligible replacement") }
        controller.viewWillDisappear(false)
        try await verifySpeechLifecycle(expect: expect)
        try await verifyDraftLifecycle(expect: expect)
        try verifyTabletGeometry(expect: expect)
        print("Keyboard controller: 2 notification paths and page/undo behavior, \(checks) checks passed")
    }

    @MainActor
    private static func verifyTabletGeometry(expect: (@autoclosure () -> Bool, String) throws -> Void) throws {
        let controller = LifecycleTestController()
        controller.traitOverrides.userInterfaceIdiom = .pad
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 810, height: 314)
        controller.updateHeight(for: 810)
        try expect(controller.layoutViewport(for: 810).isPad && !controller.layoutViewport(for: 810).compactKeys,
                   "Controller uses tablet traits instead of classifying 810pt width as phone landscape")
        try expect(controller.keyboardHeight?.constant == 314, "iPad controller requests full-size keyboard content")
        for _ in 0..<3 {
            controller.analysisExpanded = true
            controller.updateHeight(for: 810)
            try expect(controller.keyboardHeight?.constant == 540, "Detached tablet fallback requests half its 1080pt display")
            controller.analysisExpanded = false
            controller.updateHeight(for: 810)
            try expect(controller.keyboardHeight?.constant == 314, "Reopening does not accumulate tablet height")
        }
        controller.updateHeight(for: 320)
        try expect(controller.keyboardHeight?.constant == 263, "Narrow tablet window restores compact-width portrait key height")
        controller.traitOverrides.userInterfaceIdiom = .phone
        controller.updateHeight(for: 852)
        try expect(controller.keyboardHeight?.constant == 214, "iPhone landscape key height is unchanged")
    }

    @MainActor
    private static func verifyDraftLifecycle(expect: (@autoclosure () -> Bool, String) throws -> Void) async throws {
        let paragraphs = ["你好。", "这是伴语，一款可以边打字边学英语的键盘。",
                          "你可以照常输入中文，伴语会显示对应的英文表达，轻点单词或小喇叭就能听发音。"]
        let source = paragraphs.joined(separator: "\n\n")
        let translated = "Hello.\n\nThis is Banyu, a keyboard for learning English while typing.\n\nType Chinese as usual and tap words to hear English."
        let translator = LifecycleDraftTranslation(translated)
        let controller = LifecycleTestController()
        controller.hintModel = LiveHintModel(translator: translator, debounceNanoseconds: 0)
        controller.proxy.text = source
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        defer { controller.viewWillDisappear(false) }
        func waitForReady() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while controller.displayedHint.status != .ready {
                guard ContinuousClock.now < deadline else { throw LifecycleFailure(message: "multiline controller result timed out") }
                try await Task.sleep(for: .milliseconds(1))
            }
        }
        controller.updateHint()
        try await waitForReady()
        try expect(translator.requests == [source], "Controller sends all three paragraphs in one translation request")
        try expect(controller.displayedHint.source == source && controller.availableAnalysisText() == translated,
                   "Study receives the whole translated draft, preserving paragraph breaks")
        try expect(controller.availableReplacement()?.suffixToDelete == source,
                   "Use English targets the same complete draft as translation and study")
        try expect(controller.proxy.text == source, "Translation and preparation do not edit or send the host draft")

        controller.proxy.text = paragraphs[0]
        controller.proxy.following = "\n\n" + paragraphs.dropFirst().joined(separator: "\n\n")
        controller.updateHint()
        try await waitForReady()
        try expect(translator.requests.last == source, "A cursor moved between paragraphs still supplies the same draft")
        try expect(controller.availableReplacement() == nil, "No suffix replacement from the middle of a draft")

        controller.proxy.text = paragraphs[0] + "\n\n"
        controller.proxy.selection = paragraphs[1]
        controller.proxy.following = "\n\n" + paragraphs[2]
        controller.updateHint()
        try await waitForReady()
        try expect(translator.requests.last == paragraphs[1] && controller.displayedHint.source == paragraphs[1],
                   "A selected paragraph is sent alone, never omitted by joining its surroundings")
        try expect(controller.availableReplacement() == nil, "Selected text can be studied without authorizing suffix replacement")

        controller.proxy.selection = nil
        controller.proxy.following = nil
        controller.proxy.text = String(repeating: "文", count: 401)
        let calls = translator.requests.count
        controller.updateHint()
        try expect(controller.displayedHint.status == .inputLimited && translator.requests.count == calls,
                   "Oversized input is explained without a partial paid request")
        try expect(controller.availableAnalysisText() == nil && controller.availableReplacement() == nil,
                   "An oversized draft cannot retain previous learning or replacement actions")
        controller.proxy.text = ""
        controller.updateHint()
        try expect(controller.displayedHint == .idle, "Clearing the field clears the entire draft result")
    }

    private static func verifySpeechLifecycle(expect: (@autoclosure () -> Bool, String) throws -> Void) async throws {
        let controller = LifecycleTestController()
        let player = LifecycleSpeechPlayer()
        controller.speechSession = SpeechPlaybackSession(player: player)
        // Even a failed regression must never reach the real speech transport.
        controller.makeSpeechSynthesizer = { _ in LifecyclePendingSpeech() }
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        func prepare(_ provider: TranslationProvider, revision: String = "qwen-1", english: String = "Hello") {
            TranslationSettingsStore.shared.snapshot = .init(provider: provider, apiKey: "fixture-key", revision: revision)
            controller.reloadSpeechSettings()
            controller.proxy.text = "你好"
            controller.displayedHint = .init(status: .ready, source: "你好", displayText: english)
            controller.hintSnapshot = controller.documentSnapshot()
            controller.observedSnapshot = controller.documentSnapshot()
            controller.renderHint()
        }
        for provider in [TranslationProvider.apple, .custom] {
            prepare(provider)
            controller.toggleSpeech()
            try expect(controller.speechContext == nil && controller.speechSession.state == .idle,
                       "Apple/custom must not authorize retained Qwen credentials for speech")
        }
        prepare(.qwen)
        try expect(controller.speechContext?.english == "Hello", "Qwen exposes speech for the verified ready English")
        try expect(controller.speechSession.state == .idle && player.plays == 0,
                   "rendering and preparing learning must never generate or play speech automatically")

        func startPending() async -> LifecyclePendingSpeech {
            let synthesizer = LifecyclePendingSpeech()
            controller.speechSession.toggle(text: "Hello", configurationID: "qwen-1",
                                            scopeID: "Hello", synthesizer: synthesizer)
            for _ in 0..<20 where !synthesizer.started { await Task.yield() }
            return synthesizer
        }
        let cancelledByTap = await startPending()
        try expect(cancelledByTap.started, "speech must start before testing a second tap")
        controller.toggleSpeech() // It must stop, never call the newly constructed real service.
        try expect(controller.speechSession.state == .idle, "second speaker tap cancels generation")
        for _ in 0..<20 where !cancelledByTap.cancelled { await Task.yield() }
        try expect(cancelledByTap.cancelled, "speaker cancellation must reach the service")

        let cancelledByEdit = await startPending()
        controller.perform(.numbers)
        controller.perform(.symbols)
        controller.perform(.letters)
        try expect(controller.speechSession.state == .loading, "key page changes preserve the current speech request")
        controller.perform(.insert("!"))
        try expect(controller.speechSession.state == .idle && controller.speechContext == nil,
                   "editing stops speech and removes the old sentence context immediately")
        for _ in 0..<20 where !cancelledByEdit.cancelled { await Task.yield() }
        try expect(cancelledByEdit.cancelled, "editing cancels in-flight speech")

        for notification in [NSNotification.Name.NSExtensionHostWillResignActive,
                             NSNotification.Name.NSExtensionHostDidEnterBackground] {
            controller.hostActive = true
            prepare(.qwen)
            let pending = await startPending()
            NotificationCenter.default.post(name: notification, object: nil)
            try expect(controller.speechSession.state == .idle && controller.speechContext == nil,
                       "host deactivation stops and clears speech")
            for _ in 0..<20 where !pending.cancelled { await Task.yield() }
            try expect(pending.cancelled, "host deactivation cancels the service")
        }
        controller.hostActive = true
        prepare(.qwen)
        _ = await startPending()
        TranslationSettingsStore.shared.snapshot = .init(provider: .apple, apiKey: "fixture-key", revision: "apple-2")
        controller.toggleSpeech()
        try expect(controller.speechSession.state == .idle && controller.speechContext == nil,
                   "speaker tap revalidates settings and cannot reuse a key after switching to Apple")

        prepare(.qwen)
        _ = await startPending()
        controller.didReceiveMemoryWarning()
        try expect(controller.speechSession.state == .idle && controller.speechContext == nil,
                   "memory pressure releases speech and its cached data")
        prepare(.qwen)
        _ = await startPending()
        controller.viewWillDisappear(false)
        try expect(controller.speechSession.state == .idle && controller.speechContext == nil && player.plays == 0,
                   "dismissal clears speech; no fixture audio or stale result reaches playback")

        controller.visible = true
        controller.hostActive = true
        let english = "I'd like to set up a resource-intensive research platform."
        prepare(.qwen, english: english)
        controller.analysisEnglish = english
        controller.analysisSnapshot = controller.documentSnapshot()
        controller.analysisExpanded = true
        let immediate = LifecycleImmediateSpeech()
        controller.makeSpeechSynthesizer = { _ in immediate }
        let untouchedHost = controller.documentSnapshot()
        func settleSpeech() async {
            for _ in 0..<30 { await Task.yield() }
        }
        controller.toggleSpeech("set up")
        await settleSpeech()
        try expect(immediate.requests == ["set up"] && controller.speechSession.currentText == "set up",
                   "real controller reads the chosen original phrase, not the whole sentence")
        controller.toggleSpeech("resource-intensive")
        await settleSpeech()
        try expect(immediate.requests == ["set up", "resource-intensive"]
                   && controller.speechSession.currentText == "resource-intensive",
                   "selecting another word switches the playing target")
        controller.toggleSpeech("set up")
        await settleSpeech()
        try expect(immediate.requests.count == 2 && player.plays == 3,
                   "returning to an earlier phrase reuses this sentence's cached audio")
        controller.toggleSpeech()
        await settleSpeech()
        try expect(immediate.requests.last == english && controller.speechSession.currentText == english,
                   "whole-sentence button switches from a snippet to the complete translation")
        try expect(controller.documentSnapshot() == untouchedHost,
                   "word, phrase and whole-sentence playback do not edit or move host input")
        let requests = immediate.requests.count
        for snippet in ["an invented phrase", "", " ", "."] {
            controller.toggleSpeech(snippet)
        }
        await settleSpeech()
        try expect(immediate.requests.count == requests,
                   "invalid or punctuation-only snippets cannot start generation")
        controller.analysisExpanded = false
        controller.toggleSpeech("research")
        await settleSpeech()
        try expect(immediate.requests.count == requests,
                   "a callback after collapse cannot synthesize another word")
        controller.analysisExpanded = true
        controller.proxy.text += "!"
        controller.toggleSpeech("research")
        await settleSpeech()
        try expect(immediate.requests.count == requests && controller.speechSession.state == .idle,
                   "an outdated host snapshot cancels old playback and rejects the selection")
        for provider in [TranslationProvider.apple, .custom] {
            prepare(provider, english: english)
            controller.toggleSpeech("research")
        }
        await settleSpeech()
        try expect(immediate.requests.count == requests,
                   "snippet callbacks cannot use retained Qwen keys in another provider")
        controller.viewWillDisappear(false)
        TranslationSettingsStore.shared.snapshot = .init(provider: .apple)
    }
}

@main
@MainActor
final class LifecycleHarnessApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Task {
            do { try await KeyboardViewController.verifyLifecycle(); exit(0) }
            catch { print("Keyboard lifecycle FAILED: \(error)"); exit(1) }
        }
        return true
    }
}
