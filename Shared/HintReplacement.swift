import Foundation

/// Only the context the host proxy provides, never a claim to the whole document.
/// Advance revision for external edits, cursor changes, or a new interaction.
struct HintDocumentSnapshot: Equatable, Sendable {
    let documentID: UUID
    let revision: UInt64
    let before: String?
    let after: String?
    let selectedText: String?
    let isContextTruncated: Bool

    init(documentID: UUID, revision: UInt64 = 0, before: String?, after: String?,
         selectedText: String?, isContextTruncated: Bool = false) {
        self.documentID = documentID
        self.revision = revision
        self.before = before
        self.after = after
        self.selectedText = selectedText
        self.isContextTruncated = isContextTruncated
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.documentID == rhs.documentID && lhs.revision == rhs.revision &&
        lhs.isContextTruncated == rhs.isContextTruncated &&
        exact(lhs.before, rhs.before) && exact(lhs.after, rhs.after) &&
        exact(lhs.selectedText, rhs.selectedText)
    }

    // String equality allows canonical equivalence. An edit snapshot must also
    // detect a host changing the actual encoding of an otherwise equal grapheme.
    private static func exact(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case (.some(let left), .some(let right)): left.utf8.elementsEqual(right.utf8)
        default: false
        }
    }

    fileprivate func replacingBefore(_ text: String) -> Self {
        Self(documentID: documentID, revision: revision, before: text, after: after,
             selectedText: selectedText, isContextTruncated: isContextTruncated)
    }
}

/// An in-memory, exact suffix edit. The caller must check immediately before
/// EVERY deleteBackward and once more before inserting. Counts are Swift
/// Characters; if a host deletes differently, the next check refuses to continue.
struct HintReplacementPlan: Sendable {
    let originalSnapshot: HintDocumentSnapshot
    let suffixToDelete: String
    let replacementString: String

    var deleteCount: Int { suffixToDelete.count }

    fileprivate init(snapshot: HintDocumentSnapshot, suffix: String, replacement: String) {
        originalSnapshot = snapshot
        suffixToDelete = suffix
        replacementString = replacement
    }

    func expectedSnapshot(afterDeleting deletedCount: Int) -> HintDocumentSnapshot? {
        guard deletedCount >= 0, deletedCount <= deleteCount,
              let before = originalSnapshot.before else { return nil }
        return originalSnapshot.replacingBefore(String(before.dropLast(deletedCount)))
    }

    func canDeleteNext(deletedCount: Int, currentSnapshot: HintDocumentSnapshot) -> Bool {
        guard deletedCount >= 0, deletedCount < deleteCount,
              let expected = expectedSnapshot(afterDeleting: deletedCount) else { return false }
        return currentSnapshot == expected
    }

    func canInsertReplacement(currentSnapshot: HintDocumentSnapshot) -> Bool {
        currentSnapshot == expectedSnapshot(afterDeleting: deleteCount)
    }

    var expectedPostReplacementSnapshot: HintDocumentSnapshot {
        // Plans can only be constructed from a non-nil before context.
        let prefix = String((originalSnapshot.before ?? "").dropLast(deleteCount))
        return originalSnapshot.replacingBefore(prefix + replacementString)
    }

    var expectedCompletedSnapshot: HintDocumentSnapshot { expectedPostReplacementSnapshot }

    func canValidateCompleted(currentSnapshot: HintDocumentSnapshot) -> Bool {
        currentSnapshot == expectedCompletedSnapshot
    }
}

enum HintReplacementPlanner {
    /// Keep edits below the 400-character observation budget. Translation may
    /// contain multiple paragraphs, but edits remain deliberately limited
    /// to short, fully observed proxy contexts before AND after replacement.
    static let maximumCharacters = 400

    static func plan(readySource: String, translation: String,
                     readySnapshot: HintDocumentSnapshot,
                     currentSnapshot: HintDocumentSnapshot) -> HintReplacementPlan? {
        guard readySnapshot == currentSnapshot,
              !currentSnapshot.isContextTruncated,
              // Some hosts supply nil at the end. We can still edit the proven
              // left suffix, without claiming to know the entire field. Keep
              // nil distinct from empty in every subsequent snapshot check.
              currentSnapshot.after?.isEmpty != false,
              currentSnapshot.selectedText?.isEmpty != false,
              let before = currentSnapshot.before,
              !readySource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              readySource.trimmingCharacters(in: .whitespacesAndNewlines) !=
                translation.trimmingCharacters(in: .whitespacesAndNewlines),
              readySource.count < maximumCharacters,
              translation.count < maximumCharacters,
              before.count < maximumCharacters,
              before.hasSuffix(readySource),
              String(before.suffix(readySource.count)).utf8.elementsEqual(readySource.utf8)
        else { return nil }

        // Do not trim before and then delete a count derived from the trimmed
        // source: that can remove the wrong characters. Trailing spaces not in
        // readySource disable replacement; all original text stays untouched.
        let plan = HintReplacementPlan(snapshot: currentSnapshot, suffix: readySource,
                                       replacement: translation)
        guard let resultBefore = plan.expectedPostReplacementSnapshot.before,
              resultBefore.count < maximumCharacters,
              // A leading combining mark or regional indicator can merge with
              // the prefix into one grapheme. Undo must never delete that prefix.
              String(resultBefore.suffix(translation.count)).utf8.elementsEqual(translation.utf8)
        else { return nil }
        return plan
    }
}

