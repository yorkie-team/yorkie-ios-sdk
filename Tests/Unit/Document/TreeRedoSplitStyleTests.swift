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

// Ported from yorkie-js-sdk b173c093:
// `packages/sdk/test/unit/document/tree_redo_split_style_test.ts`
// (yorkie-js-sdk#1426 "Re-point operations at the elements a redo split
// re-creates").
//
// A change that splits a Tree element and styles the split-born piece --
// what an editor produces when bolding part of a word -- could be undone and
// redone locally, but after garbage collection peers rejected the redo with
// "cannot find node of CRDTTreePos" and kept failing on it. The redo of a
// split mints the split-born element under a new id, while the style
// recorded after it still named the element the undo had merged away, which
// GC then purged.
//
// These two-client suites exchange change packs directly (no server), the
// same shape `TreeSplitLinkPayloadTests.replicate` uses, but round-trip in
// both directions so a peer's acknowledgement (`grab`) clears the sender's
// local changes the way a real server ack does -- needed here because every
// case syncs several times in a row.

import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

/// Returns a document pinned to `actor`.
@MainActor
private func newActor(_ actor: String) -> Document {
    let doc = Document(key: "d")
    doc.setActor(actor)
    return doc
}

/// Takes the pending local changes through the wire form and acks them, mirroring a server
/// response that confirms them: without this, a document that syncs repeatedly in the same test
/// would re-send changes the peer already applied.
@MainActor
private func grab(_ doc: Document) throws -> PbChangePack {
    let pack = doc.createChangePack()
    let lastSeq = pack.getChanges().last?.id.getClientSeq() ?? 0
    let pb = Converter.toChangePack(pack: pack)
    try doc.applyChangePack(ChangePack(
        key: pack.getDocumentKey(),
        checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
        isRemoved: false,
        changes: [],
        versionVector: VersionVector.initial
    ))
    return pb
}

/// Decodes `batch` and applies it to `doc` as a remote change pack.
@MainActor
private func feed(_ doc: Document, _ batch: PbChangePack) throws {
    let pack = try Converter.fromChangePack(batch)
    try doc.applyChangePack(ChangePack(
        key: pack.getDocumentKey(),
        checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
        isRemoved: false,
        changes: pack.getChanges(),
        versionVector: VersionVector.initial
    ))
}

/// `hello world` in an inline in a paragraph -- two levels to split.
@MainActor
private func seed(_ doc: Document) throws {
    try doc.update { root, _ in
        root.t = JSONTree(initialRoot:
            JSONTreeElementNode(type: "root", children: [
                JSONTreeElementNode(type: "paragraph", children: [
                    JSONTreeElementNode(type: "inline", children: [
                        JSONTreeTextNode(value: "hello world")
                    ])
                ])
            ]))
    }
}

/// `<p>ab</p><p>cd</p>` -- two blocks to merge and split again.
@MainActor
private func seedBlocks(_ doc: Document) throws {
    try doc.update { root, _ in
        root.t = JSONTree(initialRoot:
            JSONTreeElementNode(type: "root", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")])
            ]))
    }
}

/// Purges the tombstones both replicas have seen.
@MainActor
private func collectBoth(_ docA: Document, _ docB: Document) {
    let vector = maxVectorOf(actors: [docA.changeID.getActorID(), docB.changeID.getActorID()])
    _ = docA.garbageCollect(minSyncedVersionVector: vector)
    _ = docB.garbageCollect(minSyncedVersionVector: vector)
}

/// Reads a replica's Tree field as XML.
@MainActor
private func xml(_ doc: Document) throws -> String {
    try XCTUnwrap(doc.getRoot().t as? JSONTree).toXML()
}

/// Applies `block` to `doc`'s tree inside an `update`, failing the test if "t" is not a tree.
@MainActor
private func updateTree(_ doc: Document, _ block: (JSONTree) throws -> Void) throws {
    try doc.update { root, _ in
        guard let tree = root.t as? JSONTree else { return }
        try block(tree)
    }
}

final class TreeRedoSplitStyleTests: XCTestCase {
    // MARK: - Tree redo of a split and a style in one change

