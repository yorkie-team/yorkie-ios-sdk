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

/// The index right after an element and right before a text sibling (index 8 below) resolves to
/// the start of that text.
///
/// `fromTreePos` used to anchor that index on the text itself at offset 0. A text left sibling
/// means "after its first N characters", and with N = 0 there is nothing to split off, so the whole
/// text became the left sibling and the edit landed after it. It now anchors on what precedes the
/// text.
///
/// Ported from yorkie-js-sdk#1482 "Resolve the index before a text that follows an element",
/// `tree_element_text_boundary_test.ts` (mirrors yorkie's `tree_find_pos_test.go` and
/// `tree_element_text_boundary_test.go`, yorkie#2079): the position computed here goes on the wire,
/// so both SDKs must resolve it the same way.
///
///     0   1   2 3 4 5 6 7    8 9 10 11 12 13 14    15
/// <r> <p> <b> h e l l o </b>   w  o  r  l  d   </p>  </r>
final class CRDTTreeElementTextBoundaryTests: XCTestCase {
    private func textNode(_ value: String) -> CRDTTreeNode {
        CRDTTreeNode(id: posT(), type: DefaultTreeNodeType.text.rawValue, value: value as NSString)
    }

    /// `editT` replaces [from, to) with `node`, or deletes it when `node` is omitted.
    private func editT(_ tree: CRDTTree, _ from: Int, _ to: Int, _ node: CRDTTreeNode? = nil, _ splitLevel: Int32 = 0) throws {
        try tree.editT((from, to), node.map { [$0] }, splitLevel, timeT(), timeT)
    }

    /// `newBoldHelloWorldTree` builds `<r><p><b>hello</b> world</p></r>`.
    private func newBoldHelloWorldTree() throws -> CRDTTree {
        let tree = CRDTTree(root: CRDTTreeNode(id: posT(), type: "r"), createdAt: timeT())
        try self.editT(tree, 0, 0, CRDTTreeNode(id: posT(), type: "p"))
        try self.editT(tree, 1, 1, CRDTTreeNode(id: posT(), type: "b"))
        try self.editT(tree, 2, 2, self.textNode("hello"))
        try self.editT(tree, 8, 8, self.textNode(" world")) // <p> has no text after </b> yet.
        XCTAssertEqual(tree.toXML(), "<r><p><b>hello</b> world</p></r>")
        return tree
    }

    /// `childrenOfP` lists the children of the first <p>, tombstones included, as `b`, `"text"` or
    /// `~"removed text"~`.
    private func childrenOfP(_ tree: CRDTTree) -> [String] {
        tree.root.innerChildren[0].innerChildren.map { node in
            let name = node.isText ? "\"\(node.value)\"" : node.type
            return node.isRemoved ? "~\(name)~" : name
        }
    }

    func test_inserts_before_the_text() throws {
        let tree = try self.newBoldHelloWorldTree()
        try self.editT(tree, 8, 8, self.textNode("|"))
        XCTAssertEqual(tree.toXML(), "<r><p><b>hello</b>| world</p></r>")
    }

    func test_deletes_the_text_from_the_boundary() throws {
        let tree = try self.newBoldHelloWorldTree()
        try self.editT(tree, 8, 14)
        XCTAssertEqual(tree.toXML(), "<r><p><b>hello</b></p></r>")
    }

    func test_skips_a_tombstone_between_the_element_and_the_text() throws {
        // <r><p><b>hello</b>[x removed] world</p></r>: the previous visible sibling of " world" is
        // still <b>.
        let tree = try self.newBoldHelloWorldTree()
        try self.editT(tree, 8, 8, self.textNode("x"))
        try self.editT(tree, 8, 9)
        XCTAssertEqual(tree.toXML(), "<r><p><b>hello</b> world</p></r>")

        try self.editT(tree, 8, 8, self.textNode("|"))
        XCTAssertEqual(tree.toXML(), "<r><p><b>hello</b>| world</p></r>")
    }

    func test_skips_a_deleted_head_of_the_same_text_like_a_separate_tombstone() throws {
        // Deleting " w" splits " world" into a tombstoned head and a live "orld" whose insPrev is
        // that head. The insert still anchors on <b>, before the tombstone, exactly as it does when
        // the tombstone is a separate node: which kind of tombstone sits there is not visible to the
        // user, so it must not change where the edit lands.
        let tree = try self.newBoldHelloWorldTree()
        try self.editT(tree, 8, 10)
        XCTAssertEqual(tree.toXML(), "<r><p><b>hello</b>orld</p></r>")

        try self.editT(tree, 8, 8, self.textNode("|"))
        XCTAssertEqual(tree.toXML(), "<r><p><b>hello</b>|orld</p></r>")
        XCTAssertEqual(self.childrenOfP(tree), ["b", "\"|\"", "~\" w\"~", "\"orld\""])

        let separate = try self.newBoldHelloWorldTree()
        try self.editT(separate, 8, 8, self.textNode("x"))
        try self.editT(separate, 8, 9)
        try self.editT(separate, 8, 8, self.textNode("|"))
        XCTAssertEqual(self.childrenOfP(separate), ["b", "\"|\"", "~\"x\"~", "\" world\""])
    }

