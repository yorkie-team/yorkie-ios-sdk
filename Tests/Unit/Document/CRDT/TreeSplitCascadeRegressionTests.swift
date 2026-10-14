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
// Ports: packages/sdk/test/unit/document/tree_split_cascade_regression_test.ts
// (yorkie-js-sdk#1456, commit 6f690a147).
//
// Regression scenarios for the split-sibling cascade of a deleted element (§4.1 of yorkie's
// docs/design/concurrent-merge-split.md). Each one loses text that nobody deleted if the
// cascade also runs when the delete lost the LWW of the element -- a tempting extra step for
// yorkie-js-sdk#1408, left out on purpose.

import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

/// `Replica` wraps a Document and hands out its pending changes once, so a test can deliver
/// them to other replicas in any causal order.
@MainActor
private final class Replica {
    let doc: Document

    init(actorNo: Int) {
        self.doc = Document(key: "doc")
        self.doc.setActor(String(format: "%024x", actorNo))
    }

    /// `flush` takes the pending changes through protobuf, as on the wire, and acks them.
    func flush() throws -> ChangePack {
        let pack = try Converter.fromChangePack(Converter.toChangePack(pack: self.doc.createChangePack()))
        let lastSeq = pack.getChanges().last?.id.getClientSeq() ?? 0
        try self.doc.applyChangePack(ChangePack(key: pack.getDocumentKey(),
                                                checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
                                                isRemoved: false,
                                                changes: [],
                                                versionVector: VersionVector.initial))
        return pack
    }

    /// `receive` applies another replica's changes.
    func receive(_ pack: ChangePack) throws {
        try self.doc.applyChangePack(ChangePack(key: pack.getDocumentKey(),
                                                checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                                isRemoved: false,
                                                changes: pack.getChanges(),
                                                versionVector: VersionVector.initial))
    }

    /// `edit` runs one local update on the tree.
    func edit(_ operation: (JSONTree) throws -> Void) throws {
        try self.doc.update { root, _ in
            try operation(XCTUnwrap(root.t as? JSONTree))
        }
    }

    var xml: String {
        (self.doc.getRoot().t as? JSONTree)?.toXML() ?? ""
    }
}

/// `start` returns n synced replicas holding
/// `<p><span>abc</span><span>de</span></p><p><span>fg</span></p>`.
@MainActor
private func start(_ count: Int) throws -> [Replica] {
    let replicas = (0 ..< count).map { Replica(actorNo: $0 + 1) }
    try replicas[0].doc.update { root, _ in
        root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [
            JSONTreeElementNode(type: "p", children: [
                JSONTreeElementNode(type: "span", children: [JSONTreeTextNode(value: "abc")]),
                JSONTreeElementNode(type: "span", children: [JSONTreeTextNode(value: "de")])
            ]),
            JSONTreeElementNode(type: "p", children: [
                JSONTreeElementNode(type: "span", children: [JSONTreeTextNode(value: "fg")])
            ])
        ]))
    }
    let initial = try replicas[0].flush()
    for replica in replicas.dropFirst() {
        try replica.receive(initial)
    }
    return replicas
}

private func visibleText(_ xml: String) -> String {
    xml.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
}

/// The editor's Enter right before a styled run.
private func enterAtSpanStart(_ tree: JSONTree) throws {
    _ = try tree.editByPath([0, 1, 0], [0, 1, 0], nil, 1)
    try tree.splitByPath([0, 2])
    _ = try tree.editByPath([0, 1], [0, 2])
}

private func splitAt0DropLeft(_ tree: JSONTree) throws {
    _ = try tree.editByPath([0, 1, 0], [0, 1, 0], nil, 1)
    _ = try tree.editByPath([0, 1], [0, 2])
}

final class TreeSplitCascadeRegressionTests: XCTestCase {
    /// r1 deletes the styled span and undoes it; r2 (newer ticket) presses Enter right before it.
    /// Both replicas keep "de" (they differ by an empty `<span>`). Cascading on a lost LWW would
    /// let r1's delete tombstone r2's split product holding "de" with r1's ticket; r1's undo
    /// restores only what r1 knew, so "de" would stay under a tombstoned `<span>` on r2.
    @MainActor
    private func assertDeleteSpanAndUndoKeepsDe(_ operation: (JSONTree) throws -> Void) throws {
        let replicas = try start(2)
        let (r1, r2) = (replicas[0], replicas[1])
        try r1.edit { _ = try $0.editByPath([0, 1], [0, 2]) }
        try r1.doc.undo()
        try r2.edit(operation)
        let p1 = try r1.flush()
        let p2 = try r2.flush()
        try r2.receive(p1)
        try r1.receive(p2)
        XCTAssertTrue(visibleText(r1.xml).contains("de"), "r1 lost \"de\": \(r1.xml)")
        XCTAssertTrue(visibleText(r2.xml).contains("de"), "r2 lost \"de\": \(r2.xml)")
    }

