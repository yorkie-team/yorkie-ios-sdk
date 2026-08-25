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

/// Ported from yorkie-js-sdk v0.7.16:
/// `packages/sdk/test/unit/document/crdt/tree_duplicate_id_test.ts`
/// (yorkie-js-sdk#1318 "Keep a tree position resolvable when two nodes claim
/// one ID").
///
/// A `CRDTTreeNodeID` (createdAt + offset) is the identity every position
/// anchors to, so it must name a single node. An undo that reverses a
/// deletion by re-inserting a copy of the removed nodes keeps their IDs,
/// which leaves two nodes under one ID; a plain `put` then picks a winner by
/// insertion order, and that order differs between a live document and one
/// rebuilt from a snapshot. These mirror the server-side rules in yorkie#1927.
final class CRDTTreeDuplicateIdTests: XCTestCase {
    /// Builds `<r><p>0123456789</p></r>` and returns the tree with the id of
    /// its text node.
    private func buildDigitTree() throws -> (tree: CRDTTree, textID: CRDTTreeNodeID) {
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: "r"), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)

        let textID = posT()
        try tree.editT(
            (1, 1),
            [CRDTTreeNode(id: textID, type: DefaultTreeNodeType.text.rawValue, value: "0123456789")],
            0, timeT(), timeT
        )
        XCTAssertEqual(tree.toXML(), "<r><p>0123456789</p></r>")

        return (tree, textID)
    }

    /// Returns the ids that name more than one node in the tree.
    private func duplicatedIDs(_ tree: CRDTTree) -> [String] {
        var counts = [String: Int]()
        tree.indexTree.traverseAll { node, _ in
            counts[node.toIDString, default: 0] += 1
        }
        return counts.filter { $0.value > 1 }.map { "\($0.key) x\($0.value)" }
    }

    /// Reproduces the state an older SDK left in stored documents: the
    /// character at text offset 5 is deleted, and a copy of it is attached
    /// under the tombstone's ORIGINAL id. It bypasses `edit` so the test keeps
    /// exercising an already-corrupted document even once the edit path
    /// refuses to create duplicates.
    @discardableResult
    private func corruptWithDuplicatedNodeID(_ tree: CRDTTree, _ textID: CRDTTreeNodeID) throws -> CRDTTreeNodeID {
        try tree.editT((6, 7), nil, 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), "<r><p>012346789</p></r>")

        let paragraph = try XCTUnwrap(tree.root.innerChildren.first)
        let tombstoneID = CRDTTreeNodeID(createdAt: textID.createdAt, offset: 5)
        let tombstone = try XCTUnwrap(tree.findFloorNode(tombstoneID))
        XCTAssertTrue(tombstone.isRemoved)

        // The copy lands before the tombstone, where an insert at the same
        // index puts it, and wins nodeMapByID because it is registered last.
        let dupe = CRDTTreeNode(id: tombstoneID, type: DefaultTreeNodeType.text.rawValue, value: "5")
        let index = try XCTUnwrap(paragraph.innerChildren.firstIndex { $0 === tombstone })
        try paragraph.insertAt(dupe, index)
        tree.registerNode(dupe)
        XCTAssertEqual(tree.toXML(), "<r><p>0123456789</p></r>")

        return tombstoneID
    }

    /// Round-trips the tree through the snapshot encoding, as a client does
    /// when it loads a document.
    private func rebuildFromSnapshot(_ tree: CRDTTree) throws -> CRDTTree {
        let object = CRDTObject(createdAt: timeT())
        object.set(key: "t", value: tree)
        let bytes = try Converter.objectToBytes(obj: object)
        let restored = try Converter.bytesToObject(bytes: bytes)
        return try XCTUnwrap(restored.get(key: "t") as? CRDTTree)
    }

    func test_drops_content_that_reuses_an_id_from_an_earlier_change() throws {
        // given
        let (tree, textID) = try self.buildDigitTree()
        try tree.editT((6, 7), nil, 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), "<r><p>012346789</p></r>")

        // when — the undo arrives as a later change, so it carries a later
        // lamport than the id its content reuses.
        let undoAt = TimeTicket(lamport: timeT().lamport + 1, delimiter: 1, actorID: ActorIDs.initial)
        try tree.editT(
            (6, 6),
            [CRDTTreeNode(id: CRDTTreeNodeID(createdAt: textID.createdAt, offset: 5), type: DefaultTreeNodeType.text.rawValue, value: "5")],
            0, undoAt, { undoAt }
        )

        // then
        XCTAssertEqual(self.duplicatedIDs(tree), [], "an id names at most one node")
        XCTAssertEqual(tree.toXML(), "<r><p>012346789</p></r>", "the copy is not inserted")
    }

    func test_drops_content_whose_id_this_edit_is_about_to_create_by_splitting() throws {
        // given — nothing has split the text node yet, so no node carries
        // (textID, 5). Resolving the insert position splits it there, which
        // creates that id moments before the copy is inserted under it.
        let (tree, textID) = try self.buildDigitTree()

        // when
        let undoAt = TimeTicket(lamport: timeT().lamport + 1, delimiter: 1, actorID: ActorIDs.initial)
        try tree.editT(
            (6, 6),
            [CRDTTreeNode(id: CRDTTreeNodeID(createdAt: textID.createdAt, offset: 5), type: DefaultTreeNodeType.text.rawValue, value: "5")],
            0, undoAt, { undoAt }
        )

        // then
        XCTAssertEqual(self.duplicatedIDs(tree), [], "an id names at most one node")
    }

    func test_drops_content_that_reuses_an_id_from_another_actor() throws {
        // given
        let (tree, textID) = try self.buildDigitTree()
        try tree.editT((6, 7), nil, 0, timeT(), timeT)

        // when
        let undoAt = TimeTicket(lamport: timeT().lamport, delimiter: 1, actorID: "0123456789abcdef01234567")
        try tree.editT(
            (6, 6),
            [CRDTTreeNode(id: CRDTTreeNodeID(createdAt: textID.createdAt, offset: 5), type: DefaultTreeNodeType.text.rawValue, value: "5")],
            0, undoAt, { undoAt }
        )

        // then
        XCTAssertEqual(self.duplicatedIDs(tree), [], "an id names at most one node")
        XCTAssertEqual(tree.toXML(), "<r><p>012346789</p></r>")
    }

    func test_keeps_colliding_content_issued_by_this_change() throws {
        // given — the delimiters an element split consumes are simulated
        // rather than replayed, so an id issued by this edit can collide with
        // one already in the tree. That content belongs to the document.
        let (tree, _) = try self.buildDigitTree()
        let existingID = tree.root.innerChildren[0].id

        // when
        let editedAt = TimeTicket(lamport: existingID.createdAt.lamport, delimiter: existingID.createdAt.delimiter + 1, actorID: existingID.createdAt.actorID)
        try tree.editT(
            (12, 12),
            [CRDTTreeNode(id: CRDTTreeNodeID(createdAt: existingID.createdAt, offset: 0), type: "p")],
            0, editedAt, { editedAt }
        )

        // then
        XCTAssertEqual(tree.toXML(), "<r><p>0123456789</p><p></p></r>", "content issued by this change is inserted even when its id collides")
    }

    func test_resolves_a_duplicated_id_to_the_same_node_after_a_snapshot_rebuild() throws {
        // given
        let (tree, textID) = try self.buildDigitTree()
        try self.corruptWithDuplicatedNodeID(tree, textID)

        // when
        let rebuilt = try self.rebuildFromSnapshot(tree)

        // then
        XCTAssertEqual(rebuilt.toXML(), tree.toXML())

        let id = CRDTTreeNodeID(createdAt: textID.createdAt, offset: 5)
        let live = try XCTUnwrap(tree.findFloorNode(id))
        let cold = try XCTUnwrap(rebuilt.findFloorNode(id))
        XCTAssertEqual(
            cold.isRemoved, live.isRemoved,
            "live resolves to a \(live.isRemoved ? "tombstone" : "live node"), rebuilt to a \(cold.isRemoved ? "tombstone" : "live node")"
        )
    }

    func test_applies_an_edit_anchored_at_a_duplicated_id_after_a_rebuild() throws {
        // given
        let (tree, textID) = try self.buildDigitTree()
        try self.corruptWithDuplicatedNodeID(tree, textID)

        // Keep editing before the duplicated id: this splits the run owning
        // offsets 0..5, so the piece at offset 0 no longer spans up to offset 5.
        try tree.editT((4, 4), [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "x")], 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), "<r><p>012x3456789</p></r>")

        let rebuilt = try self.rebuildFromSnapshot(tree)
        let parentID = rebuilt.root.innerChildren[0].id
        let editedAt = timeT()

        // when / then
        XCTAssertNoThrow(try rebuilt.edit(
            (
                CRDTTreePos(parentID: parentID, leftSiblingID: CRDTTreeNodeID(createdAt: textID.createdAt, offset: 5)),
                CRDTTreePos(parentID: parentID, leftSiblingID: CRDTTreeNodeID(createdAt: textID.createdAt, offset: 6))
            ),
            nil, 0, editedAt, { editedAt }, nil
        ))
    }

    func test_keeps_the_live_node_resolvable_when_its_tombstone_is_purged() throws {
        // given
        let (tree, textID) = try self.buildDigitTree()
        try self.corruptWithDuplicatedNodeID(tree, textID)

        let id = CRDTTreeNodeID(createdAt: textID.createdAt, offset: 5)
        let live = try XCTUnwrap(tree.findFloorNode(id))
        XCTAssertFalse(live.isRemoved)

        var tombstone: CRDTTreeNode?
        tree.indexTree.traverseAll { node, _ in
            if node.id == id, node.isRemoved {
                tombstone = node
            }
        }
        let tombstoneNode = try XCTUnwrap(tombstone)

        // when
        tree.purge(node: tombstoneNode)

        // then
        XCTAssertTrue(tree.findFloorNode(id) === live, "the live node keeps the id after its tombstone is collected")
        XCTAssertEqual(tree.toXML(), "<r><p>0123456789</p></r>")
    }

    func test_does_not_let_a_dropped_copy_widen_the_reverse_operation() throws {
        // given
        let (tree, textID) = try self.buildDigitTree()
        try tree.editT((6, 7), nil, 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), "<r><p>012346789</p></r>")

        let root = CRDTRoot(rootObject: CRDTObject(createdAt: TimeTicket.initial))
        root.registerElement(tree, parent: nil)

        // The undo of that deletion, as the copy-reinsert path builds it: one
        // content node carrying the id of the piece just tombstoned.
        let undoAt = TimeTicket(lamport: timeT().lamport + 1, delimiter: 1, actorID: ActorIDs.initial)
        let pos = try tree.findPos(6)
        let op = TreeEditOperation(
            parentCreatedAt: tree.createdAt,
            fromPos: pos,
            toPos: pos,
            contents: [CRDTTreeNode(id: CRDTTreeNodeID(createdAt: textID.createdAt, offset: 5), type: DefaultTreeNodeType.text.rawValue, value: "5")],
            splitLevel: 0,
            executedAt: undoAt
        )

        // when
        let result = try op.execute(root: root)

        // then
        XCTAssertEqual(tree.toXML(), "<r><p>012346789</p></r>", "the copy is not inserted")

        // The undo stack shifts its stored indices by this size when a remote
        // edit arrives, so it has to match what the tree accepted.
        XCTAssertEqual(op.getContentSize(), 0, "an edit whose content was dropped inserted nothing")

        // Redoing must not delete a neighbour that this edit never inserted.
        if let redo = result?.reverseOp as? TreeEditOperation {
            XCTAssertEqual(redo.fromPos, redo.toPos, "the reverse of an edit that inserted nothing spans nothing")
        }
    }

    func test_refuses_to_split_a_text_node_past_its_end() throws {
        // given
        let node = CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "hello")

        // when / then
        XCTAssertThrowsError(try node.splitText(Int32(node.size) + 1, 0)) { error in
            guard let yorkieError = error as? YorkieError else {
                return XCTFail("expected a YorkieError")
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
        }
        XCTAssertEqual(node.value, "hello", "a refused split leaves the node alone")
    }
}
