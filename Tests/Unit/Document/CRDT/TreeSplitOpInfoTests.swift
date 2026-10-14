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

// Ports: packages/sdk/test/unit/document/tree_split_opinfo_test.ts
// (yorkie-js-sdk#1455, commit a74b25134, "Report a remote split where it landed,
// not where it was asked for").
//
// A remote split reports where it split, in the receiver's coordinates. When the
// receiver concurrently inserted at the split boundary, the split keeps that insert
// on its left (§7.3 Boundary Insert Migration), so the boundary the receiver sees is
// after the insert. The OpInfo has to say so: an editor replaying it by index
// otherwise moves the insert to the new node and its model no longer matches the tree.
//
// Two in-process replicas exchange their pending changes through the converter, as on
// the wire, and each replays the OpInfos of the remote changes on a JSON mirror.

import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

/// A mutable mirror node an editor binding would keep.
private final class MirrorNode {
    var type: String
    var value: String
    var children: [MirrorNode]

    init(type: String, value: String = "", children: [MirrorNode] = []) {
        self.type = type
        self.value = value
        self.children = children
    }

    var isText: Bool { self.type == DefaultTreeNodeType.text.rawValue }

    convenience init(_ node: any JSONTreeNode) {
        if let text = node as? JSONTreeTextNode {
            self.init(type: text.type, value: text.value as String)
        } else if let element = node as? JSONTreeElementNode {
            self.init(type: element.type, children: element.children.map { MirrorNode($0) })
        } else {
            self.init(type: node.type)
        }
    }

    func copy() -> MirrorNode {
        MirrorNode(type: self.type, value: self.value, children: self.children.map { $0.copy() })
    }

    /// Merges adjacent text nodes, which the index paths do not tell apart, so a mirror and
    /// a tree compare by what an editor would see.
    func normalized() -> MirrorNode {
        if self.isText {
            return MirrorNode(type: self.type, value: self.value)
        }
        var out = [MirrorNode]()
        for child in self.children {
            let normalizedChild = child.normalized()
            if normalizedChild.isText, let last = out.last, last.isText {
                last.value += normalizedChild.value
            } else if !normalizedChild.isText || !normalizedChild.value.isEmpty {
                out.append(normalizedChild)
            }
        }
        return MirrorNode(type: self.type, children: out)
    }

    func render() -> String {
        if self.isText {
            return self.value
        }
        return "<\(self.type)>\(self.children.map { $0.render() }.joined())</\(self.type)>"
    }

    var hasText: Bool { self.children.contains { $0.isText } }
}

/// Slices by UTF-16 offsets, clamped, like the JS `String.slice`.
private func slice(_ string: String, _ from: Int, _ to: Int? = nil) -> String {
    let ns = string as NSString
    let lower = max(0, min(from, ns.length))
    let upper = max(lower, min(to ?? ns.length, ns.length))
    return ns.substring(with: NSRange(location: lower, length: upper - lower))
}

private let docKey = "tree-split-opinfo"

private typealias TestDoc = Document

/// `exchange` hands each replica's pending changes to the other through the converter, as on
/// the wire, and acknowledges them.
@MainActor
private func exchange(_ first: TestDoc, _ second: TestDoc) throws {
    let packs = [first, second].map { $0.createChangePack() }
    let docs = [first, second]
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

/// `replicas` returns two replicas seeded with `<doc><p><t>abc</t></p></doc>`; `t` is an
/// inline element holding text.
@MainActor
private func replicas(_ actorA: Int, _ actorB: Int) throws -> (TestDoc, TestDoc) {
    let docA = Document(key: docKey)
    let docB = Document(key: docKey)
    docA.setActor(String(format: "%024d", actorA))
    docB.setActor(String(format: "%024d", actorB))
    try docA.update { root, _ in
        root.t = JSONTree(initialRoot:
            JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeElementNode(type: "t", children: [JSONTreeTextNode(value: "abc")])
                ])
            ])
        )
    }
    try exchange(docA, docB)
    return (docA, docB)
}

