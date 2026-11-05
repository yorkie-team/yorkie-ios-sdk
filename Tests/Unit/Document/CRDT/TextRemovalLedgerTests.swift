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

/// Ports `packages/sdk/test/unit/document/crdt/text_removal_ledger_test.ts` from yorkie-js-sdk
/// v0.7.26 (yorkie-js-sdk#1514): CRDT-level tests of the Text removal ledger, themselves ported
/// from Go's rga_tree_split_test.go, text_restore_test.go and edit_reconcile_test.go
/// (yorkie-team/yorkie#2310).

private let actorA: ActorID = "000000000000000000000001"
private let actorB: ActorID = "000000000000000000000002"

private func ticketA(_ lamport: Int64) -> TimeTicket {
    TimeTicket(lamport: lamport, delimiter: 0, actorID: actorA)
}

private func ticketB(_ lamport: Int64) -> TimeTicket {
    TimeTicket(lamport: lamport, delimiter: 0, actorID: actorB)
}

private func vector(_ entries: [(String, Int64)]) -> VersionVector {
    var result = VersionVector()
    for (actor, lamport) in entries {
        result.set(actorID: actor, lamport: lamport)
    }
    return result
}

private func keys(_ tickets: [TimeTicket]) -> [String] {
    tickets.map { $0.toIDString }
}

/// A text node created by actor A at lamport 1, removed at `removedAt`.
private func makeNode(_ removedAt: TimeTicket? = nil) -> RGATreeSplitNode<CRDTTextValue> {
    RGATreeSplitNode(RGATreeSplitNodeID(ticketA(1), 0), CRDTTextValue("x"), removedAt)
}

/// Builds "0123456789" as a single insertion created at `seed`.
private func seededText(_ seed: TimeTicket) throws -> CRDTText {
    let text = CRDTText(rgaTreeSplit: RGATreeSplit(), createdAt: TimeTicket.initial)
    try text.edit(text.indexRangeToPosRange(0, 0), "0123456789", seed)
    XCTAssertEqual(text.toString, "0123456789")
    return text
}

/// Tombstones [from, to) of the current visible text.
@discardableResult
private func deleteRange(
    _ text: CRDTText,
    _ from: Int,
    _ to: Int,
    _ at: TimeTicket,
    _ versionVector: VersionVector? = nil
) throws -> ([TextChange], [GCPair], DataSize, RGATreeSplitPosRange, [CRDTTextValue], [RestoreSpan<CRDTTextValue>]) {
    try text.edit(text.indexRangeToPosRange(from, to), "", at, nil, versionVector)
}

final class RGATreeSplitNodeRemovalEventsTests: XCTestCase {
    func test_pairs_each_actor_events_by_place() throws {
        // given -- A's removal holds the node; B removed it and undid that.
        let node = makeNode(ticketA(5))

        // when
        try node.setRemovalEvents([ticketB(6), ticketB(4)])

        // then
        let ledger = node.ledger
        XCTAssertEqual(ledger.dels.count, 2)
        XCTAssertEqual(ledger.cancels.count, 1)
        XCTAssertEqual(ledger.cancels[0].deletion, ticketB(4))
        XCTAssertEqual(ledger.cancels[0].cancelledAt, ticketB(6))
        XCTAssertEqual(node.removedAt, ticketA(5))
        XCTAssertEqual(keys(node.getRemovalEvents()), keys([ticketB(4), ticketB(6)]))
    }

    private func assertRejects(_ removedAt: TimeTicket?, _ events: [TimeTicket], file: StaticString = #filePath, line: UInt = #line) {
        let node = makeNode(removedAt)

        XCTAssertThrowsError(try node.setRemovalEvents(events), file: file, line: line)

        // The node is left as it was.
        XCTAssertEqual(node.removedAt?.toIDString, removedAt?.toIDString, file: file, line: line)
        XCTAssertEqual(node.getRemovalEvents(), [], file: file, line: line)
    }

    func test_rejects_malformed_events_removed_at_repeated() {
        self.assertRejects(ticketA(5), [ticketA(5)])
    }

    func test_rejects_malformed_events_event_repeated() {
        self.assertRejects(nil, [ticketA(5), ticketA(5)])
    }

    func test_rejects_malformed_events_removal_without_removed_at() {
        self.assertRejects(nil, [ticketA(5)])
    }

    func test_rejects_malformed_events_removed_at_cancelled() {
        self.assertRejects(ticketA(5), [ticketA(3)])
    }

    func test_writes_nothing_when_removed_at_says_it_all() {
        // given
        let node = makeNode()

        // when
        node.recordRemoval(ticketA(5))

        // then
        XCTAssertEqual(node.getRemovalEvents(), [])
        XCTAssertFalse(node.ledger.ledgered)
    }
}

