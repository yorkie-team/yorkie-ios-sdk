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

// Ports two of the three structures from
// packages/sdk/test/unit/document/gc_rga_barrier_test.ts (yorkie-js-sdk#1405,
// mirrors Go `ba82ed91`). A collecting replica must not reorder the elements
// that survive collection: an insert whose RGA forward skip stopped at a node
// on one replica must not run past that node on a replica that has already
// collected it.
//
// Every version vector that authorises a purge here is one the server could
// genuinely compute: the element-wise min of the replicas' own vectors (the
// local `minVV`), exactly as the server's `UpdateMinVersionVector` would
// produce it from two attached clients' rows. `maxVectorOf` is used only at
// the end, to assert that nothing is retained forever.
//
// NOT ported from the upstream file:
// - "keeps insert order when a removed element was concurrently moved" (the
//   `CRDTArray`/`RGATreeList` case) and "keeps concurrent moves of one element
//   converged": both exercise `RGATreeList.purgeBarrierAt`, but through a
//   move, which needs a second LWW position register on top of the same
//   successor-ticket mechanism the Text and Tree cases below already pin.
//   `GCIntegrationTests.test_successor_barrier_drains_within_one_round` (and
//   its sibling) exercise the same `RGATreeList`/array path end-to-end against
//   a live server instead.
// - The "GC successor barrier cost" describe block (retention bounded by lag,
//   not by array size; a byte-limited array still accepting every move): these
//   pin a quantitative ceiling on retention, not the collection/convergence
//   correctness the fix is about.
// - `gc_rga_fuzz_test.ts` (`RGA_FUZZ=1`): an opt-in, non-deterministic fuzz
//   harness with its own PRNG and a report file, not a assertion a CI run can
//   gate on; Go's equivalent is also opt-in and asserts nothing on CI.

import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

private let actorA1: ActorID = "000000000000000000000001"
private let actorA2: ActorID = "000000000000000000000002"

/// `push` hands `from`'s pending changes to the server and acks them at
/// `from`, returning the changes for the caller to `pull` elsewhere.
@MainActor
@discardableResult
private func push(_ from: Document) throws -> [Change] {
    let pack = from.createChangePack()
    let changes = pack.getChanges()
    let lastSeq = changes.last?.id.getClientSeq() ?? 0
    try from.applyChangePack(ChangePack(key: pack.getDocumentKey(),
                                        checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
                                        isRemoved: false,
                                        changes: [],
                                        versionVector: VersionVector.initial))
    return changes
}

/// `pull` applies the given changes to `to`, as a pull from the server would.
@MainActor
private func pull(_ to: Document, _ changes: [Change]) throws {
    try to.applyChangePack(ChangePack(key: to.getKey(),
                                      checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                      isRemoved: false,
                                      changes: changes,
                                      versionVector: VersionVector.initial))
}

/// `oneWayDeliver` hands one replica's pending local changes to the other and
/// acks them at the sender: a push followed by the other side's pull.
@MainActor
private func oneWayDeliver(_ from: Document, to: Document) throws {
    try pull(to, push(from))
}

/// `crossSync` exchanges pending changes both ways.
@MainActor
private func crossSync(_ d1: Document, _ d2: Document) throws {
    let c1 = try push(d1)
    let c2 = try push(d2)
    try pull(d2, c1)
    try pull(d1, c2)
}

