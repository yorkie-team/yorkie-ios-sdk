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
// Ports: packages/sdk/test/unit/document/tree_split_sibling_cascade_test.ts
// (yorkie-js-sdk#1456, commit 6f690a147, "Stop the split-sibling cascade at a sibling the
// editor saw alive"; the JS half of yorkie-team/yorkie#2143).
//
// Two replicas each splitting `<span>de</span>` at offset 0 and deleting the empty left piece
// (what an editor does for Enter before a styled run) lost "de" on one replica
// (yorkie-js-sdk#1408): the cascade walked the whole `insNextID` chain of the deleted element
// and tombstoned every split product the editor did not know, including the concurrent product
// that held the moved text. The walk now passes a sibling the editor knew only if the editor
// saw it gone (removed by a change the editor knew, or enclosed whole by this delete); any
// other known sibling ends the walk.
//
// Each case runs in both role assignments and with both actor orders, so either side's ticket
// wins the LWW once. Two in-process replicas exchange their pending changes through the
// converter, without a server.

import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

private let actor1 = "000000000000000000000001"
private let actor2 = "000000000000000000000002"

/// `treeShape` renders the tree with every node's ID, tombstones included, so two replicas
/// that only agree on XML still count as diverged.
@MainActor
private func treeShape(_ doc: Document) -> String {
    guard let tree = doc.getRootObject().get(key: "t") as? CRDTTree else {
        return ""
    }
    func walk(_ node: CRDTTreeNode) -> String {
        let removed = node.isRemoved ? "x" : ""
        if node.isText {
            return "\(node.id.toIDString)\(removed)\"\(node.value as String)\""
        }
        let children = node.innerChildren.map(walk).joined(separator: ",")
        return "\(node.type)#\(node.id.toIDString)\(removed)[\(children)]"
    }
    return walk(tree.root)
}

/// `exchange` hands each replica's pending changes to the other through the converter's
/// `ChangePack`, as on the wire, without a server.
@MainActor
private func exchange(_ first: Document, _ second: Document) throws {
    let docs = [first, second]
    let packs = try docs.map { try Converter.fromChangePack(Converter.toChangePack(pack: $0.createChangePack())) }
    for (index, doc) in docs.enumerated() {
        let sender = packs[1 - index]
        try doc.applyChangePack(ChangePack(key: sender.getDocumentKey(),
                                           checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                           isRemoved: false,
                                           changes: sender.getChanges(),
                                           versionVector: VersionVector.initial))
    }
    for (index, doc) in docs.enumerated() {
        let lastSeq = packs[index].getChanges().last?.id.getClientSeq() ?? 0
        try doc.applyChangePack(ChangePack(key: packs[index].getDocumentKey(),
                                           checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
                                           isRemoved: false,
                                           changes: [],
                                           versionVector: VersionVector.initial))
    }
}

/// `replicas` returns two synced replicas holding `<p>` with the given spans. With `flip` the
/// first replica gets the higher actor ID, so its ticket wins ties.
@MainActor
private func replicas(_ spans: [String], flip: Bool = false) throws -> (Document, Document) {
    let doc1 = Document(key: "doc")
    let doc2 = Document(key: "doc")
    doc1.setActor(flip ? actor2 : actor1)
    doc2.setActor(flip ? actor1 : actor2)
    try doc1.update { root, _ in
        root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [
            JSONTreeElementNode(type: "p", children: spans.map { value in
                JSONTreeElementNode(type: "span", children: [JSONTreeTextNode(value: value)])
            })
        ]))
    }
    try exchange(doc1, doc2)
    return (doc1, doc2)
}

private typealias SplitOp = (JSONTree) throws -> Void

@MainActor
private func edit(_ doc: Document, _ op: SplitOp) throws {
    try doc.update { root, _ in
        try op(XCTUnwrap(root.t as? JSONTree))
    }
}

@MainActor
private func xml(_ doc: Document) -> String {
    (doc.getRoot().t as? JSONTree)?.toXML() ?? ""
}

/// Split the span at 0, then drop the empty left piece.
private let splitSpanAt0AndDropLeft: SplitOp = { tree in
    _ = try tree.editByPath([0, 1, 0], [0, 1, 0], nil, 1)
    _ = try tree.editByPath([0, 1], [0, 2])
}

/// Split the span at 0, split the paragraph after it, then drop the empty left piece.
private let enterAtSpanStart: SplitOp = { tree in
    _ = try tree.editByPath([0, 1, 0], [0, 1, 0], nil, 1)
    try tree.splitByPath([0, 2])
    _ = try tree.editByPath([0, 1], [0, 2])
}

