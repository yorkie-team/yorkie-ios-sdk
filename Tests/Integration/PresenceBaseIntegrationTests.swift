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

// Port of yorkie-js-sdk packages/sdk/test/unit/client/presence_base_test.ts (yorkie-js-sdk#1477).
//
// The JS file drives a fake rpcClient. Here a real server answers and the mock-error seam
// (`setMockError`) plays the `ErrPresenceBaseUnavailable` the server returns when it has no base to
// fold a patch into. The request observer (`observeRequests`) reads back what the resend carried.
//
// A mocked error returns before the request observer runs, so the observer sees only the resend --
// which is the pack under test -- and a rejected pack never reaches the server.
//
// The local server may predate presence-patch and advertise no capability, and it would store a
// PATCH as an empty presence. So no test lets a PATCH reach it: the patch is crafted in the session
// (an ack that advertises the capability, handed to the document directly) and is always the pack
// the mocked error rejects; only the put that replaces it goes out.
//
// Not ported: the JS "restores a persisted patch across a restart and attaches" shape. This SDK
// persists a patch as the put it stands for (see `Converter.toPersistedChange`), so a restored queue
// holds no patch; the attach test below instead reaches the attach with a patch pending through a
// clear that leaves the queue without a base.
//
// Requires a yorkie server at localhost:8080.

