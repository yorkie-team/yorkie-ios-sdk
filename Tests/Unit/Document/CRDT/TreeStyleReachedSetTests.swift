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

// Ported from yorkie-js-sdk b69169c0:
// `packages/sdk/test/unit/document/tree_style_reached_set_test.ts`
// (yorkie-js-sdk#1404, yorkie#2038, design doc section 9 "Port specification").
//
// `TreeStyleReachedSetConvergenceTests.swift` (Tests/Integration) already ports
// the first three scenarios of the JS file's "Tree style reached set" describe
// block, as live two-client convergence tests. This file ports the remainder,
// in the JS file's own shape: a single-replica batch-replay harness that feeds
// hand-built change packs into fresh in-process `Document`s and compares what
// the two delivery orders render. `grab`/`feed`/`seed`-style helpers mirror
// `TreeRedoSplitStyleTests.swift` and `TreeRestoreTicketOrderTests.swift`.
//
// The exhaustive scans at the end of the JS file (`describe('Tree style
// reached set scans')` and `describe('Tree style reached set nested scans')`)
// are NOT ported here: they replay every split/merge x every style range pair
// over a 12- or 22-wide base (1001 to 11592 pairs per scan, each replayed in
// both delivery orders) and assert exact pinned counts of how many diverge,
// including 241 pairs the JS file documents as an intentionally still-open
// divergence (yorkie#2070) bounded as a ratchet. Porting them verbatim would
// mean replicating that exact ratchet on the iOS tree implementation, which is
// a cross-SDK contract decision beyond this test port. The individual
// scenarios in this file (and `TreeStyleReachedSetConvergenceTests.swift`)
// cover the same reached-set rules the scans close over, one concrete shape at
// a time.

import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

/// Returns a document pinned to `actor`.
@MainActor
private func newActor(_ actor: String) -> Document {
    let doc = Document(key: "d")
    doc.setActor(actor)
    return doc
}

/// Takes a document's pending local changes through the wire form and acks them, so they can be
/// replayed into other documents in any order. Decoded afresh on every `feed`: handing one decoded
/// change to two documents would let the first rewrite the version vector the second still has to
/// read.
@MainActor
private func grab(_ doc: Document) throws -> PbChangePack {
    let pack = doc.createChangePack()
    let lastSeq = pack.getChanges().last?.id.getClientSeq() ?? 0
    let pb = Converter.toChangePack(pack: pack)
    try doc.applyChangePack(ChangePack(
        key: pack.getDocumentKey(),
        checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
        isRemoved: false,
        changes: [],
        versionVector: VersionVector.initial
    ))
    return pb
}

/// Applies a grabbed batch to `doc` as a remote change pack.
@MainActor
private func feed(_ doc: Document, _ batch: PbChangePack) throws {
    let pack = try Converter.fromChangePack(batch)
    try doc.applyChangePack(ChangePack(
        key: pack.getDocumentKey(),
        checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
        isRemoved: false,
        changes: pack.getChanges(),
        versionVector: VersionVector.initial
    ))
}

/// Applies `block` to `doc`'s tree inside an `update`, failing silently if "t" is not a tree (the
/// seeding step always sets it first).
@MainActor
private func updateTree(_ doc: Document, _ block: (JSONTree) throws -> Void) throws {
    try doc.update { root, _ in
        guard let tree = root.t as? JSONTree else { return }
        try block(tree)
    }
}

/// Returns the batch that creates `root` under `t`, optionally followed by a structural change
/// both clients have already seen.
@MainActor
private func seedBase(_ root: JSONTreeElementNode, pre: ((JSONTree) throws -> Void)? = nil) throws -> PbChangePack {
    let seed = newActor("000000000000000000000009")
    try seed.update { treeRoot, _ in
        treeRoot.t = JSONTree(initialRoot: root)
    }
    if let pre {
        try updateTree(seed, pre)
    }
    return try grab(seed)
}

/// A `<p>` element wrapping a single text node, with optional attributes.
private func p(_ value: String, _ attributes: [String: String] = [:]) -> JSONTreeElementNode {
    JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: value)], attributes: attributes)
}