/// One use, memory only. Any mismatch consumes the stored opportunity as well.
/// Do not record before actual replacement has been verified against the proxy.
struct HintReplacementUndo: Sendable {
    private var inversePlan: HintReplacementPlan?

    @discardableResult
    mutating func record(_ appliedPlan: HintReplacementPlan,
                         currentSnapshot: HintDocumentSnapshot) -> Bool {
        inversePlan = nil
        guard currentSnapshot == appliedPlan.expectedPostReplacementSnapshot else { return false }
        inversePlan = HintReplacementPlan(snapshot: currentSnapshot,
                                          suffix: appliedPlan.replacementString,
                                          replacement: appliedPlan.suffixToDelete)
        return true
    }

    func isAvailable(currentSnapshot: HintDocumentSnapshot) -> Bool {
        inversePlan?.originalSnapshot == currentSnapshot
    }

    mutating func takePlan(currentSnapshot: HintDocumentSnapshot) -> HintReplacementPlan? {
        let plan = inversePlan
        inversePlan = nil
        guard plan?.originalSnapshot == currentSnapshot else { return nil }
        return plan
    }

    mutating func invalidate() {
        inversePlan = nil
    }
}

enum HintReplacementExecutionResult: Equatable, Sendable {
    case completed(HintDocumentSnapshot)
    case restored
    case aborted
}

/// A host command is issued at most once. Delayed acknowledgement only polls;
/// it never repeats a deletion. The caller blocks other keyboard edit actions
/// during this operation and cancels its Task on document changes or dismissal.
@MainActor
enum HintReplacementExecutor {
    private enum Acknowledgement {
        case acknowledged, cancelled, timedOut, changed
    }

    static func execute(
        plan: HintReplacementPlan,
        snapshot: @MainActor () -> HintDocumentSnapshot,
        deleteBackward: @MainActor () -> Void,
        insertText: @MainActor (String) -> Void
    ) async -> HintReplacementExecutionResult {
        var acknowledgedDeletions = 0
        while acknowledgedDeletions < plan.deleteCount {
            if Task.isCancelled {
                return await restore(plan: plan, deletedCount: acknowledgedDeletions,
                                     snapshot: snapshot, insertText: insertText)
            }
            let previous = snapshot()
            guard plan.canDeleteNext(deletedCount: acknowledgedDeletions, currentSnapshot: previous),
                  let expected = plan.expectedSnapshot(afterDeleting: acknowledgedDeletions + 1)
            else { return .aborted }
            deleteBackward()
            let acknowledgement = await waitFor(expected, previous: previous, snapshot: snapshot)
            guard acknowledgement == .acknowledged else {
                // If the command has not been acknowledged, it may still be in
                // flight. Never append a guessed rollback over that uncertainty.
                if snapshot() == expected {
                    return await restore(plan: plan, deletedCount: acknowledgedDeletions + 1,
                                         snapshot: snapshot, insertText: insertText)
                }
                return .aborted
            }
            acknowledgedDeletions += 1
        }
        if Task.isCancelled {
            return await restore(plan: plan, deletedCount: acknowledgedDeletions,
                                 snapshot: snapshot, insertText: insertText)
        }
        let previous = snapshot()
        guard plan.canInsertReplacement(currentSnapshot: previous) else { return .aborted }
        insertText(plan.replacementString)
        let acknowledgement = await waitFor(plan.expectedCompletedSnapshot, previous: previous,
                                            snapshot: snapshot)
        if acknowledgement == .acknowledged {
            return .completed(plan.expectedCompletedSnapshot)
        }
        // The insertion may still be pending: no extra insertion or rollback.
        return .aborted
    }

    private static func waitFor(
        _ expected: HintDocumentSnapshot,
        previous: HintDocumentSnapshot,
        snapshot: @MainActor () -> HintDocumentSnapshot,
        allowCancelledTask: Bool = false
    ) async -> Acknowledgement {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(150))
        while true {
            let current = snapshot()
            if current == expected { return .acknowledged }
            if current != previous { return .changed }
            if Task.isCancelled && !allowCancelledTask { return .cancelled }
            if clock.now >= deadline { return .timedOut }
            // Restoration may run after cancellation. A continuation keeps its
            // bounded polling from turning into a cancelled Task.sleep busy loop.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) {
                    continuation.resume()
                }
            }
        }
    }

    private static func restore(
        plan: HintReplacementPlan,
        deletedCount: Int,
        snapshot: @MainActor () -> HintDocumentSnapshot,
        insertText: @MainActor (String) -> Void
    ) async -> HintReplacementExecutionResult {
        guard deletedCount > 0,
              let partial = plan.expectedSnapshot(afterDeleting: deletedCount),
              snapshot() == partial else { return .aborted }
        insertText(String(plan.suffixToDelete.suffix(deletedCount)))
        let acknowledgement = await waitFor(plan.originalSnapshot, previous: partial,
                                            snapshot: snapshot, allowCancelledTask: true)
        return acknowledgement == .acknowledged ? .restored : .aborted
    }
}
