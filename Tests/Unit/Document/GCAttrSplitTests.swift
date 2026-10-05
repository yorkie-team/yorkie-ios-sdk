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

/// Ports: `packages/sdk/test/unit/document/gc_attr_split_test.ts` from
/// yorkie-js-sdk PR #1363 "Register the attribute tombstones a tree split
/// copies" (commit 99dbec9d).
///
/// `CRDTTreeNode.splitElement` deep-copies the node's RHT, tombstones
/// included -- it has to, or the two halves of what was one node would
/// resolve a concurrent style differently and never reconverge.
/// `RHT.deepcopy` preserves `updatedAt` and `key`, which are exactly what
/// `RHTNode.toIDString` is made of, so the copy was indistinguishable by id
/// from the original. Registering it was missing, and the shared id made the
/// two collide in the GC map.

private let actorA1: ActorID = "000000000000000000000001"
private let actorA2: ActorID = "000000000000000000000002"

/// Exchanges pending local changes between two in-process documents,
/// mimicking a server round-trip without going through real serialization.
/// Same shape as the helper in `GCSplitLeakTests.swift`.
@MainActor
private func crossSync(_ d1: Document, _ d2: Document) throws {
    let p1 = d1.createChangePack()
    let p2 = d2.createChangePack()

    try d2.applyChangePack(ChangePack(key: p1.getDocumentKey(),
                                      checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                      isRemoved: false,
                                      changes: p1.getChanges(),
                                      versionVector: VersionVector.initial))
    try d1.applyChangePack(ChangePack(key: p2.getDocumentKey(),
                                      checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                      isRemoved: false,
                                      changes: p2.getChanges(),
                                      versionVector: VersionVector.initial))

    func ack(_ pack: ChangePack) -> ChangePack {
        let changes = pack.getChanges()
        let lastSeq = changes.last?.id.getClientSeq() ?? 0
        return ChangePack(key: pack.getDocumentKey(),
                          checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
                          isRemoved: false,
                          changes: [],
                          versionVector: VersionVector.initial)
    }
    try d1.applyChangePack(ack(p1))
    try d2.applyChangePack(ack(p2))
}

/// Checks the invariant the whole of docSize rests on: a document's garbage
/// is a function of its content, so a root rebuilt from that content reports
/// the same size and the same count. A rebuilt root is what every client
/// joining an existing document holds.
@MainActor
private func assertRebuildsSame(_ doc: Document, _ msg: String) throws {
    guard let rebuiltObject = doc.getRootObject().deepcopy() as? CRDTObject else {
        XCTFail("\(msg): deepcopy did not produce a CRDTObject")
        return
    }
    let rebuilt = CRDTRoot(rootObject: rebuiltObject)
    XCTAssertEqual(rebuilt.getDocSize().gc, doc.getDocSize().gc, "\(msg): gc")
    XCTAssertEqual(rebuilt.garbageLength, doc.getGarbageLength(), "\(msg): count")
}

/// Builds a document whose tree has a `<span>` that was styled with `color:
/// red` and then had that style removed -- one attribute tombstone, no split
/// yet.
@MainActor
private func styledAndRemoved() throws -> Document {
    let doc = Document(key: "test-doc")
    doc.setActor(actorA1)

    try doc.update { root, _ in
        root.t = JSONTree(initialRoot: JSONTreeElementNode(
            type: "doc",
            children: [
                JSONTreeElementNode(type: "p", children: [
                    JSONTreeElementNode(type: "span", children: [
                        JSONTreeTextNode(value: "abcdefghij")
                    ])
                ])
            ]
        ))
    }
    try doc.update { root, _ in
        try (root.t as? JSONTree)?.styleByPath([0, 0], [0, 1], ["color": "red"])
    }
    try doc.update { root, _ in
        try (root.t as? JSONTree)?.removeStyleByPath([0, 0], [0, 1], ["color"])
    }

    return doc
}