/// `<r><p>ab</p><p>cd</p><p>ef</p></r>`, 12 wide inside the root.
private func styleScanBase() -> JSONTreeElementNode {
    JSONTreeElementNode(type: "r", children: [p("ab"), p("cd"), p("ef")])
}

/// The same base with every paragraph bold, so a `removeStyle` has something to take off.
private func styleScanBoldBase() -> JSONTreeElementNode {
    JSONTreeElementNode(type: "r", children: [
        p("ab", ["b": "x"]), p("cd", ["b": "x"]), p("ef", ["b": "x"])
    ])
}

/// Generates one structural change and one style change from the same base, on fixed actors.
@MainActor
private func concurrentTreeChanges(
    _ base: PbChangePack,
    structural: (JSONTree) throws -> Void,
    style: (JSONTree) throws -> Void
) throws -> (PbChangePack, PbChangePack) {
    let docA = newActor("000000000000000000000001")
    let docB = newActor("000000000000000000000002")
    try feed(docA, base)
    try feed(docB, base)
    try updateTree(docA, structural)
    try updateTree(docB, style)
    return try (grab(docA), grab(docB))
}

/// Applies the two batches in the given order onto a fresh replica of the base and hands the
/// replica back.
@MainActor
private func replayInto(_ base: PbChangePack, _ first: PbChangePack, _ second: PbChangePack) throws -> Document {
    let doc = newActor("00000000000000000000000a")
    try feed(doc, base)
    try feed(doc, first)
    try feed(doc, second)
    return doc
}

/// Everything two delivery orders have to agree on: the rendered document and both halves of the
/// size ledger. A style that lands on a tombstone shows up only in the size.
private struct ReplayResult: Equatable {
    let xml: String
    let size: String
    let err: String
}

/// Replays the two batches in the given order and reports the rendered document and size ledger,
/// or the error a replay threw.
@MainActor
private func replayOrder(_ base: PbChangePack, _ first: PbChangePack, _ second: PbChangePack) -> ReplayResult {
    do {
        let doc = try replayInto(base, first, second)
        let tree = try XCTUnwrap(doc.getRoot().t as? JSONTree)
        let size = doc.getDocSize()
        let sizeDescription = "live=\(size.live.data)/\(size.live.meta) gc=\(size.gc.data)/\(size.gc.meta) gcLen=\(doc.getGarbageLength())"
        return ReplayResult(xml: tree.toXML(), size: sizeDescription, err: "")
    } catch {
        return ReplayResult(xml: "", size: "", err: "\(error)")
    }
}

/// Renders the attribute entries of every live element under the root as sorted descriptors.
/// `withTicket` adds the entry's update ticket, which carries the identity two replicas can
/// disagree on while still rendering the same.
@MainActor
private func liveAttrDescs(_ doc: Document, withTicket: Bool) throws -> [String] {
    let tree = try XCTUnwrap(doc.getRootObject().get(key: "t") as? CRDTTree)
    var descs: [String] = []

    func walk(_ node: CRDTTreeNode) {
        for child in node.children {
            if child.isText { continue }
            if let attrs = child.attrs {
                for entry in attrs {
                    var desc = "\(child.type) \(entry.key)=\"\(entry.value)\" removed=\(entry.isRemoved)"
                    if withTicket {
                        desc += " updatedAt=\(entry.updatedAt.toIDString)"
                    }
                    descs.append(desc)
                }
            }
            walk(child)
        }
    }

    walk(tree.root)
    return descs.sorted()
}

final class TreeStyleReachedSetTests: XCTestCase {
    // MARK: - Tree style reached set (remainder of the base describe block)

