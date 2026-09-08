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
private final class LifecycleSpeechPlayer: SpeechAudioPlaying {
    var onStop: (() -> Void)?
    var plays = 0
    func playLoop(_ data: Data) throws { plays += 1 }
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
private final class LifecycleDocumentProxy: NSObject, UITextDocumentProxy {
    var text = ""
    let documentIdentifier = UUID()
    var documentContextBeforeInput: String? { text }
    var documentContextAfterInput: String? { nil }
    var selectedText: String? { nil }
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
        print("Keyboard controller: 2 notification paths and page/undo behavior, \(checks) checks passed")
    }

    @MainActor
    private static func verifySpeechLifecycle(expect: (@autoclosure () -> Bool, String) throws -> Void) async throws {
        let controller = LifecycleTestController()
        let player = LifecycleSpeechPlayer()
        controller.speechSession = SpeechPlaybackSession(player: player)
        controller.loadViewIfNeeded()
        controller.viewWillAppear(false)
        func prepare(_ provider: TranslationProvider, revision: String = "qwen-1") {
            TranslationSettingsStore.shared.snapshot = .init(provider: provider, apiKey: "fixture-key", revision: revision)
            controller.reloadSpeechSettings()
            controller.proxy.text = "你好"
            controller.displayedHint = .init(status: .ready, source: "你好", displayText: "Hello")
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
            controller.speechSession.toggle(text: "Hello", configurationID: "qwen-1", synthesizer: synthesizer)
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