@MainActor
private func snapshot(_ doc: TestDoc) throws -> MirrorNode {
    let tree = try XCTUnwrap(doc.getRoot().t as? JSONTree)
    let node = try XCTUnwrap(tree.getRootTreeNode())
    return MirrorNode(node).normalized()
}

@MainActor
private func toXML(_ doc: TestDoc) throws -> String {
    try XCTUnwrap(doc.getRoot().t as? JSONTree).toXML()
}

/// `replay` applies tree-edit OpInfos to a JSON mirror by index path, the way an editor binding
/// that keeps its own model does. An edit with `fromPath == toPath` and no value is a split.
/// OpInfos do not carry its `splitLevel` today, so the caller passes the level the sender used.
///
/// A split edit that also inserts content is reported as one change when the split opened where
/// the edit asked for it -- the insert is merged onto the split change, value and all -- and as
/// two (split, then insert) when the split migrated elsewhere. `splitWithContent` says the
/// sender's split carried content, which is the only way to tell that merged change from a plain
/// insert. The content lands left of the boundary, so a merged change inserts at `from` and
/// splits after the insert.
private func replay(_ mirror: MirrorNode, _ ops: [TreeEditOpInfo], _ splitLevel: Int32, splitWithContent: Bool = false) throws -> MirrorNode {
    let mergedSplit = splitWithContent && !ops.contains { $0.from == $0.to && $0.value.isEmpty }
    let root = mirror.copy()

    for op in ops {
        let fromPath = op.fromPath
        let toPath = op.toPath
        guard fromPath.dropLast() == toPath.dropLast() else {
            throw NSError(domain: "replay", code: 1, userInfo: [NSLocalizedDescriptionKey: "cross-parent range \(fromPath) \(toPath)"])
        }
        var chain = [root]
        var parent = root
        for index in 0 ..< max(0, fromPath.count - 1) {
            parent = parent.children[fromPath[index]]
            chain.append(parent)
        }
        let from = fromPath[fromPath.count - 1]
        let to = toPath[toPath.count - 1]
        var insertedSize = 0
        let value = op.value.map { MirrorNode($0) }
        if parent.hasText {
            let text = parent.children[0]
            let inserted = value.map(\.value).joined()
            insertedSize = (inserted as NSString).length
            text.value = slice(text.value, 0, from) + inserted + slice(text.value, to)
        } else {
            insertedSize = value.count
            let lower = min(from, parent.children.count)
            let upper = max(lower, min(to, parent.children.count))
            parent.children.replaceSubrange(lower ..< upper, with: value.map { $0.normalized() })
        }

        if from == to, value.isEmpty || mergedSplit {
            // Split: `levels` levels, starting with the parent of the position.
            var levels = op.splitLevel != 0 ? op.splitLevel : splitLevel
            var node = parent
            var offset = from + insertedSize
            var depth = chain.count - 1
            while levels > 0, depth > 0 {
                levels -= 1
                var right: [MirrorNode]
                if node.hasText {
                    let text = node.children[0]
                    let rest = slice(text.value, offset)
                    text.value = slice(text.value, 0, offset)
                    node.children = text.value.isEmpty ? [] : [text]
                    right = rest.isEmpty ? [] : [MirrorNode(type: DefaultTreeNodeType.text.rawValue, value: rest)]
                } else {
                    let cut = min(offset, node.children.count)
                    right = Array(node.children[cut...])
                    node.children.removeSubrange(cut...)
                }
                let grand = chain[depth - 1]
                guard let index = grand.children.firstIndex(where: { $0 === node }) else {
                    break
                }
                grand.children.insert(MirrorNode(type: node.type, children: right), at: index + 1)
                node = grand
                offset = index + 1
                depth -= 1
            }
        }
    }
    return root.normalized()
}

