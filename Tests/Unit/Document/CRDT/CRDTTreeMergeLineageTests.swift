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

    // MARK: - A merge must not move a node under itself (yorkie-js-sdk#1478)

    private typealias EditResult = (pairs: [GCPair], removedNodes: [CRDTTreeNode], stranded: [CRDTTreeNode])

    /// `editWithTimeout` runs the merge edit off the test thread. The edit is synchronous, so a
    /// regression of the cycle guard spins `updateAncestorsSize` forever and no XCTest timeout can
    /// interrupt it: the test would hang the whole run instead of failing. Waiting on an
    /// expectation turns that hang into a failure (the stuck worker is abandoned until the test
    /// process exits).
    private func editWithTimeout(_ tree: CRDTTree, _ range: TreePosRange) -> EditResult? {
        final class Box: @unchecked Sendable {
            var result: EditResult?
            var error: Error?
        }
        let box = Box()
        let done = expectation(description: "merge edit returns")
        nonisolated(unsafe) let unsafeTree = tree
        nonisolated(unsafe) let unsafeRange = range
        let queue = DispatchQueue(label: "merge-lineage-edit")
        queue.async {
            do {
                let out = try unsafeTree.edit(unsafeRange, nil, 0, timeT(), timeT, nil)
                box.result = (out.1, out.3, out.13)
            } catch {
                box.error = error
            }
            done.fulfill()
        }
        let outcome = XCTWaiter().wait(for: [done], timeout: 10)
        XCTAssertEqual(outcome, .completed, "the merge edit never returned: a parent cycle was closed")
        if outcome == .completed, let error = box.error {
            XCTFail("edit threw: \(error)")
        }
        return outcome == .completed ? box.result : nil
    }

    private func node(_ type: String) -> CRDTTreeNode {
        CRDTTreeNode(id: posT(), type: type)
    }

    private func text(_ value: String) -> CRDTTreeNode {
        CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: value as NSString)
    }

    private struct CycleCase {
        let name: String
        let carrier: String
        let dest: String
    }

    // swiftlint:disable identifier_name
    func test_a_merge_should_not_move_a_node_under_itself() throws {
        for tc in [
            CycleCase(name: "the moved node", carrier: "d", dest: "c"),
            CycleCase(name: "a node inside it", carrier: "e", dest: "d")
        ] {
            // <r><a>x</a><b><c><d>e</d></c></b></r> with a tombstoned and one node carrying
            // mergedFrom = a, as an element payload may: rebuildMergeState then points a at that
            // node's parent. A merge of b into a resolves its destination through that pointer, so
            // it lands on c, the child it moves, or on d inside it. Moving c there would close a
            // parent cycle in the index tree and every later ancestor walk would spin forever.
            let n = [
                "r": self.node("r"), "a": self.node("a"), "x": self.text("x"), "b": self.node("b"),
                "c": self.node("c"), "d": self.node("d"), "e": self.text("e")
            ]
            try n["r"]!.append(contentsOf: [n["a"]!, n["b"]!])
            try n["a"]!.append(contentsOf: [n["x"]!])
            try n["b"]!.append(contentsOf: [n["c"]!])
            try n["c"]!.append(contentsOf: [n["d"]!])
            try n["d"]!.append(contentsOf: [n["e"]!])
            _ = n["a"]!.remove(timeT())
            n[tc.carrier]!.mergedFrom = n["a"]!.id
            n[tc.carrier]!.mergedAt = timeT()

            // Re-read exactly as the converter re-reads an element payload.
            let tree = CRDTTree(root: n["r"]!, createdAt: timeT())
            XCTAssertEqual(n["a"]!.mergedInto, n[tc.dest]!.id, tc.name)

            // b is the range this edit consumes and all of it is live, so the removed size has to
            // come back as b's pre-edit size.
            let bSize = n["b"]!.paddedSize

            let result = try XCTUnwrap(self.editWithTimeout(tree, (
                CRDTTreePos(parentID: n["a"]!.id, leftSiblingID: n["x"]!.id),
                CRDTTreePos(parentID: n["b"]!.id, leftSiblingID: n["b"]!.id)
            )))

            XCTAssertTrue(n["c"]!.parent === n["b"]!, "c stays where it was instead of moving under itself (\(tc.name))")
            XCTAssertTrue(n["d"]!.parent === n["c"]!)
            XCTAssertNil(n["c"]!.mergedFrom, "a refused child is not stamped as moved")
            XCTAssertNil(n["b"]!.mergedInto, "no moved child names b, so neither runtime nor rebuild points it")
            XCTAssertEqual(tree.toXML(), "<r></r>")

            // Left live under b, which this edit tombstoned, the skipped child would be detached by
            // b's purge while it stays registered. It is tombstoned in place with its descendants,
            // and each gets a GC pair.
            for key in ["c", "d", "e"] {
                let refused = n[key]!
                XCTAssertTrue(refused.isRemoved, "a refused child is tombstoned (\(key))")
                XCTAssertTrue(result.pairs.contains { ($0.child as? CRDTTreeNode) === refused }, "and booked for GC (\(key))")
                XCTAssertTrue(result.stranded.contains { $0 === refused }, "and reported as stranded (\(key))")
            }

            // The stranded subtree is not in removedNodes -- the merge had collected it to move --
            // yet the range the edit consumed includes it.
            let removedSize = (result.removedNodes + result.stranded).reduce(0) { $0 + $1.paddedSize }
            XCTAssertEqual(removedSize, bSize, tc.name)
        }
    }

    func test_a_merge_should_strand_the_children_after_one_the_cycle_guard_refused() throws {
        // <r><a>x</a><b><c><d>e</d></c><f>g</f></b></r> with a tombstoned and e carrying
        // mergedFrom = a, so a forwards to d. The merge of b into a collects both c and f to move;
        // the guard refuses c and tombstones it, and d with it. f, later in the same list, must not
        // then move under the tombstoned d: it is tombstoned in place too.
        let r = self.node("r"), a = self.node("a"), x = self.text("x"), b = self.node("b")
        let c = self.node("c"), d = self.node("d"), e = self.text("e"), f = self.node("f"), g = self.text("g")
        try r.append(contentsOf: [a, b])
        try a.append(contentsOf: [x])
        try b.append(contentsOf: [c, f])
        try c.append(contentsOf: [d])
        try d.append(contentsOf: [e])
        try f.append(contentsOf: [g])
        _ = a.remove(timeT())
        e.mergedFrom = a.id
        e.mergedAt = timeT()

        let tree = CRDTTree(root: r, createdAt: timeT())
        XCTAssertEqual(a.mergedInto, d.id)

        let result = try XCTUnwrap(self.editWithTimeout(tree, (
            CRDTTreePos(parentID: a.id, leftSiblingID: x.id),
            CRDTTreePos(parentID: b.id, leftSiblingID: b.id)
        )))

        XCTAssertTrue(f.parent === b, "a child must not move under a destination the guard just tombstoned")
        XCTAssertNil(f.mergedFrom, "a stranded child is not stamped")
        for node in [c, d, e, f, g] {
            XCTAssertTrue(node.isRemoved, "a stranded node is tombstoned")
            XCTAssertTrue(result.pairs.contains { ($0.child as? CRDTTreeNode) === node }, "and booked for GC")
            XCTAssertTrue(result.stranded.contains { $0 === node })
        }
    }
    // swiftlint:enable identifier_name
}