    func test_anchors_a_text_that_is_the_first_visible_child_on_the_parent() throws {
        // <r><p>[<b>hello</b> removed] world</p></r>: " world" is now the first visible child even
        // though a tombstone precedes it.
        let tree = try self.newBoldHelloWorldTree()
        try self.editT(tree, 1, 8)
        XCTAssertEqual(tree.toXML(), "<r><p> world</p></r>")

        let pos = try tree.findPos(1)
        XCTAssertEqual(pos.leftSiblingID.createdAt, pos.parentID.createdAt)

        try self.editT(tree, 1, 1, self.textNode("|"))
        XCTAssertEqual(tree.toXML(), "<r><p>| world</p></r>")
    }

    func test_anchors_on_a_split_element_before_the_text_itself() throws {
        // Splitting <b> at "hel|lo" gives the right half an insPrev, the shape the position
        // resolver redirects for text halves. It must not redirect here: element ids always carry
        // offset 0, so the anchor stays on the right half instead of moving one sibling to the left.
        //
        //     0   1   2 3 4 5    6   7 8 9    10 11 ...
        // <r> <p> <b> h e l </b> <b> l o </b>    w ...
        let tree = try self.newBoldHelloWorldTree()
        try self.editT(tree, 5, 5, nil, 1)
        XCTAssertEqual(tree.toXML(), "<r><p><b>hel</b><b>lo</b> world</p></r>")

        let rightHalf = tree.root.innerChildren[0].innerChildren[1]
        XCTAssertNotNil(rightHalf.insPrevID)
        let pos = try tree.findPos(10)
        XCTAssertEqual(pos.leftSiblingID, rightHalf.id)

        try self.editT(tree, 10, 10, self.textNode("|"))
        XCTAssertEqual(tree.toXML(), "<r><p><b>hel</b><b>lo</b>| world</p></r>")
    }

    func test_resolves_a_boundary_between_two_texts_to_the_end_of_the_left_one() throws {
        // `fromTreePos` relies on this: a text reached at offset 0 never has a text right before it,
        // so the previous visible sibling is an element.
        let tree = try self.newBoldHelloWorldTree()
        try self.editT(tree, 14, 14, self.textNode("!"))
        XCTAssertEqual(tree.toXML(), "<r><p><b>hello</b> world!</p></r>")

        let world = tree.root.innerChildren[0].innerChildren[1]
        XCTAssertEqual(world.value as String, " world")
        let pos = try tree.findPos(14)
        XCTAssertEqual(pos.leftSiblingID.createdAt, world.id.createdAt)
        XCTAssertEqual(pos.leftSiblingID.offset, world.id.offset + Int32(" world".count))
    }

    func test_moves_the_text_to_the_new_paragraph_when_splitting_at_the_boundary() throws {
        let tree = try self.newBoldHelloWorldTree()
        try self.editT(tree, 8, 8, nil, 1)
        XCTAssertEqual(tree.toXML(), "<r><p><b>hello</b></p><p> world</p></r>")
    }
}

// MARK: - Replicas

private let seedActor: ActorID = "000000000000000000000009"
private let editorActor: ActorID = "00000000000000000000000a"
private let secondActor: ActorID = "00000000000000000000000b"

/// A replica of the shared `<r><p><b>hello</b> world</p></r>` document that exchanges changes
/// through the protobuf converter, so a change is replayed exactly as it crosses the wire.
@MainActor
private final class Replica {
    let doc: Document

    init(actor: ActorID) {
        self.doc = Document(key: "d")
        self.doc.setActor(actor)
    }

    /// `grab` takes the pending local changes through the converter and acknowledges them, so they
    /// can be replayed into other documents in any order.
    func grab() throws -> PbChangePack {
        let pack = self.doc.createChangePack()
        let lastSeq = pack.getChanges().last?.id.getClientSeq() ?? 0
        let pb = Converter.toChangePack(pack: pack)
        try self.doc.applyChangePack(ChangePack(key: pack.getDocumentKey(),
                                                checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
                                                isRemoved: false,
                                                changes: [],
                                                versionVector: VersionVector.initial))
        return pb
    }

