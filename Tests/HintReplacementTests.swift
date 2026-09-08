import Foundation

private struct ReplacementTestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class ReplacementHost {
    var state: HintDocumentSnapshot
    var deleteCalls = 0
    var insertions: [String] = []
    var delay: Duration = .zero
    var ignoreDeletes = false
    var onDelete: (() -> Void)?

    init(_ state: HintDocumentSnapshot) { self.state = state }

    func deleteBackward() {
        deleteCalls += 1
        if !ignoreDeletes {
            if delay == .zero {
                applyDelete()
            } else {
                Task {
                    try? await Task.sleep(for: delay)
                    applyDelete()
                }
            }
        }
        onDelete?()
    }

    private func applyDelete() {
        state = copy(before: String((state.before ?? "").dropLast()))
    }

    func insertText(_ text: String) {
        insertions.append(text)
        if delay == .zero {
            state = copy(before: (state.before ?? "") + text)
        } else {
            Task {
                try? await Task.sleep(for: delay)
                state = copy(before: (state.before ?? "") + text)
            }
        }
    }

    func copy(before: String, revision: UInt64? = nil) -> HintDocumentSnapshot {
        HintDocumentSnapshot(documentID: state.documentID, revision: revision ?? state.revision,
                             before: before, after: state.after, selectedText: state.selectedText,
                             isContextTruncated: state.isContextTruncated)
    }

    func run(_ plan: HintReplacementPlan) async -> HintReplacementExecutionResult {
        await HintReplacementExecutor.execute(plan: plan, snapshot: { self.state },
                                               deleteBackward: { self.deleteBackward() },
                                               insertText: { self.insertText($0) })
    }
}

@main
@MainActor
struct HintReplacementTests {
    private static let document = UUID()