private struct CascadeCase {
    var spans: [String]
    /// Run on the second replica and synced before the race.
    var setup: SplitOp?
    var first: SplitOp
    var second: SplitOp
    /// Expected converged XML; nil means any, as long as both agree.
    var want: String?
    /// One replica may keep a concurrent split product as an empty span that the other
    /// tombstoned (yorkie-js-sdk#1408, not fixed here). Text must still agree.
    var emptySpanResidue = false
    /// Tombstones may sit in a different order on each side (a merge against a split).
    /// Compare shapes after GC only.
    var tombstoneOrder = false
}

private let emptySpan = "<span></span>"

private func countEmpty(_ xml: String) -> Int {
    xml.components(separatedBy: emptySpan).count - 1
}

final class TreeSplitSiblingCascadeTests: XCTestCase {
    @MainActor
    private func run(_ testCase: CascadeCase) throws {
        for swap in [false, true] {
            for flip in [false, true] {
                let label = "(swap=\(swap), flip=\(flip))"
                let (doc1, doc2) = try replicas(testCase.spans, flip: flip)
                if let setup = testCase.setup {
                    try edit(doc2, setup)
                    try exchange(doc1, doc2)
                }
                try edit(doc1, swap ? testCase.second : testCase.first)
                try edit(doc2, swap ? testCase.first : testCase.second)
                try exchange(doc1, doc2)

                var xml1 = xml(doc1)
                var xml2 = xml(doc2)
                let residue = xml1 != xml2
                if residue {
                    XCTAssertTrue(testCase.emptySpanResidue, "XML diverged \(label):\n\(xml1)\n\(xml2)")
                    // Exactly one empty span more on one side; nothing else.
                    let (count1, count2) = (countEmpty(xml1), countEmpty(xml2))
                    XCTAssertEqual(abs(count1 - count2), 1, "not one empty span \(label):\n\(xml1)\n\(xml2)")
                    let keep = min(count1, count2)
                    func drop(_ xml: String, _ count: Int) -> String {
                        var xml = xml
                        for _ in 0 ..< max(0, count - keep) {
                            if let range = xml.range(of: emptySpan) {
                                xml.replaceSubrange(range, with: "")
                            }
                        }
                        return xml
                    }
                    xml1 = drop(xml1, count1)
                    xml2 = drop(xml2, count2)
                    XCTAssertEqual(xml1, xml2, "diverged beyond an empty span \(label)")
                } else if !testCase.tombstoneOrder {
                    XCTAssertEqual(treeShape(doc1), treeShape(doc2), "shape diverged \(label)")
                }
                if let want = testCase.want {
                    XCTAssertEqual(xml1.components(separatedBy: emptySpan).joined(), want, label)
                }

                // Every tombstone the race left is collectable on both sides, and what remains
                // still agrees.
                let vector = maxVectorOf(actors: [actor1, actor2])
                _ = doc1.garbageCollect(minSyncedVersionVector: vector)
                _ = doc2.garbageCollect(minSyncedVersionVector: vector)
                XCTAssertEqual(doc1.getGarbageLength(), 0, "garbage left on d1 \(label)")
                XCTAssertEqual(doc2.getGarbageLength(), 0, "garbage left on d2 \(label)")
                if !residue {
                    XCTAssertEqual(treeShape(doc1), treeShape(doc2), "shape diverged after gc \(label)")
                }
            }
        }
    }

    @MainActor
    func test_same_boundary_split_at_0_and_drop_left_piece_on_both_sides() throws {
        try self.run(CascadeCase(spans: ["abc", "de"],
                                 first: splitSpanAt0AndDropLeft,
                                 second: splitSpanAt0AndDropLeft,
                                 want: "<doc><p><span>abc</span><span>de</span></p></doc>",
                                 emptySpanResidue: true))
    }

    @MainActor
    func test_enter_at_the_start_of_a_styled_run_on_both_sides() throws {
        try self.run(CascadeCase(spans: ["abc", "de"],
                                 first: enterAtSpanStart,
                                 second: enterAtSpanStart,
                                 want: "<doc><p><span>abc</span></p><p></p><p><span>de</span></p></doc>",
                                 emptySpanResidue: true))
    }

    @MainActor
    func test_enter_on_one_side_split_only_on_the_other() throws {
        try self.run(CascadeCase(spans: ["abc", "de"],
                                 first: enterAtSpanStart,
                                 second: { tree in
                                     _ = try tree.editByPath([0, 1, 0], [0, 1, 0], nil, 1)
                                     try tree.splitByPath([0, 2])
                                 }))
    }