/// Records the tree-edit OpInfos of the remote changes on a document.
@MainActor
private final class OpRecorder {
    var ops = [TreeEditOpInfo]()

    init(_ doc: TestDoc) {
        doc.subscribe { [weak self] event, _ in
            guard let event = event as? RemoteChangeEvent else { return }
            for op in event.value.operations {
                if let treeEdit = op as? TreeEditOpInfo {
                    self?.ops.append(treeEdit)
                }
            }
        }
    }

    var description: String {
        self.ops.map { "(\($0.fromPath)-\($0.toPath) from:\($0.from) to:\($0.to) values:\($0.value.count) level:\($0.splitLevel))" }.joined(separator: ",")
    }
}

final class TreeSplitOpInfoTests: XCTestCase {
    private struct Case {
        var insert: (JSONTree) throws -> Void
        var split: (JSONTree) throws -> Void
        var splitLevel: Int32 = 1
        /// Set when `split` also inserts content, so `replay` can tell.
        var splitContent = false
        /// Set when the case is a known, unfixed gap; the text says which.
        var fails = false
    }

    private static let insertXY: (JSONTree) throws -> Void = { tree in
        _ = try tree.editByPath([0, 0, 3], [0, 0, 3], JSONTreeTextNode(value: "XY"))
    }

    private static let insertElementXY: (JSONTree) throws -> Void = { tree in
        _ = try tree.editByPath([0, 1], [0, 1], JSONTreeElementNode(type: "t", children: [JSONTreeTextNode(value: "XY")]))
    }

    /// [name, A's actor, B's actor, local changes A makes first]. B syncs its clock to A's on the
    /// seed exchange, so without a head start B's split carries the newer ticket whatever the
    /// actor order; the head start gives A's insert the newer ticket instead.
    private static let orders: [(String, Int, Int, Int)] = [
        ("split ticket newer, inserter actor lower", 1, 2, 0),
        ("split ticket newer, inserter actor higher", 2, 1, 0),
        ("insert ticket newer", 1, 2, 2)
    ]

    @MainActor
    private func run(_ testCase: Case) throws {
        for (order, actorA, actorB, headStart) in Self.orders {
            // given: A inserts at the boundary while B splits there.
            let (docA, docB) = try replicas(actorA, actorB)
            for index in 0 ..< headStart {
                try docA.update { root, _ in root.n = Int32(index) }
            }
            try docA.update { root, _ in try testCase.insert(XCTUnwrap(root.t as? JSONTree)) }
            try docB.update { root, _ in try testCase.split(XCTUnwrap(root.t as? JSONTree)) }
            let mirrorA = try snapshot(docA)
            let mirrorB = try snapshot(docB)
            let recorderA = OpRecorder(docA)
            let recorderB = OpRecorder(docB)

            // when: they exchange.
            try exchange(docA, docB)

            // then: both converge, and replaying each side's remote OpInfos on that side's own
            // model reproduces its tree.
            let xmlA = try toXML(docA)
            XCTAssertEqual(xmlA, try toXML(docB), "replicas diverged (\(order))")
            let finalA = try snapshot(docA).render()
            let finalB = try snapshot(docB).render()
            let replayedB = try replay(mirrorB, recorderB.ops, testCase.splitLevel).render()
            let replayedA = try replay(mirrorA, recorderA.ops, testCase.splitLevel, splitWithContent: testCase.splitContent).render()
            if testCase.fails {
                // Mirrors JS `it.fails`: the gap must still reproduce; if it stops, the gap is
                // closed and this case should become a plain one.
                XCTAssertFalse(replayedB == finalB && replayedA == finalA, "known gap no longer reproduces (\(order)): make this a plain case")
            } else {
                XCTAssertEqual(replayedB, finalB, "B replay of \(recorderB.description) (\(order))")
                XCTAssertEqual(replayedA, finalA, "A replay of \(recorderA.description); A tree \(xmlA) (\(order))")
            }
        }
    }

