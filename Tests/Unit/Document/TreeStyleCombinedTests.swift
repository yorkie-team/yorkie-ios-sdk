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

/// Ported from `tree_style_combined_test.ts` (yorkie-js-sdk#1503).
///
/// A `tree.style()` that overwrites some attributes and adds others reverses into one operation
/// carrying both halves. The wire has to carry both so every replica executes the same operation.
@MainActor
final class TreeStyleCombinedTests: XCTestCase {
    private let docKey = "tree-style-combined"

    private func newReplica(_ index: Int) -> Document {
        let doc = Document(key: self.docKey)
        doc.setActor(String(format: "0000000000000000000000%02d", index))
        return doc
    }

    /// Drains a replica's pending local changes and acks them.
    private func recordChanges(_ from: Document, _ what: String) throws -> [Change] {
        let pack = from.createChangePack()
        let changes = pack.getChanges()
        XCTAssertFalse(changes.isEmpty, "\(what) produced no change to deliver")
        let lastSeq = changes.last?.id.getClientSeq() ?? 0
        try from.applyChangePack(ChangePack(
            key: pack.getDocumentKey(),
            checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
            isRemoved: false,
            changes: [],
            versionVector: VersionVector.initial
        ))
        return changes
    }

    /// Applies changes to a replica through the protobuf encoding, so a field the encoder drops
    /// would not reach the peer.
    private func deliver(_ to: Document, _ changes: [Change]) throws {
        let pb = Converter.toChangePack(pack: ChangePack(
            key: self.docKey,
            checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
            isRemoved: false,
            changes: changes,
            versionVector: VersionVector.initial
        ))
        try to.applyChangePack(Converter.fromChangePack(pb))
    }

    private func xml(_ doc: Document) throws -> String {
        try XCTUnwrap(doc.getRoot().t as? JSONTree).toXML()
    }

    private func seed(_ doc: Document) throws {
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [], attributes: ["b": "x"])
            ]))
        }
    }

    func test_converges_after_undoing_a_style_that_overwrote_and_added_attributes() throws {
        // given
        let docA = self.newReplica(1)
        let docB = self.newReplica(2)
        try self.seed(docA)
        try self.deliver(docB, self.recordChanges(docA, "initial tree"))

        // when - `b` is overwritten and `c` is added
        try docA.update { root, _ in
            try (root.t as? JSONTree)?.style(0, 1, ["b": "y", "c": "z"])
        }
        try self.deliver(docB, self.recordChanges(docA, "combined style"))

        // then
        XCTAssertEqual(try self.xml(docA), "<doc><p b=\"y\" c=\"z\"></p></doc>")
        XCTAssertEqual(try self.xml(docB), try self.xml(docA))

        // when
        try docA.undo()
        try self.deliver(docB, self.recordChanges(docA, "undo the combined style"))

        // then - the reverse restores `b` and leaves `c` (execute runs the set half only)
        XCTAssertEqual(try self.xml(docA), "<doc><p b=\"x\" c=\"z\"></p></doc>")
        XCTAssertEqual(try self.xml(docB), try self.xml(docA))
    }

    func test_keeps_both_halves_across_the_protobuf_round_trip() throws {
        // given
        let docA = self.newReplica(1)
        try self.seed(docA)
        _ = try self.recordChanges(docA, "initial tree")
        try docA.update { root, _ in
            try (root.t as? JSONTree)?.style(0, 1, ["b": "y", "c": "z"])
        }
        _ = try self.recordChanges(docA, "combined style")
        try docA.undo()
        let change = try XCTUnwrap(self.recordChanges(docA, "undo the combined style").first)
        XCTAssertTrue(change.operations.first is TreeStyleOperation)

        // when
        let decoded = try Converter.fromChangePack(Converter.toChangePack(pack: ChangePack(
            key: self.docKey,
            checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
            isRemoved: false,
            changes: [change],
            versionVector: VersionVector.initial
        )))

        // then
        let op = try XCTUnwrap(decoded.getChanges().first?.operations.first as? TreeStyleOperation)
        XCTAssertEqual(op.attributes, ["b": "x"])
        XCTAssertEqual(op.attributesToRemove, ["c"])
    }
}
