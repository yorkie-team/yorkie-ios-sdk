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

// Port of yorkie-js-sdk packages/sdk/test/unit/client/write_rejected_test.ts (yorkie-js-sdk#1462).
//
// The JS file drives a fake rpcClient; here a real server answers and a request-matching mock error
// (`setMockError(for:error:where:)`) plays the size gate, so one document can be refused while
// another syncs normally. `observeRequests` reads back the pushes that were accepted.
//
// Requires a yorkie server at localhost:8080.

/// Builds the `ResourceExhausted` error the server returns when its size gate refuses a push, with
/// the Yorkie code in the error detail metadata where `errorCodeOf` reads it.
private func writeRejection(_ code: YorkieError.Code, _ message: String) -> ConnectError {
    var info = Google_Rpc_ErrorInfo()
    info.metadata = ["code": code.rawValue]
    let payload = (try? info.serializedData()) ?? Data()
    return ConnectError(
        code: .resourceExhausted,
        message: message,
        details: [ConnectError.Detail(type: "google.rpc.ErrorInfo", payload: payload)]
    )
}

/// A value shared between the test body and the seam closures, which are not main-actor bound.
private final class Shared<T>: @unchecked Sendable {
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

final class WriteRejectedIntegrationTests: XCTestCase {
    let rpcAddress = "http://localhost:8080"

    private static let pushPull = YorkieServiceClient.Metadata.Methods.pushPullChanges

    @MainActor
    private func makeClient() async throws -> Client {
        let client = Client(self.rpcAddress, isMockingEnabled: true)
        try await client.activate()
        self.addTeardownBlock { try? await client.deactivate() }
        return client
    }

    private func docKey(_ suffix: String = "") -> String {
        "\(Date().timeIntervalSince1970)-\(self.name)\(suffix)".toDocKey
    }

    @MainActor
    func test_reports_each_rejection_code_to_the_app_and_does_not_retry_it() async throws {
        let cases: [(YorkieError.Code, WriteRejectedValue.Code, String)] = [
            (.errDocumentSizeExceedsLimit, .documentSizeExceedsLimit, "document size exceeds limit"),
            (.errChangeTooLarge, .changeTooLarge, "change is too large")
        ]

        for (code, expected, message) in cases {
            // given
            let client = try await self.makeClient()
            let doc = Document(key: self.docKey(code.rawValue))
            try await client.attach(doc, [:], .manual)
            let events = Shared([DocEvent]())
            doc.subscribe { event, _ in events.value += [event] }
            try doc.update { root, _ in
                root.text = "over the limit"
            }
            let error = writeRejection(code, message)
            client.setMockError(for: Self.pushPull, error: error)

            // when
            do {
                _ = try await client.sync(doc)
                XCTFail("the push should be rejected")
            } catch let thrown as ConnectError {
                XCTAssertEqual(thrown.message, message)
            }

            // then: reported once, with the code, the server's message and the method.
            let rejected = events.value.compactMap { $0 as? WriteRejectedEvent }
            XCTAssertEqual(rejected.count, 1, "the rejection is reported once")
            XCTAssertEqual(rejected.first?.value, WriteRejectedValue(code: expected, reason: message, method: "PushPull"))

            // A listener that only watches `sync` keeps working.
            let failed = events.value.contains { ($0 as? SyncStatusChangedEvent)?.value == .syncFailed }
            XCTAssertTrue(failed, "sync-failed is published as well")

            // Retrying cannot succeed: the server re-measures the same pack and refuses it again.
            let retry = await client.handleConnectError(error)
            XCTAssertFalse(retry, "the sync loop stops instead of resending")

            _ = try? await client.resync(doc, discardLocalChanges: true)
            try await client.detach(doc)
        }
    }

    @MainActor
    func test_delivers_the_code_to_a_typed_write_rejected_subscription() async throws {
        // given
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey())
        try await client.attach(doc, [:], .manual)
        try doc.update { root, _ in
            root.text = "over the limit"
        }
        let received = Shared([WriteRejectedValue]())
        doc.subscribeWriteRejected { event, _ in
            if let event = event as? WriteRejectedEvent {
                received.value += [event.value]
            }
        }
        client.setMockError(for: Self.pushPull, error: writeRejection(.errDocumentSizeExceedsLimit, "document size exceeds limit"))

        // when
        _ = try? await client.sync(doc)

        // then
        XCTAssertEqual(received.value, [
            WriteRejectedValue(code: .documentSizeExceedsLimit, reason: "document size exceeds limit", method: "PushPull")
        ])

        try await client.resync(doc, discardLocalChanges: true)
        try await client.detach(doc)
    }

