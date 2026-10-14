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

/// Ports `packages/sdk/test/unit/api/snapshot_converter_test.ts` from yorkie-js-sdk v0.7.25
/// (yorkie-js-sdk#1449 "Re-issue pre-attach tickets to the client's actor on attach").
///
/// Not ported: "should round-trip a tombstoned text attribute", which pins behaviour this commit
/// does not touch and which `StyleTombstoneTests` already covers on iOS. Also covers the
/// `RGATreeSplit.splitNode` negative-offset guard from the same upstream change.
@MainActor
final class SnapshotConverterTests: XCTestCase {
    /// Returns the root object of the given document as the protobuf element a Set/Add payload and
    /// a snapshot both carry.
    private func encodeRoot(_ doc: Document) throws -> PbJSONElement {
        try PbJSONElement(serializedBytes: Converter.objectToBytes(obj: doc.getRootObject()))
    }

    /// Returns the encoded Text held under `text` in the given encoded root object.
    private func pbTextOf(_ pbRoot: PbJSONElement) throws -> PbJSONElement.Text {
        let node = try XCTUnwrap(pbRoot.jsonObject.nodes.first { $0.key == "text" })
        return node.element.text
    }

    /// Identifies an encoded text node id, the way the decoders do.
    private func idKey(_ id: PbTextNodeID) -> String {
        "\(id.createdAt.lamport):\(id.createdAt.actorID.toHexString):\(id.offset)"
    }

    private func nodesOf(_ text: CRDTText) -> [RGATreeSplitNode<CRDTTextValue>] {
        text.rgaTreeSplit.filter { $0 !== text.rgaTreeSplit.head }
    }

    private func docWithSplitText() throws -> Document {
        let doc = Document(key: "test-doc")
        try doc.update { root, _ in
            root.text = JSONText()
            (root.text as? JSONText)?.edit(0, 0, "abcdef")
        }
        try doc.update { root, _ in (root.text as? JSONText)?.edit(2, 4, "x") }
        return doc
    }

    func test_should_round_trip_root_and_presences() throws {
        // given
        let doc = Document(key: "test-doc")
        try doc.update { root, presence in
            root.obj = ["nested": true, "count": Int64(42)] as [String: Any]
            root.arr = [Int64(1), Int64(2), "three"] as [Any]
            root.text = JSONText()
            (root.text as? JSONText)?.edit(0, 0, "hello")
            root.counter = JSONCounter<Int64>(value: 0)
            (root.counter as? JSONCounter<Int64>)?.increase(value: 5)
            presence.set(["cursor": 7, "name": "alice"])
        }
        let presences = doc.persistenceSnapshot().presences

        // when
        let bytes = try Converter.snapshotToBytes(root: doc.getRootObject(), presences: presences)
        let restored = try Converter.bytesToSnapshot(bytes: bytes)

        // then
        XCTAssertEqual(doc.getRootObject().toSortedJSON(), restored.root.toSortedJSON())
        XCTAssertEqual(presences, restored.presences)
    }

    func test_should_round_trip_the_insertion_links_of_split_text_nodes() throws {
        // given -- a position that names a split node's original ID resolves through the insertion
        // links (insPrev/insNext); a copy without them resolves the same position elsewhere. The Go
        // converter writes `insPrevId` too.
        let doc = try self.docWithSplitText()
        func linksOf(_ root: CRDTObject) throws -> [String] {
            let text = try XCTUnwrap(root.get(key: "text") as? CRDTText)
            return self.nodesOf(text).map {
                "\($0.id.toTestString) <\($0.insPrev?.id.toTestString ?? "-") >\($0.insNext?.id.toTestString ?? "-")"
            }
        }
        let before = try linksOf(doc.getRootObject())
        XCTAssertTrue(before.contains { !$0.hasSuffix("<- >-") })

        // when
        let restored = try Converter.bytesToSnapshot(
            bytes: Converter.snapshotToBytes(root: doc.getRootObject(), presences: [:])
        )

        // then
        XCTAssertEqual(try linksOf(restored.root), before)
    }

    func test_should_only_emit_an_insertion_link_a_decoder_can_resolve() throws {
        // given -- both decoders resolve `insPrevId` against the nodes they have already decoded: the
        // Go one rejects the whole payload on a link it cannot find, and a floor lookup would
        // otherwise match it onto the wrong node. The encoder must therefore never name a node it has
        // not already emitted.
        let doc = Document(key: "links-doc")
        try doc.update { root, _ in
            root.text = JSONText()
            (root.text as? JSONText)?.edit(0, 0, "abcdef")
        }
        try doc.update { root, _ in (root.text as? JSONText)?.edit(2, 4, "x") }
        try doc.update { root, _ in (root.text as? JSONText)?.edit(1, 2, "yz") }

        // when
        let pbText = try self.pbTextOf(self.encodeRoot(doc))

        // then
        var emitted = Set<String>()
        var linked = 0
        for pbNode in pbText.nodes {
            if pbNode.hasInsPrevID {
                linked += 1
                XCTAssertTrue(emitted.contains(self.idKey(pbNode.insPrevID)),
                              "forward or dangling insPrevId: \(self.idKey(pbNode.insPrevID))")
            }
            emitted.insert(self.idKey(pbNode.id))
        }
        XCTAssertGreaterThan(linked, 0)
    }