    /// Drives one (edit, undo, redo, undo, redo) round trip, syncing a peer after every step, and
    /// asserts the peer converges with the local replica at each point -- including after the redo
    /// re-mints the split elements and a SECOND undo/redo round trip exercises the re-split ids.
    @MainActor
    private func assertRedoOfSplitAndStyleConverges(collectGarbage: Bool, edit: (JSONTree) throws -> Void) throws {
        // given
        let docA = newActor("000000000000000000000001")
        let docB = newActor("000000000000000000000002")
        try seed(docA)
        docA.clearHistory()
        try feed(docB, grab(docA))

        // when
        try updateTree(docA) { tree in try edit(tree) }
        let edited = try xml(docA)
        try feed(docB, grab(docA))

        // then
        XCTAssertEqual(try xml(docB), edited, "edit")

        // when
        try docA.undo()
        try feed(docB, grab(docA))
        let undone = try xml(docA)

        // then
        XCTAssertEqual(try xml(docB), undone, "undo")
        // Both have seen the undo, so its tombstones can be purged.
        if collectGarbage {
            collectBoth(docA, docB)
        }

        // when
        try docA.redo()

        // then
        XCTAssertEqual(try xml(docA), edited, "redo, locally")
        try feed(docB, grab(docA))
        XCTAssertEqual(try xml(docB), edited, "redo, on the peer")

        // when -- a second round trip: the redo re-minted the split elements, so the entry it
        // pushed onto the undo stack has to name the new ones.
        try docA.undo()
        try feed(docB, grab(docA))

        // then
        XCTAssertEqual(try xml(docA), undone, "second undo, locally")
        XCTAssertEqual(try xml(docB), undone, "second undo, on the peer")

        // when
        try docA.redo()
        try feed(docB, grab(docA))

        // then
        XCTAssertEqual(try xml(docA), edited, "second redo, locally")
        XCTAssertEqual(try xml(docB), edited, "second redo, on the peer")
    }

    private func editSplitInTheMiddleBoldTheRightPiece(_ tree: JSONTree) throws {
        _ = try tree.editByPath([0, 0, 6], [0, 0, 6], nil, 1)
        try tree.styleByPath([0, 1], ["bold": "true"])
    }

    @MainActor
    func test_lets_a_peer_apply_the_redo_split_in_the_middle_bold_the_right_piece() throws {
        try self.assertRedoOfSplitAndStyleConverges(collectGarbage: false, edit: self.editSplitInTheMiddleBoldTheRightPiece)
    }

    @MainActor
    func test_lets_a_peer_apply_the_redo_split_in_the_middle_bold_the_right_piece_after_gc() throws {
        try self.assertRedoOfSplitAndStyleConverges(collectGarbage: true, edit: self.editSplitInTheMiddleBoldTheRightPiece)
    }

    private func editSplitAtTheEndBoldTheEmptyPiece(_ tree: JSONTree) throws {
        _ = try tree.editByPath([0, 0, 11], [0, 0, 11], nil, 1)
        try tree.styleByPath([0, 1], ["bold": "true"])
    }

    @MainActor
    func test_lets_a_peer_apply_the_redo_split_at_the_end_bold_the_empty_piece() throws {
        try self.assertRedoOfSplitAndStyleConverges(collectGarbage: false, edit: self.editSplitAtTheEndBoldTheEmptyPiece)
    }

    @MainActor
    func test_lets_a_peer_apply_the_redo_split_at_the_end_bold_the_empty_piece_after_gc() throws {
        try self.assertRedoOfSplitAndStyleConverges(collectGarbage: true, edit: self.editSplitAtTheEndBoldTheEmptyPiece)
    }

    /// Two levels: the split mints an inline AND a paragraph, so the `replacedIDs` -> split-ticket
    /// pairing has to line up innermost first.
    private func editSplitTwoLevelsBoldTheNewParagraph(_ tree: JSONTree) throws {
        _ = try tree.editByPath([0, 0, 6], [0, 0, 6], nil, 2)
        try tree.styleByPath([1], ["bold": "true"])
    }

    @MainActor
    func test_lets_a_peer_apply_the_redo_split_two_levels_bold_the_new_paragraph() throws {
        try self.assertRedoOfSplitAndStyleConverges(collectGarbage: false, edit: self.editSplitTwoLevelsBoldTheNewParagraph)
    }

    @MainActor
    func test_lets_a_peer_apply_the_redo_split_two_levels_bold_the_new_paragraph_after_gc() throws {
        try self.assertRedoOfSplitAndStyleConverges(collectGarbage: true, edit: self.editSplitTwoLevelsBoldTheNewParagraph)
    }

