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

// Ports: packages/sdk/test/unit/document/tree_split_order_test.ts
// (yorkie-js-sdk#1375, commit c8928853, "Order concurrent splits of one
// boundary by ticket"; mirror of yorkie-team/yorkie#2030, fixes
// yorkie-js-sdk#1373).
//
// `splitElement` places its product directly after the node it splits, so two
// replicas splitting the same node at the same boundary each apply their own
// split first and the products sit in arrival order:
//
//     <doc><p><span>abcde</span></p></doc>, both: splitByPath([0, 1])
//
//     XML, both:  <doc><p><span>abcde</span></p><p></p><p></p></doc>
//     children:   d1 = [p, split(d2), split(d1)]
//                 d2 = [p, split(d1), split(d2)]
//
// XML and `toXML` match, so the shape divergence surfaces only once a
// position-based operation lands on it: a range delete over the root leaves
// `<p></p>` on one replica for good, and the empty span between two halves of
// a concurrently split span is a different node on each replica, so it shows
// different attributes. `treeShape` renders every node's ID (and tombstone
// state), which XML cannot tell apart, so it is what the convergence checks
// below compare.
//
// All tests run locally without a server: two or three in-process replicas
// exchange their pending changes through the converter, as on the wire, so
// each replica's version vector reflects real causal knowledge.

import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

private let docKey = "tree-split-order"

/// `actorOf` renders a 1-based replica index as a 24-hex-digit actor id.
private func actorOf(_ replicaNumber: Int) -> ActorID {
    String(format: "%024d", replicaNumber)
}

/// `replicas` returns `n` in-process replicas seeded with
/// `<doc><p><span>abcde</span></p></doc>`, already converged.
@MainActor
private func replicas(_ count: Int) throws -> [Document] {
    var docs = [Document]()
    for replicaIndex in 0 ..< count {
        let doc = Document(key: docKey)
        doc.setActor(actorOf(replicaIndex + 1))
        docs.append(doc)
    }

    try docs[0].update { root, _ in
        root.t = JSONTree(initialRoot:
            JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeElementNode(type: "span", children: [JSONTreeTextNode(value: "abcde")])
                ])
            ])
        )
    }
    try exchange(docs, docs.indices.map { $0 == 0 ? [] : [0] })
    return docs
}

/// `exchange` hands every replica's pending changes to the others.
/// `orders[i]` lists, in arrival order, whose changes replica `i` receives, so
/// each replica can see the concurrent changes in a different order. Packs go
/// through the converter's `ChangePack`, as on the wire: handing a `Change`
/// object straight to another document would let the receiver rewrite its
/// version vector in place.
@MainActor
private func exchange(_ docs: [Document], _ orders: [[Int]]) throws {
    let packs = docs.map { $0.createChangePack() }

    for (replicaIndex, doc) in docs.enumerated() {
        for senderIndex in orders[replicaIndex] where senderIndex != replicaIndex {
            try doc.applyChangePack(ChangePack(key: packs[senderIndex].getDocumentKey(),
                                               checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                               isRemoved: false,
                                               changes: packs[senderIndex].getChanges(),
                                               versionVector: VersionVector.initial))
        }
    }
    for (replicaIndex, doc) in docs.enumerated() {
        let changes = packs[replicaIndex].getChanges()
        let lastSeq = changes.last?.id.getClientSeq() ?? 0
        try doc.applyChangePack(ChangePack(key: packs[replicaIndex].getDocumentKey(),
                                           checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
                                           isRemoved: false,
                                           changes: [],
                                           versionVector: VersionVector.initial))
    }
}

