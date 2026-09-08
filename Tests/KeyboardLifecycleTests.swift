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
        print("Keyboard controller: 2 notification paths and page/undo behavior, \(checks) checks passed")
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
