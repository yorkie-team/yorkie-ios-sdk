/*
 * Copyright 2026 The Yorkie Authors. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License")
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

/// Covers the `Client` half of yorkie-js-sdk#1338 "Add offline local persistence" that is
/// genuinely reachable without a running server: the storage and locking seams
/// (``MemoryDocStore``, ``NoopSessionLock``, and a contended lock double's own contract), the
/// ``Document/onLocalChange`` hook the whole persist path hangs off, the
/// ``LocalChangesDroppedEvent`` an app subscribes to, and a full store round trip at the
/// `Document` level proving persisted pending changes survive and would be re-pushed.
///
/// `Client.prepareOfflineResume(for:)` / `Client.releasePersistence(for:attachment:)` and the
/// `attach`/`detach` wiring around them are private and only exercised by driving a real
/// `attach()`, which requires a live yorkie server (an RPC round trip, the session lease taken
/// before it, and the attach response driving the restore/re-anchor branches). Those belong in
/// `Tests/Integration`, not here — see the class doc for what to add there.
final class ClientPersistenceTests: XCTestCase {
    private let actor = "000000000000000000000001"

    // MARK: MemoryDocStore

    func test_memorydocstore_round_trips_saved_bytes() async throws {
        let store = MemoryDocStore()
        let bytes = Data("hello".utf8)

        try await store.save(docKey: "doc-1", bytes: bytes)
        let loaded = try await store.load(docKey: "doc-1")

        XCTAssertEqual(loaded, bytes)
    }

    func test_memorydocstore_load_of_an_absent_key_returns_nil() async throws {
        let store = MemoryDocStore()

        let loaded = try await store.load(docKey: "never-saved")

        XCTAssertNil(loaded)
    }

    func test_memorydocstore_remove_of_an_absent_key_succeeds() async throws {
        let store = MemoryDocStore()

        try await store.remove(docKey: "never-saved")
    }

    func test_memorydocstore_overwrite_replaces_the_stored_bytes() async throws {
        let store = MemoryDocStore()

        try await store.save(docKey: "doc-1", bytes: Data("first".utf8))
        try await store.save(docKey: "doc-1", bytes: Data("second".utf8))
        let loaded = try await store.load(docKey: "doc-1")

        XCTAssertEqual(loaded, Data("second".utf8))
    }

    func test_memorydocstore_remove_clears_a_previously_saved_key() async throws {
        let store = MemoryDocStore()

        try await store.save(docKey: "doc-1", bytes: Data("hello".utf8))
        try await store.remove(docKey: "doc-1")
        let loaded = try await store.load(docKey: "doc-1")

        XCTAssertNil(loaded)
    }

    /// `MemoryDocStore` is an actor, so this only proves its interleaved writes serialize
    /// rather than race — not a claim about ordering between the two keys.
    func test_memorydocstore_is_safe_under_concurrent_access() async throws {
        let store = MemoryDocStore()

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 100 {
                group.addTask {
                    try? await store.save(docKey: "doc-\(index % 5)", bytes: Data("v\(index)".utf8))
                }
            }
        }

        for index in 0 ..< 5 {
            let loaded = try await store.load(docKey: "doc-\(index)")
            XCTAssertNotNil(loaded, "doc-\(index) should have been written by one of the concurrent saves")
        }
    }

    // MARK: NoopSessionLock

    func test_noopsessionlock_grants_a_lease() async {
        let lock = NoopSessionLock()

        let handle = await lock.acquire(name: "lease-1")

        XCTAssertNotNil(handle)
    }

    func test_noopsessionlock_grants_a_second_lease_for_the_same_name() async {
        // The point of the no-op: it imposes no coordination, so a second "session" (in the
        // same process) is never turned away by it.
        let lock = NoopSessionLock()

        let first = await lock.acquire(name: "lease-1")
        let second = await lock.acquire(name: "lease-1")

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
    }

    func test_noopsessionlock_handle_releases_without_error() async throws {
        let lock = NoopSessionLock()
        let acquired = await lock.acquire(name: "lease-1")
        let handle = try XCTUnwrap(acquired)

        await handle.release()
    }

    func test_noopsessionlock_handle_releasing_twice_is_harmless() async throws {
        let lock = NoopSessionLock()
        let acquired = await lock.acquire(name: "lease-1")
        let handle = try XCTUnwrap(acquired)

        await handle.release()
        await handle.release()
    }

    // MARK: A contended SessionLock double

    // Driving contention through `Client.attach` would need a live server: the lease is
    // acquired inside `attach`, ahead of the RPC, and there is no seam to inspect it without
    // one. So this pins the double's own contract directly instead — first acquire grants,
    // second for the same name is refused, and release frees the name for reacquisition. A
    // `Client` wired with such a lock will see `attach` throw `errInvalidArgument` on the
    // second attempt, but proving that needs `Tests/Integration`.
    func test_contended_sessionlock_grants_the_first_acquire_and_refuses_the_second() async {
        let lock = FakeContendedSessionLock()

        let first = await lock.acquire(name: "doc-1")
        let second = await lock.acquire(name: "doc-1")

        XCTAssertNotNil(first)
        XCTAssertNil(second)
    }

    func test_contended_sessionlock_grants_a_different_name_while_the_first_is_held() async {
        let lock = FakeContendedSessionLock()

        let first = await lock.acquire(name: "doc-1")
        let other = await lock.acquire(name: "doc-2")

        XCTAssertNotNil(first)
        XCTAssertNotNil(other)
    }

    // Pins the session-lease lifetime `Client.releaseSession(for:attachment:)` (private,
    // unreachable from this target) relies on: a lease it releases must be re-acquirable for
    // the same name, or a released document would lock its key out for the rest of the
    // process. `Client`'s own release paths (`detach`, `deactivate`, the removed-mid-sync
    // branch) need a server to reach and belong in `Tests/Integration`; the guarantee itself is
    // the lock's own contract, pinned here directly.
    func test_contended_sessionlock_releasing_frees_the_name_for_reacquisition() async throws {
        let lock = FakeContendedSessionLock()
        let firstAcquired = await lock.acquire(name: "doc-1")
        let first = try XCTUnwrap(firstAcquired)

        await first.release()
        let second = await lock.acquire(name: "doc-1")

        XCTAssertNotNil(second)
    }

    // MARK: Document.onLocalChange

    @MainActor
    func test_onlocalchange_fires_on_a_local_update() throws {
        let doc = Document(key: "onlocalchange-fires")
        doc.setActor(self.actor)
        var fireCount = 0
        doc.onLocalChange = { fireCount += 1 }

        try doc.update { root, _ in
            root.title = "hello"
        }

        XCTAssertEqual(fireCount, 1)
    }

    @MainActor
    func test_onlocalchange_does_not_fire_for_a_remote_change() throws {
        // A "remote" change here is a change pack built from a second, independently-actored
        // document and applied via `applyChangePack` — the same path a real pushpull response
        // takes, without needing a server. Mirrors the `crossSync` pattern in
        // `TextRestoreConvergenceTests.swift`.
        let local = Document(key: "onlocalchange-remote")
        local.setActor(self.actor)
        var fireCount = 0
        local.onLocalChange = { fireCount += 1 }

        let remote = Document(key: "onlocalchange-remote")
        remote.setActor("000000000000000000000002")
        try remote.update { root, _ in
            root.title = "from another actor"
        }

        let remotePack = remote.createChangePack()
        try local.applyChangePack(ChangePack(
            key: remotePack.getDocumentKey(),
            checkpoint: Checkpoint(serverSeq: 1, clientSeq: 0),
            isRemoved: false,
            changes: remotePack.getChanges(),
            versionVector: VersionVector.initial
        ))

        XCTAssertEqual(fireCount, 0)
        XCTAssertEqual(local.toSortedJSON(), remote.toSortedJSON())
    }

    // MARK: LocalChangesDroppedEvent

    @MainActor
    func test_localchangesdroppedevent_is_published_with_the_reason_and_dropped_changes() throws {
        // Two distinguishable local changes: the first is a single-op change with a message
        // and no presence update, the second bundles two ops with a presence update — so the
        // per-field projection below cannot pass by coincidence.
        let doc = Document(key: "dropped-event")
        doc.setActor(self.actor)
        try doc.update({ root, _ in
            root.a = "1"
        }, "first edit")
        try doc.update { root, presence in
            root.b = "2"
            root.c = "3"
            presence.set(["cursor": 1])
        }
        let pending = doc.getPendingChangeStructs()
        XCTAssertEqual(pending.count, 2)

        var received: LocalChangesDroppedEvent?
        doc.subscribe { event, _ in
            if let droppedEvent = event as? LocalChangesDroppedEvent {
                received = droppedEvent
            }
        }

        doc.publishLocalChangesDroppedEvent(reason: .epochReanchor, changes: pending)

        let event = try XCTUnwrap(received)
        XCTAssertEqual(event.type, .localChangesDropped)
        XCTAssertEqual(event.value.reason, .epochReanchor)

        // `DroppedChange` is a readable projection of `Change` (whose own fields are internal),
        // so an app can read who made a dropped change, in what order, and how much of it there
        // was. Assert the projection field-by-field against the `Change`s it was built from.
        let changes = event.value.changes
        XCTAssertEqual(changes.count, 2)

        XCTAssertLessThan(changes[0].clientSeq, changes[1].clientSeq, "clientSeq must increase in the order the changes were made")

        XCTAssertEqual(changes[0].actorID, pending[0].id.getActorID())
        XCTAssertEqual(changes[0].clientSeq, pending[0].id.getClientSeq())
        XCTAssertEqual(changes[0].lamport, pending[0].id.getLamport())
        XCTAssertEqual(changes[0].message, "first edit")
        XCTAssertEqual(changes[0].operationCount, 1)
        XCTAssertFalse(changes[0].hasPresenceChange)

        XCTAssertEqual(changes[1].actorID, pending[1].id.getActorID())
        XCTAssertEqual(changes[1].clientSeq, pending[1].id.getClientSeq())
        XCTAssertEqual(changes[1].lamport, pending[1].id.getLamport())
        XCTAssertNil(changes[1].message)
        XCTAssertEqual(changes[1].operationCount, 2)
        XCTAssertTrue(changes[1].hasPresenceChange)
    }

    @MainActor
    func test_localchangesdroppedevent_carries_the_documentpurged_reason() throws {
        let doc = Document(key: "dropped-event-purged")

        var received: LocalChangesDroppedEvent?
        doc.subscribe { event, _ in
            if let droppedEvent = event as? LocalChangesDroppedEvent {
                received = droppedEvent
            }
        }

        doc.publishLocalChangesDroppedEvent(reason: .documentPurged, changes: [])

        let event = try XCTUnwrap(received)
        XCTAssertEqual(event.value.reason, .documentPurged)
        XCTAssertEqual(event.value.changes.count, 0)
    }

    @MainActor
    func test_localchangesdroppedevent_carries_the_restorefailed_reason() throws {
        // Pins the reason a store's bytes could not be decoded at all (as opposed to
        // decoding fine but failing the actor guard, which is `.actorMismatch`).
        let doc = Document(key: "dropped-event-restore-failed")

        var received: LocalChangesDroppedEvent?
        doc.subscribe { event, _ in
            if let droppedEvent = event as? LocalChangesDroppedEvent {
                received = droppedEvent
            }
        }

        doc.publishLocalChangesDroppedEvent(reason: .restoreFailed, changes: [])

        let event = try XCTUnwrap(received)
        XCTAssertEqual(event.value.reason, .restoreFailed)
    }

    // MARK: Full store round trip (Document level)

    @MainActor
    func test_store_round_trip_preserves_pending_changes_for_repush() async throws {
        // The point of the feature: a document's un-acknowledged local changes survive a
        // save/restore cycle through a store, so a resumed session re-pushes exactly what the
        // prior session had not yet gotten acknowledged.
        let store = MemoryDocStore()
        let docKey = "store-roundtrip"

        let original = Document(key: docKey)
        original.setActor(self.actor)
        try original.update { root, _ in
            root.title = "offline edit"
        }
        try original.update { root, _ in
            root.title = "offline edit, again"
        }
        let originalPending = original.getPendingChangeStructs()
        XCTAssertEqual(originalPending.count, 2)

        try await store.save(docKey: docKey, bytes: original.toBytes())

        let loaded = try await store.load(docKey: docKey)
        let bytes = try XCTUnwrap(loaded)
        let restored = try Document.fromBytes(key: docKey, bytes: bytes)

        let restoredPending = restored.getPendingChangeStructs()
        XCTAssertEqual(restoredPending.count, originalPending.count)
        XCTAssertEqual(restored.toSortedJSON(), original.toSortedJSON())
        XCTAssertEqual(
            restoredPending.map { $0.id.getClientSeq() },
            originalPending.map { $0.id.getClientSeq() },
            "the restored pending changes should be the same changes, in the same order, ready to be re-pushed"
        )
    }

    // MARK: Persist ordering

    // `Client.enqueuePersist(_:)` chains writes for one document through `persistTasks` so
    // they cannot land out of order. That method, and the `installOfflinePersistence` wiring
    // that hangs it off `Document.onLocalChange`, are both `private` and unreachable from this
    // target (see the class doc) — reaching them needs a real `attach()`, which needs a
    // server. So this drives the same seam `Client` itself uses, `Document.onLocalChange`
    // (`internal`, reachable via `@testable`), through a hand-rolled queue that mirrors
    // `enqueuePersist`'s chaining exactly: each persist awaits whatever persist for that key is
    // already in flight before it runs. This pins the ordering *property* the fix guarantees;
    // it does not execute `Client`'s own chaining code, which is the gap noted in the report.

    @MainActor
    func test_chained_persists_land_in_order_even_when_the_first_write_is_slower() async throws {
        // given: the first save is deliberately slower than the second, so completion order
        // would invert without chaining — the exact race `enqueuePersist` closes.
        let store = RecordingSlowDocStore(delaysNanoseconds: [100_000_000, 5_000_000])
        let clientKey = "persist-ordering-client"
        let docKey = "persist-ordering"
        // A real Client, driving its own chaining code. Not activated: `enqueuePersist` only
        // needs the store and the key it derives the store key from, so the ordering guarantee
        // is exercised without any RPC.
        let client = Client("http://localhost:8080", ClientOptions(key: clientKey, store: store))
        let storeKey = "/\(clientKey)/\(docKey)"
        let doc = Document(key: docKey)
        doc.setActor(self.actor)
        doc.onLocalChange = { [weak client, weak doc] in
            guard let client, let doc else {
                return
            }
            client.enqueuePersist(doc)
        }

        // when
        try doc.update { root, _ in
            root.value = "first"
        }
        // Yields the MainActor so the first persist actually starts and captures "first" from
        // `doc` before the second edit lands — both `onLocalChange` firings happen
        // synchronously back-to-back otherwise, and the first persist would not get scheduled
        // until after both edits, capturing "second" too. This mirrors a real app: edits are
        // rarely two synchronous calls with no suspension between them.
        try await Task.sleep(nanoseconds: 20_000_000)
        try doc.update { root, _ in
            root.value = "second"
        }
        await client.drainPersists()

        // then: the last write to land carries the newest bytes, not whichever save happened
        // to finish its I/O first.
        let loaded = try await store.load(docKey: storeKey)
        let lastBytes = try XCTUnwrap(loaded)
        let lastDoc = try Document.fromBytes(key: docKey, bytes: lastBytes)
        XCTAssertEqual(lastDoc.toSortedJSON(), "{\"value\":\"second\"}")

        let completionOrder = await store.completionOrder
        XCTAssertEqual(completionOrder.count, 2)
        let firstCompletedDoc = try Document.fromBytes(key: docKey, bytes: completionOrder[0])
        let secondCompletedDoc = try Document.fromBytes(key: docKey, bytes: completionOrder[1])
        XCTAssertEqual(
            firstCompletedDoc.toSortedJSON(), "{\"value\":\"first\"}",
            "chained: the slower first write still completes before the second one starts"
        )
        XCTAssertEqual(secondCompletedDoc.toSortedJSON(), "{\"value\":\"second\"}")
    }

    // MARK: Client.getActorID()

    @MainActor
    func test_getactorid_is_nil_before_activation() {
        // Client's designated init performs no network I/O — it only builds RPC client config
        // — so this is reachable without a server.
        let client = Client("http://localhost:8080")

        XCTAssertNil(client.getActorID())
    }
}

/// A hand-rolled ``SessionLock`` double that grants the first acquire for a given name and
/// refuses every subsequent one until it is released — mimicking two sessions of the same
/// process contending for the same persisted document, the case ``NoopSessionLock`` (by
/// design) does not guard against.
///
/// An `actor` rather than a plain class so `heldNames` is genuinely protected under concurrent
/// `acquire`/`release`, the same guarantee a real cross-process lock would need to provide.
private actor FakeContendedSessionLock: SessionLock {
    /// Releases a lease back to the owning lock. `@unchecked Sendable`: its only mutable-looking
    /// state is a `weak var` to the (itself `Sendable`) owning actor, read only to hop back onto
    /// it; the `name` is immutable.
    private final class Handle: SessionLockHandle, @unchecked Sendable {
        weak var owner: FakeContendedSessionLock?
        let name: String

        init(owner: FakeContendedSessionLock, name: String) {
            self.owner = owner
            self.name = name
        }

        func release() async {
            await self.owner?.release(name: self.name)
        }
    }

    private var heldNames = Set<String>()

    func acquire(name: String) async -> SessionLockHandle? {
        guard !self.heldNames.contains(name) else {
            return nil
        }
        self.heldNames.insert(name)
        return Handle(owner: self, name: name)
    }

    func release(name: String) async {
        self.heldNames.remove(name)
    }
}

/// A ``DocStore`` double whose `save` can be told to sleep before it writes, so a test can
/// force two overlapping saves to *complete* in an order different from the one they were
/// *called* in — the exact race chaining in `Client.enqueuePersist(_:)` closes. Records the
/// bytes of every save in the order it completed, plus the last one to land, so a test can
/// assert on both.
private actor RecordingSlowDocStore: DocStore {
    /// Sleep durations to consume, one per call to `save`, in call order. Falls back to no
    /// delay once exhausted.
    private var delaysNanoseconds: [UInt64]
    private(set) var completionOrder = [Data]()
    private var stored: Data?

    init(delaysNanoseconds: [UInt64]) {
        self.delaysNanoseconds = delaysNanoseconds
    }

    func save(docKey: String, bytes: Data) async throws {
        let delay = self.delaysNanoseconds.isEmpty ? 0 : self.delaysNanoseconds.removeFirst()
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
        }
        self.completionOrder.append(bytes)
        self.stored = bytes
    }

    func load(docKey: String) async throws -> Data? {
        self.stored
    }

    func remove(docKey: String) async throws {
        self.stored = nil
    }
}
