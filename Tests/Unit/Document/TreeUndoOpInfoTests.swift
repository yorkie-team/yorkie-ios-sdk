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

// Ports: packages/sdk/test/unit/document/tree_undo_opinfo_test.ts
// (yorkie-js-sdk#1421, "Report where Tree undo and redo landed in their
// OpInfo"). A Tree undo reports where it landed through its OpInfos. This
// covers the one case where there is nothing to report: the undone nodes come
// back under an ancestor a peer removed in the meantime, so they take no room
// in the index and have no position an editor could be told about. The undo
// still ran, so it still has to be published and delivered -- an operation
// that mutates one replica and reaches no other is divergence.

import XCTest
@testable import Yorkie
#if SWIFT_TEST
@testable import YorkieTestHelper
#endif

private let actorA: ActorID = "000000000000000000000001"
private let actorB: ActorID = "000000000000000000000002"

/// `recordChanges` drains a replica's pending local changes so they can be
/// delivered to the other one. The emptiness check matters here: a step that
/// silently produced nothing -- an undo that found no entry -- would make the
/// convergence assertions trivially true.
@MainActor
private func recordChanges(_ from: Document, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws -> [Change] {
    let pack = from.createChangePack()
    let changes = pack.getChanges()
    XCTAssertFalse(changes.isEmpty, "\(what) produced no change to deliver", file: file, line: line)

    let lastSeq = changes.last?.id.getClientSeq() ?? 0
    try from.applyChangePack(ChangePack(key: pack.getDocumentKey(),
                                        checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
                                        isRemoved: false,
                                        changes: [],
                                        versionVector: VersionVector.initial))
    return changes
}

/// `deliver` applies recorded changes to a replica. The neutral checkpoint
/// keeps the receiver's own pending local changes, and `VersionVector.initial`
/// keeps garbage collection out of the delivery.
@MainActor
private func deliver(_ to: Document, _ changes: [Change]) throws {
    try to.applyChangePack(ChangePack(key: to.getKey(),
                                      checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                      isRemoved: false,
                                      changes: changes,
                                      versionVector: VersionVector.initial))
}

/// `collect` garbage-collects both replicas off the min of their version
/// vectors, which is what a sync round does once every replica has seen the
/// removal. `deliver` keeps collection out of delivery, so a test that wants
/// it asks for it here.
@MainActor
private func collect(_ replicaA: Document, _ replicaB: Document) {
    var min: [String: Int64] = [:]
    for (actorID, lamport) in replicaA.getVersionVector() {
        let other = replicaB.getVersionVector().get(actorID)
        min[actorID] = (other == nil || lamport < other!) ? lamport : other!
    }
    replicaA.garbageCollect(minSyncedVersionVector: VersionVector(vector: min))
    replicaB.garbageCollect(minSyncedVersionVector: VersionVector(vector: min))
}

@MainActor
private func xmlOf(_ doc: Document) throws -> String {
    try XCTUnwrap(doc.getRoot().t as? JSONTree).toXML()
}

final class TreeUndoOpInfoTests: XCTestCase {
    @MainActor
    func test_reports_no_position_and_still_publishes_and_delivers_the_undo() throws {
        // given
        let replicaA = Document(key: "tree-undo-opinfo")
        let replicaB = Document(key: "tree-undo-opinfo")
        replicaA.setActor(actorA)
        replicaB.setActor(actorB)

        try replicaA.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")])
            ]))
        }
        try deliver(replicaB, recordChanges(replicaA, "initial tree"))

        // A deletes the text in the first paragraph, then B removes the
        // paragraph itself. A's pending undo now has nowhere visible to put
        // the text back.
        try replicaA.update { root, _ in _ = try (root.t as? JSONTree)?.editByPath([0, 0], [0, 2]) }
        try deliver(replicaB, recordChanges(replicaA, "delete text"))
        try replicaB.update { root, _ in _ = try (root.t as? JSONTree)?.editByPath([0], [1]) }
        try deliver(replicaA, recordChanges(replicaB, "remove paragraph"))
        XCTAssertEqual(try xmlOf(replicaA), "<doc><p>cd</p></doc>")

        // when -- the undo publishes its change with no operation to report,
        // rather than publishing nothing: it is queued and consumes a
        // clientSeq either way, and offline persistence appends off this
        // event (`Document.onLocalChange`, which fires unconditionally).
        var published = 0
        var opInfos: [any OperationInfo] = []
        replicaA.subscribe { event, _ in
            guard let change = event as? LocalChangeEvent else {
                return
            }
            published += 1
            opInfos.append(contentsOf: change.value.operations)
        }
        try replicaA.undo()

        // then
        XCTAssertEqual(published, 1, "the undo published its change")
        XCTAssertTrue(opInfos.isEmpty, "and reported no position in it")
        XCTAssertEqual(try xmlOf(replicaA), "<doc><p>cd</p></doc>")

        // Nothing was visible to report, but the restore still has to reach
        // B. Undoing B's own removal brings the paragraph back, and the text
        // with it only if A's restore landed there too.
        try deliver(replicaB, recordChanges(replicaA, "undo the text deletion"))
        try replicaB.undo()
        try deliver(replicaA, recordChanges(replicaB, "undo the paragraph removal"))

        XCTAssertEqual(try xmlOf(replicaB), "<doc><p>ab</p><p>cd</p></doc>")
        XCTAssertEqual(try xmlOf(replicaA), try xmlOf(replicaB))
    }

    @MainActor
    func test_leaves_a_collected_node_tombstoned_when_its_parent_comes_back() throws {
        // given
        let replicaA = Document(key: "tree-undo-opinfo")
        let replicaB = Document(key: "tree-undo-opinfo")
        replicaA.setActor(actorA)
        replicaB.setActor(actorB)

        try replicaA.update { root, _ in
            root.t = JSONTree(initialRoot: JSONTreeElementNode(type: "doc", children: [
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "ab")]),
                JSONTreeElementNode(type: "p", children: [JSONTreeTextNode(value: "cd")])
            ]))
        }
        try deliver(replicaB, recordChanges(replicaA, "initial tree"))

        // Same run as above, except both replicas have seen the text deletion
        // before the undo, so collection purges its tombstone on both.
        try replicaA.update { root, _ in _ = try (root.t as? JSONTree)?.editByPath([0, 0], [0, 2]) }
        try deliver(replicaB, recordChanges(replicaA, "delete text"))
        collect(replicaA, replicaB)
        XCTAssertEqual(replicaA.getGarbageLength(), 0, "the text tombstone is collected")
        XCTAssertEqual(replicaB.getGarbageLength(), 0, "on both replicas")

        try replicaB.update { root, _ in _ = try (root.t as? JSONTree)?.editByPath([0], [1]) }
        try deliver(replicaA, recordChanges(replicaB, "remove paragraph"))
        XCTAssertEqual(try xmlOf(replicaA), "<doc><p>cd</p></doc>")

        // when
        try replicaA.undo()
        try deliver(replicaB, recordChanges(replicaA, "undo the text deletion"))
        try replicaB.undo()
        try deliver(replicaA, recordChanges(replicaB, "undo the paragraph removal"))

        // then -- the undo recreates the purged text under a parent that is
        // removed at that moment, and `recreateFromSpan` births it
        // tombstoned, so restoring the paragraph does not bring the text back
        // with it. Both replicas collect off the same min version vector, so
        // both land here: the outcome differs from the uncollected run above,
        // but never between peers.
        XCTAssertEqual(try xmlOf(replicaB), "<doc><p></p><p>cd</p></doc>")
        XCTAssertEqual(try xmlOf(replicaA), try xmlOf(replicaB))
    }
}
