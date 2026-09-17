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
final class OfflinePersistenceTests: XCTestCase {
    let rpcAddress = "http://localhost:8080"

    /// A ``SessionLock`` that grants a name once and refuses it until released, standing in for
    /// the cross-process lock an App Group deployment would supply.
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
