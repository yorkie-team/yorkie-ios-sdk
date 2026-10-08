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

/// A merge pointer (`mergedFrom`, and the `mergedInto` derived from it) is not always
/// server-derived: an element payload (Set/Add/ArraySet) keeps the lineage a reverse-of-Remove
/// legitimately carries, so both ends of a merge relation can be client-supplied. Every reader
/// therefore resolves them to the exact element they name, never to a floor match or a text node.
/// Ported from yorkie-js-sdk#1406 "Sync the protos with Go and harden crafted tree payloads",
/// `tree_merge_lineage_test.ts` (mirrors yorkie's `tree_merge_lineage_test.go`, yorkie#2033).
final class CRDTTreeMergeLineageTests: XCTestCase {
    private struct Fixture {
        let tree: CRDTTree
        let p1: CRDTTreeNode
        let p2: CRDTTreeNode
        let p3: CRDTTreeNode
        let text: CRDTTreeNode
    }

    /// `buildFixture` builds `<r><p></p><p>cd</p><p></p></r>`: p1 is the merge destination, p2
    /// holds the text that carries a lineage, and p3 is the unrelated live element a forged
    /// pointer tries to name.
    private func buildFixture() throws -> Fixture {
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: "r"), createdAt: timeT())
        let p1ID = posT()
        let p2ID = posT()
        let p3ID = posT()
        let textID = posT()
        try tree.editT((0, 0), [CRDTTreeNode(id: p1ID, type: "p")], 0, timeT(), timeT)
        try tree.editT((2, 2), [CRDTTreeNode(id: p2ID, type: "p")], 0, timeT(), timeT)
        try tree.editT((3, 3), [CRDTTreeNode(id: textID, type: DefaultTreeNodeType.text.rawValue, value: "cd")], 0, timeT(), timeT)
        try tree.editT((6, 6), [CRDTTreeNode(id: p3ID, type: "p")], 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), "<r><p></p><p>cd</p><p></p></r>")

        return try Fixture(
            tree: tree,
            p1: XCTUnwrap(tree.findFloorNode(p1ID)),
            p2: XCTUnwrap(tree.findFloorNode(p2ID)),
            p3: XCTUnwrap(tree.findFloorNode(p3ID)),
            text: XCTUnwrap(tree.findFloorNode(textID))
        )
    }

    /// `forgedIDOf` returns an id with the node's createdAt and an offset the node never had: a
    /// floor lookup answers with the node, an exact lookup does not.
    private func forgedIDOf(_ node: CRDTTreeNode) -> CRDTTreeNodeID {
        CRDTTreeNodeID(createdAt: node.id.createdAt, offset: node.id.offset + 9)
    }

    func test_rebuildMergeState_should_not_plant_a_pointer_through_a_forged_source() throws {
        // given -- tombstoned, so the "a live element is never a merge
        // source" guard is satisfied and the forged offset is the only thing
        // left to reject it: the test fails if the resolver here goes back
        // to a floor lookup.
        let fixture = try self.buildFixture()
        fixture.p3.removedAt = timeT()
        fixture.text.mergedFrom = self.forgedIDOf(fixture.p3)
        fixture.text.mergedAt = timeT()

        // when -- re-read exactly as the converter re-reads an element payload.
        _ = CRDTTree(root: fixture.tree.root, createdAt: timeT())

        // then
        XCTAssertNil(fixture.p3.mergedInto, "a later delete would follow this pointer and tombstone p3 children")
    }

    func test_rebuildMergeState_should_still_rebuild_a_genuine_source() throws {
        // given -- a genuine source is a tombstone: the merge removes the
        // boundary element before moving its children out of it.
        let fixture = try self.buildFixture()
        fixture.p3.removedAt = timeT()
        fixture.text.mergedFrom = fixture.p3.id
        fixture.text.mergedAt = timeT()

        // when
        _ = CRDTTree(root: fixture.tree.root, createdAt: timeT())

        // then
        XCTAssertEqual(fixture.p3.mergedInto, fixture.p2.id)
    }

    func test_rebuildMergeState_should_not_plant_a_pointer_on_a_live_source() throws {
        // given -- the id is exact and names an element, so the shape checks
        // pass; only the source being live says no merge ever moved these
        // children. Planting here would arm the merge-delete cascade to
        // tombstone p3's own children the moment a later, unrelated edit
        // removes p3.
        let fixture = try self.buildFixture()
        fixture.text.mergedFrom = fixture.p3.id
        fixture.text.mergedAt = timeT()
        XCTAssertNil(fixture.p3.removedAt)

        // when
        _ = CRDTTree(root: fixture.tree.root, createdAt: timeT())

        // then
        XCTAssertNil(fixture.p3.mergedInto)
    }

    func test_rebuildMergeState_should_not_name_a_text_node_as_a_source() throws {
        // given -- removed as a genuine source would be, so only its being a
        // text node rejects it: the id is exact and the child's parent is an
        // element.
        let fixture = try self.buildFixture()
        fixture.text.removedAt = timeT()
        fixture.p2.mergedFrom = fixture.text.id
        fixture.p2.mergedAt = timeT()

        // when
        _ = CRDTTree(root: fixture.tree.root, createdAt: timeT())

        // then
        XCTAssertNil(fixture.text.mergedInto)
    }

    func test_rebuildMergeState_should_not_name_a_text_node_as_a_destination() throws {
        // given -- a merge moves children under an element, so a child
        // sitting under a text node cannot be one a merge moved. `prepend`
        // refuses the shape, so plant it directly, as a decoder that did not
        // check would.
        let fixture = try self.buildFixture()
        // Exact and tombstoned, so the source passes every other guard and
        // only the destination being a text node is left to reject the
        // pointer.
        fixture.p3.removedAt = timeT()
        let child = CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "x")
        child.mergedFrom = fixture.p3.id
        child.mergedAt = timeT()
        fixture.text.innerChildren.append(child)
        child.parent = fixture.text

        // when
        _ = CRDTTree(root: fixture.tree.root, createdAt: timeT())

        // then
        XCTAssertNil(fixture.p3.mergedInto)
    }

    func test_a_merge_should_not_re_derive_a_pointer_from_a_forged_source() throws {
        // given -- the lineage stays on the node inside the live document,
        // and a merge re-derives `mergedInto` from it whenever it moves that
        // node again. Resolved by floor there, the forged offset would plant
        // on p3 the pointer the decode refused to.
        let fixture = try self.buildFixture()
        // Tombstoned, as a genuine source is, so the merge's own "the source
        // must already be removed" guard cannot be what rejects this: the
        // forged offset has to be.
        fixture.p3.removedAt = timeT()
        fixture.text.mergedFrom = self.forgedIDOf(fixture.p3)
        fixture.text.mergedAt = timeT()

        // when -- an ordinary merge of p2 into p1 moves the text carrying the lineage.
        try fixture.tree.editT((1, 3), nil, 0, timeT(), timeT)
        XCTAssertEqual(fixture.tree.toXML(), "<r><p>cd</p></r>")

        // then
        XCTAssertNil(fixture.p3.mergedInto, "an ordinary merge must not plant a pointer on an unrelated node")
    }

    func test_a_merge_should_not_re_derive_a_pointer_onto_a_live_source() throws {
        // given -- same path, the other half of the rule: the id is exact
        // and names an element, so only p3 still being live says no merge
        // ever moved this text out of it.
        let fixture = try self.buildFixture()
        fixture.text.mergedFrom = fixture.p3.id
        fixture.text.mergedAt = timeT()
        XCTAssertNil(fixture.p3.removedAt)

        // when
        try fixture.tree.editT((1, 3), nil, 0, timeT(), timeT)
        XCTAssertEqual(fixture.tree.toXML(), "<r><p>cd</p><p></p></r>")

        // then
        XCTAssertNil(fixture.p3.mergedInto, "an ordinary merge must not plant a pointer on a live node")
    }

    func test_a_merge_should_still_re_derive_a_pointer_from_its_own_source() throws {
        // given / when -- the positive control for both guards above: in a
        // merge the engine itself stamps, the source is the boundary element
        // step 02 tombstoned, named exactly, so the pointer must still be
        // planted.
        let fixture = try self.buildFixture()

        try fixture.tree.editT((1, 3), nil, 0, timeT(), timeT)
        XCTAssertEqual(fixture.tree.toXML(), "<r><p>cd</p><p></p></r>")

        // then
        XCTAssertEqual(fixture.text.mergedFrom, fixture.p2.id)
        XCTAssertTrue(fixture.p2.isRemoved)
        XCTAssertEqual(fixture.p2.mergedInto, fixture.p1.id)
    }

    func test_a_delete_should_not_cascade_through_a_floor_only_destination() throws {
        // given -- p1 holds a child whose lineage names p2, and p2's pointer
        // floors onto p1 without naming it. Deleting p2 must not tombstone
        // p1's child.
        let fixture = try self.buildFixture()
        try fixture.tree.editT((1, 1), [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "ab")], 0, timeT(), timeT)
        let ab = try XCTUnwrap(fixture.p1.innerChildren.first)
        ab.mergedFrom = fixture.p2.id
        ab.mergedAt = timeT()
        fixture.p2.mergedInto = self.forgedIDOf(fixture.p1)

        // when -- delete p2 whole: <r><p>ab</p>|<p>cd</p>|<p></p></r>.
        try fixture.tree.editT((4, 8), nil, 0, timeT(), timeT)

        // then
        XCTAssertEqual(fixture.tree.toXML(), "<r><p>ab</p><p></p></r>")
    }

    func test_resolveMergeTarget_should_not_forward_to_a_text_node() throws {
        // given
        let fixture = try self.buildFixture()
        fixture.p1.removedAt = timeT()
        fixture.p1.mergedInto = fixture.text.id

        // when
        let target = fixture.tree.resolveMergeTargetForTest(fixture.p1)

        // then
        XCTAssertTrue(target === fixture.p1)
    }

    func test_an_insert_should_not_be_redirected_into_a_text_node() throws {
        // given -- the merge-destination redirect parks an insert at the
        // leftmost of a merged-away parent into its merge target. A text
        // node can hold no children, so a pointer naming one must fall
        // through to the normal path.
        let fixture = try self.buildFixture()
        try fixture.tree.editT((0, 2), nil, 0, timeT(), timeT)
        XCTAssertEqual(fixture.tree.toXML(), "<r><p>cd</p><p></p></r>")
        fixture.p1.mergedInto = fixture.text.id

        let pos = CRDTTreePos(parentID: fixture.p1.id, leftSiblingID: fixture.p1.id)
        let inserted = CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "x")

        // when
        _ = try fixture.tree.edit((pos, pos), [inserted], 0, timeT(), timeT)

        // then -- `toXML` renders a text node's own value and never walks its
        // children, so the XML is identical whether the redirect fired or
        // not: assert on where the node actually landed instead. The
        // fall-through parks it under the removed p1, where the born-dead
        // branch tombstones it.
        XCTAssertTrue(inserted.parent === fixture.p1)
        XCTAssertEqual(fixture.text.innerChildren.count, 0)
        XCTAssertEqual(fixture.tree.toXML(), "<r><p>cd</p><p></p></r>")
    }
}