    @MainActor
    func test_text_split_of_the_inline_element() throws {
        try self.run(Case(insert: Self.insertXY, split: { _ = try $0.editByPath([0, 0, 3], [0, 0, 3], nil, 1) }))
    }

    @MainActor
    func test_enter_text_split_then_paragraph_split() throws {
        try self.run(Case(insert: Self.insertXY, split: { tree in
            _ = try tree.editByPath([0, 0, 3], [0, 0, 3], nil, 1)
            try tree.splitByPath([0, 1])
        }))
    }

    @MainActor
    func test_paragraph_split_with_a_concurrent_element_insert_at_the_boundary() throws {
        try self.run(Case(insert: Self.insertElementXY, split: { try $0.splitByPath([0, 1]) }))
    }

    @MainActor
    func test_text_and_paragraph_split_in_one_edit() throws {
        try self.run(Case(insert: Self.insertXY, split: { _ = try $0.editByPath([0, 0, 3], [0, 0, 3], nil, 2) }, splitLevel: 2))
    }

    /// Known gap, reported but not fixed (mirrors the JS `it.fails`): the split is corrected at
    /// its first level only. Here the paragraph level is the one §7.3 makes keep the concurrent
    /// `<t>XY</t>` on its left, and it keeps it across the `<t></t>` the first level minted, so
    /// the result (`<p><t>abc</t><t>XY</t></p><p><t></t></p>`) is the two children reordered as
    /// well as split. No split position, at any level, describes a reorder, so the change still
    /// reports the first level's boundary and a binding replaying it moves `XY` into the new
    /// paragraph. Expressing it would need the change to carry a move.
    @MainActor
    func test_concurrent_element_insert_at_the_paragraph_boundary_split_level_2_known_gap() throws {
        try self.run(Case(insert: Self.insertElementXY, split: { _ = try $0.editByPath([0, 0, 3], [0, 0, 3], nil, 2) }, splitLevel: 2, fails: true))
    }

    @MainActor
    func test_both_split_the_same_text_boundary() throws {
        try self.run(Case(insert: { _ = try $0.editByPath([0, 0, 3], [0, 0, 3], nil, 1) }, split: { _ = try $0.editByPath([0, 0, 3], [0, 0, 3], nil, 1) }))
    }

    @MainActor
    func test_both_split_the_same_paragraph_boundary() throws {
        try self.run(Case(insert: { try $0.splitByPath([0, 1]) }, split: { try $0.splitByPath([0, 1]) }))
    }

    @MainActor
    func test_split_away_from_the_insert_control() throws {
        try self.run(Case(insert: Self.insertXY, split: { _ = try $0.editByPath([0, 0, 2], [0, 0, 2], nil, 1) }))
    }

    /// The split boundary migrates past the concurrent `XY`, so it no longer coincides with the
    /// position the content was inserted at and the insert is emitted as its own change after the
    /// split one.
    @MainActor
    func test_text_split_that_also_inserts_content_at_the_insert_boundary() throws {
        try self.run(Case(insert: Self.insertXY, split: { _ = try $0.editByPath([0, 0, 3], [0, 0, 3], JSONTreeTextNode(value: "Z"), 1) }, splitContent: true))
    }

    /// Nothing migrates the boundary here, so the split and the insert still share a position and
    /// the insert merges onto the split change.
    @MainActor
    func test_text_split_that_also_inserts_content_away_from_the_insert() throws {
        try self.run(Case(insert: Self.insertXY, split: { _ = try $0.editByPath([0, 0, 2], [0, 0, 2], JSONTreeTextNode(value: "Z"), 1) }, splitContent: true))
    }

    @MainActor
    func test_text_and_paragraph_split_in_one_edit_with_inserted_content() throws {
        try self.run(Case(insert: Self.insertXY, split: { _ = try $0.editByPath([0, 0, 3], [0, 0, 3], JSONTreeTextNode(value: "Z"), 2) }, splitLevel: 2, splitContent: true))
    }
}
