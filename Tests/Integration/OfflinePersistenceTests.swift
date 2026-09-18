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

import Connect
import SwiftProtobuf
import XCTest
@testable import Yorkie

// Port of yorkie-js-sdk packages/sdk/test/integration/offline_persistence_test.ts at v0.7.20
// (yorkie-js-sdk#1338).
//
// These exercise the parts of offline persistence that only a real server can prove: that a
// resumed document's un-pushed changes actually reach the server, that the session lease and the
// stored copy are torn down on the paths that end an attachment, and that the duplicate-attach
// guard holds. The unit suites cover the seams (store, lock, envelope, events); this covers the
// behaviour those seams exist for.
//
// Requires a yorkie server at localhost:8080.
/// A ``SessionLock`` that grants a name once and refuses it until released, standing in for
/// the cross-process lock an App Group deployment would supply.
/// Builds the `ErrClientNotFound` the server sends when it no longer knows a client, shaped so
/// `errorCodeOf` reads the code out of the error details exactly as it does for a real one.
private func clientNotFoundError() -> ConnectError {
    var info = Google_Rpc_ErrorInfo()
    info.metadata = ["code": YorkieError.Code.errClientNotFound.rawValue]
    let payload = (try? info.serializedData()) ?? Data()
    return ConnectError(
        code: .failedPrecondition,
        message: "client not found",
        details: [ConnectError.Detail(type: "google.rpc.ErrorInfo", payload: payload)]
    )
}

private actor CountingSessionLock: SessionLock {
    private var held = Set<String>()
    private(set) var releaseCount = 0

    private struct Handle: SessionLockHandle {
        let name: String
        let owner: CountingSessionLock

        func release() async {
            await self.owner.free(self.name)
        }
    }

    func acquire(name: String) async -> SessionLockHandle? {
        guard self.held.contains(name) == false else {
            return nil
        }
        self.held.insert(name)
        return Handle(name: name, owner: self)
    }

    fileprivate func free(_ name: String) {
        guard self.held.contains(name) else {
            return
        }
        self.held.remove(name)
        self.releaseCount += 1
    }

    func isHeld(_ name: String) -> Bool {
        self.held.contains(name)
    }
}

final class OfflinePersistenceTests: XCTestCase {
    let rpcAddress = "http://localhost:8080"

    // MARK: Resume

    // The point of the whole feature: edits made while the push cannot complete survive the
    // client going away, and the next session pushes them to the server for real.
    @MainActor
    func test_resumes_unpushed_changes_into_a_later_session() async throws {
        // given: a client that edits in manual mode and never syncs, so the changes stay
        // un-acknowledged exactly as they would be offline.
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let store = MemoryDocStore()
        let clientKey = UUID().uuidString

        let first = Client(self.rpcAddress, ClientOptions(key: clientKey, store: store))
        try await first.activate()
        let firstDoc = Document(key: docKey)
        try await first.attach(firstDoc, [:], .manual)
        try await firstDoc.update { root, _ in
            root.title = "written offline"
        }

        // when: the session ends without ever syncing, and a new client resumes from the store.
        // deactivate, not detach: detach deliberately discards the stored copy.
        try await first.deactivate()

        let second = Client(self.rpcAddress, ClientOptions(key: clientKey, store: store))
        try await second.activate()
        let secondDoc = Document(key: docKey)
        try await second.attach(secondDoc, [:], .manual)
        try await second.sync()
        self.addTeardownBlock { try? await second.deactivate() }

        // then: the resumed document carries the edit, and a third client reading the document
        // fresh from the server sees it too — so it really was pushed, not just restored locally.
        XCTAssertEqual((secondDoc.getRoot().title as? String), "written offline")

        let observer = Client(self.rpcAddress)
        try await observer.activate()
        let observerDoc = Document(key: docKey)
        try await observer.attach(observerDoc, [:], .manual)
        self.addTeardownBlock { try? await observer.deactivate() }

        XCTAssertEqual((observerDoc.getRoot().title as? String), "written offline")
    }