    /// ... and here the style names the inner element the second ticket did NOT mint, which only
    /// resolves if the pairing is right.
    private func editSplitTwoLevelsBoldTheNewInline(_ tree: JSONTree) throws {
        _ = try tree.editByPath([0, 0, 6], [0, 0, 6], nil, 2)
        try tree.styleByPath([1, 0], ["bold": "true"])
    }

    @MainActor
    func test_lets_a_peer_apply_the_redo_split_two_levels_bold_the_new_inline() throws {
        try self.assertRedoOfSplitAndStyleConverges(collectGarbage: false, edit: self.editSplitTwoLevelsBoldTheNewInline)
    }

    @MainActor
    func test_lets_a_peer_apply_the_redo_split_two_levels_bold_the_new_inline_after_gc() throws {
        try self.assertRedoOfSplitAndStyleConverges(collectGarbage: true, edit: self.editSplitTwoLevelsBoldTheNewInline)
    }

    /// A tree EDIT, not a style, follows the split: its reverse travels as identity-preserving
    /// restore spans, which name the split-created element as their parent and have to be
    /// re-pointed too.
    private func editSplitThenInsertIntoTheNewElement(_ tree: JSONTree) throws {
        _ = try tree.editByPath([0, 0, 6], [0, 0, 6], nil, 1)
        _ = try tree.editByPath([0, 1, 0], [0, 1, 0], JSONTreeTextNode(value: "X"))
    }

    @MainActor
    func test_lets_a_peer_apply_the_redo_split_then_insert_into_the_new_element() throws {
        try self.assertRedoOfSplitAndStyleConverges(collectGarbage: false, edit: self.editSplitThenInsertIntoTheNewElement)
    }

    @MainActor
    func test_lets_a_peer_apply_the_redo_split_then_insert_into_the_new_element_after_gc() throws {
        try self.assertRedoOfSplitAndStyleConverges(collectGarbage: true, edit: self.editSplitThenInsertIntoTheNewElement)
    }

    // MARK: - The split and the style are in different history entries

    /// The split and the operation naming its elements are in DIFFERENT history entries here, so
    /// nothing in the popped entry re-points the latter: only `History.reconcileTreeNodeID`,
    /// sweeping the stacks, can.
    @MainActor
    private func assertRepointsAnotherHistoryEntry(collectGarbage: Bool) throws {
        // given
        let docA = newActor("000000000000000000000001")
        let docB = newActor("000000000000000000000002")
        try seed(docA)
        docA.clearHistory()
        try feed(docB, grab(docA))

        // Entry 1: the split. Entry 2: a style naming what it created.
        try updateTree(docA) { tree in _ = try tree.editByPath([0, 0, 6], [0, 0, 6], nil, 1) }
        let split = try xml(docA)
        try updateTree(docA) { tree in try tree.styleByPath([0, 1], ["bold": "true"]) }
        let styled = try xml(docA)
        try feed(docB, grab(docA))
        XCTAssertEqual(try xml(docB), styled, "edits")

        // when -- undo the style, then the split. The redo stack now holds a re-split entry and,
        // above it, a style entry naming the pre-split element.
        try docA.undo()
        try feed(docB, grab(docA))
        try docA.undo()
        try feed(docB, grab(docA))
        let merged = try xml(docA)

        // then
        XCTAssertEqual(try xml(docB), merged, "both undone")
        if collectGarbage {
            collectBoth(docA, docB)
        }

        // when -- redoing the split mints new elements; the style entry still on the stack has to
        // follow them, or the peer cannot apply it.
        try docA.redo()
        try feed(docB, grab(docA))

        // then
        XCTAssertEqual(try xml(docA), split, "redo split, locally")
        XCTAssertEqual(try xml(docB), split, "redo split, on the peer")
        if collectGarbage {
            collectBoth(docA, docB)
        }

        // when
        try docA.redo()

        // then
        XCTAssertEqual(try xml(docA), styled, "redo style, locally")
        try feed(docB, grab(docA))
        XCTAssertEqual(try xml(docB), styled, "redo style, on the peer")
    }

    @MainActor
    func test_re_points_another_history_entry_at_the_re_split_elements() throws {
        try self.assertRepointsAnotherHistoryEntry(collectGarbage: false)
    }

