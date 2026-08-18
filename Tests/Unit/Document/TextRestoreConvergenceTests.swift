/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

/// Ports: `packages/sdk/test/unit/document/text_restore_convergence_test.ts`
/// from yorkie-js-sdk v0.7.13 (yorkie-js-sdk#1293 "Identity-preserving
/// restore for Text undo/redo").
///
/// Before this feature, undoing a delete replayed the delete's *reverse
/// operation* as a fresh insert. When two replicas concurrently undo
/// *overlapping* deletes, replaying both reverse-inserts independently
/// duplicates the overlap instead of reviving the original identity-addressed
/// content once — "0123456789" becomes something like "01234545 6789" (the
/// overlap doubled). Identity-preserving restore reconstructs the original
/// span by tombstoned-node identity, so a set union of the two restores
/// converges to exactly "0123456789" regardless of undo order.

private let actorA1: ActorID = "000000000000000000000001"
private let actorA2: ActorID = "000000000000000000000002"

/// Exchanges pending local changes between two in-process documents,
/// mimicking a server round-trip without serialization (so restore
/// metadata that never crosses the wire in a real client survives — this
/// suite only needs identical in-memory convergence, not wire fidelity).
/// Mirrors the helper in `GCSplitLeakTests.swift`; kept local so the two
/// suites stay independent.
@MainActor
private func crossSync(_ d1: Document, _ d2: Document) throws {
    let p1 = d1.createChangePack()
    let p2 = d2.createChangePack()

    try d2.applyChangePack(ChangePack(key: p1.getDocumentKey(),
                                       checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                       isRemoved: false,
                                       changes: p1.getChanges(),
                                       versionVector: VersionVector.initial))
    try d1.applyChangePack(ChangePack(key: p2.getDocumentKey(),
                                       checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                       isRemoved: false,
                                       changes: p2.getChanges(),
                                       versionVector: VersionVector.initial))

    func ack(_ pack: ChangePack) -> ChangePack {
        let changes = pack.getChanges()
        let lastSeq = changes.last?.id.getClientSeq() ?? 0
        return ChangePack(key: pack.getDocumentKey(),
                           checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
                           isRemoved: false,
                           changes: [],
                           versionVector: VersionVector.initial)
    }
    try d1.applyChangePack(ack(p1))
    try d2.applyChangePack(ack(p2))
}

/// Builds two replicas that both hold "0123456789", then concurrently delete
/// overlapping ranges — d1 deletes "45" (indices 4..6), d2 deletes the
/// superset "234567" (indices 2..8) — and cross-syncs to the converged
/// "0189". Each replica keeps its own delete on its own undo stack.
@MainActor
private func buildOverlappingDeletes() throws -> (Document, Document) {
    let d1 = Document(key: "test-doc")
    let d2 = Document(key: "test-doc")
    d1.setActor(actorA1)
    d2.setActor(actorA2)

    try d1.update { root, _ in
        root.text = JSONText()
        _ = (root.text as? JSONText)?.edit(0, 0, "0123456789")
    }
    try crossSync(d1, d2)

    try d1.update { root, _ in _ = (root.text as? JSONText)?.edit(4, 6, "") } // delete "45"
    try d2.update { root, _ in _ = (root.text as? JSONText)?.edit(2, 8, "") } // delete "234567"
    try crossSync(d1, d2)

    let text1 = (d1.getRoot().text as? JSONText)?.toString
    let text2 = (d2.getRoot().text as? JSONText)?.toString
    XCTAssertEqual(text1, "0189")
    XCTAssertEqual(text2, text1)

    return (d1, d2)
}

final class TextRestoreConvergenceTests: XCTestCase {
    /// The feature's motivating case: two clients concurrently undo
    /// overlapping deletions. The undos are identity-addressed, so restoring
    /// both must revive the original insertion exactly once (a set union of
    /// the two restored ranges), converging to identical content and
    /// identical node ids on both replicas regardless of the order the
    /// restores are applied.
    @MainActor
    private func runBothUndos(undoD1First: Bool) throws -> (Document, Document) {
        let (d1, d2) = try buildOverlappingDeletes()
        if undoD1First {
            try d1.undo()
            try crossSync(d1, d2)
            try d2.undo()
        } else {
            try d2.undo()
            try crossSync(d1, d2)
            try d1.undo()
        }
        try crossSync(d1, d2)
        return (d1, d2)
    }

