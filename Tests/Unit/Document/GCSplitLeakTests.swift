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

/// Ports: `packages/sdk/test/unit/document/gc_split_leak_test.ts` from
/// yorkie-js-sdk v0.7.13 (yorkie-js-sdk#1292 "Register GC pairs for pieces
/// split off tombstoned nodes").
///
/// A piece split off an already-tombstoned node inherits `removedAt` without
/// passing through `remove()`, so before the fix it missed GC pair
/// registration and stayed in the tree/text forever — an asymmetric,
/// replica-dependent leak.

private let actorA1: ActorID = "000000000000000000000001"
private let actorA2: ActorID = "000000000000000000000002"

/// Exchanges pending local changes between two in-process documents,
/// mimicking a server round-trip without going through real serialization.
/// A neutral checkpoint (clientSeq 0) on delivery keeps the receiver's own
/// pending local changes intact, and `VersionVector.initial` keeps GC out of
/// the exchange (GC interaction is exercised explicitly by each test).
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

    // Self-ack: drop exactly the delivered changes from each sender's local
    // queue so the next crossSync doesn't re-send (and re-apply) them.
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

/// Builds two replicas where d1 deletes "el" (splitting the text node) and
/// d2 concurrently deletes the whole `<p>` (tombstoning it unsplit). When
/// d1's delete arrives at d2, it splits d2's tombstoned text node, creating
/// pieces that are born already-removed.
@MainActor
private func buildTombstoneSplitReplicas() throws -> (Document, Document) {
    let d1 = Document(key: "test-doc")
    let d2 = Document(key: "test-doc")
    d1.setActor(actorA1)
    d2.setActor(actorA2)

    try d1.update { root, _ in
        root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [
            JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "hello")])
        ]))
    }
    try crossSync(d1, d2)

    try d1.update { root, _ in _ = try (root.t as? JSONTree)?.edit(2, 4) }
    try d2.update { root, _ in _ = try (root.t as? JSONTree)?.edit(0, 7) }
    try crossSync(d1, d2)

    return (d1, d2)
}

/// `buildTextReplicas` creates two in-process replicas that share a Text
/// field seeded with "abcdef" and already converged.
@MainActor
private func buildTextReplicas() throws -> (Document, Document) {
    let d1 = Document(key: "test-doc")
    let d2 = Document(key: "test-doc")
    d1.setActor(actorA1)
    d2.setActor(actorA2)

    try d1.update { root, _ in
        root.k = JSONText()
        _ = (root.k as? JSONText)?.edit(0, 0, "abcdef")
    }
    try crossSync(d1, d2)

    return (d1, d2)
}

/// Counts tombstoned nodes still physically present in the text's
/// `RGATreeSplit`. After a full-vector garbage collection this must be zero;
/// any remainder is a node that was never registered (or was
/// toggle-unregistered) for GC.
@MainActor
private func countTextTombstones(_ doc: Document) -> Int {
    guard let text = doc.getRootObject().get(key: "k") as? CRDTText else {
        return -1
    }

    var count = 0
    for node in text.rgaTreeSplit where node.isRemoved {
        count += 1
    }
    return count
}

// MARK: - GC tombstone-split leak (Tree)