    // A sync that is merely acked drains `localChanges` without appending one, so the
    // local-change hook never fires. Without the post-sync persist the stored envelope would keep
    // an already-pushed change under a stale checkpoint and the next resume would re-push it.
    @MainActor
    func test_persists_the_advanced_checkpoint_after_a_sync() async throws {
        // given
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let store = MemoryDocStore()
        let clientKey = UUID().uuidString

        let client = Client(self.rpcAddress, ClientOptions(key: clientKey, store: store))
        try await client.activate()
        let doc = Document(key: docKey)
        try await client.attach(doc, [:], .manual)
        try await doc.update { root, _ in
            root.title = "pushed"
        }

        // when: the change is pushed and acknowledged, with no further local edit afterwards.
        try await client.sync()
        try await client.deactivate()

        // then: the stored envelope reflects the post-sync state — nothing left pending.
        let storeKey = "/\(clientKey)/\(docKey)"
        let bytes = try await store.load(docKey: storeKey)
        let persisted = try XCTUnwrap(bytes)
        let restored = try Document.fromBytes(key: docKey, bytes: persisted)
        XCTAssertTrue(restored.getPendingChangeStructs().isEmpty,
                      "an acknowledged change must not stay pending in the stored envelope")
    }

    // A stored copy that cannot be restored must not take the caller's own work with it.
    // `restoreFromBytes` is all-or-nothing and throws before touching the document, so a reset
    // on that path destroys edits the app made before attaching — on the very code path that
    // exists to prevent data loss.
    @MainActor
    func test_an_unusable_stored_copy_does_not_discard_the_callers_own_edits() async throws {
        // given: a store holding bytes that cannot be decoded, under the key this client reads.
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let store = MemoryDocStore()
        let clientKey = UUID().uuidString
        try await store.save(docKey: "/\(clientKey)/\(docKey)", bytes: Data([0xDE, 0xAD, 0xBE, 0xEF]))

        let client = Client(self.rpcAddress, ClientOptions(key: clientKey, store: store))
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }

        // and: a document the app has already edited, before it is ever attached.
        let doc = Document(key: docKey)
        var droppedReasons = [LocalChangesDroppedValue.Reason]()
        await doc.subscribe { event, _ in
            if let dropped = event as? LocalChangesDroppedEvent {
                droppedReasons.append(dropped.value.reason)
            }
        }
        try await doc.update { root, _ in
            root.title = "written before attach"
        }

        // when: the attach finds the unusable stored copy.
        try await client.attach(doc, [:], .manual)
        try await client.sync()

        // then: the app's edit survived and reached the server, and the unusable copy was
        // reported as undecodable rather than as another identity's store.
        XCTAssertEqual((doc.getRoot().title as? String), "written before attach")
        XCTAssertEqual(droppedReasons, [.restoreFailed])

