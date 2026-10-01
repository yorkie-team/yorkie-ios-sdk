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

/// Ported from yorkie-js-sdk PR #1364 (commit 248551a1, yorkie-team/yorkie#2008):
/// `packages/sdk/test/unit/document/crdt/tree_to_tree_pos_test.ts`.
///
/// `toTreePos` (reached here through the public ``CRDTTree/toIndex(_:_:_:)``)
/// walks up from a removed node until it finds one that is still alive,
/// dereferencing `parent` on every hop. `purge` unlinks a node by clearing its
/// own `parent` link and touches none of its children, so a chain that ends in
/// a purged node runs the walk off the top of the tree.
///
/// This drives the state directly rather than through an undo, on purpose. The
/// restore path that used to produce it no longer can -- `recreateFromSpan` now
/// refuses to place a node live under a tombstone -- so a test that reached the
/// guard through a document-level history would stop reaching it and start
/// passing without exercising anything. The guard is defence in depth and
/// outlives the one sequence that was known to need it, so it is pinned here at
/// the level it lives at.
///
/// Mirrors the JS/Go tests of the same name so all SDKs fail the same way on
/// the same shape.
final class CRDTTreeToTreePosTests: XCTestCase {
    /// `buildHelloTree` builds `<r><p>hello</p></r>`.
    private func buildHelloTree() throws -> CRDTTree {
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: "r"), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((1, 1),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "hello")],
                       0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), "<r><p>hello</p></r>")
        return tree
    }

    func test_rejects_a_chain_ending_in_a_purged_node() throws {
        // given
        let tree = try buildHelloTree()
        let paragraph = try XCTUnwrap(tree.root.innerChildren.first)
        let text = try XCTUnwrap(paragraph.innerChildren.first)

        // Remove the whole <p>, tombstoning it and its text.
        try tree.editT((0, 7), nil, 0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), "<r></r>")
        XCTAssertTrue(paragraph.isRemoved)
        XCTAssertTrue(text.isRemoved)

        // Purge <p> while its text child is still around. Purge clears the purged
        // node's own parent link and touches none of its children, so the text
        // node keeps pointing at a <p> that no longer hangs off the root.
        tree.purge(node: paragraph)
        XCTAssertNil(paragraph.parent, "purge unlinks the node it purges")
        XCTAssertNotNil(text.parent, "but leaves its children pointing at it")

        // when / then — resolving a position anchored at the text node now walks
        // text -> <p> -> nil. Before the guard this force-unwrapped nil and
        // crashed deep inside the walk.
        XCTAssertThrowsError(try tree.toIndex(text, text)) { error in
            guard let yorkieError = error as? YorkieError else {
                XCTFail("expected YorkieError")
                return
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument)
            XCTAssertTrue(yorkieError.message.contains("node not found"), "unexpected message: \(yorkieError.message)")
        }
    }

    func test_still_resolves_through_a_removed_parent_that_has_a_live_ancestor() throws {
        // given
        let tree = try buildHelloTree()
        let paragraph = try XCTUnwrap(tree.root.innerChildren.first)
        let text = try XCTUnwrap(paragraph.innerChildren.first)

        try tree.editT((0, 7), nil, 0, timeT(), timeT)
        XCTAssertTrue(text.isRemoved)

        // when — nothing is purged, so the walk from the removed text node
        // reaches the live root and resolves normally.
        let index = try tree.toIndex(text, text)

        // then
        XCTAssertGreaterThanOrEqual(index, 0)
    }
}