final class GCTreeSplitLeakTests: XCTestCase {
    @MainActor
    func test_purges_the_same_nodes_on_both_replicas_when_a_tombstone_is_split_remotely() throws {
        // given — two replicas that converge to an identical, fully-tombstoned tree.
        let (d1, d2) = try buildTombstoneSplitReplicas()

        let xml1 = (d1.getRoot().t as? JSONTree)?.toXML()
        let xml2 = (d2.getRoot().t as? JSONTree)?.toXML()
        XCTAssertEqual(xml1, "<doc></doc>")
        XCTAssertEqual(xml2, xml1)

        // when — both replicas run a full garbage collection against the same
        // fully-synced version vector.
        let purged1 = d1.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1, actorA2]))
        let purged2 = d2.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1, actorA2]))

        // then — same full vector, same logical tombstones, so purge counts must
        // match. Before the fix, the replica whose tombstone was split by the
        // remote delete leaked the born-dead pieces (d1=4, d2=2).
        XCTAssertEqual(purged1, purged2, "asymmetric purge for identical state: d1=\(purged1) d2=\(purged2)")
        XCTAssertEqual(d1.getGarbageLength(), 0)
        XCTAssertEqual(d2.getGarbageLength(), 0)

        // docSize must also stay symmetric: born-dead pieces were never live, so
        // registering them must not move sizes out of docSize.live, and a full GC
        // must drain docSize.gc to zero on both replicas.
        XCTAssertEqual(d2.getDocSize(), d1.getDocSize())
        XCTAssertEqual(d1.getDocSize().gc, DataSize(data: 0, meta: 0))
    }

    @MainActor
    func test_registers_gc_pairs_for_tree_tombstones_after_snapshot_round_trip() throws {
        // given — d2's tree carries born-dead pieces split off a tombstone.
        let (_, d2) = try buildTombstoneSplitReplicas()

        // when — snapshot-encode d2's root (tombstones included) and rebuild a
        // root from it, as a client receiving a snapshot would.
        let bytes = try Converter.objectToBytes(obj: d2.getRootObject())
        let rebuiltObject = try Converter.bytesToObject(bytes: bytes)
        let rebuilt = CRDTRoot(rootObject: rebuiltObject)

        // then — the rebuilt root must see and purge the same garbage as the live
        // one, including the pieces split off the tombstoned text node. Before
        // the fix, `CRDTTree.getGCPairs` traversed only visible nodes, so a
        // snapshot-loaded root registered no tree tombstones at all.
        XCTAssertGreaterThan(d2.getGarbageLength(), 0)
        XCTAssertEqual(rebuilt.garbageLength, d2.getGarbageLength())

        let purgedLive = d2.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1, actorA2]))
        let purgedRebuilt = rebuilt.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1, actorA2]))
        XCTAssertEqual(purgedRebuilt, purgedLive)
        XCTAssertEqual(rebuilt.garbageLength, 0)

        // The rebuilt root counts tombstones straight into docSize.gc (they were
        // never in its docSize.live), so a full GC must drain gc to zero without
        // pushing live negative.
        XCTAssertEqual(rebuilt.getDocSize().gc, DataSize(data: 0, meta: 0))
        XCTAssertEqual(rebuilt.getDocSize().live, d2.getDocSize().live)
    }

    /// Shared body for the two read-path range-conversion regression cases.
    /// Each conversion method must independently drain the pending GC pairs.
    /// Every case builds its own freshly tombstoned tree — the first
    /// conversion splits the tombstone, so sharing one tree would leave a
    /// second conversion with nothing to split.
    @MainActor
    private func assertReadPathConversionRegistersGCPairs(
        convert: (JSONTree, TreePosStructRange) throws -> Void
    ) throws {
        // given — d1 has a stored selection into "hello", then a peer tombstones
        // the whole `<p>` before the selection is resolved.
        let d1 = Document(key: "test-doc")
        let d2 = Document(key: "test-doc")
        d1.setActor(actorA1)
        d2.setActor(actorA2)

        try d1.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "hello")])
            ]))
        }
        try crossSync(d1, d2)

        // Capture a selection that points into the middle of "hello", as a
        // stored cursor/selection would.
        guard let tree = d1.getRoot().t as? JSONTree else {
            return XCTFail("tree not initialized")
        }
        let selection = try tree.indexRangeToPosRange((2, 4))

        // A peer deletes the whole <p>, tombstoning "hello" on d1.
        try d2.update { root, _ in _ = try (root.t as? JSONTree)?.edit(0, 7) }
        try crossSync(d1, d2)

        // when — resolving the stored selection now lands inside the tombstoned
        // text and splits it, a read path that emits no operation.
        guard let treeAfterSync = d1.getRoot().t as? JSONTree else {
            return XCTFail("tree not initialized")
        }
        try convert(treeAfterSync, selection)

        _ = d1.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1, actorA2]))

        // then — after GC the clone tree (mutated by the read-path split) and the
        // document root must hold the same physical nodes. A born-removed piece
        // that never registered a GC pair would linger in the clone's node map,
        // making it larger. Before the fix the clone kept the leaked piece(s).
        let cloneTree = d1.getClone()?.root.object.get(key: "t") as? CRDTTree
        let rootTree = d1.getRootObject().get(key: "t") as? CRDTTree
        XCTAssertNotNil(cloneTree)
        XCTAssertNotNil(rootTree)
        XCTAssertEqual(cloneTree?.nodeSize, rootTree?.nodeSize)
        XCTAssertEqual(d1.getGarbageLengthFromClone(), 0)
    }

    @MainActor
    func test_registers_gc_pairs_split_during_read_path_range_conversion_via_posRangeToIndexRange() throws {
        try self.assertReadPathConversionRegistersGCPairs { tree, range in
            _ = try tree.posRangeToIndexRange(range)
        }
    }

    @MainActor
    func test_registers_gc_pairs_split_during_read_path_range_conversion_via_posRangeToPathRange() throws {
        try self.assertReadPathConversionRegistersGCPairs { tree, range in
            _ = try tree.posRangeToPathRange(range)
        }
    }
}