    /// The mirror of `test_styles_both_paragraphs_a_concurrent_merge_joins`
    /// (Tests/Integration/TreeStyleReachedSetConvergenceTests.swift) with a
    /// `removeStyle` instead of a `style`, over the bold base: the merge target
    /// a range start moved into must not be CLEARED either.
    @MainActor
    func test_does_not_clear_the_merge_target_a_range_start_moved_into() throws {
        // given
        let base = try seedBase(styleScanBoldBase())

        // when — d1 merges p1+p2 as before; d2 un-bolds from inside p2 only
        // through just past p2's close tag, a range that never names p1.
        let (pA, pB) = try concurrentTreeChanges(
            base,
            structural: { try $0.edit(1, 5) },
            style: { try $0.removeStyle(6, 8, ["b"]) }
        )

        // then — neither replica clears the merge target.
        let ab = replayOrder(base, pA, pB)
        let ba = replayOrder(base, pB, pA)
        XCTAssertEqual(ba.xml, "<r><p b=\"x\">cd</p><p b=\"x\">ef</p></r>")
        XCTAssertEqual(ab, ba, "merge-then-remove-style clears the target")
    }

    /// The mirror of `test_styles_both_halves_of_a_concurrently_split_paragraph`
    /// (Tests/Integration/TreeStyleReachedSetConvergenceTests.swift) with a
    /// `removeStyle` instead of a `style`, over the bold base.
    @MainActor
    func test_clears_both_halves_of_a_concurrently_split_paragraph() throws {
        // given
        let base = try seedBase(styleScanBoldBase())

        // when — d1 splits p2 ("cd") between 'c' and 'd'; d2 un-bolds all of
        // p2.
        let (pA, pB) = try concurrentTreeChanges(
            base,
            structural: { try $0.edit(6, 6, nil, 1) },
            style: { try $0.removeStyle(5, 8, ["b"]) }
        )

        // then — the clear carries onto BOTH halves of the split.
        let ab = replayOrder(base, pA, pB)
        let ba = replayOrder(base, pB, pA)
        XCTAssertEqual(ba.xml, "<r><p b=\"x\">ab</p><p>c</p><p>d</p><p b=\"x\">ef</p></r>")
        XCTAssertEqual(ab, ba, "split-then-remove-style diverges")
    }

    // MARK: - Tree style reached set matches the complex suite

    /// Asserts both delivery orders of `structural`/`style` starting from
    /// `base` (with an optional `pre` structural change both replicas have
    /// already seen) render `want`, and — when `wantAttrs` is given — that the
    /// live attribute entries on the second order match `wantAttrs` exactly
    /// and both orders agree on entry identity (ticket included).
    @MainActor
    private func assertComplexSuiteCase(
        base: JSONTreeElementNode,
        pre: ((JSONTree) throws -> Void)? = nil,
        structural: (JSONTree) throws -> Void,
        style: (JSONTree) throws -> Void,
        want: String,
        wantAttrs: [String]? = nil
    ) throws {
        let base = try seedBase(base, pre: pre)
        let (pA, pB) = try concurrentTreeChanges(base, structural: structural, style: style)
        let abDoc = try replayInto(base, pA, pB)
        let baDoc = try replayInto(base, pB, pA)
        let abXML = try XCTUnwrap(abDoc.getRoot().t as? JSONTree).toXML()
        let baXML = try XCTUnwrap(baDoc.getRoot().t as? JSONTree).toXML()

        XCTAssertEqual(baXML, want)
        if let wantAttrs {
            XCTAssertEqual(try liveAttrDescs(baDoc, withTicket: false), wantAttrs)
            XCTAssertEqual(
                try liveAttrDescs(abDoc, withTicket: true),
                try liveAttrDescs(baDoc, withTicket: true),
                "the two orders hold different attribute entries on live nodes"
            )
        }
        XCTAssertEqual(abXML, baXML, "the two delivery orders render differently")
    }

    private func twoParagraphs() -> JSONTreeElementNode {
        JSONTreeElementNode(type: "r", children: [p("ab"), p("cd")])
    }

    private func threeParagraphs() -> JSONTreeElementNode {
        JSONTreeElementNode(type: "r", children: [p("ab"), p("cd"), p("ef")])
    }

    private let bold = ["bold": "x"]

    @MainActor
    func test_covering_merged_content() throws {
        try self.assertComplexSuiteCase(
            base: self.twoParagraphs(),
            structural: { try $0.edit(0, 4) },
            style: { try $0.style(4, 8, self.bold) },
            want: "<r><p bold=\"x\">cd</p></r>"
        )
    }

