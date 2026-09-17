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
        let doc = Document(key: "dropped-event")
        doc.setActor(self.actor)
        try doc.update { root, _ in
            root.a = "1"
        }
        try doc.update { root, _ in
            root.b = "2"
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
        XCTAssertEqual(event.value.changes.count, 2)
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
