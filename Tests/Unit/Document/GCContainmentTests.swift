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

/// Ports `packages/sdk/test/unit/document/gc_containment_test.ts` from
/// yorkie-js-sdk v0.7.21 (yorkie-js-sdk#1341, "Keep a client syncing when a
/// restore duplicates an element identity, and stop `arr[i] = x` from growing
/// the document without bound"). See ``CRDTRoot`` for the corresponding
/// production change (commit 160aa95dc2).
///
/// Two porting deviations from upstream, both required by the iOS surface:
///
/// - Upstream's array-set scenarios assign an object (`r.arr[0] = { b: 2 }`).
///   ``JSONArray/setValue(index:value:)`` on iOS only supports `Int` and
///   throws ``YorkieError/errNotReady`` otherwise, so those scenarios are
///   ported with `Int` values. The intent -- an array set displacing an
///   element, then a remove, then a collection that must not throw and must
///   leave nothing behind -- is unchanged.
/// - Upstream's "left behind by an older client" scenario reaches into the
///   private `gcElementSetByCreatedAt` via a type cast, which `@testable
///   import` cannot expose on iOS (`private` stays private across module
///   boundaries, testable or not). It is reproduced legitimately instead:
///   ``CRDTRoot/registerRemovedElement(_:)`` on an element that was never
///   passed to ``CRDTRoot/registerElement(_:parent:)`` leaves exactly the
///   same state -- a `gcElementSetByCreatedAt` member `elementPairMapByCreatedAt`
///   cannot resolve -- without touching production code.
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

/// `broadcast` is `deliver` for more than one receiver. The ack happens once,
/// after every receiver has the pack: it clears the sender's local changes,
/// so acking per receiver would leave a later one with nothing.
@MainActor
private func broadcast(_ from: Document, to tos: [Document]) throws {
    let pack = from.createChangePack()
    let changes = pack.getChanges()

    for to in tos {
        try to.applyChangePack(ChangePack(key: pack.getDocumentKey(),
                                          checkpoint: Checkpoint(serverSeq: 0, clientSeq: 0),
                                          isRemoved: false,
                                          changes: changes,
                                          versionVector: VersionVector.initial))
    }

    let lastSeq = changes.last?.id.getClientSeq() ?? 0
    try from.applyChangePack(ChangePack(key: pack.getDocumentKey(),
                                        checkpoint: Checkpoint(serverSeq: 0, clientSeq: lastSeq),
                                        isRemoved: false,
                                        changes: [],
                                        versionVector: VersionVector.initial))
}

