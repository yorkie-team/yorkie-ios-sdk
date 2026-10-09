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

/// Ported from yorkie-js-sdk#1394 "Guard empty-text anchors and reset the clone
/// on failed applies": `packages/sdk/test/unit/document/crdt/tree_boundary_anchor_test.ts`.
///
/// Only `leftAnchorID`'s empty-text guard changed on the JS side (item 3 of the
/// upstream PR). `emptyRunReachesActor` (item 2) was dropped from the final PR
/// scope because JS already matched Go `main` there, and this SDK already reads
/// the unfiltered-by-tombstone child set (`innerChildren`, the Swift analogue of
/// JS's `allChildren`) rather than the removed-filtering `children`, so no
/// source change was needed for it either. The first test below is kept anyway,
/// as upstream kept it, as a regression lock on that already-correct behaviour.
final class CRDTTreeBoundaryAnchorTests: XCTestCase {
    private let actorA = "000000000000000000000001"
    private let actorB = "000000000000000000000002"

    private func ticketOf(_ lamport: Int64, _ actorID: String) -> TimeTicket {
        TimeTicket(lamport: lamport, delimiter: 0, actorID: actorID)
    }

    /// Returns a tree whose root holds `sibling` (created by B, with its
    /// `insNextID` pointing at `own`) followed by `own` (created by A) -- the
    /// shape `emptyRunReachesActor` walks: an unknown concurrent split sibling
    /// standing right before this actor's own split product.
    private func buildTree() throws -> (tree: CRDTTree, sibling: CRDTTreeNode, own: CRDTTreeNode, removedChild: CRDTTreeNode) {
        let root = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.ticketOf(1, self.actorA), offset: 0), type: "r")
        let sibling = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.ticketOf(5, self.actorB), offset: 0), type: "p")
        let own = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.ticketOf(6, self.actorA), offset: 0), type: "p")
        let removedChild = CRDTTreeNode(
            id: CRDTTreeNodeID(createdAt: self.ticketOf(7, self.actorB), offset: 0),
            type: DefaultTreeNodeType.text.rawValue,
            value: "ab"
        )
        try sibling.append(contentsOf: [removedChild])
        try root.append(contentsOf: [sibling])
        try root.append(contentsOf: [own])
        sibling.insNextID = own.id

        let tree = CRDTTree(root: root, createdAt: self.ticketOf(1, self.actorA))
        return (tree, sibling, own, removedChild)
    }

    func test_does_not_let_a_tombstone_change_which_side_a_split_lands_on() throws {
        // given
        let (tree, sibling, _, removedChild) = try self.buildTree()

        // when / then -- a child stands between the boundary and our split, so the run is not empty.
        XCTAssertFalse(tree.emptyRunReachesActorForTest(sibling, self.actorA, VersionVector()))

        // Removing that child must not flip the answer. This predicate decides which side of a
        // concurrent boundary an insertion lands on, and every replica has to decide the same way;
        // `isRemoved` is mutable and delivery-order dependent, so reading the removed-filtering
        // `children` here would make a replica that has already applied the removal place the
        // insertion differently from one that has not.
        _ = removedChild.remove(self.ticketOf(8, self.actorA))
        XCTAssertFalse(tree.emptyRunReachesActorForTest(sibling, self.actorA, VersionVector()))
    }

    func test_anchors_an_empty_text_node_on_its_own_id_never_offset_minus_1() throws {
        // given
        let (tree, _, _, _) = try self.buildTree()
        let empty = CRDTTreeNode(
            id: CRDTTreeNodeID(createdAt: self.ticketOf(9, self.actorB), offset: 0),
            type: DefaultTreeNodeType.text.rawValue,
            value: ""
        )

        // when
        let anchor = tree.leftAnchorIDForTest(empty)

        // then -- the empty node anchors on its own id, never one code unit before its own start.
        XCTAssertEqual(anchor.offset, 0)
        XCTAssertEqual(anchor, empty.id)

        // A text node with characters still anchors on its last one.
        let text = CRDTTreeNode(
            id: CRDTTreeNodeID(createdAt: self.ticketOf(10, self.actorB), offset: 3),
            type: DefaultTreeNodeType.text.rawValue,
            value: "abc"
        )
        XCTAssertEqual(tree.leftAnchorIDForTest(text).offset, 5)
    }
}