final class GCAttrSplitTests: XCTestCase {
    @MainActor
    func test_counts_and_collects_the_tombstone_a_tree_split_copied() throws {
        // given
        let doc = try styledAndRemoved()
        XCTAssertEqual(doc.getGarbageLength(), 1)
        try assertRebuildsSame(doc, "before the split")

        // when
        try doc.update { root, _ in
            _ = try (root.t as? JSONTree)?.editByPath([0, 0, 1], [0, 0, 1], nil, 1)
        }

        // then
        XCTAssertEqual((doc.getRoot().t as? JSONTree)?.toXML(), "<doc><p><span>a</span><span>bcdefghij</span></p></doc>")
        XCTAssertEqual(doc.getGarbageLength(), 2)
        try assertRebuildsSame(doc, "after the split")

        XCTAssertEqual(doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1])), 2)
        XCTAssertEqual(doc.getGarbageLength(), 0)
        XCTAssertEqual(doc.getDocSize().gc, DataSize(data: 0, meta: 0))
        try assertRebuildsSame(doc, "after collecting")
    }

    @MainActor
    func test_counts_a_tombstone_the_second_split_copied_from_the_first_copy() throws {
        // given
        let doc = try styledAndRemoved()

        // when
        try doc.update { root, _ in
            _ = try (root.t as? JSONTree)?.editByPath([0, 0, 1], [0, 0, 1], nil, 1)
        }
        try doc.update { root, _ in
            _ = try (root.t as? JSONTree)?.editByPath([0, 1, 4], [0, 1, 4], nil, 1)
        }

        // then
        XCTAssertEqual(doc.getGarbageLength(), 3)
        try assertRebuildsSame(doc, "after splitting a split")

        XCTAssertEqual(doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1])), 3)
        XCTAssertEqual(doc.getDocSize().gc, DataSize(data: 0, meta: 0))
    }

    @MainActor
    func test_drains_when_a_later_style_revives_the_key_on_both_halves() throws {
        // given
        let doc = try styledAndRemoved()
        try doc.update { root, _ in
            _ = try (root.t as? JSONTree)?.editByPath([0, 0, 1], [0, 0, 1], nil, 1)
        }
        XCTAssertEqual(doc.getGarbageLength(), 2)

        // when — re-setting the key supersedes both tombstones. Each un-registers
        // against its own parent; keyed on the child alone, the second
        // registration re-added the entry the first removed.
        try doc.update { root, _ in
            try (root.t as? JSONTree)?.styleByPath([0, 0], [0, 2], ["color": "blue"])
        }

        // then
        XCTAssertEqual(doc.getGarbageLength(), 0)
    }

    @MainActor
    func test_purges_the_same_tree_tombstones_on_both_replicas() throws {
        // given
        let d1 = Document(key: "test-doc")
        let d2 = Document(key: "test-doc")
        d1.setActor(actorA1)
        d2.setActor(actorA2)

        try d1.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(
                type: "doc",
                children: [
                    JSONTreeElementNode(type: "p", children: [
                        JSONTreeElementNode(type: "span", children: [
                            JSONTreeTextNode(value: "abcdefghij")
                        ])
                    ])
                ]
            ))
        }
        try d1.update { root, _ in
            try (root.t as? JSONTree)?.styleByPath([0, 0], [0, 1], ["color": "red"])
        }
        try d1.update { root, _ in
            try (root.t as? JSONTree)?.removeStyleByPath([0, 0], [0, 1], ["color"])
        }
        try crossSync(d1, d2)

        // when
        try d1.update { root, _ in
            _ = try (root.t as? JSONTree)?.editByPath([0, 0, 1], [0, 0, 1], nil, 1)
        }
        try crossSync(d1, d2)

        // then
        XCTAssertEqual((d2.getRoot().t as? JSONTree)?.toXML(), (d1.getRoot().t as? JSONTree)?.toXML())
        // Both replicas leaked the copy before the fix, so agreeing with each
        // other is not enough -- name the count they must agree on.
        XCTAssertEqual(d1.getGarbageLength(), 2)
        XCTAssertEqual(d2.getGarbageLength(), 2)
        XCTAssertEqual(d2.getDocSize(), d1.getDocSize())

        let purged1 = d1.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1, actorA2]))
        let purged2 = d2.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1, actorA2]))
        XCTAssertEqual(purged2, purged1)
        XCTAssertEqual(d1.getDocSize().gc, DataSize(data: 0, meta: 0))
        XCTAssertEqual(d2.getDocSize().gc, DataSize(data: 0, meta: 0))
    }
}
