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

// Ports: packages/sdk/test/unit/document/crdt/root_internal_gc_pair_test.ts
// (yorkie-js-sdk#1405, "Port three GC correctness fixes from the Go SDK",
// mirrors Go `96bcb779`/`registerInternalGCPairs`).
//
// `CRDTRoot.registerElement` used to book the tombstones a Text/Tree/Array
// carries INSIDE itself (removed tree nodes, removed text pieces, removed
// attributes, dead array positions) only once, in `CRDTRoot.init`'s
// snapshot-load scan. Any other route that brings such an element into the
// document -- a remote Set/Add/ArraySet payload, or an undo re-setting a
// `deepcopy` of a removed container -- left those internal tombstones
// unbooked: invisible to every later edit, charged to nothing, and
// collectable by nothing. See ``CRDTRoot/registerInternalGCPairs(_:)``.

import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

private let actorA1: ActorID = "000000000000000000000001"
private let actorA2: ActorID = "000000000000000000000002"

/// `deliver` pushes the sender's pending changes into the receiver, then acks
/// them back to the sender so the next call does not re-send them. The
/// receiver applies with `OpSource.remote`, which is also how the server
/// replays a change log to build a snapshot.
@MainActor
private func deliver(_ from: Document, to: Document) throws {
    let pack = from.createChangePack()
    let changes = pack.getChanges()

    try to.applyChangePack(ChangePack(key: pack.getDocumentKey(),
                                      checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                      isRemoved: false,
                                      changes: changes,
                                      versionVector: VersionVector.initial))

    let lastSeq = changes.last?.id.getClientSeq() ?? 0
    try from.applyChangePack(ChangePack(key: pack.getDocumentKey(),
                                        checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
                                        isRemoved: false,
                                        changes: [],
                                        versionVector: VersionVector.initial))
}

/// `tombstonesIn` counts the removed nodes still linked into the `t` tree.
@MainActor
private func tombstonesIn(_ doc: Document) -> Int {
    guard let tree = doc.getRootObject().get(key: "t") as? CRDTTree else {
        return 0
    }

    func walk(_ node: CRDTTreeNode) -> Int {
        let mine = node.isRemoved ? 1 : 0
        if node.isText {
            return mine
        }
        return mine + node.innerChildren.reduce(0) { $0 + walk($1) }
    }

    return walk(tree.root)
}

/// `assertMatchesRebuild` asserts the running `docSize` and garbage count
/// equal what a root rebuilt from the same content computes.
@MainActor
private func assertMatchesRebuild(_ doc: Document, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
    let copy = try XCTUnwrap(doc.getRootObject().deepcopy() as? CRDTObject, file: file, line: line)
    let rebuilt = CRDTRoot(rootObject: copy)

    XCTAssertEqual(doc.getDocSize(), rebuilt.getDocSize(), "\(message): docSize", file: file, line: line)
    XCTAssertEqual(doc.getGarbageLength(), rebuilt.garbageLength, "\(message): garbage", file: file, line: line)
}

final class RootInternalGCPairTests: XCTestCase {
    /// `ticket` builds a `TimeTicket` for `actorA1` with the given lamport, for
    /// hand-building a tree without a `ChangeContext`.
    private func ticket(_ lamport: Int64) -> TimeTicket {
        TimeTicket(lamport: lamport, delimiter: 0, actorID: actorA1)
    }

