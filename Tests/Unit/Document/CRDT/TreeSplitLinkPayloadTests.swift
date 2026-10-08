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

// Ports: packages/sdk/test/unit/document/tree_split_link_payload_test.ts
// (yorkie-js-sdk#1375, commit c8928853, "Order concurrent splits of one
// boundary by ticket").
//
// A Set/Add/ArraySet payload carries a whole element, and the wire format
// carries insPrevID/insNextID on every tree node it holds. `Converter` strips
// them on the way in (`fromElementSimple`), because such a payload is
// client-supplied and its nodes can never be split products.
//
// A reverse operation reaches the document without passing the converter:
// undo executes the copy it captured directly. Unless the copy is stripped
// too, the replica that ran the undo keeps links every other replica -- and
// the server -- decoded away, and the two disagree from there on.

import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

/// `splitLinks` lists every split-sibling link the tree under `key` carries,
/// one line per node that has one. Empty when the tree carries none.
@MainActor
private func splitLinks(_ doc: Document, key: String = "t") -> [String] {
    guard let tree = doc.getRootObject().get(key: key) as? CRDTTree else {
        return []
    }
    var lines = [String]()
    func walk(_ node: CRDTTreeNode) {
        let prev = node.insPrevID?.toIDString
        let next = node.insNextID?.toIDString
        if prev != nil || next != nil {
            lines.append("\(node.id.toIDString) prev=\(prev ?? "nil") next=\(next ?? "nil")")
        }
        node.innerChildren.forEach(walk)
    }
    walk(tree.root)
    return lines
}

/// `replicate` hands every change `from` has produced to a fresh replica,
/// through the converter's protobuf encode/decode, as on the wire. A native
/// in-process exchange (as other suites use) never calls `fromElementSimple`,
/// so it would not exercise the strip this file tests.
@MainActor
private func replicate(_ from: Document) throws -> Document {
    let pbPack = Converter.toChangePack(pack: from.createChangePack())
    let restored = try Converter.fromChangePack(pbPack)

    let to = Document(key: "test-doc")
    to.setActor("000000000000000000000002")
    try to.applyChangePack(ChangePack(key: restored.getDocumentKey(),
                                      checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                      isRemoved: false,
                                      changes: restored.getChanges(),
                                      versionVector: VersionVector.initial))
    return to
}

/// `withSplitTree` returns a document holding a tree whose span and paragraph
/// have both been split, so its nodes carry split-sibling links.
@MainActor
private func withSplitTree() throws -> Document {
    let doc = Document(key: "test-doc")
    doc.setActor("000000000000000000000001")
    try doc.update { root, _ in
        root.t = JSONTree(initialRoot:
            JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeElementNode(type: "span", children: [JSONTreeTextNode(value: "abcde")])
                ])
            ])
        )
    }
    try doc.update { root, _ in
        guard let tree = root.t as? JSONTree else { return }
        _ = try tree.editByPath([0, 0, 3], [0, 0, 3], nil, 1)
    }
    return doc
}

/// `xmlOf` reads a replica's Tree field as XML.
@MainActor
private func xmlOf(_ doc: Document) throws -> String {
    try XCTUnwrap(doc.getRoot().t as? JSONTree).toXML()
}

final class TreeSplitLinkPayloadTests: XCTestCase {
    @MainActor
    func test_the_tree_a_split_leaves_behind_does_carry_them() throws {
        // given / when
        let doc = try withSplitTree()

        // then
        XCTAssertFalse(splitLinks(doc).isEmpty)
    }

    @MainActor
    func test_an_undone_set_restores_the_same_links_here_and_on_a_replica() throws {
        // given
        let doc = try withSplitTree()
        let restored = try xmlOf(doc)

        // when
        try doc.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [])
            ]))
        }
        try doc.undo()
        let replica = try replicate(doc)

        // then
        XCTAssertEqual(try xmlOf(doc), restored)
        XCTAssertEqual(try xmlOf(replica), restored)
        XCTAssertEqual(splitLinks(doc), splitLinks(replica))
    }

    @MainActor
    func test_an_undone_remove_restores_the_same_links_here_and_on_a_replica() throws {
        // given
        let doc = try withSplitTree()
        let restored = try xmlOf(doc)

        // when
        try doc.update { root, _ in
            root.remove(key: "t")
        }
        try doc.undo()
        let replica = try replicate(doc)

        // then
        XCTAssertEqual(try xmlOf(doc), restored)
        XCTAssertEqual(try xmlOf(replica), restored)
        XCTAssertEqual(splitLinks(doc), splitLinks(replica))
    }
}
