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

private let docKey = "tree-restore-text-parent"
private let sender: ActorID = "000000000000000000000001"
private let receiver: ActorID = "000000000000000000000002"
private let textType = DefaultTreeNodeType.text.rawValue

private typealias SpansOf = (_ at: TimeTicket, _ pID: CRDTTreeNodeID, _ textID: CRDTTreeNodeID) -> [TreeRestoreSpan]

/// `newReplica` returns a document with the given actor.
@MainActor
private func newReplica(_ actor: ActorID) -> Document {
    let doc = Document(key: docKey)
    doc.setActor(actor)
    return doc
}

/// `seed` sets `<r><p>hello</p></r>` on the given replica.
@MainActor
private func seed(_ doc: Document) throws {
    try doc.update { root, _ in
        root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
            JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "hello")])
        ]))
    }
}

/// `roundTrip` passes the given changes through the protobuf encoding a push and a pull take.
private func roundTrip(_ changes: [Change]) throws -> [Change] {
    let pack = ChangePack(key: docKey,
                          checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                          isRemoved: false,
                          changes: changes,
                          versionVector: VersionVector.initial)
    return try Converter.fromChangePack(Converter.toChangePack(pack: pack)).getChanges()
}

/// `deliver` applies the given changes to a replica as a pull would. The neutral checkpoint keeps
/// its pending changes, and the initial version vector keeps garbage collection out of the delivery.
@MainActor
private func deliver(_ doc: Document, _ changes: [Change]) throws {
    try doc.applyChangePack(ChangePack(key: docKey,
                                       checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                       isRemoved: false,
                                       changes: changes,
                                       versionVector: VersionVector.initial))
}

/// `pendingChanges` returns every change the replica has not had acknowledged.
@MainActor
private func pendingChanges(_ doc: Document) -> [Change] {
    doc.createChangePack().getChanges()
}

@MainActor
private func xml(_ doc: Document) throws -> String {
    try XCTUnwrap(doc.getRoot().t as? JSONTree).toXML()
}

/// `craft` makes `from` insert a text node, then replaces that change's operation with a restore
/// TreeEdit carrying `spansOf(...)`, and returns all of `from`'s changes after the protobuf round
/// trip a push takes. `pID` and `textID` name the seeded `<p>` and its `hello` text node, read
/// before the insertion lands in front of `hello`. The span's own ID reuses the replaced insertion's
/// ticket: it is causally known to the change, and no node holds it on a replica that never saw the
/// insertion, so restore falls through to recreateFromSpan.
@MainActor
private func craft(_ from: Document, _ spansOf: SpansOf) throws -> [Change] {
    let crdtTree = try XCTUnwrap(from.getRootObject().get(key: "t") as? CRDTTree)
    let paragraph = try XCTUnwrap(crdtTree.root.innerChildren.first)
    let paragraphText = try XCTUnwrap(paragraph.innerChildren.first)
    XCTAssertTrue(paragraphText.isText)
    let (pID, textID) = (paragraph.id, paragraphText.id)
    try from.update { root, _ in
        try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "x"))
    }

    var changes = pendingChanges(from)
    let last = try XCTUnwrap(changes.last)
    XCTAssertEqual(last.operations.count, 1)
    let valid = try XCTUnwrap(last.operations[0] as? TreeEditOperation)

    let spans = spansOf(valid.executedAt, pID, textID)
    let crafted = TreeEditOperation(parentCreatedAt: valid.parentCreatedAt,
                                    fromPos: valid.fromPos,
                                    toPos: valid.toPos,
                                    contents: nil,
                                    splitLevel: 0,
                                    executedAt: valid.executedAt,
                                    isUndoOp: true,
                                    fromIdx: nil,
                                    toIdx: nil,
                                    restoreSpans: spans,
                                    restoreMode: .restore)
    changes[changes.count - 1] = Change(id: last.id,
                                        operations: [crafted],
                                        presenceChange: last.presenceChange,
                                        message: last.message)

    let decoded = try roundTrip(changes)
    let decodedOp = try XCTUnwrap(decoded.last?.operations.first as? TreeEditOperation)
    XCTAssertEqual(decodedOp.restoreSpans?.count, spans.count, "decoding cannot tell a text parent from an element")
    return decoded
}