    @MainActor
    func test_split_at_0_and_drop_left_piece_against_a_plain_split_at_0() throws {
        try self.run(CascadeCase(spans: ["abc", "de"],
                                 first: splitSpanAt0AndDropLeft,
                                 second: { _ = try $0.editByPath([0, 1, 0], [0, 1, 0], nil, 1) }))
    }

    @MainActor
    func test_split_at_different_offsets_and_drop_left_piece_on_both_sides() throws {
        try self.run(CascadeCase(spans: ["abc", "defg"],
                                 first: { tree in
                                     _ = try tree.editByPath([0, 1, 1], [0, 1, 1], nil, 1)
                                     _ = try tree.editByPath([0, 1], [0, 2])
                                 },
                                 second: { tree in
                                     _ = try tree.editByPath([0, 1, 3], [0, 1, 3], nil, 1)
                                     _ = try tree.editByPath([0, 1], [0, 2])
                                 },
                                 emptySpanResidue: true))
    }

    @MainActor
    func test_split_and_drop_left_piece_against_deleting_the_whole_span() throws {
        try self.run(CascadeCase(spans: ["abc", "de"],
                                 first: { tree in
                                     _ = try tree.editByPath([0, 1, 1], [0, 1, 1], nil, 1)
                                     _ = try tree.editByPath([0, 1], [0, 2])
                                 },
                                 second: { _ = try $0.editByPath([0, 1], [0, 2]) },
                                 want: "<doc><p><span>abc</span></p></doc>",
                                 emptySpanResidue: true))
    }

    /// `<span>ab</span><span>cd</span>`, the second a split product. One side merges it back and
    /// deletes the whole; the other splits "cd". "d" was inside what the deleter deleted.
    @MainActor
    func test_merge_the_split_sibling_back_and_delete_against_splitting_it() throws {
        try self.run(CascadeCase(spans: ["abcd"],
                                 setup: { _ = try $0.editByPath([0, 0, 2], [0, 0, 2], nil, 1) },
                                 first: { tree in
                                     _ = try tree.editByPath([0, 0, 2], [0, 1, 0])
                                     _ = try tree.editByPath([0, 0], [0, 1])
                                 },
                                 second: { _ = try $0.editByPath([0, 1, 1], [0, 1, 1], nil, 1) },
                                 want: "<doc><p></p></doc>",
                                 tombstoneOrder: true))
    }

    /// One side deletes "ab"; the other presses Enter at the start of "cd", which nobody deleted.
    @MainActor
    func test_delete_an_element_against_enter_at_the_start_of_its_split_sibling() throws {
        try self.run(CascadeCase(spans: ["abcd"],
                                 setup: { _ = try $0.editByPath([0, 0, 2], [0, 0, 2], nil, 1) },
                                 first: { _ = try $0.editByPath([0, 0], [0, 1]) },
                                 second: { tree in
                                     _ = try tree.editByPath([0, 1, 0], [0, 1, 0], nil, 1)
                                     _ = try tree.editByPath([0, 1], [0, 2])
                                 },
                                 want: "<doc><p><span>cd</span></p></doc>"))
    }

    /// One side deletes both halves; the other splits "cd" and deletes "c". The deleter's delete
    /// of "cd" may lose the LWW.
    @MainActor
    func test_delete_an_element_and_its_split_sibling_against_splitting_and_deleting_that_sibling() throws {
        try self.run(CascadeCase(spans: ["abcd"],
                                 setup: { _ = try $0.editByPath([0, 0, 2], [0, 0, 2], nil, 1) },
                                 first: { _ = try $0.editByPath([0, 0], [0, 2]) },
                                 second: { tree in
                                     _ = try tree.editByPath([0, 1, 1], [0, 1, 1], nil, 1)
                                     _ = try tree.editByPath([0, 1], [0, 2])
                                 },
                                 want: "<doc><p></p></doc>"))
    }

    /// `<span>ab</span><span>cd</span>`, the second a split product the second replica made
    /// beforehand. That replica splits each half again while the other deletes the first half;
    /// "cd" was never in its range.
    @MainActor
    func test_cascade_stops_at_a_split_sibling_the_deleter_already_knew() throws {
        try self.run(CascadeCase(spans: ["abcd"],
                                 setup: { _ = try $0.editByPath([0, 0, 2], [0, 0, 2], nil, 1) },
                                 first: { _ = try $0.editByPath([0, 0], [0, 1]) },
                                 second: { tree in
                                     _ = try tree.editByPath([0, 1, 1], [0, 1, 1], nil, 1)
                                     _ = try tree.editByPath([0, 0, 1], [0, 0, 1], nil, 1)
                                 },
                                 want: "<doc><p><span>c</span><span>d</span></p></doc>"))
    }
}