    @MainActor
    func test_across_chained_merge() throws {
        try self.assertComplexSuiteCase(
            base: self.threeParagraphs(),
            structural: { tree in
                try tree.edit(7, 9)
                try tree.edit(3, 5)
            },
            style: { tree in
                try tree.edit(12, 12, JSONTreeElementNode(type: "p", children: []))
                try tree.style(0, 9, self.bold)
            },
            want: "<r><p bold=\"x\">abcdef</p><p></p></r>"
        )
    }

    /// The interloper inserted at the merged anchor stays UNSTYLED.
    @MainActor
    func test_after_moved_anchor() throws {
        try self.assertComplexSuiteCase(
            base: self.twoParagraphs(),
            structural: { try $0.edit(0, 5) },
            style: { tree in
                try tree.edit(8, 8, JSONTreeElementNode(type: "p", children: []))
                try tree.style(0, 6, self.bold)
            },
            want: "<r><p></p>cd</r>"
        )
    }

    @MainActor
    func test_covers_own_insert_into_merged_range() throws {
        try self.assertComplexSuiteCase(
            base: self.twoParagraphs(),
            structural: { try $0.edit(0, 5) },
            style: { tree in
                try tree.edit(5, 5, JSONTreeElementNode(type: "b", children: []))
                try tree.style(0, 8, self.bold)
            },
            want: "<r><b bold=\"x\"></b>cd</r>"
        )
    }

    @MainActor
    func test_sibling_before_tombstone() throws {
        try self.assertComplexSuiteCase(
            base: JSONTreeElementNode(type: "r", children: [
                JSONTreeElementNode(type: "b", children: []), p("ab"), p("cd")
            ]),
            structural: { try $0.edit(2, 7) },
            style: { try $0.style(0, 8, self.bold) },
            want: "<r><b bold=\"x\"></b>cd</r>"
        )
    }

    /// The range ends inside the merged-away paragraph, so the interloper the
    /// merge pulls next to that anchor stays out of the reached set.
    @MainActor
    func test_skips_interloper_descendants() throws {
        try self.assertComplexSuiteCase(
            base: self.twoParagraphs(),
            structural: { try $0.edit(0, 5) },
            style: { tree in
                try tree.edit(8, 8, JSONTreeElementNode(type: "p", children: []))
                try tree.edit(9, 9, JSONTreeElementNode(type: "b", children: []))
                try tree.style(0, 6, self.bold)
            },
            want: "<r><p><b></b></p>cd</r>"
        )
    }

    /// The range ends inside the merged-away paragraph, so the interloper the
    /// merge pulls next to that anchor stays out of the reached set.
    @MainActor
    func test_across_merged_anchor() throws {
        try self.assertComplexSuiteCase(
            base: self.twoParagraphs(),
            structural: { try $0.edit(0, 5) },
            style: { tree in
                try tree.edit(8, 8, JSONTreeElementNode(type: "p", children: []))
                try tree.style(0, 5, self.bold)
            },
            want: "<r><p></p>cd</r>",
            wantAttrs: []
        )
    }

    /// The same range as a `removeStyle`, which must not leave an attribute
    /// container behind on the interloper either.
    @MainActor
    func test_remove_style_across_merged_anchor() throws {
        try self.assertComplexSuiteCase(
            base: self.twoParagraphs(),
            structural: { try $0.edit(0, 5) },
            style: { tree in
                try tree.edit(8, 8, JSONTreeElementNode(type: "p", children: []))
                try tree.removeStyle(0, 5, ["bold"])
            },
            want: "<r><p></p>cd</r>",
            wantAttrs: []
        )
    }

    @MainActor
    func test_remove_style_after_moved_anchor() throws {
        try self.assertComplexSuiteCase(
            base: self.twoParagraphs(),
            structural: { try $0.edit(0, 5) },
            style: { tree in
                try tree.edit(8, 8, JSONTreeElementNode(type: "p", children: []))
                try tree.removeStyle(0, 6, ["bold"])
            },
            want: "<r><p></p>cd</r>",
            wantAttrs: []
        )
    }