/// Port of the Go `TestRestoreSpanUnderTextParentStaysApplicable` (yorkie#2175), via
/// yorkie-js-sdk#1475 `tree_restore_text_parent_test.ts`. A TreeEdit restore span names its node's
/// parent by ID, and the ID can name a text node; its isText flag can also disagree with its
/// nodeType. No honest replica produces such a span, but any client with write access can send one,
/// and the server stores a pushed change before it applies it. The change must therefore apply, both
/// on a replica that pulls it and on one replaying every change from scratch, and leave the tree as
/// it was: the span's node is left unplaced, as it is when its parent is missing. Go, JS and iOS skip
/// the same spans, so their replicas converge.
final class TreeRestoreTextParentTests: XCTestCase {
    private struct Case {
        let name: String
        let spansOf: SpansOf
    }

    private func span(_ id: CRDTTreeNodeID, _ nodeType: String, isText: Bool, length: Int32, value: NSString? = nil, parent: CRDTTreeNodeID) -> TreeRestoreSpan {
        TreeRestoreSpan(id: id, nodeType: nodeType, isText: isText, length: length, value: value, attrs: nil,
                        parentID: parent, leftSiblingID: nil, rightSiblingID: nil)
    }

    @MainActor
    func test_a_crafted_restore_span_leaves_the_tree_applicable() throws {
        let cases = [
            Case(name: "element span under a text parent") { at, _, textID in
                [self.span(CRDTTreeNodeID(createdAt: at, offset: 0), "p", isText: false, length: 0, parent: textID)]
            },
            Case(name: "text span under a text parent") { at, _, textID in
                [self.span(CRDTTreeNodeID(createdAt: at, offset: 0), textType, isText: true, length: 1, value: "x", parent: textID)]
            },
            Case(name: "element span typed as text") { at, pID, _ in
                [self.span(CRDTTreeNodeID(createdAt: at, offset: 0), textType, isText: false, length: 0, parent: pID)]
            },
            Case(name: "text span typed as an element, twice") { at, pID, _ in
                let bad = self.span(CRDTTreeNodeID(createdAt: at, offset: 0), "p", isText: true, length: 1, value: "x", parent: pID)
                return [bad, bad]
            }
        ]

        for tc in cases {
            let first = newReplica(sender)
            try seed(first)
            let second = newReplica(receiver)
            try deliver(second, roundTrip(pendingChanges(first)))

            let changes = try craft(first, tc.spansOf)

            // A replica that pulls the change.
            try deliver(second, Array(changes.suffix(1)))
            XCTAssertEqual(try xml(second), "<r><p>hello</p></r>", tc.name)

            // A replica replaying every stored change, as a snapshot rebuild does.
            let built = newReplica("000000000000000000000003")
            try deliver(built, changes)
            XCTAssertEqual(built.toSortedJSON(), second.toSortedJSON(), "replicas converge: \(tc.name)")

            // The tree stays editable after the skipped span.
            try second.update { root, _ in
                try (root.t as? JSONTree)?.edit(6, 6, JSONTreeTextNode(value: "!"))
            }
            XCTAssertEqual(try xml(second), "<r><p>hello!</p></r>", tc.name)
        }
    }

    /// The honest path: undo after GC recreates a purged text node under its element parent, and the
    /// pulling replica agrees. Redo removes it again.
    @MainActor
    func test_honest_undo_after_gc() throws {
        let first = newReplica(sender)
        try seed(first)
        try first.update { root, _ in
            try (root.t as? JSONTree)?.edit(1, 6)
        }
        XCTAssertGreaterThan(first.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [sender])), 0)
        try first.undo()
        XCTAssertEqual(try xml(first), "<r><p>hello</p></r>")

        let changes = try roundTrip(pendingChanges(first))
        let undo = try XCTUnwrap(changes.last?.operations.first as? TreeEditOperation)
        XCTAssertFalse(undo.restoreSpans?.isEmpty ?? true, "the undo takes the restore path")

        let second = newReplica(receiver)
        try deliver(second, changes)
        XCTAssertEqual(try xml(second), "<r><p>hello</p></r>")
        XCTAssertEqual(second.toSortedJSON(), first.toSortedJSON())

        try first.redo()
        XCTAssertEqual(try xml(first), "<r><p></p></r>")
        try deliver(second, Array(roundTrip(pendingChanges(first)).suffix(1)))
        XCTAssertEqual(try xml(second), "<r><p></p></r>")
    }
}
