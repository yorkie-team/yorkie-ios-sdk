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

// Ports: packages/sdk/test/unit/document/tree_remove_style_split_test.ts
// (yorkie-js-sdk#1375, commit c8928853, "Order concurrent splits of one
// boundary by ticket"; mirror of yorkie-team/yorkie#2033).
//
// `removeStyle` now runs the §7.5 advance-past-unknown-split-siblings pass on
// both range anchors, the same way `style` always has. Before this, a
// `removeStyle` whose range was resolved before a concurrent split of the
// same boundary could land on the wrong side of it and diverge from `style`'s
// equivalent case.

import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

private let docKey = "tree-remove-style-split"

private func actorOf(_ replicaNumber: Int) -> ActorID {
    String(format: "%024d", replicaNumber)
}

/// `replicas` returns two in-process replicas seeded with
/// `<doc><p><span bold="true">abcde</span></p></doc>`, already converged.
@MainActor
private func replicas() throws -> [Document] {
    var docs = [Document]()
    for replicaIndex in 0 ..< 2 {
        let doc = Document(key: docKey)
        doc.setActor(actorOf(replicaIndex + 1))
        docs.append(doc)
    }

    try docs[0].update { root, _ in
        root.t = JSONTree(initialRoot:
            JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeElementNode(type: "span",
                                        children: [JSONTreeTextNode(value: "abcde")],
                                        attributes: ["bold": "true"])
                ])
            ])
        )
    }
    try exchange(docs, [[], [0]])
    return docs
}

/// `exchange` hands every replica's pending changes to the others, in the
/// arrival order `orders[i]` lists for replica `i`.
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

@MainActor
private func treeOf(_ doc: Document) throws -> JSONTree {
    try XCTUnwrap(doc.getRoot().t as? JSONTree)
}

final class TreeRemoveStyleSplitTests: XCTestCase {
    /// `removeStyle` over a concurrently split boundary converges whichever
    /// side arrives first, regardless of which replica applies the split and
    /// which applies the `removeStyle`.
    @MainActor
    func test_converges_whichever_side_arrives_first() throws {
        // given
        let docs = try replicas()

        // when
        try docs[0].update { root, _ in
            guard let tree = root.t as? JSONTree else { return }
            _ = try tree.editByPath([0, 0, 3], [0, 0, 3], nil, 1)
        }
        try docs[1].update { root, _ in
            guard let tree = root.t as? JSONTree else { return }
            try tree.removeStyleByPath([0, 0], [0, 1], ["bold"])
        }
        try exchange(docs, [[1], [0]])

        // then
        XCTAssertEqual(try treeOf(docs[1]).toXML(), try treeOf(docs[0]).toXML())
    }

    /// `removeStyle` still converges when both replicas split and one of them
    /// also removes the style, all within the same local update.
    @MainActor
    func test_converges_when_both_replicas_split_and_one_removes_the_style() throws {
        // given
        let docs = try replicas()

        // when
        try docs[0].update { root, _ in
            guard let tree = root.t as? JSONTree else { return }
            _ = try tree.editByPath([0, 0, 3], [0, 0, 3], nil, 1)
            try tree.removeStyleByPath([0, 0], [0, 1], ["bold"])
        }
        try docs[1].update { root, _ in
            guard let tree = root.t as? JSONTree else { return }
            _ = try tree.editByPath([0, 0, 3], [0, 0, 3], nil, 1)
        }
        try exchange(docs, [[1], [0]])

        // then
        XCTAssertEqual(try treeOf(docs[1]).toXML(), try treeOf(docs[0]).toXML())
    }
}
