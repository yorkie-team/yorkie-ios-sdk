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
/// `packages/sdk/test/unit/document/undo_content_identity_test.ts`
/// (yorkie-js-sdk#1319 "Stop undo and element splits from reusing a node's
/// identity").
///
/// A reverse operation that re-inserts a copy of the nodes an edit removed
/// carries their original ids. Inserting them again would put two nodes under
/// one id, which is what makes a position anchored there ambiguous. Undo
/// gives a restored value a new identity elsewhere already — `ArraySetOperation`
/// and `AddOperation` both take a fresh ticket in `Document.executeUndoRedo`
/// — and the tree's copy path is the one that did not, until
/// `TreeEditOperation.reissueContentIDs` closed the gap.
final class TreeEditOperationReissueContentIDsTests: XCTestCase {
    /// Collects the ids of a content subtree.
    private func idsOf(_ contents: [CRDTTreeNode]) -> [String] {
        var ids = [String]()
        for content in contents {
            traverseAll(node: content) { node, _ in ids.append(node.toIDString) }
        }
        return ids
    }

    func test_gives_copied_content_a_fresh_identity() throws {
        // given
        let pos = CRDTTreePos(parentID: posT(), leftSiblingID: posT())
        let p = CRDTTreeNode(id: posT(), type: "p")
        try p.append(contentsOf: [
            CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "a"),
            CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "b")
        ])

        let op = TreeEditOperation(
            parentCreatedAt: timeT(),
            fromPos: pos,
            toPos: pos,
            contents: [p],
            splitLevel: 0,
            executedAt: timeT(),
            isUndoOp: true
        )
        let before = self.idsOf(op.contents!)

        // when
        try op.reissueContentIDs { timeT() }

        // then
        let after = self.idsOf(op.contents!)
        // The count is stated rather than derived from the same traversal the
        // reissue uses, so a traversal that skipped a node would show up here.
        XCTAssertEqual(after.count, 3, "the <p> and its two texts")
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(Set(after).count, after.count, "every node gets its own id")
        for id in after {
            XCTAssertFalse(before.contains(id), "no node keeps the id it was copied from")
        }
    }

    // Deliberately over-constrained: a restore reverse is built with no
    // contents at all in production, so this pins the guard rather than a
    // shape production emits.
    func test_leaves_a_restore_mode_reverse_alone() throws {
        // given
        let pos = CRDTTreePos(parentID: posT(), leftSiblingID: posT())
        let node = CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "a")
        let op = TreeEditOperation(
            parentCreatedAt: timeT(),
            fromPos: pos,
            toPos: pos,
            contents: [node],
            splitLevel: 0,
            executedAt: timeT(),
            isUndoOp: true,
            restoreSpans: [],
            restoreMode: .restore,
            retombstoneSpans: []
        )
        let before = self.idsOf(op.contents!)

        // when
        try op.reissueContentIDs { timeT() }

        // then
        XCTAssertEqual(self.idsOf(op.contents!), before, "a restore revives nodes by identity and must keep it")
    }

    func test_assigns_ids_that_a_later_reissue_does_not_repeat() throws {
        // given
        let pos = CRDTTreePos(parentID: posT(), leftSiblingID: posT())
        let first = CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "a")
        let second = CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "a")

        let opA = TreeEditOperation(parentCreatedAt: timeT(), fromPos: pos, toPos: pos, contents: [first], splitLevel: 0, executedAt: timeT(), isUndoOp: true)
        let opB = TreeEditOperation(parentCreatedAt: timeT(), fromPos: pos, toPos: pos, contents: [second], splitLevel: 0, executedAt: timeT(), isUndoOp: true)

        // when
        try opA.reissueContentIDs { timeT() }
        try opB.reissueContentIDs { timeT() }

        // then
        XCTAssertNotEqual(self.idsOf(opA.contents!), self.idsOf(opB.contents!))
    }

    func test_refuses_to_reissue_ids_on_a_splitting_edit() throws {
        // given — `reissueContentIDs` relies on the reconstruction's simulated
        // delimiter range never overlapping the ids it assigns, which only
        // holds while the operation carries no split (see the doc comment on
        // `reissueContentIDs`).
        let pos = CRDTTreePos(parentID: posT(), leftSiblingID: posT())
        let node = CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "a")
        let op = TreeEditOperation(
            parentCreatedAt: timeT(),
            fromPos: pos,
            toPos: pos,
            contents: [node],
            splitLevel: 1,
            executedAt: timeT(),
            isUndoOp: true
        )

        // when / then
        XCTAssertThrowsError(try op.reissueContentIDs { timeT() }) { error in
            XCTAssertEqual((error as? YorkieError)?.code, .errRefused)
        }
    }
}
