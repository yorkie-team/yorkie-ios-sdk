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

private let spanActor: ActorID = "000000000000000000000001"

private func ticketOf(_ lamport: Int64) -> TimeTicket {
    TimeTicket(lamport: lamport, delimiter: 0, actorID: spanActor)
}

private let textType = DefaultTreeNodeType.text.rawValue

private struct HelloTree {
    let tree: CRDTTree
    let paragraph: CRDTTreeNode
    let text: CRDTTreeNode
}

/// `helloTree` returns `<r><p>hello</p></r>` and its `<p>` and text node.
private func helloTree() throws -> HelloTree {
    let root = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: ticketOf(1), offset: 0), type: "r")
    let paragraph = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: ticketOf(2), offset: 0), type: "p")
    let text = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: ticketOf(3), offset: 0), type: textType, value: "hello")
    try paragraph.append(contentsOf: [text])
    try root.append(contentsOf: [paragraph])
    return HelloTree(tree: CRDTTree(root: root, createdAt: ticketOf(1)), paragraph: paragraph, text: text)
}

private func span(id: CRDTTreeNodeID, nodeType: String, isText: Bool, length: Int32, value: NSString? = nil, parentID: CRDTTreeNodeID?) -> TreeRestoreSpan {
    TreeRestoreSpan(id: id, nodeType: nodeType, isText: isText, length: length, value: value, attrs: nil,
                    parentID: parentID, leftSiblingID: nil, rightSiblingID: nil)
}

/// `textSpan` returns the restore span an honest replica captures for `node`.
private func textSpan(_ node: CRDTTreeNode, _ parent: CRDTTreeNode) -> TreeRestoreSpan {
    span(id: node.id, nodeType: node.type, isText: true, length: Int32(node.value.length), value: node.value, parentID: parent.id)
}

/// Ports of the Go `TestTreeRestoreTextParentSkip` and `TestTreeRestoreKindMismatchSkip` (yorkie#2175),
/// via yorkie-js-sdk#1475 "Skip a Tree restore span with a text parent",
/// `tree_restore_span_kind_test.ts`. Both SDKs must skip the same spans, or a Go and an iOS/JS replica
/// diverge on the same change.
final class TreeRestoreSpanKindTests: XCTestCase {
    /// A span whose parent ID names a text node is skipped like a missing parent instead of throwing.
    /// A text node cannot hold children, and node kind never changes, so every replica skips the same
    /// span.
    func test_skips_a_span_under_a_text_parent() throws {
        for isText in [false, true] {
            let fixture = try helloTree()
            let id = CRDTTreeNodeID(createdAt: ticketOf(9), offset: 0)
            let bad = isText
                ? span(id: id, nodeType: textType, isText: true, length: 1, value: "x", parentID: fixture.text.id)
                : span(id: id, nodeType: "p", isText: false, length: 0, parentID: fixture.text.id)

            let (untombstoned, recreated, pairs, _, _) = try fixture.tree.restore([bad], ticketOf(10))

            XCTAssertTrue(untombstoned.isEmpty)
            XCTAssertTrue(recreated.isEmpty, "a node under a text parent is skipped (isText=\(isText))")
            XCTAssertTrue(pairs.isEmpty)
            XCTAssertEqual(fixture.tree.toXML(), "<r><p>hello</p></r>", "tree is untouched")
            let found = fixture.tree.findFloorNode(id)
            XCTAssertFalse(found?.id == id, "the node is never registered")
        }
    }

    /// A span whose isText disagrees with its nodeType is skipped by both restore and retombstone.
    /// Recreating it would build a node of the wrong kind: a zero-length text node, or an element
    /// carrying a value. The text lookup cannot see such an element, so a second copy of the span
    /// inserted another node under the same ID.
    func test_skips_a_span_whose_kind_disagrees() throws {
        for isText in [false, true] {
            let fixture = try helloTree()
            let id = CRDTTreeNodeID(createdAt: ticketOf(9), offset: 0)
            let bad = isText
                ? span(id: id, nodeType: "p", isText: true, length: 1, value: "x", parentID: fixture.paragraph.id)
                : span(id: id, nodeType: textType, isText: false, length: 0, parentID: fixture.paragraph.id)

            let (untombstoned, recreated, _, _, _) = try fixture.tree.restore([bad, bad], ticketOf(10))

            XCTAssertTrue(untombstoned.isEmpty)
            XCTAssertTrue(recreated.isEmpty, "a mismatched span is skipped (isText=\(isText))")
            XCTAssertEqual(fixture.tree.toXML(), "<r><p>hello</p></r>")
        }
    }

