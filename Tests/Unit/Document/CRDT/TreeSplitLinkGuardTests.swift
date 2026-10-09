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

// Ports: packages/sdk/test/unit/document/tree_split_link_guard_test.ts
// (yorkie-js-sdk#1375, commit c8928853, "Order concurrent splits of one
// boundary by ticket").
//
// `insNextID` is a structural pointer that only `splitElement` is supposed to
// write, but the wire format carries it on every tree node, so a document
// rebuilt from stored client changes can hold a chain that loops back on
// itself. An unbounded walk of that chain spins the applying task forever --
// and `collectUnknownSplitSiblings`'s cascade also appends to its result on
// every turn, so it burns memory while it spins.
//
// The converter now strips the field from client-supplied content
// (`fromTreeNodesWhenEdit` for operation content, `dropSplitLinksInElement`
// for the element bytes a Set/Add/ArraySet carries), so these chains should no
// longer be constructible. The walks stay bounded anyway: documents stored
// before that already carry whatever a client sent.

import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

// `knownActor` creates the nodes the operation under test knows about.
private let knownActor: ActorID = "000000000000000000000001"
// `cycleActor` creates the two nodes that point at each other. They have to be
// unknown to the operation's version vector: that is the only case these
// walks follow the chain at all.
private let cycleActor: ActorID = "000000000000000000000002"
// `remoteActor` runs the operation.
private let remoteActor: ActorID = "000000000000000000000003"

/// `ticketer` hands out tickets with increasing lamports for a given actor.
private func ticketer() -> (ActorID) -> TimeTicket {
    var lamport: Int64 = 0
    return { actor in
        lamport += 1
        return TimeTicket(lamport: lamport, delimiter: 0, actorID: actor)
    }
}

final class TreeSplitLinkGuardTests: XCTestCase {
    /// `poisonedTree` builds
    ///
    ///     <r><p>ab</p><p></p><p></p><p>cd</p></r>
    ///
    /// where the two middle paragraphs were created by `cycleActor` and point
    /// at each other through `insNextID`, and both the first paragraph and its
    /// text node link into that cycle. Every `insNextID` walk reachable from
    /// the first paragraph runs into it.
    @MainActor
    private func poisonedTree() throws -> CRDTTree {
        let issue = ticketer()
        func node(_ actor: ActorID, _ type: String, _ value: String? = nil) -> CRDTTreeNode {
            CRDTTreeNode(id: CRDTTreeNodeID(createdAt: issue(actor), offset: 0), type: type, value: value as NSString?)
        }
        let issueKnown = { issue(knownActor) }

        let tree = CRDTTree(root: node(knownActor, "r"), createdAt: issue(knownActor))

        let first = node(knownActor, "p")
        try tree.editT((0, 0), [first], 0, issueKnown(), issueKnown)

        let text = node(knownActor, "text", "ab")
        try tree.editT((1, 1), [text], 0, issueKnown(), issueKnown)

        let left = node(cycleActor, "p")
        try tree.editT((4, 4), [left], 0, issueKnown(), issueKnown)

        let right = node(cycleActor, "p")
        try tree.editT((6, 6), [right], 0, issueKnown(), issueKnown)

        let last = node(knownActor, "p")
        try tree.editT((8, 8), [last], 0, issueKnown(), issueKnown)

        try tree.editT((9, 9), [node(knownActor, "text", "cd")], 0, issueKnown(), issueKnown)

        XCTAssertEqual(tree.toXML(), "<r><p>ab</p><p></p><p></p><p>cd</p></r>")

        text.insNextID = left.id
        first.insNextID = left.id
        left.insNextID = right.id
        right.insNextID = left.id

        return tree
    }

    private var editedAt: TimeTicket {
        TimeTicket(lamport: .max, delimiter: 0, actorID: remoteActor)
    }

    // `knownActor`'s nodes are known, `cycleActor`'s are not.
    private var vector: VersionVector {
        VersionVector(vector: [knownActor: .max, remoteActor: .max])
    }

    /// `edit` walks the chain twice: Phase 3 range narrowing follows
    /// `fromLeft`'s chain looking for a sibling under `toParent`, and
    /// `collectUnknownSplitSiblings` cascades the delete to unknown split
    /// siblings of every element it removes.
    @MainActor
    func test_edit_over_the_cycle_terminates() throws {
        // given
        let tree = try self.poisonedTree()
        let range: TreePosRange = try (tree.findPos(3), tree.findPos(11))

        // when / then
        let editedAt = self.editedAt
        XCTAssertNoThrow(try tree.edit(range, nil, 0, editedAt, { editedAt }, self.vector))
        _ = tree.toXML()
    }

    /// `style` propagates to unknown split siblings along the same chain.
    @MainActor
    func test_style_over_the_cycle_terminates() throws {
        // given
        let tree = try self.poisonedTree()
        let range: TreePosRange = try (tree.findPos(0), tree.findPos(12))

        // when / then
        XCTAssertNoThrow(try tree.style(range, ["b": "t"], self.editedAt, self.vector))
        _ = tree.toXML()
    }

    /// `removeStyle` propagates to unknown split siblings along the same
    /// chain.
    @MainActor
    func test_remove_style_over_the_cycle_terminates() throws {
        // given
        let tree = try self.poisonedTree()
        let range: TreePosRange = try (tree.findPos(0), tree.findPos(12))

        // when / then
        XCTAssertNoThrow(try tree.removeStyle(range, ["b"], self.editedAt, self.vector))
        _ = tree.toXML()
    }
}

final class TreeDropSplitLinksTests: XCTestCase {
    /// `dropSplitLinks` clears the links on the node and every descendant.
    @MainActor
    func test_clears_the_links_on_the_node_and_every_descendant() throws {
        // given
        let issue = ticketer()
        func node(_ type: String, _ value: String? = nil) -> CRDTTreeNode {
            CRDTTreeNode(id: CRDTTreeNodeID(createdAt: issue(knownActor), offset: 0), type: type, value: value as NSString?)
        }

        let root = node("r")
        let para = node("p")
        let text = node("text", "ab")
        try root.append(contentsOf: [para])
        try para.append(contentsOf: [text])

        let other = CRDTTreeNodeID(createdAt: issue(cycleActor), offset: 0)
        root.insNextID = other
        para.insPrevID = other
        para.insNextID = other
        text.insNextID = other

        // when
        root.dropSplitLinks()

        // then
        for node in [root, para, text] {
            XCTAssertNil(node.insPrevID)
            XCTAssertNil(node.insNextID)
        }
    }
}
