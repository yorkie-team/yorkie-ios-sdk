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

/// Ports a representative subset of `packages/sdk/test/unit/document/surrogate_index_test.ts`
/// from yorkie-js-sdk#1447 ("Reject indexes that split a UTF-16 surrogate pair"), the JS half of
/// yorkie-team/yorkie#2085.
///
/// Text and Tree indexes count UTF-16 code units -- ``CRDTTextValue/content`` and
/// ``CRDTTreeNode/value`` are both `NSString`, matching JS's `string.length`, specifically so
/// this SDK's offsets stay wire-compatible with JS's -- so a local index between the two halves
/// of a non-BMP character names no character boundary. Splitting a node there is rejected the
/// same way JS rejects it.
///
/// Not ported: JS's "Mid-surrogate-pair indexes the document computed" cases, which craft raw
/// wire `ChangePack`s to simulate an older client sending a mid-pair remote operation, plus its
/// fine-grained "resolves indexes after a split" / "local seam" cases. The former need low-level
/// protobuf scaffolding this suite does not otherwise use; both exercise the same
/// `findPosUnchecked` routing already covered by `test_Tree_discards_earlier_edits_of_the_rejected_update`
/// and `test_undoes_and_redoes_around_an_intact_pair` below, and that routing was additionally
/// verified by direct code audit: every `tree.findPos` call in `TreeEditOperation.swift` (undo
/// reconciliation, redo-split, reverse-operation building) was moved to `findPosUnchecked`,
/// mirroring upstream's companion change to `tree_edit_operation.ts` in the same commit.
final class SurrogateIndexTests: XCTestCase {
    private let midPairMessage = "index must not split a UTF-16 surrogate pair"
    private let loneSurrogateMessage = "content must not contain a lone UTF-16 surrogate"

    /// One non-BMP character followed by a BMP one: 2 characters, 3 UTF-16 code units. Text
    /// offset 1 (Tree index 2) is the only position that cuts the emoji in half.
    private let surrogateText = "😀x"

    /// Builds a `String` from raw UTF-16 code units, including an unpaired surrogate -- which a
    /// Swift string literal cannot spell (`"\u{D83D}"` does not compile: a lone surrogate is not
    /// a valid Unicode scalar), but `NSString(characters:length:)` holds one directly, and
    /// bridging it to `String` and back is lossless (verified empirically: round-tripping
    /// `[0x61, 0xD83D]` through `as String` and back to `NSString` reproduces both code units
    /// unchanged). This is exactly why ``CRDTTextValue/content`` and ``CRDTTreeNode/value`` are
    /// `NSString`, not `String`: it is what lets this SDK keep the raw code unit the way JS
    /// does, instead of Go's lossy U+FFFD replacement.
    private func surrogateString(_ units: [UInt16]) -> String {
        var mutableUnits = units
        return NSString(characters: &mutableUnits, length: mutableUnits.count) as String
    }