    // Port of Go TestRegisterElementBooksInternalTombstones (yorkie#2033).
    func test_books_a_tombstone_inside_the_registered_element() {
        // given
        let root = CRDTRoot()

        let treeRoot = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.ticket(1), offset: 0), type: "r")
        let para = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.ticket(2), offset: 0), type: "p")
        treeRoot.innerChildren.append(para)
        para.parent = treeRoot
        let text = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.ticket(3), offset: 0), type: "text", value: "hello")
        para.innerChildren.append(text)
        text.parent = para

        // The payload was captured while this node was already a tombstone.
        text.removedAt = self.ticket(4)

        let treeCreatedAt = self.ticket(5)
        let tree = CRDTTree(root: treeRoot, createdAt: treeCreatedAt)
        root.object.set(key: "tree", value: tree, executedAt: treeCreatedAt)

        // when
        let before = root.garbageLength
        root.registerElement(tree, parent: root.object)

        // then
        XCTAssertEqual(root.garbageLength, before + 1, "a tombstone inside the registered element has to be collectable")
        let gc = root.getDocSize().gc
        XCTAssertNotEqual(gc.data + gc.meta, 0, "its bytes belong to gc")

        XCTAssertEqual(root.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1])), 1)
        XCTAssertEqual(root.getDocSize().gc, DataSize(data: 0, meta: 0))
    }

    // Port of Go TestRegisterElementSkipsTombstonedTreeRoot (yorkie#2033).
    func test_never_books_the_tree_root() {
        // given
        let root = CRDTRoot()

        let treeRoot = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.ticket(1), offset: 0), type: "r")
        let para = CRDTTreeNode(id: CRDTTreeNodeID(createdAt: self.ticket(2), offset: 0), type: "p")
        treeRoot.innerChildren.append(para)
        para.parent = treeRoot

        // A crafted payload marks every node removed, the root included.
        treeRoot.removedAt = self.ticket(3)
        para.removedAt = self.ticket(4)

        let treeCreatedAt = self.ticket(5)
        let tree = CRDTTree(root: treeRoot, createdAt: treeCreatedAt)
        root.object.set(key: "tree", value: tree, executedAt: treeCreatedAt)

        // when
        let before = root.garbageLength
        root.registerElement(tree, parent: root.object)

        // then
        XCTAssertEqual(root.garbageLength, before + 1, "only the parented tombstone is booked, never the root")
        XCTAssertEqual(root.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1])), 1)
    }

    @MainActor
    func test_books_the_tombstones_an_undone_container_removal_brings_back() throws {
        // given
        let doc = Document(key: "test-doc")
        doc.setActor(actorA1)

        try doc.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abc")])
            ]))
        }
        try doc.update { root, _ in
            _ = try (root.t as? JSONTree)?.edit(2, 3)
        }
        try doc.update { root, _ in
            root.remove(key: "t")
        }

        // when
        try doc.undo()

        // then
        XCTAssertEqual(try XCTUnwrap(doc.getRoot().t as? JSONTree).toXML(), "<r><p>ac</p></r>")
        // No rebuild check here: the orphaned tombstone tree still holds its
        // own pair for "b" until collection, as it does in Go --
        // `unregisterRemovedElementPair` releases element charges but not the
        // internal pairs (see ``CRDTRoot``'s doc comment on `GCChargeKey`).

        doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1]))
        XCTAssertEqual(tombstonesIn(doc), 0, "the restored tombstone is collected")
        XCTAssertEqual(doc.getGarbageLength(), 0)
        try assertMatchesRebuild(doc, "after gc")
    }

    @MainActor
    func test_books_them_on_a_replica_that_decodes_the_same_set() throws {
        // given
        let d1 = Document(key: "test-doc")
        let d2 = Document(key: "test-doc")
        d1.setActor(actorA1)
        d2.setActor(actorA2)

        try d1.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "r", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "abc")])
            ]))
        }
        try d1.update { root, _ in
            _ = try (root.t as? JSONTree)?.edit(2, 3)
        }
        try d1.update { root, _ in
            root.remove(key: "t")
        }
        try deliver(d1, to: d2)

        // when -- the undo carries a Set whose tree still holds the
        // tombstoned "b".
        try d1.undo()
        try deliver(d1, to: d2)

        // then
        XCTAssertEqual(try XCTUnwrap(d2.getRoot().t as? JSONTree).toXML(), "<r><p>ac</p></r>")

        d2.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1, actorA2]))
        XCTAssertEqual(tombstonesIn(d2), 0, "the decoded tombstone is collected")
        XCTAssertEqual(d2.getGarbageLength(), 0)
        try assertMatchesRebuild(d2, "remote after gc")
    }
}