    @MainActor
    func test_parks_only_the_rejected_document_and_takes_it_back_once_a_push_is_accepted() async throws {
        // given: two realtime documents on one client; the size gate refuses `big` alone.
        let client = try await self.makeClient()
        let big = Document(key: self.docKey("-big"))
        let small = Document(key: self.docKey("-small"))
        try await client.attach(big, [:], .realtime)
        try await client.attach(small, [:], .realtime)
        let bigID = try XCTUnwrap(client.getDocumentAttachment(big.getKey())).resourceID
        let smallID = try XCTUnwrap(client.getDocumentAttachment(small.getKey())).resourceID

        let refusing = Shared(true)
        let refusedBig = Shared(0)
        let acceptedBig = Shared(0)
        let acceptedSmall = Shared(0)
        client.setMockError(for: Self.pushPull, error: writeRejection(.errDocumentSizeExceedsLimit, "document size exceeds limit")) { request in
            guard let request = request as? Yorkie_V1_PushPullChangesRequest, request.documentID == bigID, refusing.value else {
                return false
            }
            refusedBig.value += 1
            return true
        }
        client.observeRequests(for: Self.pushPull) { request in
            guard let request = request as? Yorkie_V1_PushPullChangesRequest else { return }
            if request.documentID == bigID { acceptedBig.value += 1 }
            if request.documentID == smallID { acceptedSmall.value += 1 }
        }

        let rejected = self.expectation(description: "big is reported as write-rejected")
        rejected.assertForOverFulfill = false
        let rejections = Shared(0)
        big.subscribeWriteRejected { _, _ in
            rejections.value += 1
            rejected.fulfill()
        }

        // when
        try big.update { root, _ in
            root.text = "over the limit"
        }
        try small.update { root, _ in
            root.text = "well within it"
        }
        await self.fulfillment(of: [rejected], timeout: 10)

        // then: the loop is alive for everything else, and big stays parked.
        let smallAgain = self.expectation(description: "small keeps syncing on the shared loop")
        smallAgain.assertForOverFulfill = false
        let baseline = acceptedSmall.value
        let poll = Task { @MainActor in
            try? small.update { root, _ in
                root.text = "still editable"
            }
            while acceptedSmall.value <= baseline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            smallAgain.fulfill()
        }
        await self.fulfillment(of: [smallAgain], timeout: 10)
        poll.cancel()

        XCTAssertEqual(refusedBig.value, 1, "the rejected push is not sent a second time")
        XCTAssertEqual(rejections.value, 1, "the rejection is reported to its document")
        XCTAssertTrue(client.getCondition(.syncLoop), "the client-wide loop is still running")
        XCTAssertTrue(try XCTUnwrap(client.getDocumentAttachment(big.getKey())).isWriteRejected())
        XCTAssertFalse(try XCTUnwrap(client.getDocumentAttachment(small.getKey())).isWriteRejected())

        // Shrinking the document is the natural recovery: the next push the server accepts unparks
        // it, and the loop carries it again from then on.
        refusing.value = false
        _ = try await client.sync(big)
        XCTAssertFalse(try XCTUnwrap(client.getDocumentAttachment(big.getKey())).isWriteRejected(), "an accepted push puts the document back on the loop")

        let acceptedBefore = acceptedBig.value
        let pushedAgain = self.expectation(description: "the loop pushes the recovered document again")
        pushedAgain.assertForOverFulfill = false
        let watcher = Task { @MainActor in
            try? big.update { root, _ in
                root.text = "small enough now"
            }
            while acceptedBig.value <= acceptedBefore {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            pushedAgain.fulfill()
        }
        await self.fulfillment(of: [pushedAgain], timeout: 10)
        watcher.cancel()

        try await client.detach(big)
        try await client.detach(small)
    }

    @MainActor
    func test_resyncs_with_the_oversized_changes_discarded_and_syncs_again() async throws {
        // given: a realtime document whose oversized change the size gate refuses.
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey())
        try await client.attach(doc, [:], .realtime)
        let docID = try XCTUnwrap(client.getDocumentAttachment(doc.getKey())).resourceID

        let refused = Shared(0)
        let accepted = Shared(0)
        // The size gate as the server applies it: every pack carrying the oversized change is
        // refused however often it is resent; anything else is stored and acked.
        client.setMockError(for: Self.pushPull, error: writeRejection(.errDocumentSizeExceedsLimit, "document size exceeds limit")) { request in
            guard let request = request as? Yorkie_V1_PushPullChangesRequest, request.documentID == docID,
                  let pack = try? request.changePack.serializedData(),
                  pack.range(of: Data("payload-over-the-gate".utf8)) != nil
            else {
                return false
            }
            refused.value += 1
            return true
        }
        client.observeRequests(for: Self.pushPull) { request in
            if (request as? Yorkie_V1_PushPullChangesRequest)?.documentID == docID { accepted.value += 1 }
        }

        let rejected = self.expectation(description: "the oversized push is reported")
        rejected.assertForOverFulfill = false
        let rejections = Shared(0)
        doc.subscribeWriteRejected { _, _ in
            rejections.value += 1
            rejected.fulfill()
        }
        try doc.update { root, _ in
            root.text = "payload-over-the-gate"
        }
        await self.fulfillment(of: [rejected], timeout: 10)

        // The loop pushed once, was refused, and parked this document instead of resending.
        XCTAssertEqual(refused.value, 1, "the refused pack is not resent")
        XCTAssertTrue(client.getCondition(.syncLoop))
        XCTAssertTrue(try XCTUnwrap(client.getDocumentAttachment(doc.getKey())).isWriteRejected())

        // when
        let discarded = try await client.resync(doc, discardLocalChanges: true)

        // then: the oversized change is handed back, and the same instance is re-anchored.
        XCTAssertFalse(discarded.isEmpty, "the oversized change is handed back")
        XCTAssertEqual(doc.status, .attached)
        XCTAssertNil(doc.getRoot().text)
        XCTAssertTrue(client.getCondition(.syncLoop))

        // An edit made after the recovery is pushed by the loop and acked, and nothing the gate
        // refused went out after the first push.
        let acked = self.expectation(description: "the edit after the recovery is acked")
        acked.assertForOverFulfill = false
        doc.subscribeSync { event, _ in
            if (event as? SyncStatusChangedEvent)?.value == .synced { acked.fulfill() }
        }
        let acceptedBefore = accepted.value
        try doc.update { root, _ in
            root.text = "small"
        }
        await self.fulfillment(of: [acked], timeout: 10)
        let pending = await doc.hasLocalChanges()
        XCTAssertGreaterThan(accepted.value, acceptedBefore, "the loop pushed after the recovery")
        XCTAssertFalse(pending, "the pushed change was acked")
        XCTAssertEqual(refused.value, 1, "only the original push was refused")
        XCTAssertEqual(rejections.value, 1)

        try await client.detach(doc)
    }
}