    func test_should_drop_an_insertion_link_that_names_no_decoded_node() throws {
        // given -- a Text can arrive inside a client-supplied Set/Add payload, where its links are as
        // untrusted as the tree links `dropSplitLinksInElement` strips. `findNode` is a floor
        // lookup, so a forged forward link would silently attach the node to whatever sorts below it.
        let doc = try self.docWithSplitText()
        var pbRoot = try self.encodeRoot(doc)
        var pbText = try self.pbTextOf(pbRoot)
        // Point the first node at the last one: a link no decoder can have resolved by the time the
        // first node is read.
        pbText.nodes[0].insPrevID = try XCTUnwrap(pbText.nodes.last).id
        self.replaceText(in: &pbRoot, with: pbText)

        // when
        let decoded = try Converter.bytesToObject(bytes: pbRoot.serializedData())

        // then
        let nodes = try self.nodesOf(XCTUnwrap(decoded.get(key: "text") as? CRDTText))
        XCTAssertNil(nodes[0].insPrev)
    }

    func test_should_drop_an_insertion_link_that_names_another_insertion() throws {
        // given -- every producer of a link points it at an earlier piece of the SAME insertion, so
        // a link across insertions is one no local edit could have made. Being decoded earlier is not
        // enough to accept it: a later Edit resolving through such a link computes an offset relative
        // to a node of a different insertion, which lands out of range or negative.
        let doc = Document(key: "cross-insertion-doc")
        try doc.update { root, _ in
            root.text = JSONText()
            (root.text as? JSONText)?.edit(0, 0, "abc")
        }
        try doc.update { root, _ in (root.text as? JSONText)?.edit(3, 3, "def") }
        var pbRoot = try self.encodeRoot(doc)
        var pbText = try self.pbTextOf(pbRoot)
        XCTAssertEqual(pbText.nodes.count, 2)
        // The second insertion decodes after the first, so this link resolves by exact id -- only the
        // same-insertion check rejects it.
        pbText.nodes[1].insPrevID = pbText.nodes[0].id
        self.replaceText(in: &pbRoot, with: pbText)

        // when
        let decoded = try Converter.bytesToObject(bytes: pbRoot.serializedData())

        // then
        let nodes = try self.nodesOf(XCTUnwrap(decoded.get(key: "text") as? CRDTText))
        XCTAssertNil(nodes[1].insPrev)
    }

    func test_should_round_trip_an_empty_document() throws {
        // given
        let doc = Document(key: "empty-doc")

        // when
        let restored = try Converter.bytesToSnapshot(
            bytes: Converter.snapshotToBytes(root: doc.getRootObject(), presences: [:])
        )

        // then
        XCTAssertEqual(doc.getRootObject().toSortedJSON(), restored.root.toSortedJSON())
        XCTAssertTrue(restored.presences.isEmpty)
    }

    func test_should_encode_the_content_of_an_object_and_an_array_value() throws {
        // given -- a pre-existing gap fixed alongside the re-issue: `toElementSimple` never encoded
        // the bytes of an Object or an Array, so a value a reverse operation restores (the undo of a
        // Remove) reached the wire without its children. yorkie-js-sdk always encoded them.
        let doc = Document(key: "simple-doc")
        try doc.update { root, _ in
            root.obj = ["k": "v"] as [String: Any]
            root.arr = [Int64(1), Int64(2)] as [Any]
        }

        // when
        let object = try XCTUnwrap(doc.getRootObject().get(key: "obj"))
        let array = try XCTUnwrap(doc.getRootObject().get(key: "arr"))
        let simpleObject = try Converter.toElementSimple(object)
        let simpleArray = try Converter.toElementSimple(array)

        // then
        XCTAssertFalse(simpleObject.value.isEmpty)
        XCTAssertFalse(simpleArray.value.isEmpty)
        let decodedObject = try XCTUnwrap(Converter.fromElementSimple(pbElementSimple: simpleObject) as? CRDTObject)
        let decodedArray = try XCTUnwrap(Converter.fromElementSimple(pbElementSimple: simpleArray) as? CRDTArray)
        XCTAssertEqual(decodedObject.toSortedJSON(), "{\"k\":\"v\"}")
        XCTAssertEqual(decodedArray.toSortedJSON(), "[1,2]")
    }

    func test_should_reject_a_negative_split_offset() throws {
        // given -- `findNodeWithSplit` derives the offset by subtracting the node's own offset from
        // the position's, so a position resolved through an `insPrev` link into a node of a HIGHER
        // offset -- which only a forged link can produce -- arrives at `splitNode` negative. Without
        // the guard the split clamps it into an out-of-range slice (an `NSRangeException` on iOS).
        let doc = Document(key: "negative-split")
        try doc.update { root, _ in
            root.text = JSONText()
            (root.text as? JSONText)?.edit(0, 0, "abcdef")
        }
        try doc.update { root, _ in (root.text as? JSONText)?.edit(2, 4, "") }
        let text = try XCTUnwrap(doc.getRootObject().get(key: "text") as? CRDTText)
        let nodes = self.nodesOf(text)
        XCTAssertEqual(nodes.map(\.id.offset), [0, 2, 4])
        // Forge the link: the node at offset 2 now claims the node at offset 4 as its insertion
        // predecessor.
        nodes[1].setInsPrev(nodes[2])
        let pos = RGATreeSplitPos(nodes[1].id, 0)

        // when / then
        XCTAssertThrowsError(try text.rgaTreeSplit.findNodeWithSplit(pos, TimeTicket.initial)) { error in
            let yorkieError = error as? YorkieError
            XCTAssertEqual(yorkieError?.code, .errInvalidArgument)
            XCTAssertEqual(yorkieError?.message, "offset should be between 0 and the length of the node")
        }
    }

    private func replaceText(in pbRoot: inout PbJSONElement, with pbText: PbJSONElement.Text) {
        var object = pbRoot.jsonObject
        guard let index = object.nodes.firstIndex(where: { $0.key == "text" }) else { return }
        object.nodes[index].element.text = pbText
        pbRoot.jsonObject = object
    }
}