    /// `<i>` arrived in `<p>` through a merge both clients have seen, so a
    /// range covering it still reaches it when a second merge lifts it into
    /// the root.
    @MainActor
    func test_covers_earlier_merged_child() throws {
        try self.assertComplexSuiteCase(
            base: JSONTreeElementNode(type: "r", children: [
                p("ab"),
                JSONTreeElementNode(type: "s", children: [JSONTreeElementNode(type: "i", children: [])])
            ]),
            pre: { try $0.edit(3, 5) },
            structural: { try $0.edit(0, 1) },
            style: { try $0.style(0, 5, self.bold) },
            want: "<r>ab<i bold=\"x\"></i></r>",
            wantAttrs: ["i bold=\"x\" removed=false"]
        )
    }

    /// The merge collapses the range, and the recovery hands back exactly the
    /// writer's own insert — which the range ended inside, so it is styled.
    @MainActor
    func test_style_from_side_moved_anchor() throws {
        try self.assertComplexSuiteCase(
            base: self.twoParagraphs(),
            structural: { try $0.edit(0, 5) },
            style: { tree in
                try tree.edit(8, 8, JSONTreeElementNode(type: "p", children: []))
                try tree.style(6, 9, self.bold)
            },
            want: "<r><p bold=\"x\"></p>cd</r>",
            wantAttrs: ["p bold=\"x\" removed=false"]
        )
    }

    /// The removal entry that arbitrates a later `setAttr` must land on the
    /// surviving `<p>` in both orders, with one identity.
    @MainActor
    func test_remove_style_from_side_moved_anchor() throws {
        try self.assertComplexSuiteCase(
            base: self.twoParagraphs(),
            structural: { try $0.edit(0, 5) },
            style: { tree in
                try tree.edit(8, 8, JSONTreeElementNode(type: "p", children: []))
                try tree.removeStyle(6, 9, ["bold"])
            },
            want: "<r><p></p>cd</r>",
            wantAttrs: ["p bold=\"\" removed=true"]
        )
    }

    /// Both anchors sit inside the merged paragraph, so the resolved range
    /// moves with the merge and stays ordered — the recovery must not widen
    /// it onto the writer's insert.
    @MainActor
    func test_style_from_side_ordered_range() throws {
        try self.assertComplexSuiteCase(
            base: self.twoParagraphs(),
            structural: { try $0.edit(0, 5) },
            style: { tree in
                try tree.edit(8, 8, JSONTreeElementNode(type: "p", children: []))
                try tree.style(6, 7, self.bold)
            },
            want: "<r><p></p>cd</r>",
            wantAttrs: []
        )
    }

    // MARK: - Tree style reached set across a level-2 split before the range

    /// `<r><p><p><p>abcd</p><p>efgh</p></p><p>ijkl</p></p></r>`, every
    /// paragraph carrying `italic`.
    private func nested() -> JSONTreeElementNode {
        JSONTreeElementNode(type: "r", children: [
            JSONTreeElementNode(type: "p", children: [
                JSONTreeElementNode(type: "p", children: [
                    p("abcd", ["italic": "a"]), p("efgh", ["italic": "a"])
                ]),
                p("ijkl", ["italic": "a"])
            ])
        ])
    }

    /// A level-2 split of the paragraph just BEFORE a style range. The style
    /// covered only `<p>efgh</p>`; the split carries the right half of
    /// `<p>abcd</p>` into a new parent, so the traversal starting right after
    /// `<p>abcd</p>` now passes that half's End token. The range never ran
    /// past `<p>abcd</p>`'s end, so neither half may be styled.
    @MainActor
    func test_styles_only_the_paragraph_the_range_covered() throws {
        // given
        let base = try seedBase(self.nested())

        // when
        let (pA, pB) = try concurrentTreeChanges(
            base,
            structural: { try $0.edit(5, 5, nil, 2) },
            style: { try $0.style(8, 14, ["bold": "aa"]) }
        )

        // then
        let ab = replayOrder(base, pA, pB)
        let ba = replayOrder(base, pB, pA)
        XCTAssertEqual(
            ba.xml,
            "<r><p><p><p italic=\"a\">ab</p></p><p><p italic=\"a\">cd</p>" +
                "<p bold=\"aa\" italic=\"a\">efgh</p></p><p italic=\"a\">ijkl</p></p></r>"
        )
        XCTAssertEqual(ab, ba, "split-then-style diverges")
    }

