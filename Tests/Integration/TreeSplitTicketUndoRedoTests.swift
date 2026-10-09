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
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

/// Ported from yorkie-js-sdk v0.7.24: `packages/sdk/test/unit/document/split_ticket_test.ts`
/// "gives each split reverse in one undo entry its own tickets"
/// (yorkie-js-sdk#1404 "Port three tree convergence fixes from the Go SDK",
/// mirroring Go's `TestTreeSplitUndo`).
///
/// An undo issues one ticket per operation, but a splitLevel N reverse mints N
/// elements. Left to reconstruct those from its own `executedAt`, a level 2
/// reverse walks two delimiters past the ticket it was issued on -- onto the
/// ticket of the NEXT operation in the same undo entry, since one `update`
/// block can push more than one operation into the same change. Every replica
/// and the server then land two live nodes under one id.
///
/// This runs with a local offline `Document` -- no server required -- because
/// the bug and the fix are both entirely local to `Document.executeUndoRedo`
/// building the undo change.
final class TreeSplitTicketUndoRedoTests: XCTestCase {
    /// Returns `<r><d><p>ab</p></d><d><p>cd</p></d><d><p>ef</p></d></r>`, the
    /// shape two successive L2 merges need, and so the shape that puts two
    /// splitLevel-2 reverses into one undo entry.
    @MainActor
    private func threeBlockDoc() throws -> Document {
        let doc = Document(key: "split-ticket-undo-redo".toDocKey)
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot:
                JSONTreeElementNode(type: "r", children: ["ab", "cd", "ef"].map { value in
                    JSONTreeElementNode(type: "d", children: [
                        JSONTreeElementNode(type: "p", children: [
                            JSONTreeTextNode(value: value)
                        ])
                    ])
                })
            )
        }
        return doc
    }

    @MainActor
    private func xml(_ doc: Document) -> String {
        (doc.getRoot().t as? JSONTree)?.toXML() ?? ""
    }

    /// Returns the ids that name more than one live-or-tombstoned node in `t`.
    @MainActor
    private func duplicatedIDs(_ doc: Document) throws -> [String] {
        let tree = try XCTUnwrap(doc.getRootObject().get(key: "t") as? CRDTTree)
        var counts = [String: Int]()
        tree.indexTree.traverseAll { node, _ in
            counts[node.toIDString, default: 0] += 1
        }
        return counts.filter { $0.value > 1 }.map { "\($0.key) x\($0.value)" }
    }

    @MainActor
    func test_gives_each_split_reverse_in_one_undo_entry_its_own_tickets() throws {
        // given
        let doc = try self.threeBlockDoc()
        let before = self.xml(doc)
        XCTAssertEqual(before, "<r><d><p>ab</p></d><d><p>cd</p></d><d><p>ef</p></d></r>")

        // when — two L2 merges land in ONE change, so undoing them generates
        // two splitLevel-2 reverse operations in a single undo entry.
        try doc.update { root, _ in
            _ = try (root.t as? JSONTree)?.edit(4, 8)
            _ = try (root.t as? JSONTree)?.edit(6, 10)
        }
        XCTAssertEqual(self.xml(doc), "<r><d><p>abcdef</p></d></r>")

        // then — undo must restore the original shape without doubling up any
        // node's identity.
        try doc.undo()
        XCTAssertEqual(self.xml(doc), before)
        XCTAssertEqual(try self.duplicatedIDs(doc), [], "an id names at most one node after undo")

        // and — a redo replays the merges, and a second undo mints the splits
        // again, each from its own tickets rather than colliding with the
        // first undo's.
        try doc.redo()
        XCTAssertEqual(self.xml(doc), "<r><d><p>abcdef</p></d></r>")
        try doc.undo()
        XCTAssertEqual(self.xml(doc), before)
        XCTAssertEqual(try self.duplicatedIDs(doc), [], "an id names at most one node after the second undo")
    }
}
