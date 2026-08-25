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
/// `packages/sdk/test/unit/document/undo_copy_path_test.ts`
/// (yorkie-js-sdk#1319 "Stop undo and element splits from reusing a node's
/// identity").
///
/// These drive a real undo/redo through the copy-reinsert reverse — the one
/// that re-inserts the nodes a deletion removed instead of reviving them by
/// identity. `CRDTTree.edit` only fills the identity spans when the edit was
/// merge- and split-free, so the copy path is what remains for merge
/// propagation and for reverse operations older SDKs left on an undo stack.
/// Neither is reachable through ordinary editing, so the spans are blanked
/// here to reproduce it faithfully.
///
/// The JS test reproduces this by monkey-patching `CRDTTree.prototype.edit`.
/// `CRDTTree` is not `final`, so the Swift port subclasses it instead and
/// overrides `edit` to blank the same two return values.
final class CRDTTreeUndoCopyPathTests: XCTestCase {
    /// Forces every edit through this tree onto the copy-reinsert reverse
    /// path by blanking the identity spans (`removedSpans` / `insertedSpans`,
    /// tuple positions 7 and 8) that `CRDTTree.edit` would otherwise fill —
    /// the same shape `toReverseOperation` sees for a merge- or split-touched
    /// edit, or a reverse an older SDK left on an undo stack.
    private final class CopyPathForcingCRDTTree: CRDTTree {
        override func edit(
            _ range: TreePosRange,
            _ contents: [CRDTTreeNode]?,
            _ splitLevel: Int32,
            _ editedAt: TimeTicket,
            _ issueTimeTicket: () -> TimeTicket,
            _ versionVector: VersionVector?
        ) throws -> ([TreeChange], [GCPair], DataSize, [CRDTTreeNode], Int, Int, Set<String>, [TreeRestoreSpan], [TreeRestoreSpan], Int) {
            var result = try super.edit(range, contents, splitLevel, editedAt, issueTimeTicket, versionVector)
            result.7 = []
            result.8 = []
            return result
        }
    }

    /// Returns a root that resolves the tree by its creation ticket (as
    /// `TreeEditOperation.execute` requires) and the tree itself, holding
    /// `<r><p>abcdef</p></r>`.
    private func buildDoc() throws -> (root: CRDTRoot, tree: CRDTTree) {
        let tree = CopyPathForcingCRDTTree(root: CRDTTreeNode(id: posT(), type: "r"), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT(
            (1, 1),
            [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "abcdef")],
            0, timeT(), timeT
        )
        XCTAssertEqual(tree.toXML(), "<r><p>abcdef</p></r>")

        let root = CRDTRoot(rootObject: CRDTObject(createdAt: TimeTicket.initial))
        root.registerElement(tree, parent: nil)
        return (root, tree)
    }

    /// Returns the ids that name more than one node in the tree.
    private func duplicatedIDs(_ tree: CRDTTree) -> [String] {
        var counts = [String: Int]()
        tree.indexTree.traverseAll { node, _ in
            counts[node.toIDString, default: 0] += 1
        }
        return counts.filter { $0.value > 1 }.map { $0.key }
    }

    /// Deletes "bcd" (leaving "aef") through the copy-path-forced tree and
    /// returns the executed delete op alongside its reverse (undo) op — the
    /// content-copy shape `toReverseOperation` falls back to.
    private func deleteBCD(_ root: CRDTRoot, _ tree: CRDTTree) throws -> TreeEditOperation {
        let fromPos = try tree.findPos(2)
        let toPos = try tree.findPos(5)
        let deleteOp = TreeEditOperation(
            parentCreatedAt: tree.createdAt,
            fromPos: fromPos,
            toPos: toPos,
            contents: nil,
            splitLevel: 0,
            executedAt: timeT()
        )
        let result = try deleteOp.execute(root: root)
        XCTAssertEqual(tree.toXML(), "<r><p>aef</p></r>")
        return try XCTUnwrap(result?.reverseOp as? TreeEditOperation)
    }

    func test_restores_the_text_without_duplicating_an_id() throws {
        // given
        let (root, tree) = try self.buildDoc()
        let before = tree.toXML()
        let reverseOp = try self.deleteBCD(root, tree)
        XCTAssertNotNil(reverseOp.contents, "the copy path re-inserts the removed nodes as content")

        // when — drive the undo exactly as `Document.executeUndoRedo` does:
        // assign a fresh executedAt, reissue the reverse op's content ids,
        // then execute it.
        reverseOp.executedAt = timeT()
        try reverseOp.reissueContentIDs { timeT() }
        try reverseOp.execute(root: root)

        // then
        XCTAssertEqual(tree.toXML(), before, "the undo restores the text")
        XCTAssertEqual(self.duplicatedIDs(tree), [], "the re-inserted copy must not reuse the tombstone it came from")
    }

    func test_does_not_splice_the_copy_into_the_chain_it_came_from() throws {
        // given
        let (root, tree) = try self.buildDoc()
        let reverseOp = try self.deleteBCD(root, tree)

        var before = Set<String>()
        tree.indexTree.traverseAll { node, _ in before.insert(node.toIDString) }

        // when
        reverseOp.executedAt = timeT()
        try reverseOp.reissueContentIDs { timeT() }
        try reverseOp.execute(root: root)

        // then
        var insertedCount = 0
        tree.indexTree.traverseAll { node, _ in
            let id = node.toIDString
            if before.contains(id) {
                return
            }
            insertedCount += 1
            // The copy came from a deepcopy of a node the deletion removed,
            // which carries that node's split chain and merge lineage. A
            // fresh identity has to be fresh in those too, or the copy is
            // spliced into a chain it never belonged to.
            XCTAssertNil(node.insPrevID, "\(id) kept a split chain")
            XCTAssertNil(node.insNextID, "\(id) kept a split chain")
            XCTAssertNil(node.mergedFrom, "\(id) kept a merge lineage")
            XCTAssertNil(node.mergedAt, "\(id) kept a merge lineage")
        }
        XCTAssertGreaterThan(insertedCount, 0, "the undo re-inserted the removed content")
    }

    func test_returns_to_the_deleted_state_on_redo() throws {
        // given
        let (root, tree) = try self.buildDoc()
        let undoOp = try self.deleteBCD(root, tree)
        let deleted = tree.toXML()

        undoOp.executedAt = timeT()
        try undoOp.reissueContentIDs { timeT() }
        let undoResult = try undoOp.execute(root: root)

        // when
        let redoOp = try XCTUnwrap(undoResult?.reverseOp as? TreeEditOperation)
        redoOp.executedAt = timeT()
        try redoOp.reissueContentIDs { timeT() }
        try redoOp.execute(root: root)

        // then
        XCTAssertEqual(tree.toXML(), deleted)
        XCTAssertEqual(self.duplicatedIDs(tree), [])
    }
}