        let observer = Client(self.rpcAddress)
        try await observer.activate()
        self.addTeardownBlock { try? await observer.deactivate() }
        let observerDoc = Document(key: docKey)
        try await observer.attach(observerDoc, [:], .manual)
        XCTAssertEqual((observerDoc.getRoot().title as? String), "written before attach")
    }

    // MARK: Lease lifetime

    // A lease held past the end of an attachment locks the document key out of every later
    // session. Deactivate ends the client's claim on all of its documents at once.
    @MainActor
    func test_deactivate_releases_the_session_lease() async throws {
        // given
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let store = MemoryDocStore()
        let lock = CountingSessionLock()
        let clientKey = UUID().uuidString

        let client = Client(self.rpcAddress, ClientOptions(key: clientKey, store: store, sessionLock: lock))
        try await client.activate()
        let doc = Document(key: docKey)
        try await client.attach(doc, [:], .manual)

        let leaseName = "yorkie-session:/\(clientKey)/\(docKey)"
        let heldWhileAttached = await lock.isHeld(leaseName)
        XCTAssertTrue(heldWhileAttached, "the lease should be held for the attachment's lifetime")

        // when
        try await client.deactivate()

        // then: the lease is free, so a later session can resume the document.
        let heldAfterDeactivate = await lock.isHeld(leaseName)
        XCTAssertFalse(heldAfterDeactivate, "deactivate must not leak the session lease")

        let next = Client(self.rpcAddress, ClientOptions(key: clientKey, store: store, sessionLock: lock))
        try await next.activate()
        let nextDoc = Document(key: docKey)
        try await next.attach(nextDoc, [:], .manual)
        self.addTeardownBlock { try? await next.deactivate() }
    }

    // Detach gives the document up deliberately, so unlike deactivate it also drops the stored
    // copy — there are no un-pushed changes left that a later session should resume.
    @MainActor
    func test_detach_releases_the_lease_and_clears_the_stored_copy() async throws {
        // given
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let store = MemoryDocStore()
        let lock = CountingSessionLock()
        let clientKey = UUID().uuidString

        let client = Client(self.rpcAddress, ClientOptions(key: clientKey, store: store, sessionLock: lock))
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }
        let doc = Document(key: docKey)
        try await client.attach(doc, [:], .manual)
        try await doc.update { root, _ in
            root.title = "detached"
        }

        // when
        try await client.detach(doc)

        // then
        let storeKey = "/\(clientKey)/\(docKey)"
        let remaining = try await store.load(docKey: storeKey)
        XCTAssertNil(remaining, "detach should not leave a stored copy behind")

        let leaseName = "yorkie-session:/\(clientKey)/\(docKey)"
        let stillHeld = await lock.isHeld(leaseName)
        XCTAssertFalse(stillHeld, "detach must release the session lease")
    }

    // The lease is what keeps two sessions from resuming the same persisted document and both
    // re-pushing the same un-acknowledged changes.
    @MainActor
    func test_a_second_session_cannot_resume_a_leased_document() async throws {
        // given
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let store = MemoryDocStore()
        let lock = CountingSessionLock()
        let clientKey = UUID().uuidString

        let first = Client(self.rpcAddress, ClientOptions(key: clientKey, store: store, sessionLock: lock))
        try await first.activate()
        self.addTeardownBlock { try? await first.deactivate() }
        try await first.attach(Document(key: docKey), [:], .manual)

        // when: a second client sharing the same store and lock attaches the same key.
        let second = Client(self.rpcAddress, ClientOptions(key: clientKey, store: store, sessionLock: lock))
        try await second.activate()
        self.addTeardownBlock { try? await second.deactivate() }

        // then
        do {
            try await second.attach(Document(key: docKey), [:], .manual)
            XCTFail("the second session should be refused while the first holds the lease")
        } catch let error as YorkieError {
            XCTAssertEqual(error.code, .errInvalidArgument)
        }
    }

    // The server evicting the client record tears the client down through
    // `handleConnectError`, not through `deactivate()`. That path drops the attachments — and
    // with them the only reference to each lease — so a lease not released there is never
    // released at all, and `deactivate()` will not do it either, because it early-returns once
    // the status is already deactivated.
    @MainActor
    func test_an_internal_teardown_releases_the_session_lease() async throws {
        // given: an attached document whose lease is held.
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let store = MemoryDocStore()
        let lock = CountingSessionLock()
        let clientKey = UUID().uuidString

        let client = Client(self.rpcAddress,
                            ClientOptions(key: clientKey, store: store, sessionLock: lock),
                            isMockingEnabled: true)
        try await client.activate()
        let doc = Document(key: docKey)
        try await client.attach(doc, [:], .manual)

        let leaseName = "yorkie-session:/\(clientKey)/\(docKey)"
        let heldWhileAttached = await lock.isHeld(leaseName)
        XCTAssertTrue(heldWhileAttached)

        // when: the next sync reports that the server no longer knows this client, which is
        // what drives the internal teardown rather than an app-initiated deactivate.
        client.setMockError(for: YorkieServiceClient.Metadata.Methods.pushPullChanges,
                            error: clientNotFoundError())
        try? await client.sync()

        // then: the teardown ran, and it did not strand the lease.
        XCTAssertFalse(client.isActive, "ErrClientNotFound should deactivate the client")
        let heldAfter = await lock.isHeld(leaseName)
        XCTAssertFalse(heldAfter, "an internal teardown must not leak the session lease")
    }

    // Attach can still fail after the RPC succeeds and the attachment has taken ownership of
    // the lease — the watch loop, the initialization wait timing out, the `initialRoot` update.
    // Left in place behind a thrown attach, that holds the lease for the process lifetime and
    // keeps writing for a document the caller believes is not attached.
    //
    // This drives `rollBackFailedAttach` directly, on a genuinely attached document, and
    // asserts it undoes all three: the attachment, the lease, and the persist hook. The catch
    // block that calls it could not be reached from here — a mocked watch failure still signals
    // initialization, so the attach succeeds rather than throwing — so the wiring itself is
    // covered by reading, not by this test.
    @MainActor
    func test_rolling_back_a_failed_attach_releases_everything_it_took() async throws {
        // given: an attached document, persisting, holding its lease.
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let store = MemoryDocStore()
        let lock = CountingSessionLock()
        let clientKey = UUID().uuidString

        let client = Client(self.rpcAddress, ClientOptions(key: clientKey, store: store, sessionLock: lock))
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }

        let doc = Document(key: docKey)
        try await client.attach(doc, [:], .manual)

        let leaseName = "yorkie-session:/\(clientKey)/\(docKey)"
        let heldWhileAttached = await lock.isHeld(leaseName)
        XCTAssertTrue(heldWhileAttached)
        XCTAssertNotNil(doc.onLocalChange)
        XCTAssertTrue(client.has(docKey))

        // when
        await client.rollBackFailedAttach(doc)

        // then: nothing the attach took is still held.
        XCTAssertFalse(client.has(docKey), "the attachment must not survive the rollback")
        let stillHeld = await lock.isHeld(leaseName)
        XCTAssertFalse(stillHeld, "the session lease must not survive the rollback")
        XCTAssertNil(doc.onLocalChange, "the document must stop persisting")
    }

    // MARK: Duplicate attach (yorkie-js-sdk#1337)

    // Both calls run against a store, so each suspends in the offline-resume preamble before
    // reaching the server. The in-flight marker has to be set before that suspension or both
    // pass the guard and the duplicate surfaces as a misleading ErrClientNotFound that
    // deactivates the whole client.
    @MainActor
    func test_concurrent_attach_of_the_same_key_is_rejected() async throws {
        // given
        let docKey = "\(Date().timeIntervalSince1970)-\(self.description)".toDocKey
        let client = Client(self.rpcAddress, ClientOptions(key: UUID().uuidString, store: MemoryDocStore()))
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }

        // when: two attaches of the same key are started before either completes.
        let outcomes = await withTaskGroup(of: YorkieError?.self) { group -> [YorkieError?] in
            for _ in 0 ..< 2 {
                group.addTask { @MainActor in
                    do {
                        _ = try await client.attach(Document(key: docKey), [:], .manual)
                        return nil
                    } catch let error as YorkieError {
                        return error
                    } catch {
                        return YorkieError(code: .errUnexpected, message: "\(error)")
                    }
                }
            }
            var collected = [YorkieError?]()
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        let failures = outcomes.compactMap { $0 }.count
        let alreadyAttached = outcomes.compactMap { $0 }.filter { $0.code == .errAlreadyAttached }.count

        // then: exactly one succeeded, and the loser was rejected locally rather than by the
        // server — the client is still usable.
        XCTAssertEqual(failures, 1, "exactly one of the two concurrent attaches should fail")
        XCTAssertEqual(alreadyAttached, 1, "the duplicate must be rejected as already-attached")
        XCTAssertTrue(client.isActive, "a rejected duplicate must not deactivate the client")
    }
}