    static func main() async throws {
        try plannerTests()
        try snapshotAndStepTests()
        try undoTests()
        try await synchronousAndDelayedTests()
        try await interruptionTests()
        print("PASS: suffix replacement — mixed input, unchanged English, exact snapshots, graphemes, one-use undo, synchronous/delayed host acknowledgement, mutation, timeout and cancellation")
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw ReplacementTestFailure(description: message) }
    }

    private static func snapshot(_ before: String?, after: String? = "", selected: String? = nil,
                                 id: UUID = document, revision: UInt64 = 3,
                                 truncated: Bool = false) -> HintDocumentSnapshot {
        HintDocumentSnapshot(documentID: id, revision: revision, before: before, after: after,
                             selectedText: selected, isContextTruncated: truncated)
    }

    private static func plan(_ before: String?, source: String = "你好", translated: String = "Hello",
                             after: String? = "", selected: String? = nil,
                             truncated: Bool = false) -> HintReplacementPlan? {
        let state = snapshot(before, after: after, selected: selected, truncated: truncated)
        return HintReplacementPlanner.plan(readySource: source, translation: translated,
                                            readySnapshot: state, currentSnapshot: state)
    }

    private static func require(_ plan: HintReplacementPlan?, _ message: String) throws -> HintReplacementPlan {
        guard let plan else { throw ReplacementTestFailure(description: message) }
        return plan
    }

    private static func plannerTests() throws {
        let simple = try require(plan("你好"), "A short exact suffix must be replaceable")
        try expect(simple.deleteCount == 2 && simple.expectedCompletedSnapshot.before == "Hello",
                   "Replace only the exact source")
        let repeated = try require(plan("你好。你好。", source: "你好。"), "Repeated sentences must be supported")
        try expect(repeated.expectedCompletedSnapshot.before == "你好。Hello", "Never remove an earlier repeated sentence")
        let leading = try require(plan(" \t你好"), "Leading whitespace belongs to the prefix")
        try expect(leading.expectedCompletedSnapshot.before == " \tHello", "Preserve prefix whitespace exactly")
        try expect(plan("你好 \t") == nil, "Do not guess a deletion count after trimming trailing whitespace")
        let exactSpaces = try require(plan("你好 \t", source: "你好 \t"), "An explicitly captured suffix may contain whitespace")
        try expect(exactSpaces.suffixToDelete == "你好 \t", "Capture an exact suffix, not a trimmed count")
        try expect(plan(nil) == nil, "Unknown left context must be rejected")
        let unknownRight = try require(plan("你好", after: nil), "A known left suffix does not require full-field access")
        try expect(unknownRight.expectedCompletedSnapshot.after == nil, "Unknown right context remains unknown")
        try expect(plan("你好", after: "后面的文字") == nil, "A known middle-of-sentence cursor must be rejected")
        try expect(plan("你好", selected: "好") == nil, "Selection must disable replacement")
        try expect(plan("你好", selected: "") != nil, "An empty selection means no selected text")
        try expect(plan("你好", truncated: true) == nil, "Explicitly truncated context must be rejected")
        try expect(plan("你好", source: "") == nil && plan("你好", translated: " \n") == nil,
                   "Reject empty source and translation")
        try expect(plan("你好", translated: "你好") == nil && plan("你好", translated: " 你好 ") == nil,
                   "Reject unchanged translations including whitespace-only differences")
        for source in ["hello，明天见", "Please 帮我一下", "meeting改到明天吧"] {
            try expect(plan(source, source: source, translated: "A translated sentence.") != nil,
                       "Mixed-language input remains replaceable even when language detection says English")
        }
        try expect(plan("Hello", source: "Hello", translated: "Hello") == nil,
                   "Unchanged English must not expose an unnecessary replacement")
        try expect(plan("你好", source: "您好") == nil, "A nonmatching source must not generate an edit")
        let edge = String(repeating: "文", count: 399)
        try expect(plan(edge, source: edge, translated: "Text") != nil, "399 characters remain within the bound")
        try expect(plan(edge + "文", source: edge + "文") == nil, "The 400-character boundary may be truncated")
        try expect(plan(String(repeating: "。", count: 398) + "你好") == nil,
                   "Saturated observed context remains unavailable even for a short suffix")
        try expect(plan("你好", translated: String(repeating: "a", count: 400)) == nil,
                   "Translation deletion for undo must also be bounded")
        try expect(plan(String(repeating: "。", count: 397) + "你好", translated: "Hello") == nil,
                   "The expected undo snapshot must fit the same bound")
        try expect(plan("🇨你好", translated: "🇳") == nil,
                   "An inserted regional indicator must not merge with a prefix that undo could then remove")
        try expect(plan("a你好", translated: "\u{301}Hello") == nil,
                   "A leading combining mark must not absorb the preceding original grapheme")
        print("PASS: planning — suffix-only, repeats, whitespace policy, nil context, selection and 400-character guards")
    }

    private static func snapshotAndStepTests() throws {
        let source = "你好👨‍👩‍👧‍👦👍🏽e\u{301}"
        let original = "上一句。 \t" + source
        let edit = try require(plan(original, source: source, translated: "Hello 👋"), "Unicode source plan")
        try expect(edit.deleteCount == 5, "Deletion count must use extended grapheme clusters")
        for index in 0..<edit.deleteCount {
            guard let expected = edit.expectedSnapshot(afterDeleting: index) else {
                throw ReplacementTestFailure(description: "Expected step snapshot must exist")
            }
            try expect(edit.canDeleteNext(deletedCount: index, currentSnapshot: expected), "Each exact step must be permitted")
            try expect(!edit.canDeleteNext(deletedCount: index, currentSnapshot: snapshot("unrelated")),
                       "An unexpected partial edit must stop deletion")
        }
        try expect(edit.expectedSnapshot(afterDeleting: -1) == nil &&
                   edit.expectedSnapshot(afterDeleting: edit.deleteCount + 1) == nil,
                   "Out-of-range step counts must be rejected")
        try expect(!edit.canDeleteNext(deletedCount: edit.deleteCount, currentSnapshot: snapshot("上一句。 \t")),
                   "No extra deletion may cross the source boundary")
        try expect(edit.canInsertReplacement(currentSnapshot: snapshot("上一句。 \t")), "Insert only at the verified prefix")
        try expect(!edit.canInsertReplacement(currentSnapshot: snapshot("上一句。 \tX")), "Never insert after a host edit")

        let ready = snapshot("你好")
        let changes = [snapshot("你好", id: UUID()), snapshot("你好", revision: 4),
                       snapshot("您好"), snapshot("你好", after: "后"), snapshot("你好", after: nil),
                       snapshot("你好", selected: "好"), snapshot("你好", truncated: true)]
        for changed in changes {
            try expect(HintReplacementPlanner.plan(readySource: "你好", translation: "Hello",
                                                   readySnapshot: ready, currentSnapshot: changed) == nil,
                       "Document, revision, cursor or text changes invalidate an old translation snapshot")
        }
        let decomposed = snapshot("e\u{301}")
        let composed = snapshot("é")
        try expect(decomposed != composed, "Canonical equivalence must not conceal a host encoding change")
        try expect(plan("é", source: "e\u{301}", translated: "accent") == nil,
                   "Suffix matching must preserve the exact original encoding")
        print("PASS: snapshots and steps — document/revision changes, nil/empty distinction, exact Unicode and deletion bounds")
    }

    private static func undoTests() throws {
        let edit = try require(plan("前句。你好👨‍👩‍👧‍👦", source: "你好👨‍👩‍👧‍👦", translated: "Hello 👋"), "Undo input")
        var undo = HintReplacementUndo()
        try expect(!undo.record(edit, currentSnapshot: edit.originalSnapshot), "Do not offer undo for an unapplied plan")
        try expect(undo.record(edit, currentSnapshot: edit.expectedCompletedSnapshot), "Record verified completion")
        let reverse = try require(undo.takePlan(currentSnapshot: edit.expectedCompletedSnapshot), "Take matching undo")
        try expect(reverse.expectedCompletedSnapshot == edit.originalSnapshot, "Undo must restore exact bytes and prefix")
        try expect(undo.takePlan(currentSnapshot: edit.expectedCompletedSnapshot) == nil, "Undo may be taken only once")
        undo.record(edit, currentSnapshot: edit.expectedCompletedSnapshot)
        try expect(!undo.isAvailable(currentSnapshot: snapshot("前句。Hello 👋", revision: 4)), "An intervening edit invalidates undo")
        try expect(undo.takePlan(currentSnapshot: snapshot("前句。Hello 👋", revision: 4)) == nil,
                   "Stale undo cannot edit the document")
        try expect(undo.takePlan(currentSnapshot: edit.expectedCompletedSnapshot) == nil,
                   "A rejected undo must not become valid again when text happens to match")
        undo.record(edit, currentSnapshot: edit.expectedCompletedSnapshot)
        undo.invalidate()
        try expect(!undo.isAvailable(currentSnapshot: edit.expectedCompletedSnapshot), "Lifecycle invalidation clears original text")
        print("PASS: undo — only verified completion, exact restoration, one use and stale snapshot invalidation")
    }

    private static func synchronousAndDelayedTests() async throws {
        let edit = try require(plan("前句。你好👨‍👩‍👧‍👦", source: "你好👨‍👩‍👧‍👦", translated: "Hello 👋"), "Execution plan")
        for delay in [Duration.zero, .milliseconds(8)] {
            let host = ReplacementHost(edit.originalSnapshot)
            host.delay = delay
            let result = await host.run(edit)
            try expect(result == .completed(edit.expectedCompletedSnapshot), "Immediate and delayed hosts must complete")
            try expect(host.deleteCalls == edit.deleteCount && host.insertions == [edit.replacementString],
                       "Waiting for acknowledgement must never repeat a delete or insertion")
            var undo = HintReplacementUndo()
            undo.record(edit, currentSnapshot: host.state)
            let reverse = try require(undo.takePlan(currentSnapshot: host.state), "Execution undo")
            let undoResult = await host.run(reverse)
            try expect(undoResult == .completed(edit.originalSnapshot), "Execute one-use undo through the same checks")
        }
        let nilEdit = try require(plan("你好", after: nil), "Nil-right host plan")
        let nilHost = ReplacementHost(nilEdit.originalSnapshot)
        let nilResult = await nilHost.run(nilEdit)
        try expect(nilResult == .completed(nilEdit.expectedCompletedSnapshot), "Nil right context stays stable across operations")
        print("PASS: executor — immediate and delayed delete/insert acknowledgement, exact command counts and executable undo")
    }

    private static func interruptionTests() async throws {
        let edit = try require(plan("前句。你好👨‍👩‍👧‍👦", source: "你好👨‍👩‍👧‍👦"), "Interruption plan")
        let changed = ReplacementHost(edit.originalSnapshot)
        changed.onDelete = { changed.state = changed.copy(before: "外部新内容", revision: 4) }
        let changedResult = await changed.run(edit)
        try expect(changedResult == .aborted && changed.deleteCalls == 1 && changed.insertions.isEmpty,
                   "An external mutation must immediately stop without guessed rollback")

        let timeout = ReplacementHost(edit.originalSnapshot)
        timeout.ignoreDeletes = true
        let clock = ContinuousClock()
        let started = clock.now
        let timeoutResult = await timeout.run(edit)
        try expect(timeoutResult == .aborted && timeout.deleteCalls == 1 && timeout.insertions.isEmpty,
                   "An unacknowledged command times out without repetition or unsafe restoration")
        try expect(started.duration(to: clock.now) < .seconds(1), "An acknowledgement timeout must remain bounded")

        let cancelled = ReplacementHost(edit.originalSnapshot)
        var task: Task<HintReplacementExecutionResult, Never>?
        cancelled.onDelete = { if cancelled.deleteCalls == 2 { task?.cancel() } }
        task = Task { await cancelled.run(edit) }
        let cancelledResult = await task!.value
        try expect(cancelledResult == .restored && cancelled.state == edit.originalSnapshot,
                   "Cancellation after acknowledged deletion restores only the verified deleted suffix")
        try expect(cancelled.deleteCalls == 2 && cancelled.insertions == [String(edit.suffixToDelete.suffix(2))],
                   "Partial restoration must append exact deleted graphemes in original order")

        let pending = ReplacementHost(edit.originalSnapshot)
        pending.delay = .milliseconds(20)
        var pendingTask: Task<HintReplacementExecutionResult, Never>?
        pending.onDelete = { pendingTask?.cancel() }
        pendingTask = Task { await pending.run(edit) }
        let pendingResult = await pendingTask!.value
        try expect(pendingResult == .aborted && pending.insertions.isEmpty,
                   "Cancellation with an unacknowledged host command must not issue a competing rollback")
        try await Task.sleep(for: .milliseconds(30))
        try expect(pending.deleteCalls == 1 && pending.state == edit.expectedSnapshot(afterDeleting: 1),
                   "A delayed host may finish one issued command, but the executor issues no more")
        print("PASS: interruption — host mutation, 150 ms timeout, verified partial restoration and pending-command cancellation")
    }
}