// MARK: - GC tombstone-split leak (Text)

// Same class of leak in the Text CRDT: `RGATreeSplitNode.split()` copies
// `removedAt` into the new piece, so pieces split off an already-tombstoned
// text node are born removed without passing through `remove()` and miss GC
// pair registration. Additionally, a concurrent delete that overwrites an
// existing tombstone (LWW) used to re-push a GC pair for it, and
// `CRDTRoot.registerGCPair`'s toggle semantics then deleted the existing
// registration.
final class GCTextSplitLeakTests: XCTestCase {
    @MainActor
    func test_purges_pieces_split_off_a_tombstoned_text_node() throws {
        // given — d1 tombstones the whole node; d2 concurrently deletes a middle
        // slice. When d2's delete arrives at d1, it splits d1's tombstone into
        // three pieces; the piece after the deleted range is born dead.
        let (d1, d2) = try buildTextReplicas()

        try d1.update { root, _ in _ = (root.k as? JSONText)?.edit(0, 6, "") }
        try d2.update { root, _ in _ = (root.k as? JSONText)?.edit(2, 4, "") }
        try crossSync(d1, d2)

        XCTAssertEqual((d1.getRootObject().get(key: "k") as? CRDTText)?.toString, "")
        XCTAssertEqual((d2.getRootObject().get(key: "k") as? CRDTText)?.toString, "")

        // when
        let purged1 = d1.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1, actorA2]))
        let purged2 = d2.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1, actorA2]))

        // then
        XCTAssertEqual(purged1, purged2, "asymmetric purge for identical state: d1=\(purged1) d2=\(purged2)")
        XCTAssertEqual(countTextTombstones(d1), 0)
        XCTAssertEqual(countTextTombstones(d2), 0)
        XCTAssertEqual(d1.getGarbageLength(), 0)
        XCTAssertEqual(d2.getGarbageLength(), 0)

        // Same docSize invariants as the tree case.
        XCTAssertEqual(d2.getDocSize(), d1.getDocSize())
        XCTAssertEqual(d1.getDocSize().gc, DataSize(data: 0, meta: 0))
    }

    @MainActor
    func test_keeps_gc_registration_when_a_newer_concurrent_delete_overwrites_a_tombstone() throws {
        // given — bump d1's lamport so its whole-range delete is newer than d2's
        // slice delete. When d1's delete arrives at d2, canRemove() allows the
        // LWW overwrite of d2's own tombstone; re-pushing a GC pair for that node
        // used to toggle-unregister it.
        let (d1, d2) = try buildTextReplicas()

        try d1.update { root, _ in _ = (root.k as? JSONText)?.edit(6, 6, "!") }
        try d1.update { root, _ in _ = (root.k as? JSONText)?.edit(0, 7, "") }
        try d2.update { root, _ in _ = (root.k as? JSONText)?.edit(2, 4, "") }
        try crossSync(d1, d2)

        XCTAssertEqual((d1.getRootObject().get(key: "k") as? CRDTText)?.toString, "")
        XCTAssertEqual((d2.getRootObject().get(key: "k") as? CRDTText)?.toString, "")

        // when
        let purged1 = d1.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1, actorA2]))
        let purged2 = d2.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1, actorA2]))

        // then
        XCTAssertEqual(purged1, purged2, "asymmetric purge for identical state: d1=\(purged1) d2=\(purged2)")
        XCTAssertEqual(countTextTombstones(d1), 0)
        XCTAssertEqual(countTextTombstones(d2), 0)
        XCTAssertEqual(d1.getGarbageLength(), 0)
        XCTAssertEqual(d2.getGarbageLength(), 0)
    }
}