/// `treeShape` renders the tree under `t` with every node's ID, tombstones
/// included. XML cannot tell two empty `<p>`s apart; this can, so it is what
/// the convergence checks below compare.
@MainActor
private func treeShape(_ doc: Document) throws -> String {
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

/// `treeOf` fetches a replica's Tree field as a `JSONTree`.
@MainActor
private func treeOf(_ doc: Document) throws -> JSONTree {
    try XCTUnwrap(doc.getRoot().t as? JSONTree)
}

final class TreeSplitOrderTests: XCTestCase {
    // MARK: - Concurrent split at the same boundary

    private typealias SplitCase = (name: String, split: (JSONTree) throws -> Void)

    private var cases: [SplitCase] {
        [
            ("paragraph split", { tree in try tree.splitByPath([0, 1]) }),
            ("span split", { tree in _ = try tree.editByPath([0, 0, 3], [0, 0, 3], nil, 1) }),
            ("span and paragraph split in one edit", { tree in _ = try tree.editByPath([0, 0, 3], [0, 0, 3], nil, 2) }),
            ("span split, then paragraph split in a second edit", { tree in
                _ = try tree.editByPath([0, 0, 3], [0, 0, 3], nil, 1)
                try tree.splitByPath([0, 1])
            }),
            ("the same at the end of the text", { tree in
                _ = try tree.editByPath([0, 0, 5], [0, 0, 5], nil, 1)
                try tree.splitByPath([0, 1])
            })
        ]
    }

    /// Two replicas split the same boundary concurrently, then converge; a
    /// subsequent range delete over the whole document must leave the same
    /// (empty) result on both, not strand a `<p></p>` on one of them.
    @MainActor
    private func assertTwoReplicasThenRangeDelete(_ split: @escaping (JSONTree) throws -> Void) throws {
        let docs = try replicas(2)
        for doc in docs {
            try doc.update { root, _ in
                guard let tree = root.t as? JSONTree else { return }
                try split(tree)
            }
        }
        try exchange(docs, [[1], [0]])

        XCTAssertEqual(try treeOf(docs[1]).toXML(), try treeOf(docs[0]).toXML())
        XCTAssertEqual(try treeShape(docs[1]), try treeShape(docs[0]))

        try docs[0].update { root, _ in
            guard let tree = root.t as? JSONTree else { return }
            let rootNode = try tree.getRootTreeNode()
            let count = (rootNode as? JSONTreeElementNode)?.children.count ?? 0
            _ = try tree.editByPath([0], [count])
        }
        try exchange(docs, [[1], [0]])

        XCTAssertEqual(try treeOf(docs[0]).toXML(), "<doc></doc>")
        XCTAssertEqual(try treeOf(docs[1]).toXML(), "<doc></doc>")
    }

    /// Three replicas split the same boundary concurrently, each seeing the
    /// others' changes in a different arrival order; all three must end up
    /// with the identical node shape.
    @MainActor
    private func assertThreeReplicasEachArrivalOrder(_ split: @escaping (JSONTree) throws -> Void) throws {
        let docs = try replicas(3)
        for doc in docs {
            try doc.update { root, _ in
                guard let tree = root.t as? JSONTree else { return }
                try split(tree)
            }
        }
        try exchange(docs, [[2, 1], [0, 2], [1, 0]])

        let shape = try treeShape(docs[0])
        XCTAssertEqual(try treeShape(docs[1]), shape)
        XCTAssertEqual(try treeShape(docs[2]), shape)
        XCTAssertTrue(try treeOf(docs[0]).toXML().contains("abc"))
    }

    @MainActor
    func test_paragraph_split_two_replicas_then_range_delete() throws {
        try self.assertTwoReplicasThenRangeDelete(self.cases[0].split)
    }

    @MainActor
    func test_paragraph_split_three_replicas_each_arrival_order() throws {
        try self.assertThreeReplicasEachArrivalOrder(self.cases[0].split)
    }

    @MainActor
    func test_span_split_two_replicas_then_range_delete() throws {
        try self.assertTwoReplicasThenRangeDelete(self.cases[1].split)
    }

    @MainActor
    func test_span_split_three_replicas_each_arrival_order() throws {
        try self.assertThreeReplicasEachArrivalOrder(self.cases[1].split)
    }

    @MainActor
    func test_span_and_paragraph_split_in_one_edit_two_replicas_then_range_delete() throws {
        try self.assertTwoReplicasThenRangeDelete(self.cases[2].split)
    }

    @MainActor
    func test_span_and_paragraph_split_in_one_edit_three_replicas_each_arrival_order() throws {
        try self.assertThreeReplicasEachArrivalOrder(self.cases[2].split)
    }

    @MainActor
    func test_span_split_then_paragraph_split_in_a_second_edit_two_replicas_then_range_delete() throws {
        try self.assertTwoReplicasThenRangeDelete(self.cases[3].split)
    }

    @MainActor
    func test_span_split_then_paragraph_split_in_a_second_edit_three_replicas_each_arrival_order() throws {
        try self.assertThreeReplicasEachArrivalOrder(self.cases[3].split)
    }

    @MainActor
    func test_the_same_at_the_end_of_the_text_two_replicas_then_range_delete() throws {
        try self.assertTwoReplicasThenRangeDelete(self.cases[4].split)
    }

    @MainActor
    func test_the_same_at_the_end_of_the_text_three_replicas_each_arrival_order() throws {
        try self.assertThreeReplicasEachArrivalOrder(self.cases[4].split)
    }

    /// The empty node between two halves of a concurrently split span must
    /// carry the same attributes on every replica, not just the same tag.
    @MainActor
    func test_the_empty_node_between_two_halves_carries_the_same_attributes_everywhere() throws {
        let docs = try replicas(2)
        try docs[0].update { root, _ in
            guard let tree = root.t as? JSONTree else { return }
            _ = try tree.editByPath([0, 0, 3], [0, 0, 3], nil, 1)
            try tree.styleByPath([0, 0], ["bold": "true"])
        }
        try docs[1].update { root, _ in
            guard let tree = root.t as? JSONTree else { return }
            _ = try tree.editByPath([0, 0, 3], [0, 0, 3], nil, 1)
            try tree.styleByPath([0, 1], ["italic": "true"])
        }
        try exchange(docs, [[1], [0]])

        XCTAssertEqual(try treeOf(docs[1]).toXML(), try treeOf(docs[0]).toXML())
    }

    // MARK: - Concurrent split after an older split of the same boundary

    /// When one actor has already split the same boundary and is causally
    /// known to the other, a second concurrent split of that boundary must
    /// still converge. The other two shapes the upstream commit lists here
    /// (the older actor then splitting the *paragraph*, in one edit or two)
    /// are documented upstream as a known, still-open divergence (not fixed
    /// by this change) and are intentionally not asserted here.
    @MainActor
    private func assertOlderActorSplitsTheSpanAgain(olderReplica older: Int) throws {
        let split: (JSONTree) throws -> Void = { tree in _ = try tree.editByPath([0, 0, 3], [0, 0, 3], nil, 1) }

        func applySplit(_ doc: Document) throws {
            try doc.update { root, _ in
                guard let tree = root.t as? JSONTree else { return }
                try split(tree)
            }
        }

        let docs = try replicas(2)
        try applySplit(docs[older])
        try exchange(docs, [[1], [0]])

        try applySplit(docs[older])
        try applySplit(docs[1 - older])
        try exchange(docs, [[1], [0]])

        XCTAssertEqual(try treeOf(docs[1]).toXML(), try treeOf(docs[0]).toXML())
        XCTAssertEqual(try treeShape(docs[1]), try treeShape(docs[0]))
    }

    @MainActor
    func test_older_actor_splits_the_span_again_older_split_by_replica_0() throws {
        try self.assertOlderActorSplitsTheSpanAgain(olderReplica: 0)
    }

    @MainActor
    func test_older_actor_splits_the_span_again_older_split_by_replica_1() throws {
        try self.assertOlderActorSplitsTheSpanAgain(olderReplica: 1)
    }
}