final class GCContainmentTests: XCTestCase {
    @MainActor
    func test_collects_an_array_element_replaced_by_an_array_set() throws {
        // given -- an array set followed by a remove, no undo anywhere.
        let doc = Document(key: "array-set-then-remove")
        try doc.update { root, _ in root.arr = [1] }
        try doc.update { root, _ in try (root.arr as? JSONArray)?.setValue(index: 0, value: 2) }
        try doc.update { root, _ in _ = (root.arr as? JSONArray)?.remove(at: 0) }

        // when -- the value an array set installs has to be registered with
        // its parent, or garbage collection cannot reach it to purge it and
        // throws on the missing parent instead, inside `applyChangePack`,
        // which is what stops the client from syncing again.
        let collected = doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))

        // then
        XCTAssertGreaterThan(collected, 0)
        XCTAssertEqual(doc.getGarbageLength(), 0)
        XCTAssertEqual(doc.toSortedJSON(), "{\"arr\":[]}")
    }

    @MainActor
    func test_collects_the_element_an_array_assignment_displaces() throws {
        // given -- an array holding one number.
        let doc = Document(key: "array-set-leak")
        try doc.update { root, _ in root.arr = [0] }

        func set(_ value: Int) throws {
            try doc.update { root, _ in try (root.arr as? JSONArray)?.setValue(index: 0, value: value) }
            doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))
        }

        // One cycle establishes the steady state: an array holding one
        // number, with the element it displaced collected.
        try set(1)
        let steady = doc.getDocSize()
        XCTAssertEqual(doc.getGarbageLength(), 0)

        // when -- the displaced elements used to stay charged to live with
        // nothing able to reach them, so an ordinary assignment loop grew the
        // document without bound. No undo is involved.
        for value in 2 ... 10 {
            try set(value)
        }

        // then
        XCTAssertEqual(doc.toSortedJSON(), "{\"arr\":[10]}")
        XCTAssertEqual(doc.getGarbageLength(), 0)
        XCTAssertEqual(doc.getDocSize(), steady)
    }

    /// ``JSONArray/setValue(index:value:)`` applies the set to the clone while
    /// ``ArraySetOperation`` applies it to the root, so the two have to agree.
    /// The clone is not a convenience copy: ``Document/update(_:_:)`` measures
    /// *its* `docSize` against `maxSizeLimit`, and every later index-based
    /// local edit is resolved against its ordering.
    @MainActor
    func test_an_array_assignment_keeps_the_clone_in_step_with_the_root() throws {
        // given
        let doc = Document(key: "array-set-clone-parity")
        try doc.update { root, _ in root.arr = [0] }

        // when -- ten assignments, each followed by a collection.
        for value in 1 ... 10 {
            try doc.update { root, _ in try (root.arr as? JSONArray)?.setValue(index: 0, value: value) }
            doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))
        }

        // then
        XCTAssertEqual(doc.getCloneRoot()?.toSortedJSON(), doc.toSortedJSON())
        XCTAssertEqual(doc.cloned.root.getDocSize(), doc.getDocSize())
    }

    /// `RGATreeList.set` used to anchor its insert on the element's *current*
    /// position node, while ``ArraySetOperation`` anchors on the element's
    /// `createdAt` -- the anchor `rga_tree_list.ts` `set()` uses. For an
    /// element that had been moved the two resolve to different nodes, so the
    /// clone and the root ended up ordering the array differently and every
    /// later index-based local edit on this client addressed the wrong
    /// element.
    @MainActor
    func test_an_array_assignment_after_a_move_keeps_the_clone_in_step_with_the_root() throws {
        // given -- an array whose middle element has been moved.
        let doc = Document(key: "array-set-after-move")
        try doc.update { root, _ in root.arr = [0, 1, 2] }
        try doc.update { root, _ in try (root.arr as? JSONArray)?.moveAfterByIndex(prevIndex: 0, targetIndex: 2) }

        // when
        try doc.update { root, _ in try (root.arr as? JSONArray)?.setValue(index: 1, value: 99) }

        // then
        XCTAssertEqual(doc.getCloneRoot()?.toSortedJSON(), doc.toSortedJSON())
    }

    @MainActor
    func test_collects_the_tombstone_an_undone_object_remove_leaves_on_a_peer() throws {
        // given -- `SetOperation` restores the member under its original
        // createdAt, and the object re-keys onto the restored node. The
        // removal's member in the gc set then resolves to that live element,
        // whose removedAt is nil, so collection can never take it.
        // Deregistering the stale registration is what clears it, and that
        // has to happen wherever the operation is applied -- not only on the
        // replica that performed the undo.
        let d1 = Document(key: "undone-object-remove")
        let d2 = Document(key: "undone-object-remove")
        d1.setActor(actorA1)
        d2.setActor(actorA2)

        try d1.update { root, _ in
            root.obj = ["k": Int64(1)]
            root.keep = Int64(0)
        }
        try deliver(d1, to: d2)

        try d1.update({ root, _ in root.remove(key: "obj") }, "remove obj")
        try d1.undo()
        try deliver(d1, to: d2)

        XCTAssertEqual(d1.toSortedJSON(), "{\"keep\":0,\"obj\":{\"k\":1}}")
        XCTAssertEqual(d2.toSortedJSON(), "{\"keep\":0,\"obj\":{\"k\":1}}")

        // when
        let vector = maxVectorOf(actors: [actorA1, actorA2])
        d1.garbageCollect(minSyncedVersionVector: vector)
        d2.garbageCollect(minSyncedVersionVector: vector)

        // then
        XCTAssertEqual(d1.toSortedJSON(), "{\"keep\":0,\"obj\":{\"k\":1}}")
        XCTAssertEqual(d2.toSortedJSON(), "{\"keep\":0,\"obj\":{\"k\":1}}")
        XCTAssertEqual(d1.getGarbageLength(), 0)
        XCTAssertEqual(d2.getGarbageLength(), 0, "the peer holds a worklist entry that can never be collected")
    }

    func test_survives_a_gc_set_member_left_behind_by_an_older_client() throws {
        // given -- {"items": [{"a": 1}]}
        let actorId = "000000000000000000000009"
        let rootObject = CRDTObject(createdAt: TimeTicket.initial)
        let items = CRDTArray(createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let itemObject = CRDTObject(createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        let a1 = Primitive(value: .integer(1), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        itemObject.set(key: "a", value: a1)
        try items.insert(value: itemObject, prevCreatedAt: items.getHead().createdAt)
        rootObject.set(key: "items", value: items)

        let root = CRDTRoot(rootObject: rootObject)

        // A document written by an SDK that left two elements under one
        // createdAt holds a gc set member the pair map cannot resolve. That
        // state is not reachable through the public API -- and not through
        // `private` storage even with `@testable import` -- so it is staged
        // legitimately instead: registering an element as removed without
        // ever registering it as live leaves `elementPairMapByCreatedAt`
        // with nothing for its createdAt, exactly what an older client's
        // mis-registration would leave behind.
        let orphan = Primitive(value: .integer(999), createdAt: TimeTicket(lamport: 999, delimiter: 0, actorID: actorId))
        root.registerRemovedElement(orphan)

        let before = root.getDocSize()

        // when
        let collected = root.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorId]))

        // then -- the member is skipped, not forgotten: its size is still
        // charged to `docSize.gc`, and only `deregisterElement` releases
        // that, so dropping it would leave the charge with nothing reporting
        // it as garbage.
        XCTAssertEqual(collected, 0)
        XCTAssertEqual(root.getDocSize(), before)
        XCTAssertGreaterThan(root.garbageLength, 0)
        XCTAssertEqual(root.toSortedJSON(), "{\"items\":[{\"a\":1}]}")
    }

    func test_survives_a_gc_set_member_whose_element_has_no_parent() throws {
        // given -- {"items": [{"a": 1}]}, with the item removed normally
        // (as `r.items.splice(0, 1)` would).
        let actorId = "000000000000000000000009"
        let rootObject = CRDTObject(createdAt: TimeTicket.initial)
        let items = CRDTArray(createdAt: TimeTicket(lamport: 1, delimiter: 0, actorID: actorId))
        let itemObject = CRDTObject(createdAt: TimeTicket(lamport: 2, delimiter: 0, actorID: actorId))
        let a1 = Primitive(value: .integer(1), createdAt: TimeTicket(lamport: 3, delimiter: 0, actorID: actorId))
        itemObject.set(key: "a", value: a1)
        try items.insert(value: itemObject, prevCreatedAt: items.getHead().createdAt)
        rootObject.set(key: "items", value: items)

        let root = CRDTRoot(rootObject: rootObject)

        let removedAt = TimeTicket(lamport: 4, delimiter: 0, actorID: actorId)
        let tombstone = try items.delete(createdAt: itemObject.createdAt, executedAt: removedAt)
        root.registerRemovedElement(tombstone)

        // `ArraySetOperation` used to register its value without a parent, so
        // the pair resolves but `purge` has nothing to call. Re-register the
        // tombstone that way to reproduce what such a document carries.
        root.registerElement(tombstone, parent: nil)

        let before = root.getDocSize()

        // when
        let collected = root.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [actorId]))

        // then
        XCTAssertEqual(collected, 0)
        XCTAssertEqual(root.getDocSize(), before)
        XCTAssertEqual(root.toSortedJSON(), "{\"items\":[]}")
    }

    /// The reverse of a remove is a set of `value.deepcopy()`, taken when the
    /// removal was recorded. A peer that added a member into the container
    /// before the removal is captured is a member `value.deepcopy()` also
    /// carries -- but the *registration* of that member, in the undoing
    /// replica's own ``CRDTRoot``, is the live entry a peer's earlier update
    /// already installed, not a copy. Retiring the whole subtree wholesale
    /// (rather than retiring only the top-level entry the restore actually
    /// makes stale) evicts that live entry from the pair map along with it,
    /// and nothing puts it back -- so a later change addressed at that
    /// member throws `fail to find` inside `applyChangePack` on the very
    /// replica that performed the undo.
    ///
    /// This is the iOS-reachable manifestation of yorkie-js-sdk#1341's
    /// "restore duplicates an element identity" family. Upstream's own
    /// scenario relies on an *ungated* `deregisterElement` call that runs on
    /// every replica applying the reverse `Set`, including a remote one that
    /// never performed the undo; pre-fix iOS gated that call on
    /// `source == .undoRedo` (yorkie-js-sdk#1349), so only the replica that
    /// ran the undo ever evicted anything. Reproducing the eviction here
    /// therefore requires the undoing replica itself to already hold the
    /// peer's member -- i.e. to have synced it in before removing -- rather
    /// than upstream's ordering, where the undoing replica never sees the
    /// member at all.
    @MainActor
    func test_keeps_a_member_a_peer_added_into_it_addressable() throws {
        // given -- d1 removes obj before it has ever seen a member d2 is
        // about to add into it, so the deepcopy the removal captures for
        // undo does not contain that member.
        let d1 = Document(key: "restore-foreign")
        let d2 = Document(key: "restore-foreign")

        try d1.update { root, _ in root.obj = ["k": Int64(1)] }
        try deliver(d1, to: d2)

        try d1.update({ root, _ in root.remove(key: "obj") }, "remove obj")

        // d2, concurrently and before seeing d1's removal, adds a member
        // into obj. Delivering it to d1 attaches the member onto d1's own
        // tombstone -- the same instance the pending undo's reverse `Set`
        // will resolve through, and a strict superset of the deepcopy that
        // `Set` is about to restore.
        try d2.update { root, _ in (root.obj as? JSONObject)?.n = ["y": Int64(1)] }
        try deliver(d2, to: d1)

        // d1 undoes its own removal. The reverse `Set` restores the
        // deepcopy taken before the member existed.
        try d1.undo()

        // d2 edits the member it added. Delivering this to d1 sends a remote
        // `Set` addressed at the member's own createdAt, which has to
        // resolve through d1's own pair map.
        try d2.update { root, _ in ((root.obj as? JSONObject)?.n as? JSONObject)?.x = Int64(5) }

        // when / then -- the peer's change must still apply to d1, or the
        // change log is permanently unreplayable.
        XCTAssertNoThrow(
            try deliver(d2, to: d1),
            "the peer's change no longer applies, so the change log is unreplayable"
        )
    }

    /// Each cycle leaves another tombstone answering to the same createdAt.
    /// Collection that resolves an entry through a createdAt-keyed index
    /// rather than through the element it was registered for will, on a
    /// later pass, unlink a live member on a dead one's behalf or fail to
    /// find the node at all -- and a crash inside `garbageCollect` inside
    /// `applyChangePack` is exactly yorkie-js-sdk#1340.
    @MainActor
    func test_survives_being_restored_and_removed_repeatedly() throws {
        // given
        let doc = Document(key: "restore-repeat")
        try doc.update { root, _ in root.o = ["k": Int64(1)] }

        for _ in 0 ..< 3 {
            try doc.update({ root, _ in root.remove(key: "o") }, "remove o")
            try doc.undo()
        }
        try doc.update({ root, _ in root.remove(key: "o") }, "remove o")

        // when
        let collected = doc.garbageCollect(minSyncedVersionVector: maxVectorOf(actors: [doc.changeID.getActorID()]))

        // then
        XCTAssertGreaterThan(collected, 0)
        XCTAssertEqual(doc.toSortedJSON(), "{}")
        XCTAssertEqual(doc.getGarbageLength(), 0)
    }
}