    @MainActor
    private func newSurrogateDoc(actor: String = "000000000000000000000001") throws -> Document {
        let doc = Document(key: "surrogate-index")
        doc.setActor(actor)
        try doc.update { root, _ in
            root.tree = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: self.surrogateText)])
            ]))
            root.text = JSONText()
            (root.text as? JSONText)?.edit(0, 0, self.surrogateText)
        }
        return doc
    }

    private func assertYorkieError(
        _ expression: @autoclosure () throws -> Void,
        contains expectedMessage: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let yorkieError = error as? YorkieError else {
                XCTFail("expected YorkieError, got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(yorkieError.code, .errInvalidArgument, file: file, line: line)
            XCTAssertTrue(
                yorkieError.message.contains(expectedMessage),
                "got: \(yorkieError.message)", file: file, line: line
            )
        }
    }

    /// Asserts that `body` is refused and leaves the document unchanged.
    @MainActor
    private func assertRejectsMidSurrogate(
        _ doc: Document,
        _ name: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: (JSONObject, inout Presence) throws -> Void
    ) {
        let before = doc.toSortedJSON()
        try self.assertYorkieError(doc.update(body), contains: self.midPairMessage, file: file, line: line)
        XCTAssertEqual(doc.toSortedJSON(), before, "\(name): the refused edit left no trace", file: file, line: line)
    }

    // given/when/then: `isUTF16Boundary` is checked against an independent, encoded definition
    // -- the boundaries are where a walk over the value's Characters (Swift's grapheme
    // clusters, each exactly one JS code point here) stops, plus everything outside the value.
    func test_isUTF16Boundary_matches_the_encoded_definition_at_every_offset() {
        func encodedBoundary(_ value: String, _ offset: Int) -> Bool {
            let nsValue = value as NSString
            if offset <= 0 || offset >= nsValue.length {
                return true
            }
            var at = 0
            for character in value {
                if at == offset {
                    return true
                }
                at += String(character).utf16.count
            }
            return false
        }

        for value in ["", "abc", "가나다", "😀", "😀x", "x😀", "😀😁", "a😀b😁c"] {
            let nsValue = value as NSString
            for offset in -1 ... (nsValue.length + 1) {
                XCTAssertEqual(
                    isUTF16Boundary(nsValue, offset),
                    encodedBoundary(value, offset),
                    "value \(value.debugDescription), offset \(offset)"
                )
            }
        }

        // A lone surrogate on its own has no pair to split, so every offset around it is a
        // boundary -- unlike a value where the pair is intact.
        let lone = self.surrogateString([0xD83D]) as NSString
        XCTAssertTrue(isUTF16Boundary(lone, 0))
        XCTAssertTrue(isUTF16Boundary(lone, 1))
    }

    func test_isUTF16Boundary_rejects_only_the_offset_inside_a_surrogate_pair() {
        let value = "a😀b" as NSString
        XCTAssertTrue(isUTF16Boundary(value, 1))
        XCTAssertFalse(isUTF16Boundary(value, 2))
        XCTAssertTrue(isUTF16Boundary(value, 3))
    }

    // MARK: - Reject lone-surrogate content

    // `JSONText.edit` keeps its existing failure style (catch internally, log, return `nil`)
    // rather than throwing out of `doc.update` -- unlike `JSONTree`'s edit family, which
    // propagates ``YorkieError`` directly. So this checks the `nil` return and the unchanged
    // content, not a thrown error.
    @MainActor
    func test_Text_edit_refuses_lone_surrogate_content() throws {
        // A lone half diverges across SDKs on its own, and once stored it pairs with whatever
        // code unit it is kept next to, which makes the index at that seam one the index guard
        // refuses for the lifetime of the text.
        let cases: [(String, [UInt16])] = [
            ("a lone high surrogate", [0x61, 0xD83D]),
            ("a lone low surrogate", [0xDE00, 0x62]),
            ("a reversed pair", [0xDE00, 0xD83D]),
            ("a half beside a whole pair", [0xD83D, 0xDE00, 0xD83D])
        ]

        for (name, units) in cases {
            let value = self.surrogateString(units)
            let doc = try self.newSurrogateDoc()
            try doc.update { root, _ in
                let result = (root.text as? JSONText)?.edit(0, 0, value)
                XCTAssertNil(result, name)
            }
            XCTAssertEqual((doc.getRoot().text as? JSONText)?.toString, self.surrogateText, name)
        }
    }

    @MainActor
    func test_Tree_edit_refuses_lone_surrogate_content() throws {
        let cases: [(String, [UInt16])] = [
            ("a lone high surrogate", [0x61, 0xD83D]),
            ("a lone low surrogate", [0xDE00, 0x62]),
            ("a reversed pair", [0xDE00, 0xD83D]),
            ("a half beside a whole pair", [0xD83D, 0xDE00, 0xD83D])
        ]

        for (name, units) in cases {
            let value = self.surrogateString(units)
            let doc = try self.newSurrogateDoc()
            let before = doc.toSortedJSON()
            try self.assertYorkieError(
                doc.update { root, _ in
                    try (root.tree as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: value))
                },
                contains: self.loneSurrogateMessage
            )
            XCTAssertEqual(doc.toSortedJSON(), before, name)
        }
    }

    @MainActor
    func test_accepts_whole_characters_on_both_sides_of_a_pair() throws {
        let doc = try self.newSurrogateDoc()
        try doc.update { root, _ in
            (root.text as? JSONText)?.edit(0, 0, "a😀b")
            _ = try (root.tree as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "a😀b"))
        }
        XCTAssertEqual((doc.getRoot().tree as? JSONTree)?.toXML(), "<r><p>a😀b😀x</p></r>")
        XCTAssertEqual((doc.getRoot().text as? JSONText)?.toString, "a😀b😀x")
    }

    // MARK: - Reject mid-surrogate-pair indexes

    // Same non-throwing failure style as the lone-surrogate case above: `edit` returns `nil`.
    @MainActor
    func test_Text_edit_rejects_a_mid_pair_index() throws {
        let doc = try self.newSurrogateDoc()
        try doc.update { root, _ in
            let result = (root.text as? JSONText)?.edit(1, 1, "y")
            XCTAssertNil(result)
        }
        XCTAssertEqual((doc.getRoot().text as? JSONText)?.toString, self.surrogateText)
    }

    // `JSONText.setStyle` keeps its existing failure style too: it returns `false` rather than
    // throwing.
    @MainActor
    func test_Text_setStyle_rejects_a_mid_pair_index() throws {
        let doc = try self.newSurrogateDoc()
        try doc.update { root, _ in
            let result = (root.text as? JSONText)?.setStyle(0, 1, ["bold": "true"])
            XCTAssertEqual(result, false)
        }
        XCTAssertEqual((doc.getRoot().text as? JSONText)?.toString, self.surrogateText)
    }

    // Mirrors JS's table of Tree entry points that all route through the same checked
    // `CRDTTree.findPos`. The last component of a path into a text node is a UTF-16 offset, so
    // `[0, 1]` is offset 1 of the text under the first <p>.
    @MainActor
    func test_Tree_entry_points_reject_a_mid_pair_index() throws {
        let yNode = JSONTreeTextNode(value: "y")
        let cases: [(String, (JSONObject) throws -> Void)] = [
            ("Tree.edit", { root in try (root.tree as? JSONTree)?.edit(2, 2, yNode) }),
            ("Tree.editBulk", { root in try (root.tree as? JSONTree)?.editBulk(2, 2, [yNode]) }),
            ("Tree.style", { root in try (root.tree as? JSONTree)?.style(1, 2, ["bold": "true"]) }),
            ("Tree.removeStyle", { root in try (root.tree as? JSONTree)?.removeStyle(1, 2, ["bold"]) }),
            ("Tree.editByPath", { root in try (root.tree as? JSONTree)?.editByPath([0, 1], [0, 1], yNode) }),
            ("Tree.editBulkByPath", { root in try (root.tree as? JSONTree)?.editBulkByPath([0, 1], [0, 1], [yNode]) }),
            ("Tree.styleByPath", { root in try (root.tree as? JSONTree)?.styleByPath([0, 0], [0, 1], ["bold": "true"]) }),
            ("Tree.removeStyleByPath", { root in try (root.tree as? JSONTree)?.removeStyleByPath([0, 0], [0, 1], ["bold"]) }),
            ("Tree.splitByPath", { root in try (root.tree as? JSONTree)?.splitByPath([0, 1]) })
        ]

        for (name, fn) in cases {
            let doc = try self.newSurrogateDoc()
            self.assertRejectsMidSurrogate(doc, name) { root, _ in try fn(root) }
        }
    }

    @MainActor
    func test_keeps_valid_Text_boundaries_editable() throws {
        for (idx, expected) in [(0, "y😀x"), (2, "😀yx"), (3, "😀xy")] {
            let doc = try self.newSurrogateDoc()
            try doc.update { root, _ in
                (root.text as? JSONText)?.edit(idx, idx, "y")
            }
            XCTAssertEqual((doc.getRoot().text as? JSONText)?.toString, expected, "index \(idx)")
        }
    }

    @MainActor
    func test_keeps_valid_Tree_boundaries_editable() throws {
        for (idx, expected) in [(1, "<r><p>y😀x</p></r>"), (3, "<r><p>😀yx</p></r>"), (4, "<r><p>😀xy</p></r>")] {
            let doc = try self.newSurrogateDoc()
            try doc.update { root, _ in
                _ = try (root.tree as? JSONTree)?.edit(idx, idx, JSONTreeTextNode(value: "y"))
            }
            XCTAssertEqual((doc.getRoot().tree as? JSONTree)?.toXML(), expected, "index \(idx)")
        }
    }

    // A rejected `doc.update` must roll back in full for Tree: an earlier, otherwise-valid edit
    // in the same updater must not survive just because a later one in the same closure threw.
    // `JSONTree`'s edit family throws, so `Document.update` catches it, drops the mutated clone
    // entirely (see `Document.update`), and never commits -- the earlier `edit(4, 4, z)` is
    // discarded along with the rejected one.
    @MainActor
    func test_Tree_discards_earlier_edits_of_the_rejected_update() throws {
        let zNode = JSONTreeTextNode(value: "z")
        let doc = try self.newSurrogateDoc()
        let original = (doc.getRoot().tree as? JSONTree)?.toXML()

        self.assertRejectsMidSurrogate(doc) { root, _ in
            try (root.tree as? JSONTree)?.edit(4, 4, zNode)
            try (root.tree as? JSONTree)?.edit(2, 2, zNode)
        }
        XCTAssertEqual((doc.getRoot().tree as? JSONTree)?.toXML(), original)

        try doc.update { root, _ in
            try (root.tree as? JSONTree)?.edit(4, 4, zNode)
        }
        let edited = (doc.getRoot().tree as? JSONTree)?.toXML()
        XCTAssertEqual(edited, "<r><p>😀xz</p></r>")

        try doc.undo()
        XCTAssertEqual((doc.getRoot().tree as? JSONTree)?.toXML(), original)
        try doc.redo()
        XCTAssertEqual((doc.getRoot().tree as? JSONTree)?.toXML(), edited)
    }

    // The Text counterpart of the test above, but documenting the opposite outcome: because
    // `JSONText.edit` does not throw (see the failure-style note on
    // `test_Text_edit_rejects_a_mid_pair_index`), nothing signals `Document.update` to drop the
    // clone, so an earlier, valid `edit` in the same updater DOES survive a later rejected one
    // in that closure -- unlike Tree's throwing methods. This is a pre-existing property of
    // `JSONText`'s catch-and-return-nil wrapper, not something this port changes; it is pinned
    // here so a future change to that wrapper's error handling does not silently flip it.
    @MainActor
    func test_Text_edit_does_not_roll_back_an_earlier_edit_in_the_same_update() throws {
        let doc = try self.newSurrogateDoc()

        try doc.update { root, _ in
            let valid = (root.text as? JSONText)?.edit(3, 3, "z")
            XCTAssertNotNil(valid, "the earlier, in-range edit succeeds")
            let rejected = (root.text as? JSONText)?.edit(1, 1, "y")
            XCTAssertNil(rejected, "the later, mid-pair edit is refused")
        }

        XCTAssertEqual((doc.getRoot().text as? JSONText)?.toString, "😀xz")
    }

    // The unchecked paths (`findPosUnchecked`, used by undo/redo reconciliation) must still
    // resolve correctly around an intact pair -- the fix narrows what the checked path
    // accepts, and must not also narrow what undo/redo can replay. Compared via `toXML()` /
    // `.toString`, not `toSortedJSON()`: inserting mid-node physically splits the underlying
    // RGA node, and undo removes the inserted content without re-merging the split, so the
    // internal JSON shape differs from the pre-edit document even though the visible content
    // (and a fresh edit at the same position) is identical.
    @MainActor
    func test_undoes_and_redoes_around_an_intact_pair() throws {
        let cases: [(String, (JSONObject) throws -> Void)] = [
            ("insert after the pair", { root in
                try (root.tree as? JSONTree)?.edit(3, 3, JSONTreeTextNode(value: "y"))
                (root.text as? JSONText)?.edit(2, 2, "y")
            }),
            ("delete the pair", { root in
                try (root.tree as? JSONTree)?.edit(1, 3)
                (root.text as? JSONText)?.edit(0, 2, "")
            }),
            ("replace the pair", { root in
                try (root.tree as? JSONTree)?.edit(1, 3, JSONTreeTextNode(value: "y"))
                (root.text as? JSONText)?.edit(0, 2, "y")
            })
        ]

        for (name, fn) in cases {
            let doc = try self.newSurrogateDoc()
            let originalXML = (doc.getRoot().tree as? JSONTree)?.toXML()
            let originalText = (doc.getRoot().text as? JSONText)?.toString
            try doc.update { root, _ in try fn(root) }
            let editedXML = (doc.getRoot().tree as? JSONTree)?.toXML()
            let editedText = (doc.getRoot().text as? JSONText)?.toString

            try doc.undo()
            XCTAssertEqual((doc.getRoot().tree as? JSONTree)?.toXML(), originalXML, name)
            XCTAssertEqual((doc.getRoot().text as? JSONText)?.toString, originalText, name)
            try doc.redo()
            XCTAssertEqual((doc.getRoot().tree as? JSONTree)?.toXML(), editedXML, name)
            XCTAssertEqual((doc.getRoot().text as? JSONText)?.toString, editedText, name)
        }
    }
}