    @MainActor
    func test_re_points_another_history_entry_at_the_re_split_elements_after_gc() throws {
        try self.assertRepointsAnotherHistoryEntry(collectGarbage: true)
    }

    // MARK: - Tree split that re-creates a block a merge took away

    // Not an undo/redo: a peer merges two blocks, then a plain split separates them again,
    // re-creating the merged-away block under a new id. A history entry naming the old block has
    // to follow it, whichever replica split.

    @MainActor
    func test_re_points_the_history_when_the_split_is_a_local_edit() throws {
        // given
        let docA = newActor("000000000000000000000001")
        let docB = newActor("000000000000000000000002")
        try seedBlocks(docA)
        docA.clearHistory()
        try feed(docB, grab(docA))

        // when -- a's entry names the second block; b merges it into the first.
        try updateTree(docA) { tree in try tree.styleByPath([1], ["bold": "true"]) }
        try feed(docB, grab(docA))
        try updateTree(docB) { tree in _ = try tree.editByPath([0, 2], [1, 0]) }
        try feed(docA, grab(docB))

        // a splits the blocks apart again, then the merged-away block is purged.
        try updateTree(docA) { tree in _ = try tree.editByPath([0, 2], [0, 2], nil, 1) }
        try feed(docB, grab(docA))
        collectBoth(docA, docB)

        try docA.undo()
        try feed(docB, grab(docA))
        try docA.undo()
        try feed(docB, grab(docA))

        // then
        XCTAssertEqual(try xml(docB), try xml(docA))
    }

    @MainActor
    func test_re_points_the_history_when_the_split_arrives_from_a_peer() throws {
        // given
        let docA = newActor("000000000000000000000001")
        let docB = newActor("000000000000000000000002")
        try seedBlocks(docA)
        docA.clearHistory()
        try feed(docB, grab(docA))

        // when -- b's entry names the second block; a merges it away and splits again.
        try updateTree(docB) { tree in try tree.styleByPath([1], ["bold": "true"]) }
        try feed(docA, grab(docB))
        try updateTree(docA) { tree in _ = try tree.editByPath([0, 2], [1, 0]) }
        try updateTree(docA) { tree in _ = try tree.editByPath([0, 2], [0, 2], nil, 1) }
        try feed(docB, grab(docA))
        collectBoth(docA, docB)

        try docB.undo()
        try feed(docA, grab(docB))

        // then
        XCTAssertEqual(try xml(docA), try xml(docB))
    }

    // MARK: - History.reconcileTreeNodeID

    // A node id is only unique inside its own tree, and the pairs that drive the sweep arrive from
    // a peer's change as well as this replica's own. An entry recorded against a DIFFERENT tree
    // element must come through untouched, or a split in one tree silently re-addresses pending
    // work in another.

    func test_re_points_only_the_entries_targeting_the_same_tree() {
        // given
        let actor = "000000000000000000000001"
        func tick(_ lamport: Int64) -> TimeTicket {
            TimeTicket(lamport: lamport, delimiter: 0, actorID: actor)
        }
        let treeA = tick(1)
        let treeB = tick(2)
        let prev = CRDTTreeNodeID(createdAt: tick(10), offset: 0)
        let curr = CRDTTreeNodeID(createdAt: tick(20), offset: 0)
        func posAt(_ id: CRDTTreeNodeID) -> CRDTTreePos {
            CRDTTreePos(parentID: id, leftSiblingID: id)
        }
        func styleOn(_ parentCreatedAt: TimeTicket) -> TreeStyleOperation {
            TreeStyleOperation(
                parentCreatedAt: parentCreatedAt,
                fromPos: posAt(prev),
                toPos: posAt(prev),
                attributes: ["bold": "true"],
                attributesToRemove: [],
                executedAt: tick(30)
            )
        }

        let history = History()
        let onA = styleOn(treeA)
        let onB = styleOn(treeB)
        history.pushUndo([.operation(onA), .operation(onB)])

        // when
        history.reconcileTreeNodeID(parentCreatedAt: treeA, prev: prev, curr: curr)

        // then
        XCTAssertEqual(onA.fromPos.parentID.createdAt, curr.createdAt, "the entry on the split tree follows the new id")
        XCTAssertEqual(onB.fromPos.parentID.createdAt, prev.createdAt, "the entry on another tree keeps its own id")
    }
}