    /// The other half of restore's kind check: a mismatched span naming a node still present as a
    /// TOMBSTONE must not revive it either. The check sits before the un-tombstone branch, so without
    /// it the span would resurrect content its kind does not describe.
    func test_keeps_a_tombstone_a_mismatched_span_names() throws {
        let fixture = try helloTree()
        var lamport: Int64 = 20
        let issue: () -> TimeTicket = {
            defer { lamport += 1 }
            return ticketOf(lamport)
        }
        try fixture.tree.editT((1, 6), nil, 0, issue(), issue)
        XCTAssertEqual(fixture.tree.toXML(), "<r><p></p></r>")

        // Same identity as the tombstoned text, but typed as an element.
        let honest = textSpan(fixture.text, fixture.paragraph)
        let bad = span(id: honest.id, nodeType: "p", isText: true, length: honest.length, value: honest.value, parentID: honest.parentID)
        let (untombstoned, recreated, _, _, _) = try fixture.tree.restore([bad], issue())

        XCTAssertTrue(untombstoned.isEmpty, "a mismatched span revives nothing")
        XCTAssertTrue(recreated.isEmpty)
        XCTAssertEqual(fixture.tree.toXML(), "<r><p></p></r>", "the tombstone stays dead")
    }

    /// The retombstone half of the kind check. The spans name a LIVE node, so retombstone would find
    /// and re-remove it without the check; a span carrying an identity no node holds would pass either
    /// way.
    func test_retombstone_skips_a_mismatched_span() throws {
        let cases: [(name: String, isText: Bool, nodeType: String)] = [
            ("text node in an element-flagged span", false, textType),
            ("text node typed as an element", true, "p")
        ]
        for tc in cases {
            let fixture = try helloTree()
            let honest = textSpan(fixture.text, fixture.paragraph)
            let bad = span(id: honest.id, nodeType: tc.nodeType, isText: tc.isText, length: honest.length, value: honest.value, parentID: honest.parentID)

            let (pairs, _, _) = try fixture.tree.retombstone([bad], ticketOf(20))

            XCTAssertTrue(pairs.isEmpty, "a mismatched span re-tombstones nothing: \(tc.name)")
            XCTAssertEqual(fixture.tree.toXML(), "<r><p>hello</p></r>", "tree is untouched: \(tc.name)")
        }
    }
}

/// Port of the Go `TestTreeRestoreClaimedIdentitySkip` (yorkie#2175). A span is skipped when the
/// identity it would recreate is already held by a surviving node. Nothing on the wire ties a span's
/// ID to a purged node of its own insertion, and registering a node under a claimed ID overwrites the
/// live registration, leaving two nodes under one identity.
final class TreeRestoreSpanClaimedIdentityTests: XCTestCase {
    func test_skips_a_text_span_naming_a_live_element() throws {
        let fixture = try helloTree()

        // findPiecesOverlapping stops at the non-text floor node, so the gap branch would recreate a
        // text node under <p>'s exact identity.
        let bad = span(id: fixture.paragraph.id, nodeType: textType, isText: true, length: 1, value: "x", parentID: fixture.tree.root.id)
        let (untombstoned, recreated, _, _, _) = try fixture.tree.restore([bad], ticketOf(20))

        XCTAssertTrue(untombstoned.isEmpty)
        XCTAssertTrue(recreated.isEmpty, "a claimed identity is not recreated")
        XCTAssertEqual(fixture.tree.toXML(), "<r><p>hello</p></r>")
        XCTAssertTrue(fixture.tree.findFloorNode(fixture.paragraph.id) === fixture.paragraph, "<p> still holds its own identity")
    }

    func test_skips_an_element_span_inside_a_live_text_run() throws {
        let fixture = try helloTree()

        // Offset 2 falls inside "hello": the id is the one the next honest split of that run mints,
        // so creating an element there plants a duplicate that split would collide with.
        let bad = span(id: CRDTTreeNodeID(createdAt: fixture.text.id.createdAt, offset: 2), nodeType: "p", isText: false, length: 0, parentID: fixture.paragraph.id)
        let (untombstoned, recreated, _, _, _) = try fixture.tree.restore([bad], ticketOf(20))

        XCTAssertTrue(untombstoned.isEmpty)
        XCTAssertTrue(recreated.isEmpty, "an id inside a live run is not recreated")
        XCTAssertEqual(fixture.tree.toXML(), "<r><p>hello</p></r>")

        // The honest split that mints that id still works afterwards.
        var lamport: Int64 = 21
        let issue: () -> TimeTicket = {
            defer { lamport += 1 }
            return ticketOf(lamport)
        }
        let inserted = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: issue(), offset: 0), type: textType, value: "Z")
        try fixture.tree.editT((3, 3), [inserted], 0, issue(), issue)
        XCTAssertEqual(fixture.tree.toXML(), "<r><p>heZllo</p></r>")
        XCTAssertEqual(fixture.tree.size, 8, "the length cache stays sound")
    }
}