final class TextRemovalLedgerTests: XCTestCase {
    func test_returns_removed_spans_in_document_order() throws {
        // given -- restore anchors each recreated fragment after the one before it, so the reverse
        // of an edit has to list them left to right.
        let text = try seededText(ticketA(1))
        for (index, pos) in [8, 6, 4, 2].enumerated() {
            try text.edit(text.indexRangeToPosRange(pos, pos), "x", ticketA(Int64(2 + index)))
        }
        XCTAssertEqual(text.toString, "01x23x45x67x89")

        // when
        let result = try deleteRange(text, 0, 14, ticketA(10))

        // then
        XCTAssertEqual(result.5.map { $0.value.toString }.joined(), "01x23x45x67x89")
    }

    func test_keeps_one_uncancelled_removal_per_actor() throws {
        // given -- a removal by an actor that already holds an uncancelled one is not recorded:
        // only a change that leaves its own earlier removal out of its vector can send it.
        let text = try seededText(ticketA(1))
        try deleteRange(text, 2, 4, ticketA(2))

        // when -- the same actor removes [1,3) of "01456789" again, with a vector that knows the
        // insertion but not its own removal of "23".
        try deleteRange(text, 1, 3, ticketA(5), vector([(actorA, 1)]))

        // then
        var checked = 0
        for node in text.rgaTreeSplit where node.id.offset == 2 {
            XCTAssertEqual(node.removedAt, ticketA(2))
            XCTAssertEqual(node.getRemovalEvents(), [])
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func test_cancels_only_the_undoing_actor_removal() throws {
        // given -- A and B remove "2" concurrently, B with the later ticket. A's undo has to
        // cancel A's removal, not the latest one, and leave B's holding it.
        let text = try seededText(ticketA(1))
        let range = try text.createRange(2, 3)
        try deleteRange(text, 2, 3, ticketA(2))
        try text.edit(range, "", ticketB(3), nil, vector([(actorA, 1)]))
        XCTAssertEqual(text.toString, "013456789")

        // when
        try text.restore(
            [RestoreSpan(createdAt: ticketA(1), start: 2, end: 3, value: CRDTTextValue("2"))],
            ticketA(4)
        )

        // then
        XCTAssertEqual(text.toString, "013456789")
        var checked = 0
        for node in text.rgaTreeSplit where node.id.offset == 2 {
            XCTAssertNil(node.uncancelledRemovalBy(actorA))
            XCTAssertEqual(node.uncancelledRemovalBy(actorB), ticketB(3))
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func test_reports_nothing_tombstoned_by_a_redo_of_a_removed_piece() throws {
        // given -- a redo that re-removes a span another actor already tombstoned, by a deletion
        // the redo never saw, splits that tombstone and hands back the born-dead remainders as GC
        // pairs, but nothing went live to dead. It still records the redo on the piece, which the
        // reverse names.
        let seed = ticketA(1)
        let text = try seededText(seed)
        try deleteRange(text, 2, 8, ticketB(2))
        XCTAssertEqual(text.toString, "0189")

        // when
        let (pairs, changes, _, recorded) = try text.retombstone(
            [RestoreSpan(createdAt: seed, start: 4, end: 6, value: CRDTTextValue("45"))],
            ticketA(3),
            vector([(actorA, 3)])
        )

        // then
        XCTAssertTrue(changes.isEmpty)
        XCTAssertGreaterThan(pairs.count, 0)
        XCTAssertEqual(recorded.count, 1)
    }
}

final class EditOperationEmptyUndoTests: XCTestCase {
    func test_runs_as_a_no_op_wherever_it_points() throws {
        // given -- stacked entries are not reconciled against remote undos and redos, so a degraded
        // identity reverse once ran past the end of a text other replicas had emptied and failed
        // (seed 152 of Go's TestTextUndoFuzz).
        let root = CRDTRoot()
        let text = CRDTText(rgaTreeSplit: RGATreeSplit(), createdAt: ticketA(1))
        _ = root.object.set(key: "t", value: text, executedAt: ticketA(1))
        root.registerElement(text, parent: root.object)
        try text.edit(text.indexRangeToPosRange(0, 0), "0123456789", ticketA(2))

        let head = text.rgaTreeSplit.head.id
        let stale = RGATreeSplitPos(head, 50)
        let undo = EditOperation(
            parentCreatedAt: text.createdAt,
            fromPos: stale,
            toPos: stale,
            content: "",
            attributes: [:],
            executedAt: TimeTicket(lamport: 100, delimiter: 0, actorID: actorA),
            isUndoOp: true
        )

        // when
        let result = try undo.execute(root: root, source: .undoRedo)

        // then
        XCTAssertEqual(result?.opInfos.count, 0)
        XCTAssertEqual(text.toString, "0123456789")
        for pos in [undo.fromPos, undo.toPos] {
            XCTAssertEqual(pos.id, head)
            XCTAssertEqual(pos.relativeOffset, 0)
        }
        let reverse = result?.reverseOp as? EditOperation
        XCTAssertNotNil(reverse)
        XCTAssertEqual(reverse?.fromPos.relativeOffset, 0)
    }
}