    /// `feed` applies a grabbed batch to this document.
    func feed(_ batch: PbChangePack) throws {
        let pack = try Converter.fromChangePack(batch)
        try self.doc.applyChangePack(ChangePack(key: pack.getDocumentKey(),
                                                checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                                isRemoved: false,
                                                changes: pack.getChanges(),
                                                versionVector: VersionVector.initial))
    }

    var xml: String {
        (self.doc.getRoot().t as? JSONTree)?.toXML() ?? ""
    }
}

/// `runConcurrently` seeds `<r><p><b>hello</b> world</p></r>` on two replicas, runs `edit` on the
/// first and `other` on the second without either seeing the other, exchanges the changes and
/// returns both results.
@MainActor
private func runConcurrently(_ edit: (JSONTree) throws -> Void, _ other: (JSONTree) throws -> Void) throws -> (String, String) {
    let seed = Replica(actor: seedActor)
    try seed.doc.update { root, _ in
        root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
            JSONTreeElementNode(type: "p", children: [
                JSONTreeElementNode(type: "b", children: [JSONTreeTextNode(value: "hello")]),
                JSONTreeTextNode(value: " world")
            ])
        ]))
    }
    let base = try seed.grab()

    let editor = Replica(actor: editorActor)
    let second = Replica(actor: secondActor)
    try editor.feed(base)
    try second.feed(base)

    try editor.doc.update { root, _ in try edit(XCTUnwrap(root.t as? JSONTree)) }
    try second.doc.update { root, _ in try other(XCTUnwrap(root.t as? JSONTree)) }

    let edits = try editor.grab()
    let others = try second.grab()
    try editor.feed(others)
    try second.feed(edits)

    return (editor.xml, second.xml)
}

private func insertText(_ value: String) -> JSONTreeTextNode {
    JSONTreeTextNode(value: value)
}

/// An index right after an element and right before a text sibling anchors on the element. On a
/// replica that has split that element concurrently, the anchor has to move past the split half the
/// editing change did not know, or the edit lands between the two halves instead of before the text.
final class TextBoundaryConcurrentSplitTests: XCTestCase {
    private struct Case {
        let name: String
        let edit: (JSONTree) throws -> Void
        let want: String
    }

    @MainActor
    func test_under_a_concurrent_split() throws {
        let split: (JSONTree) throws -> Void = { try $0.edit(5, 5, nil, 1) } // <b>hel</b><b>lo</b>
        let cases = [
            Case(name: "insert before the text",
                 edit: { try $0.edit(8, 8, insertText("|")) },
                 want: "<r><p><b>hel</b><b>lo</b>| world</p></r>"),
            Case(name: "delete the text from the boundary",
                 edit: { try $0.edit(8, 14) },
                 want: "<r><p><b>hel</b><b>lo</b></p></r>"),
            Case(name: "split the paragraph at the boundary",
                 edit: { try $0.edit(8, 8, nil, 1) },
                 want: "<r><p><b>hel</b><b>lo</b></p><p> world</p></r>"),
            Case(name: "style a range that ends at the boundary",
                 edit: { try $0.style(1, 8, ["k": "v"]) },
                 want: "<r><p><b k=\"v\">hel</b><b k=\"v\">lo</b> world</p></r>")
        ]

        for tc in cases {
            let (editor, splitter) = try runConcurrently(tc.edit, split)
            XCTAssertEqual(editor, tc.want, "\(tc.name): editor")
            XCTAssertEqual(splitter, tc.want, "\(tc.name): splitter")
        }
    }
}

/// The element anchor must also hold up when another replica edits that boundary concurrently:
/// removes the element the edit anchored on, or inserts at the same index, so two edits share the
/// anchor and the RGA tie-break orders them.
final class TextBoundaryConcurrentEditTests: XCTestCase {
    @MainActor
    func test_under_a_concurrent_edit() throws {
        let insert: (JSONTree) throws -> Void = { try $0.edit(8, 8, insertText("|")) }
        let cases: [(name: String, other: (JSONTree) throws -> Void, want: String)] = [
            ("the anchor element is removed", { try $0.edit(1, 8) }, "<r><p>| world</p></r>"),
            ("another insert at the same boundary", { try $0.edit(8, 8, insertText("x")) }, "<r><p><b>hello</b>x| world</p></r>")
        ]

        for tc in cases {
            let (editor, other) = try runConcurrently(insert, tc.other)
            XCTAssertEqual(editor, tc.want, "\(tc.name): editor")
            XCTAssertEqual(other, tc.want, "\(tc.name): other")
        }
    }
}
