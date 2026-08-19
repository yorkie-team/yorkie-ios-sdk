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

/// Unit coverage for the v0.7.14 identity-preserving Tree restore
/// (yorkie-js-sdk#1297) and the merge-tombstone move it depends on
/// (yorkie-js-sdk#1303).
final class TreeRestoreTests: XCTestCase {
    /// Regression: `recreateFromSpan` must slice the span's text in UTF-16 with an
    /// EXCLUSIVE end. `String.substring(from:to:)` treats `to` as inclusive and
    /// indexes by grapheme, so using it produced a recreated node one character
    /// too long whose `size` disagreed with JS — corrupting every ancestor's index
    /// accounting and overlapping the id range of a surviving piece.
    ///
    /// The bug only shows on a PARTIAL gap: when the gap runs to the end of the
    /// span, the inclusive end clamps to `count - 1` and the result looks right.
    func test_recreates_a_prefix_gap_with_exactly_the_requested_length() throws {
        // given — "hello" inserted as one 5-char run, then the whole run purged
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: "root"), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        let textID = posT()
        try tree.editT((1, 1),
                       [CRDTTreeNode(id: textID, type: DefaultTreeNodeType.text.rawValue, value: "hello")],
                       0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), "<root><p>hello</p></root>")

        let paragraph = try XCTUnwrap(tree.root.innerChildren.first)
        let textNode = try XCTUnwrap(paragraph.innerChildren.first)
        textNode.remove(timeT())
        // Purge it through the real GC path so restore must take the recreate
        // branch rather than simply un-tombstoning in place.
        tree.purge(node: textNode)
        XCTAssertEqual(tree.toXML(), "<root><p></p></root>")

        // when — restore only the PREFIX [0, 3) of the original 5-char span. The
        // span still carries the WHOLE original value ("hello"), exactly as
        // `makeRestoreSpan` captured it; the recreate slices the prefix out of
        // it. That is what exposes an inclusive end — the slice must not run on
        // into the 4th character.
        let span = TreeRestoreSpan(id: textID,
                                   nodeType: DefaultTreeNodeType.text.rawValue,
                                   isText: true,
                                   length: 3,
                                   value: "hello",
                                   attrs: nil,
                                   parentID: paragraph.id,
                                   leftSiblingID: nil,
                                   rightSiblingID: nil)
        let (untombstoned, recreated) = try tree.restore([span])

        // then — exactly 3 characters, and `size` agrees with the value length
        XCTAssertTrue(untombstoned.isEmpty, "the node was purged, so nothing can be un-tombstoned")
        let node = try XCTUnwrap(recreated.first)
        XCTAssertEqual(node.value as String, "hel", "an inclusive-end slice would yield 'hell'")
        XCTAssertEqual(node.size, 3, "size must match the UTF-16 length of the recreated value")
        XCTAssertEqual(tree.toXML(), "<root><p>hel</p></root>")
    }

    /// `restore` is idempotent on a live node and revives a tombstoned one in
    /// place, without recreating a duplicate.
    func test_restore_untombstones_in_place_and_is_idempotent() throws {
        // given
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: "root"), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        let textID = posT()
        try tree.editT((1, 1),
                       [CRDTTreeNode(id: textID, type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                       0, timeT(), timeT)
        let paragraph = try XCTUnwrap(tree.root.innerChildren.first)
        let textNode = try XCTUnwrap(paragraph.innerChildren.first)
        textNode.remove(timeT())
        XCTAssertEqual(tree.toXML(), "<root><p></p></root>")

        let span = TreeRestoreSpan(id: textID,
                                   nodeType: DefaultTreeNodeType.text.rawValue,
                                   isText: true,
                                   length: 2,
                                   value: "ab",
                                   attrs: nil,
                                   parentID: paragraph.id,
                                   leftSiblingID: nil,
                                   rightSiblingID: nil)

        // when — restore twice
        let (first, recreatedFirst) = try tree.restore([span])
        let sizeAfterFirst = tree.size
        let (second, recreatedSecond) = try tree.restore([span])

        // then
        XCTAssertEqual(first.count, 1, "the tombstoned node is revived in place")
        XCTAssertTrue(recreatedFirst.isEmpty, "a surviving node is never recreated")
        XCTAssertEqual(tree.toXML(), "<root><p>ab</p></root>")
        XCTAssertTrue(second.isEmpty, "restoring a live node is a no-op")
        XCTAssertTrue(recreatedSecond.isEmpty)
        XCTAssertEqual(tree.size, sizeAfterFirst, "an idempotent restore must not change size")
    }

    /// `retombstone` re-removes by identity and is likewise idempotent, so a redo
    /// applied twice cannot double-count.
    func test_retombstone_removes_by_identity_and_is_idempotent() throws {
        // given
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: "root"), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        let textID = posT()
        try tree.editT((1, 1),
                       [CRDTTreeNode(id: textID, type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                       0, timeT(), timeT)
        let paragraph = try XCTUnwrap(tree.root.innerChildren.first)
        let span = TreeRestoreSpan(id: textID,
                                   nodeType: DefaultTreeNodeType.text.rawValue,
                                   isText: true,
                                   length: 2,
                                   value: "ab",
                                   attrs: nil,
                                   parentID: paragraph.id,
                                   leftSiblingID: nil,
                                   rightSiblingID: nil)

        // when
        let firstPairs = tree.retombstone([span], timeT())
        let xmlAfterFirst = tree.toXML()
        let secondPairs = tree.retombstone([span], timeT())

        // then
        XCTAssertEqual(firstPairs.count, 1, "the live node is tombstoned and registered for GC")
        XCTAssertEqual(xmlAfterFirst, "<root><p></p></root>")
        XCTAssertTrue(secondPairs.isEmpty, "re-tombstoning an already-removed node is a no-op")
        XCTAssertEqual(tree.toXML(), xmlAfterFirst)
    }

    /// yorkie-js-sdk#1303: a merge moves tombstoned children too, so they survive
    /// as RGA anchors. Moving a tombstone must be size-neutral in BOTH dimensions
    /// — iOS caches only the visible `size` and derives the include-removed total
    /// from `innerChildren`, so this asserts both rather than trusting one.
    func test_moveChild_relocates_a_tombstone_without_disturbing_either_size() throws {
        // given — <p>ab</p><p>cd</p>, with "ab" tombstoned
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: "root"), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((1, 1),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                       0, timeT(), timeT)
        try tree.editT((4, 4), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((5, 5),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "cd")],
                       0, timeT(), timeT)
        XCTAssertEqual(tree.toXML(), "<root><p>ab</p><p>cd</p></root>")

        let root = tree.root
        let first = try XCTUnwrap(root.innerChildren.first)
        let second = try XCTUnwrap(root.innerChildren.last)
        let tombstone = try XCTUnwrap(first.innerChildren.first)
        tombstone.remove(timeT())

        let visibleBefore = tree.size
        let totalBefore = root.nodeLength(includeRemoved: true)

        // when — move the tombstone to the other paragraph, as merge does
        try second.moveChild(child: tombstone)

        // then — neither dimension moves: a removed node contributes to neither
        XCTAssertEqual(tree.size, visibleBefore, "a tombstone contributes no visible size to either parent")
        XCTAssertEqual(root.nodeLength(includeRemoved: true), totalBefore,
                       "the include-removed total is conserved by the move")
        XCTAssertTrue(second.innerChildren.contains { $0 === tombstone }, "the tombstone re-parented")
        XCTAssertFalse(first.innerChildren.contains { $0 === tombstone }, "and left its old parent")
        XCTAssertEqual(tree.toXML(), "<root><p></p><p>cd</p></root>")
    }

    /// Moving a LIVE child must relocate its visible size rather than conserve it
    /// in place — the complementary case to the tombstone move above.
    func test_moveChild_relocates_a_live_child_size_to_the_new_parent() throws {
        // given
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: "root"), createdAt: timeT())
        try tree.editT((0, 0), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)
        try tree.editT((1, 1),
                       [CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: "ab")],
                       0, timeT(), timeT)
        try tree.editT((4, 4), [CRDTTreeNode(id: posT(), type: "p")], 0, timeT(), timeT)

        let root = tree.root
        let first = try XCTUnwrap(root.innerChildren.first)
        let second = try XCTUnwrap(root.innerChildren.last)
        let live = try XCTUnwrap(first.innerChildren.first)
        let totalBefore = tree.size

        // when
        try second.moveChild(child: live)

        // then — the document total is unchanged, but the size moved parents
        XCTAssertEqual(tree.size, totalBefore, "moving within the tree conserves the document size")
        XCTAssertEqual(first.size, 0, "the old parent gave up the child's size")
        XCTAssertEqual(second.size, live.paddedSize, "the new parent took it on")
        XCTAssertEqual(tree.toXML(), "<root><p></p><p>ab</p></root>")
    }
}