    @MainActor
    func test_converges_when_both_replicas_undo_overlapping_deletes_d1_first() throws {
        // given / when
        let (d1, d2) = try self.runBothUndos(undoD1First: true)

        // then — the overlap must be revived exactly once, not duplicated.
        XCTAssertEqual((d1.getRoot().text as? JSONText)?.toString, "0123456789")
        XCTAssertEqual(
            (d1.getRoot().text as? JSONText)?.toTestString,
            (d2.getRoot().text as? JSONText)?.toTestString,
            "both replicas must converge to identical content AND node ids"
        )
    }

    @MainActor
    func test_converges_to_the_same_state_under_the_opposite_undo_order_d2_first() throws {
        // given / when — run the scenario under both undo orders independently.
        let (a1, a2) = try self.runBothUndos(undoD1First: true)
        let (b1, b2) = try self.runBothUndos(undoD1First: false)

        // then — both orders converge to the same fully-restored content, and
        // each pair agrees on node identity with its own peer.
        XCTAssertEqual((a1.getRoot().text as? JSONText)?.toString, "0123456789")
        XCTAssertEqual((b1.getRoot().text as? JSONText)?.toString, "0123456789")
        XCTAssertEqual(
            (a1.getRoot().text as? JSONText)?.toTestString,
            (a2.getRoot().text as? JSONText)?.toTestString
        )
        XCTAssertEqual(
            (b1.getRoot().text as? JSONText)?.toTestString,
            (b2.getRoot().text as? JSONText)?.toTestString
        )
    }

    @MainActor
    func test_purges_symmetrically_with_docSize_gc_drained_after_both_undos() throws {
        // given
        let (d1, d2) = try self.runBothUndos(undoD1First: true)
        let vector = maxVectorOf(actors: [actorA1, actorA2])

        // when
        let purged1 = d1.garbageCollect(minSyncedVersionVector: vector)
        let purged2 = d2.garbageCollect(minSyncedVersionVector: vector)

        // then
        XCTAssertEqual(purged1, purged2, "both replicas must purge the same count")
        XCTAssertEqual(d1.getGarbageLength(), 0)
        XCTAssertEqual(d2.getGarbageLength(), 0)

        for d in [d1, d2] {
            XCTAssertEqual(d.getDocSize().gc, DataSize(data: 0, meta: 0), "every revived node must leave docSize.gc empty")
        }
    }
}

/// Ports: "identity-preserving restore GC accounting" from the same JS file.
///
/// `unregisterGCPair` (revive) must reverse `registerGCPair` (tombstone) bit
/// for bit, including the `timeTicketSize` meta term, or `docSize` drifts
/// across undo/redo cycles. The anchor is the post-delete state, NOT the
/// pristine pre-delete one: deleting "45" splits the insertion into
/// "0123"|"45"|"6789", and reviving un-tombstones "45" without re-merging the
/// splits, so the extra fragment metadata legitimately persists. That
/// fragmentation is orthogonal to GC accounting; what must be exactly
/// reversible is the gc<->live movement, which this pins by round-tripping
/// the cycle.
final class TextRestoreGCAccountingTests: XCTestCase {
    @MainActor
    func test_reverses_gc_accounting_exactly_across_delete_undo_redo_undo() throws {
        // given
        let doc = Document(key: "test-doc")
        try doc.update { root, _ in
            root.text = JSONText()
            _ = (root.text as? JSONText)?.edit(0, 0, "0123456789")
        }

        // when — delete "45" tombstones the split-off piece: registerGCPair.
        try doc.update { root, _ in _ = (root.text as? JSONText)?.edit(4, 6, "") }
        let deleted = doc.getDocSize()

        // then
        XCTAssertNotEqual(deleted.gc, DataSize(data: 0, meta: 0), "delete registers GC")

        // when — undo revives the piece: unregisterGCPair.
        try doc.undo()
        let revived = doc.getDocSize()

        // then — revive must drain the tombstoned size out of gc, including the
        // meta term.
        XCTAssertEqual(revived.gc, DataSize(data: 0, meta: 0), "revive must drain the tombstoned size out of gc, including the meta term")

        // when — redo re-tombstones the piece: registerGCPair again.
        try doc.redo()

        // then — redo must reproduce the tombstoned docSize exactly, including meta.
        XCTAssertEqual(doc.getDocSize(), deleted, "redo must reproduce the tombstoned docSize exactly, including meta")

        // when — undo again revives the piece a second time.
        try doc.undo()

        // then — the revived docSize is bit-identical across cycles, including meta.
        XCTAssertEqual(doc.getDocSize(), revived, "the revived docSize is bit-identical across cycles, including meta")
    }
}