/// Builds the error a server without a presence base answers a pack that carries a patch with, shaped
/// so `errorCodeOf` reads the code out of the error details exactly as it does for a real response.
private func presenceBaseUnavailableError() -> ConnectError {
    var info = Google_Rpc_ErrorInfo()
    info.metadata = ["code": YorkieError.Code.errPresenceBaseUnavailable.rawValue]
    let payload = (try? info.serializedData()) ?? Data()
    return ConnectError(
        code: .failedPrecondition,
        message: "presence base unavailable",
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

final class PresenceBaseIntegrationTests: XCTestCase {
    let rpcAddress = "http://localhost:8080"

    private static let pushPull = YorkieServiceClient.Metadata.Methods.pushPullChanges
    private static let attach = YorkieServiceClient.Metadata.Methods.attachDocument
    private static let detach = YorkieServiceClient.Metadata.Methods.detachDocument
    private static let remove = YorkieServiceClient.Metadata.Methods.removeDocument

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

    /// Hands the document a pack that advertises `presence-patch` without acknowledging anything, as
    /// the reply of a server that takes patches would.
    @MainActor
    private func advertisePresencePatch(_ doc: Document, checkpoint: Checkpoint) throws {
        try doc.applyChangePack(ChangePack(key: doc.getKey(),
                                           checkpoint: checkpoint,
                                           isRemoved: false,
                                           changes: [],
                                           versionVector: nil,
                                           capabilities: [presencePatchCapability]))
    }

    private func kinds(of pack: Yorkie_V1_ChangePack) -> [Yorkie_V1_PresenceChange.ChangeType] {
        pack.changes.map { $0.presenceChange.type }
    }

    @MainActor
    func test_resends_an_attach_pack_with_a_full_put_when_the_base_is_gone() async throws {
        // given: a detached document whose queue holds a patch and a later clear. The clear leaves it
        // without a base, so the attach's own presence seed is a put and the patch is the only one.
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)
        try doc.update { _, presence in presence.set(["name": "a"]) }
        try self.advertisePresencePatch(doc, checkpoint: .initial)
        try doc.update { _, presence in presence.set(["cursor": 1]) }
        try doc.update { _, presence in presence.clear() }
        let queued = Converter.toChangePack(pack: doc.createChangePack())
        XCTAssertEqual(self.kinds(of: queued), [.put, .patch, .clear])

        let sent = Box([Yorkie_V1_ChangePack]())
        client.observeRequests(for: Self.attach) { request in
            if let request = request as? Yorkie_V1_AttachDocumentRequest {
                sent.value += [request.changePack]
            }
        }
        client.setMockError(for: Self.attach, error: presenceBaseUnavailableError(), count: 1)

        // when
        try await client.attach(doc, ["name": "b"], .manual)

        // then: the rejected pack never reached the server; the resend carries the patch as the put it
        // stands for. Without the retry the attach fails, and fails identically on every later try.
        XCTAssertEqual(doc.status, .attached)
        XCTAssertEqual(sent.value.count, 1)
        let resent = try XCTUnwrap(sent.value.first)
        XCTAssertEqual(self.kinds(of: resent), [.put, .put, .clear, .put])
        XCTAssertEqual(Set(resent.changes[1].presenceChange.presence.data.keys), ["name", "cursor"])
        XCTAssertTrue(resent.changes.allSatisfy { $0.presenceChange.removedKeys.isEmpty })

        try await client.detach(doc)
    }

    @MainActor
    func test_resends_a_push_pull_pack_with_a_full_put_when_the_base_is_gone() async throws {
        // given: an attached document that has learned the capability, with a patch pending.
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)
        try await client.attach(doc, ["name": "a"], .manual)
        try self.advertisePresencePatch(doc, checkpoint: doc.checkpoint)
        XCTAssertTrue(doc.canPatchPresence())
        try doc.update { _, presence in presence.set(["cursor": 1]) }
        XCTAssertTrue(doc.hasPendingPresencePatch())

        let sent = Box([Yorkie_V1_ChangePack]())
        client.observeRequests(for: Self.pushPull) { request in
            if let request = request as? Yorkie_V1_PushPullChangesRequest {
                sent.value += [request.changePack]
            }
        }
        client.setMockError(for: Self.pushPull, error: presenceBaseUnavailableError(), count: 1)

        // when
        try await client.sync(doc)

        // then
        XCTAssertEqual(sent.value.count, 1)
        let resent = try XCTUnwrap(sent.value.first)
        XCTAssertEqual(self.kinds(of: resent), [.put])
        XCTAssertEqual(Set(resent.changes[0].presenceChange.presence.data.keys), ["name", "cursor"])
        XCTAssertFalse(doc.hasPendingPresencePatch())
        // The server that took the resend advertises nothing (or, if it takes patches, everything it
        // supports); either way the document agrees with it rather than with the rejected reply.
        XCTAssertEqual(doc.getMyPresence()?["cursor"] as? Int, 1)

        try await client.detach(doc)
    }

    @MainActor
    func test_resends_a_detach_pack_with_a_full_put_when_the_base_is_gone() async throws {
        // given
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)
        try await client.attach(doc, ["name": "a"], .manual)
        try self.advertisePresencePatch(doc, checkpoint: doc.checkpoint)
        try doc.update { _, presence in presence.set(["cursor": 1]) }

        let sent = Box([Yorkie_V1_ChangePack]())
        client.observeRequests(for: Self.detach) { request in
            if let request = request as? Yorkie_V1_DetachDocumentRequest {
                sent.value += [request.changePack]
            }
        }
        client.setMockError(for: Self.detach, error: presenceBaseUnavailableError(), count: 1)

        // when: the detach queues the presence clear behind the pending patch, then pushes both.
        try await client.detach(doc)

        // then
        XCTAssertEqual(doc.status, .detached)
        XCTAssertEqual(sent.value.count, 1)
        let resent = try XCTUnwrap(sent.value.first)
        XCTAssertEqual(self.kinds(of: resent), [.put, .clear])
        XCTAssertEqual(Set(resent.changes[0].presenceChange.presence.data.keys), ["name", "cursor"])
    }

    @MainActor
    func test_resends_a_remove_pack_with_a_full_put_when_the_base_is_gone() async throws {
        // given
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)
        try await client.attach(doc, ["name": "a"], .manual)
        try self.advertisePresencePatch(doc, checkpoint: doc.checkpoint)
        try doc.update { _, presence in presence.set(["cursor": 1]) }

        let sent = Box([Yorkie_V1_ChangePack]())
        client.observeRequests(for: Self.remove) { request in
            if let request = request as? Yorkie_V1_RemoveDocumentRequest {
                sent.value += [request.changePack]
            }
        }
        client.setMockError(for: Self.remove, error: presenceBaseUnavailableError(), count: 1)

        // when
        try await client.remove(doc)

        // then: the rebuilt pack is still a removal.
        XCTAssertEqual(doc.status, .removed)
        XCTAssertEqual(sent.value.count, 1)
        let resent = try XCTUnwrap(sent.value.first)
        XCTAssertTrue(resent.isRemoved)
        XCTAssertEqual(self.kinds(of: resent), [.put])
    }

    @MainActor
    func test_propagates_an_error_that_is_not_a_lost_presence_base() async throws {
        // given: one mocked error that is not ErrPresenceBaseUnavailable. A wrong retry would send the
        // pack to the real server, which would accept it and make the attach succeed.
        let client = try await self.makeClient()
        let doc = Document(key: self.docKey)
        let observed = Box(0)
        client.observeRequests(for: Self.attach) { _ in observed.value += 1 }
        client.setMockError(for: Self.attach,
                            error: ConnectError(code: .internalError, message: "boom", details: []),
                            count: 1)

        // when / then
        do {
            try await client.attach(doc, ["name": "a"], .manual)
            XCTFail("the attach should have failed with the original error")
        } catch {
            XCTAssertEqual(doc.status, .detached)
        }
        XCTAssertEqual(observed.value, 0, "only a lost presence base is retried")
    }
}
