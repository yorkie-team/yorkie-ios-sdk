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

// Port of yorkie-js-sdk packages/sdk/test/unit/client/resync_test.ts (yorkie-js-sdk#1463).
//
// The JS file drives a fake rpcClient; here a real server answers and the mock-error seam
// (`setMockError`) plays the webhook that refuses writes. The request observer and the response
// hook (`observeRequests` / `setResponseHook`) read back what went on the wire and open the
// re-anchor window from inside the detach RPC.
//
// One deliberate difference: the JS fake never acks the attach-time presence change, so the data
// loss event carries 2 changes there. A real server acks it with the attach response, so only the
// refused edit is left in the queue and the event carries 1.
//
// Requires a yorkie server at localhost:8080.

/// Builds the error an auth webhook denial produces, shaped so `errorCodeOf` and
/// `errorMetadataOf` read the code and reason out of the error details exactly as they do for a
/// real one.
private func permissionDeniedError(_ reason: String) -> ConnectError {
    var info = Google_Rpc_ErrorInfo()
    info.metadata = ["code": YorkieError.Code.errPermissionDenied.rawValue, "reason": reason]
    let payload = (try? info.serializedData()) ?? Data()
    return ConnectError(
        code: .permissionDenied,
        message: "permission denied",
        details: [ConnectError.Detail(type: "google.rpc.ErrorInfo", payload: payload)]
    )
}

/// A value shared between the test body and the seam closures, which are not main-actor bound.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) {
        self.stored = value
    }

    var value: T {
        get { self.lock.withLock { self.stored } }
        set { self.lock.withLock { self.stored = newValue } }
    }
}

/// A latch a test closes around a seam closure: `wait()` suspends until `open()` is called.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            if self.isOpen {
                self.lock.unlock()
                continuation.resume()
            } else {
                self.waiter = continuation
                self.lock.unlock()
            }
        }
    }

    func open() {
        self.lock.lock()
        self.isOpen = true
        let pending = self.waiter
        self.waiter = nil
        self.lock.unlock()
        pending?.resume()
    }
}

final class ResyncIntegrationTests: XCTestCase {
    let rpcAddress = "http://localhost:8080"

    private static let pushPull = YorkieServiceClient.Metadata.Methods.pushPullChanges
    private static let attach = YorkieServiceClient.Metadata.Methods.attachDocument
    private static let detach = YorkieServiceClient.Metadata.Methods.detachDocument