/// `minVV` is the element-wise min of the given vectors, 0 for an actor any
/// vector does not carry -- mirrors what the server computes as the minimum
/// synced version vector across attached clients.
private func minVV(_ vectors: VersionVector...) -> VersionVector {
    var actors = Set<ActorID>()
    for vector in vectors {
        for (actorID, _) in vector {
            actors.insert(actorID)
        }
    }

    var out: [String: Int64] = [:]
    for actorID in actors {
        var minLamport: Int64?
        for vector in vectors {
            let lamport = vector.get(actorID) ?? 0
            minLamport = minLamport.map { Swift.min($0, lamport) } ?? lamport
        }
        out[actorID] = minLamport ?? 0
    }
    return VersionVector(vector: out)
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

final class GCSuccessorBarrierTests: XCTestCase {
    // Port of Go TestConcurrentDeleteAndInsertThenGCKeepsTextOrder: the
    // tombstone left by the delete is what stops the skip in
    // `RGATreeSplit.findNodeWithSplit`.
    @MainActor
    func test_keeps_text_order_after_collecting_a_concurrently_deleted_node() throws {
        // given
        let remover = Document(key: "test-doc")
        let mover = Document(key: "test-doc")
        remover.setActor(actorA1)
        mover.setActor(actorA2)

        try remover.update { root, _ in
            root.t = JSONText()
            (root.t as? JSONText)?.edit(0, 0, "A")
            (root.t as? JSONText)?.edit(0, 0, "W")
        }
        try crossSync(remover, mover)
        XCTAssertEqual(try XCTUnwrap(mover.getRoot().t as? JSONText).toString, "WA")

        // mover: bump its clock, then append "S" anchored right after "A".
        for index in 0 ..< 3 {
            try mover.update { root, _ in root["mover-\(index)"] = Int32(index) }
        }
        try mover.update { root, _ in _ = (root.t as? JSONText)?.edit(2, 2, "S") }
        XCTAssertEqual(try XCTUnwrap(mover.getRoot().t as? JSONText).toString, "WAS")

        // remover: delete "A". It reaches mover, so it is causally stable.
        try remover.update { root, _ in _ = (root.t as? JSONText)?.edit(1, 2, "") }
        try oneWayDeliver(remover, to: mover)
        XCTAssertEqual(try XCTUnwrap(mover.getRoot().t as? JSONText).toString, "WS")
        let vv = minVV(remover.getVersionVector(), mover.getVersionVector())

        // remover keeps editing without pulling: insert "X" right after "W".
        try remover.update { root, _ in root["remover-0"] = Int32(0) }
        try remover.update { root, _ in _ = (root.t as? JSONText)?.edit(1, 1, "X") }
        XCTAssertEqual(try XCTUnwrap(remover.getRoot().t as? JSONText).toString, "WX")

        // when -- mover collects with that vector: the only difference
        // between them.
        mover.garbageCollect(minSyncedVersionVector: vv)
        try oneWayDeliver(remover, to: mover)
        try crossSync(remover, mover)

        // then
        XCTAssertEqual(try XCTUnwrap(mover.getRoot().t as? JSONText).toString,
                       try XCTUnwrap(remover.getRoot().t as? JSONText).toString,
                       "text replicas diverged after collecting a tombstone")

        // Holding the purge back must be a delay, not a leak.
        remover.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1, actorA2]))
        mover.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1, actorA2]))
        XCTAssertEqual(remover.getGarbageLength(), 0, "remover leaked garbage")
        XCTAssertEqual(mover.getGarbageLength(), 0, "mover leaked garbage")
        try assertMatchesRebuild(remover, "remover")
        try assertMatchesRebuild(mover, "mover")
    }

    // Port of Go TestConcurrentDeleteAndInsertThenGCKeepsTreeOrder: the same
    // defect in `CRDTTree`, whose sibling skip in `findNodesAndSplitText`
    // reads the parent's children with the removed ones included.
    @MainActor
    func test_keeps_tree_order_after_collecting_a_concurrently_deleted_node() throws {
        // given
        let remover = Document(key: "test-doc")
        let mover = Document(key: "test-doc")
        remover.setActor(actorA1)
        mover.setActor(actorA2)

        try remover.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [])
            ]))
            _ = try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "A"))
            _ = try (root.t as? JSONTree)?.edit(1, 1, JSONTreeTextNode(value: "W"))
        }
        try crossSync(remover, mover)
        XCTAssertEqual(try XCTUnwrap(mover.getRoot().t as? JSONTree).toXML(), "<doc><p>WA</p></doc>")

        for index in 0 ..< 3 {
            try mover.update { root, _ in root["mover-\(index)"] = Int32(index) }
        }
        try mover.update { root, _ in _ = try (root.t as? JSONTree)?.edit(3, 3, JSONTreeTextNode(value: "S")) }
        XCTAssertEqual(try XCTUnwrap(mover.getRoot().t as? JSONTree).toXML(), "<doc><p>WAS</p></doc>")

        try remover.update { root, _ in _ = try (root.t as? JSONTree)?.edit(2, 3) }
        try oneWayDeliver(remover, to: mover)
        XCTAssertEqual(try XCTUnwrap(mover.getRoot().t as? JSONTree).toXML(), "<doc><p>WS</p></doc>")
        let vv = minVV(remover.getVersionVector(), mover.getVersionVector())

        try remover.update { root, _ in root["remover-0"] = Int32(0) }
        try remover.update { root, _ in _ = try (root.t as? JSONTree)?.edit(2, 2, JSONTreeTextNode(value: "X")) }
        XCTAssertEqual(try XCTUnwrap(remover.getRoot().t as? JSONTree).toXML(), "<doc><p>WX</p></doc>")

        // when
        mover.garbageCollect(minSyncedVersionVector: vv)
        try oneWayDeliver(remover, to: mover)
        try crossSync(remover, mover)

        // then
        XCTAssertEqual(try XCTUnwrap(mover.getRoot().t as? JSONTree).toXML(),
                       try XCTUnwrap(remover.getRoot().t as? JSONTree).toXML(),
                       "tree replicas diverged after collecting a tombstone")

        remover.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1, actorA2]))
        mover.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorA1, actorA2]))
        XCTAssertEqual(remover.getGarbageLength(), 0, "remover leaked garbage")
        XCTAssertEqual(mover.getGarbageLength(), 0, "mover leaked garbage")
        try assertMatchesRebuild(remover, "remover")
        try assertMatchesRebuild(mover, "mover")
    }
}