    @MainActor
    func test_delete_span_and_undo_vs_enter_at_span_start_de_stays_visible_on_both() throws {
        try self.assertDeleteSpanAndUndoKeepsDe(enterAtSpanStart)
    }

    @MainActor
    func test_delete_span_and_undo_vs_split_at_0_and_drop_left_de_stays_visible_on_both() throws {
        try self.assertDeleteSpanAndUndoKeepsDe(splitAt0DropLeft)
    }

    /// r1 does the #1408 shape; r2 (newer ticket) does the same and types "y" at the start of its
    /// new span. Nobody deletes "de" or "y". Cascading on a lost LWW would tombstone r2's product
    /// with "y" in it on r2 as well. r1 does not show "y": on r1, r2's product is split off a span
    /// r1 has already deleted, so it is born tombstoned. That is not the cascade.
    @MainActor
    func test_enter_and_type_vs_enter_the_typed_y_survives_on_the_typist_replica() throws {
        let replicas = try start(2)
        let (r1, r2) = (replicas[0], replicas[1])
        try r1.edit(splitAt0DropLeft)
        try r2.edit { tree in
            try splitAt0DropLeft(tree)
            _ = try tree.editByPath([0, 1, 0], [0, 1, 0], JSONTreeTextNode(value: "y"))
        }
        let p1 = try r1.flush()
        let p2 = try r2.flush()
        try r2.receive(p1)
        try r1.receive(p2)
        XCTAssertTrue(visibleText(r1.xml).contains("de"), "r1: \(r1.xml)")
        XCTAssertTrue(visibleText(r2.xml).contains("yde"), "r2: \(r2.xml)")
    }

    /// No undo. r1 splits the second span in the middle with level 2 (Enter in the middle of a
    /// styled run): `<p>abc,d</p><p>e</p>`. r2, concurrently, deletes "c" and "d" across the span
    /// boundary, merging the second span into the first. r3 has seen r1 and does the #1408 shape on
    /// the "d" span. Nobody deleted "e" and every replica keeps it. Cascading on a lost LWW would
    /// let the merge-turned-delete on r3 run through the whole chain, including r1's level-2
    /// product in the next paragraph that holds "e".
    @MainActor
    func test_enter_level_2_vs_cross_span_merge_vs_split_at_0_and_drop_e_survives() throws {
        for rev in [false, true] {
            let replicas = try start(3)
            let (r1, r2, r3) = (replicas[0], replicas[1], replicas[2])
            try r1.edit { _ = try $0.editByPath([0, 1, 1], [0, 1, 1], nil, 2) }
            let p1 = try r1.flush()
            try r2.edit { _ = try $0.editByPath([0, 0, 2], [0, 1, 1]) }
            let p2 = try r2.flush()
            try r3.receive(p1)
            try r3.edit(splitAt0DropLeft)
            let p3 = try r3.flush()
            if rev {
                try r1.receive(p3)
                try r1.receive(p2)
            } else {
                try r1.receive(p2)
                try r1.receive(p3)
            }
            try r2.receive(p1)
            try r2.receive(p3)
            try r3.receive(p2)
            for (index, replica) in [r1, r2, r3].enumerated() {
                XCTAssertTrue(visibleText(replica.xml).contains("e"), "r\(index + 1) (rev=\(rev)) lost \"e\": \(replica.xml)")
            }
        }
    }

    /// Same family, convergence: the replicas agree; cascading on a lost LWW would leave r2
    /// without "e".
    @MainActor
    func test_delete_span_and_undo_vs_split_at_0_and_drop_vs_split_in_middle_and_drop_converge() throws {
        let replicas = try start(3)
        let (r1, r2, r3) = (replicas[0], replicas[1], replicas[2])
        try r1.edit { _ = try $0.editByPath([0, 1], [0, 2]) }
        try r1.doc.undo()
        let p1 = try r1.flush()
        try r2.edit(splitAt0DropLeft)
        let p2 = try r2.flush()
        try r3.receive(p1)
        try r3.edit { tree in
            _ = try tree.editByPath([0, 1, 1], [0, 1, 1], nil, 1)
            _ = try tree.editByPath([0, 1], [0, 2])
        }
        let p3 = try r3.flush()
        try r1.receive(p2)
        try r1.receive(p3)
        try r2.receive(p1)
        try r2.receive(p3)
        try r3.receive(p2)
        XCTAssertEqual(r2.xml, r1.xml, "r2 diverged from r1")
        XCTAssertEqual(r3.xml, r1.xml, "r3 diverged from r1")
    }
}