    @MainActor
    private func makeClient() async throws -> Client {
        let client = Client(self.rpcAddress, isMockingEnabled: true)
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }
        return client
    }

    private var docKey: String {
        "\(Date().timeIntervalSince1970)-\(self.name)".toDocKey
    }

    @MainActor
    func test_discards_refused_changes_and_reanchors_the_same_document() async throws {
        // given: a manual-mode document with a presence and an edit the webhook refused.
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)
        let attaches = Box(0)
        let detachChangeCounts = Box([Int]())
        client.observeRequests(for: Self.attach) { _ in attaches.value += 1 }
        client.observeRequests(for: Self.detach) { request in
            let count = (request as? Yorkie_V1_DetachDocumentRequest)?.changePack.changes.count ?? -1
            detachChangeCounts.value += [count]
        }
        try await client.attach(doc, ["cursor": 7], .manual)
        try doc.update { root, _ in
            root.text = "refused edit"
        }
        XCTAssertEqual(doc.getRoot().text as? String, "refused edit")

        // when
        let discarded = try await client.resync(doc, discardLocalChanges: true)

        // then: the caller gets the refused work back.
        XCTAssertTrue(discarded.contains { $0.operationCount > 0 }, "the refused content change is handed back")

        // The detach pack mints nothing: no queue and no presence clear, so no clientSeq goes out
        // over the hole the discard left.
        XCTAssertEqual(detachChangeCounts.value, [0])

        // The same instance is attached again, re-anchored on the server state.
        XCTAssertEqual(attaches.value, 2)
        XCTAssertEqual(doc.status, .attached)
        XCTAssertNil(doc.getRoot().text)
        // Presence is not what the server refused, so it is carried over.
        XCTAssertEqual(doc.getMyPresence()?["cursor"] as? Int, 7)
        XCTAssertTrue(client.getCondition(.syncLoop))
        XCTAssertTrue(doc.isMintable)

        try await client.detach(doc)
    }

    @MainActor
    func test_reanchors_a_realtime_document_under_the_sync_mode_it_had() async throws {
        // given: a realtime document, and an observer watching the same key.
        let key = self.docKey
        let client = try await self.makeClient()
        let doc = Document(key: key)
        try await client.attach(doc, [:], .realtime)

        let observer = try await self.makeClient()
        let observerDoc = Document(key: key)
        try await observer.attach(observerDoc, [:], .realtime)

        try doc.update { root, _ in
            root.text = "refused edit"
        }

        // The webhook denies the push the sync loop sends. `handleConnectError` does not retry
        // ErrPermissionDenied, so the loop stops and the document is wedged until a resync.
        let denied = self.expectation(description: "auth-error published for the denied push")
        denied.assertForOverFulfill = false
        let method = Box("")
        let reason = Box("")
        doc.subscribeAuthError { event, _ in
            guard let event = event as? AuthErrorEvent else { return }
            method.value = event.value.method.description
            reason.value = event.value.reason
            denied.fulfill()
        }
        client.setMockError(for: Self.pushPull, error: permissionDeniedError("document is locked"))
        await self.fulfillment(of: [denied], timeout: 10)
        XCTAssertEqual(method.value, "PushPull")
        XCTAssertEqual(reason.value, "document is locked")
        XCTAssertFalse(client.getCondition(.syncLoop))

        // when
        let discarded = try await client.resync(doc, discardLocalChanges: true)

        // then: re-attached as realtime rather than quietly downgraded, and the loop is running.
        XCTAssertFalse(discarded.isEmpty)
        XCTAssertEqual(client.getDocumentAttachment(key)?.syncMode, .realtime)
        XCTAssertTrue(client.getCondition(.syncLoop))
        XCTAssertEqual(doc.status, .attached)
        XCTAssertNil(doc.getRoot().text)

        // And it syncs again with no help from the test: an edit after the recovery reaches the
        // observer, so the server accepted it (no ErrInvalidClientSeq from a minted hole).
        let arrived = self.expectation(description: "observer sees the edit made after the re-anchor")
        arrived.assertForOverFulfill = false
        observerDoc.subscribe { event, document in
            if event is RemoteChangeEvent, document.getRoot().text as? String == "edited after the re-anchor" {
                arrived.fulfill()
            }
        }
        try doc.update { root, _ in
            root.text = "edited after the re-anchor"
        }
        await self.fulfillment(of: [arrived], timeout: 10)

        try await client.detach(doc)
        try await observer.detach(observerDoc)
    }

    @MainActor
    func test_reports_the_discarded_changes_as_a_data_loss_event() async throws {
        // given
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)
        try await client.attach(doc, ["cursor": 1], .manual)
        try doc.update { root, _ in
            root.text = "refused edit"
        }

        var dropped = [LocalChangesDroppedValue]()
        doc.subscribe { event, _ in
            if let event = event as? LocalChangesDroppedEvent {
                dropped.append(event.value)
            }
        }

        // when
        try await client.resync(doc, discardLocalChanges: true)

        // then: the loss reaches the app through the same event the other discard paths use.
        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(dropped.first?.reason, .writeDenied)
        // One change, where the JS test expects two: its fake never acks the attach-time presence
        // change, so that change is still queued there. A real server acks it with the attach
        // response, leaving only the refused edit.
        XCTAssertEqual(dropped.first?.changes.count, 1)

        try await client.detach(doc)
    }

    @MainActor
    func test_restores_the_queue_when_the_detach_is_itself_refused() async throws {
        // given
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)
        try await client.attach(doc, [:], .manual)
        try doc.update { root, _ in
            root.text = "refused edit"
        }
        let pendingBefore = doc.getPendingChangeStructs().map { $0.id.getClientSeq() }

        var dropped = 0
        doc.subscribe { event, _ in
            if event is LocalChangesDroppedEvent {
                dropped += 1
            }
        }
        client.setMockError(for: Self.detach, error: permissionDeniedError("document is locked"))

        // when
        var failed = false
        do {
            try await client.resync(doc, discardLocalChanges: true)
        } catch {
            failed = true
        }

        // then: a refused detach must not destroy the work. The document is left as it was found
        // and the call can be retried.
        XCTAssertTrue(failed)
        XCTAssertEqual(doc.status, .attached)
        XCTAssertEqual(doc.getPendingChangeStructs().map { $0.id.getClientSeq() }, pendingBefore)
        XCTAssertEqual(doc.getRoot().text as? String, "refused edit")
        XCTAssertEqual(dropped, 0, "nothing was lost, so nothing is reported as lost")

        // "Exactly as it was found" includes writable: the hole was filled back in.
        try doc.update { root, _ in
            root.text = "edited after the rollback"
        }
        XCTAssertEqual(doc.getRoot().text as? String, "edited after the rollback")

        // And the retry goes through once the webhook relents.
        try await client.resync(doc, discardLocalChanges: true)
        XCTAssertEqual(doc.status, .attached)
        try await client.detach(doc)
    }

    @MainActor
    func test_waits_for_an_in_flight_sync_before_it_detaches() async throws {
        // given: a sync suspended inside its PushPull response, holding the client's sync lock.
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)
        try await client.attach(doc, [:], .manual)
        try doc.update { root, _ in
            root.text = "refused edit"
        }

        let detaches = Box(0)
        client.observeRequests(for: Self.detach) { _ in detaches.value += 1 }
        let inFlight = Gate()
        let release = Gate()
        client.setResponseHook(for: Self.pushPull) { _ in
            inFlight.open()
            await release.wait()
        }
        let sync = Task { @MainActor in try await client.sync(doc) }
        await inFlight.wait()
        client.setResponseHook(for: Self.pushPull, nil)

        // when: the resync is asked for while the sync is still in flight.
        let resync = Task { @MainActor in try await client.resync(doc, discardLocalChanges: true) }
        try await Task.sleep(nanoseconds: 300_000_000)

        // then: it has not touched the document yet.
        XCTAssertEqual(detaches.value, 0, "the detach waits for the in-flight sync")

        release.open()
        _ = try await sync.value
        _ = try await resync.value
        XCTAssertEqual(detaches.value, 1)
        XCTAssertEqual(doc.status, .attached)

        try await client.detach(doc)
    }

    @MainActor
    func test_resyncs_with_the_sync_mode_in_force_when_it_gets_the_lock() async throws {
        // given: a resync queued behind an in-flight sync, which then has its mode changed.
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)
        try await client.attach(doc, [:], .manual)
        try doc.update { root, _ in
            root.text = "refused edit"
        }

        let inFlight = Gate()
        let release = Gate()
        client.setResponseHook(for: Self.pushPull) { _ in
            inFlight.open()
            await release.wait()
        }
        let sync = Task { @MainActor in try await client.sync(doc) }
        await inFlight.wait()
        client.setResponseHook(for: Self.pushPull, nil)

        let resync = Task { @MainActor in try await client.resync(doc, discardLocalChanges: true) }
        try await Task.sleep(nanoseconds: 300_000_000)

        // when: the app changes the mode while the resync waits for the lock.
        _ = try client.changeSyncMode(doc, .polling)
        release.open()
        _ = try await sync.value
        _ = try await resync.value

        // then: the re-attach restores the mode the document has now, not the one it had when
        // the resync was called.
        XCTAssertEqual(client.getDocumentAttachment(doc.getKey())?.syncMode, .polling)

        try await client.detach(doc)
    }

    @MainActor
    func test_two_concurrent_resyncs_each_run_against_the_live_attachment() async throws {
        // given
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)
        let attaches = Box(0)
        let detachedIDs = Box([String]())
        client.observeRequests(for: Self.attach) { _ in attaches.value += 1 }
        client.observeRequests(for: Self.detach) { request in
            detachedIDs.value += [(request as? Yorkie_V1_DetachDocumentRequest)?.documentID ?? ""]
        }
        try await client.attach(doc, ["cursor": 3], .manual)
        let firstID = try XCTUnwrap(client.getDocumentAttachment(doc.getKey())).resourceID
        try doc.update { root, _ in
            root.text = "refused edit"
        }

        // when: the recovery fires twice, as an auth-error handler can.
        let first = Task { @MainActor in try await client.resync(doc, discardLocalChanges: true) }
        let second = Task { @MainActor in try await client.resync(doc, discardLocalChanges: true) }
        let firstDropped = try await first.value
        _ = try await second.value

        // then: both ran to the end, one after the other, and the second worked on the attachment
        // the first one left rather than the one it was called against.
        XCTAssertEqual(attaches.value, 3)
        XCTAssertEqual(detachedIDs.value.count, 2)
        XCTAssertEqual(detachedIDs.value, [firstID, firstID], "the server document is the same; each detach is for it")
        let liveAttachment = try XCTUnwrap(client.getDocumentAttachment(doc.getKey()))
        XCTAssertEqual(doc.status, .attached)
        XCTAssertEqual(liveAttachment.syncMode, .manual)
        XCTAssertEqual(doc.getMyPresence()?["cursor"] as? Int, 3)
        XCTAssertTrue(doc.isMintable)
        XCTAssertFalse(firstDropped.isEmpty)

        try await client.detach(doc)
    }

    @MainActor
    func test_refuses_an_edit_minted_inside_the_resync_window() async throws {
        // given: an edit is attempted while the detach RPC is in flight, the widest part of the
        // window.
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)
        let refusal = Box<YorkieError.Code?>(nil)
        let detachChangeCounts = Box([Int]())
        client.observeRequests(for: Self.detach) { request in
            let count = (request as? Yorkie_V1_DetachDocumentRequest)?.changePack.changes.count ?? -1
            detachChangeCounts.value += [count]
        }
        client.setResponseHook(for: Self.detach) { _ in
            await MainActor.run {
                do {
                    try doc.update { root, _ in
                        root.text = "minted mid-resync"
                    }
                } catch {
                    refusal.value = (error as? YorkieError)?.code
                }
            }
        }
        try await client.attach(doc, [:], .manual)
        try doc.update { root, _ in
            root.text = "refused edit"
        }

        // when
        try await client.resync(doc, discardLocalChanges: true)

        // then: refused loudly, rather than wedging the detach with ErrInvalidClientSeq or being
        // wiped by the re-anchor with nothing reported.
        XCTAssertEqual(refusal.value, .errRefused)
        XCTAssertEqual(detachChangeCounts.value, [0], "the refused edit never reached the detach pack")

        // The window closes with the re-anchor: the document is writable again.
        XCTAssertEqual(doc.status, .attached)
        try doc.update { root, _ in
            root.text = "edited after the re-anchor"
        }
        XCTAssertEqual(doc.getRoot().text as? String, "edited after the re-anchor")

        try await client.detach(doc)
    }

    @MainActor
    func test_keeps_detach_and_the_undo_predicate_usable_inside_the_window() async throws {
        // given
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)
        let detachChangeCounts = Box([Int]())
        client.observeRequests(for: Self.detach) { request in
            let count = (request as? Yorkie_V1_DetachDocumentRequest)?.changePack.changes.count ?? -1
            detachChangeCounts.value += [count]
        }
        try await client.attach(doc, [:], .manual)
        try doc.update { root, _ in
            root.text = "refused edit"
        }
        XCTAssertTrue(doc.canUndo)

        // The state resync leaves between the discard and the re-anchor, reached directly so the
        // window can be inspected while it is open.
        _ = doc.discardLocalChanges()

        // `canUndo` answers for `undo`, which now refuses.
        XCTAssertFalse(doc.canUndo)

        // `detach` mints a presence clear, which `update` refuses in this window. The clear is a
        // courtesy, so it is skipped rather than failing the detach over it.
        try await client.detach(doc)
        XCTAssertEqual(doc.status, .detached)
        XCTAssertEqual(detachChangeCounts.value, [0], "the presence clear was skipped, not minted over the hole")
    }

    @MainActor
    func test_refuses_a_resync_that_does_not_opt_into_discarding() async throws {
        // given
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)
        try await client.attach(doc, [:], .manual)

        // when / then
        do {
            try await client.resync(doc, discardLocalChanges: false)
            XCTFail("expected resync to refuse")
        } catch let error as YorkieError {
            XCTAssertEqual(error.code, .errInvalidArgument)
            XCTAssertTrue(error.message.contains("discardLocalChanges"))
        }

        try await client.detach(doc)
    }

    @MainActor
    func test_refuses_a_resync_for_a_document_that_is_not_attached() async throws {
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)

        do {
            try await client.resync(doc, discardLocalChanges: true)
            XCTFail("expected resync to refuse")
        } catch let error as YorkieError {
            XCTAssertEqual(error.code, .errNotAttached)
        }
    }

    @MainActor
    func test_publishes_auth_error_for_a_pushpull_the_webhook_denied() async throws {
        // given
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)
        try await client.attach(doc, [:], .manual)
        try doc.update { root, _ in
            root.text = "refused edit"
        }

        let published = self.expectation(description: "auth-error published")
        published.assertForOverFulfill = false
        let method = Box("")
        let reason = Box("")
        doc.subscribeAuthError { event, _ in
            guard let event = event as? AuthErrorEvent else { return }
            method.value = event.value.method.description
            reason.value = event.value.reason
            published.fulfill()
        }
        client.setMockError(for: Self.pushPull, error: permissionDeniedError("document is locked"))

        // when
        _ = try? await client.sync()
        await self.fulfillment(of: [published], timeout: 10)

        // then: a refused write is reported as what it is, not as a bare sync failure the app
        // cannot tell from a network error.
        XCTAssertEqual(method.value, "PushPull")
        XCTAssertEqual(reason.value, "document is locked")

        try await client.resync(doc, discardLocalChanges: true)
        try await client.detach(doc)
    }
}