    /// The `removeStyle` mirror of `test_styles_only_the_paragraph_the_range_covered`.
    @MainActor
    func test_clears_only_the_paragraph_the_range_covered() throws {
        // given
        let base = try seedBase(self.nested())

        // when
        let (pA, pB) = try concurrentTreeChanges(
            base,
            structural: { try $0.edit(5, 5, nil, 2) },
            style: { try $0.removeStyle(8, 14, ["italic"]) }
        )

        // then
        let ab = replayOrder(base, pA, pB)
        let ba = replayOrder(base, pB, pA)
        XCTAssertEqual(
            ba.xml,
            "<r><p><p><p italic=\"a\">ab</p></p><p><p italic=\"a\">cd</p>" +
                "<p>efgh</p></p><p italic=\"a\">ijkl</p></p></r>"
        )
        XCTAssertEqual(ab, ba, "split-then-remove-style diverges")
    }

    // MARK: - Tree style reached set before a split and merge in one change

    /// `<r><p><p><p>abcd</p><p>efgh</p></p><p>ijkl</p></p></r>`, 22 wide
    /// inside the root, every paragraph carrying `attrs`.
    private func nestedScanBase(_ attrs: [String: String]? = nil) -> JSONTreeElementNode {
        func para(_ children: [any JSONTreeNode]) -> JSONTreeElementNode {
            JSONTreeElementNode(type: "p", children: children, attributes: attrs ?? [:])
        }
        let abcd = para([JSONTreeTextNode(value: "abcd")])
        let efgh = para([JSONTreeTextNode(value: "efgh")])
        let ijkl = para([JSONTreeTextNode(value: "ijkl")])
        let level2 = para([abcd, efgh])
        let level1 = para([level2, ijkl])
        return JSONTreeElementNode(type: "r", children: [level1])
    }

    /// A split and a merge in one change, against a range that began BEFORE
    /// the split paragraph. The change splits `<p>efgh</p>` after "e" and then
    /// deletes across the boundary before it, merging "e" into `<p>abcd</p>`;
    /// the style covers both paragraphs whole. Applied after the style's
    /// change, the merge moves the traversal past the known half's Start
    /// token, and only the split-family closure styles `<p>fgh</p>`. The
    /// range never named that paragraph as its parent, so begins-inside alone
    /// drops the closure there; it began before the paragraph, and the
    /// document-order half of the guard keeps it.
    private func splitAndMergeEdit(_ tree: JSONTree) throws {
        try tree.edit(10, 10, nil, 1)
        try tree.edit(7, 9)
    }

    @MainActor
    func test_styles_both_paragraphs_the_range_covered() throws {
        // given
        let base = try seedBase(self.nestedScanBase())

        // when
        let (pA, pB) = try concurrentTreeChanges(
            base,
            structural: self.splitAndMergeEdit,
            style: { try $0.style(0, 14, ["b": "x"]) }
        )

        // then
        let ab = replayOrder(base, pA, pB)
        let ba = replayOrder(base, pB, pA)
        XCTAssertEqual(
            ba.xml,
            "<r><p b=\"x\"><p b=\"x\"><p b=\"x\">abcde</p><p b=\"x\">fgh</p></p>" +
                "<p>ijkl</p></p></r>"
        )
        XCTAssertEqual(ab, ba, "split-and-merge-then-style diverges")
    }

    @MainActor
    func test_clears_both_paragraphs_the_range_covered() throws {
        // given
        let base = try seedBase(self.nestedScanBase(["b": "x"]))

        // when
        let (pA, pB) = try concurrentTreeChanges(
            base,
            structural: self.splitAndMergeEdit,
            style: { try $0.removeStyle(0, 14, ["b"]) }
        )

        // then
        let ab = replayOrder(base, pA, pB)
        let ba = replayOrder(base, pB, pA)
        XCTAssertEqual(
            ba.xml,
            "<r><p><p><p>abcde</p><p>fgh</p></p><p b=\"x\">ijkl</p></p></r>"
        )
        XCTAssertEqual(ab, ba, "split-and-merge-then-remove-style diverges")
    }
}
