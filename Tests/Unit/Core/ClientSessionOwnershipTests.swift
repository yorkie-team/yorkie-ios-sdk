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

// Ports the parts of yorkie-js-sdk 0.7.27 that apply on iOS:
//   - #1527 (packages/sdk/test/unit/client/deactivate_orphan_attachment_test.ts, and the
//     identity checks of the new channel_test.ts cases)
//   - #1522 (packages/sdk/test/unit/client/keepalive_deactivate_test.ts): only the session
//     guards. The keepalive deactivate API itself does not exist on iOS.
//
// No server is needed: the client is never activated through RPC, `adoptAttachment` stands in
// for an attach, and the teardown is driven through `handleConnectError`.

import Connect
import Foundation
import SwiftProtobuf
import XCTest
@testable import Yorkie

private func clientNotFound() -> ConnectError {
    var info = Google_Rpc_ErrorInfo()
    info.metadata = ["code": YorkieError.Code.errClientNotFound.rawValue]
    let payload = (try? info.serializedData()) ?? Data()
    return ConnectError(
        code: .notFound,
        message: "client not found",
        details: [ConnectError.Detail(type: "google.rpc.ErrorInfo", payload: payload)]
    )
}

private let firstActor = "000000000000000000000001"
private let secondActor = "000000000000000000000002"

@MainActor
final class ClientSessionOwnershipTests: XCTestCase {
    private func makeClient() -> Client {
        Client("http://localhost:1", ClientOptions(), isMockingEnabled: true)
    }

    // MARK: - deactivate teardown (#1527)

    /// Mirrors JS: "tears down an attachment a same-key attach evicted from the map"
    func test_tears_down_an_attachment_a_same_key_attach_evicted_from_the_map() async throws {
        // given - two attachments of one key; the second takes the key from the first
        let client = self.makeClient()
        let first = try Channel(key: "same-key")
        let second = try Channel(key: "same-key")
        first.setStatus(.attached)
        second.setStatus(.attached)
        let evicted = Attachment(resource: first, resourceID: "s1")
        let held = Attachment(resource: second, resourceID: "s2")
        client.adoptAttachment(evicted, key: "same-key", actorID: firstActor)
        client.adoptAttachment(held, key: "same-key", actorID: firstActor)
        XCTAssertTrue((client.attachmentMap["same-key"] as AnyObject) === held)

        // when - the teardown `deactivate` runs once its RPC has returned
        try await client.handleConnectError(clientNotFound())

        // then - both are torn down, not just the one the key still names
        XCTAssertFalse(client.isActive)
        XCTAssertEqual(first.getStatus(), .detached)
        XCTAssertEqual(second.getStatus(), .detached)
        XCTAssertFalse(client.has("same-key"))
    }

    /// Mirrors JS: "refuses a detach through a Channel object that no longer holds the key"
    func test_detachChannel_throws_errNotAttached_for_a_replaced_channel_and_keeps_the_new_one() async throws {
        // given - `old` was replaced by `next` under the same key
        let client = self.makeClient()
        let old = try Channel(key: "re-attached")
        let next = try Channel(key: "re-attached")
        old.setStatus(.attached)
        next.setStatus(.attached)
        client.adoptAttachment(Attachment(resource: old, resourceID: "s1"), key: "re-attached", actorID: firstActor)
        let nextAttachment = Attachment(resource: next, resourceID: "s2")
        client.adoptAttachment(nextAttachment, key: "re-attached", actorID: firstActor)

        // when - the stale object detaches
        do {
            try await client.detachChannel(old)
            XCTFail("detaching a replaced Channel must throw")
        } catch {
            // then
            XCTAssertEqual((error as? YorkieError)?.code, .errNotAttached)
        }

        // then - the channel attached in its place is untouched
        XCTAssertTrue((client.attachmentMap["re-attached"] as AnyObject) === nextAttachment)
        XCTAssertEqual(next.getStatus(), .attached)
        XCTAssertTrue(client.has("re-attached"))
    }

    /// Mirrors JS: "keeps the new channel when the old detach ends" (identity part)
    func test_detachChannel_of_the_current_channel_removes_only_its_own_key() async throws {
        // given
        let client = self.makeClient()
        let channel = try Channel(key: "detach-me")
        let other = try Channel(key: "keep-me")
        channel.setStatus(.attached)
        other.setStatus(.attached)
        client.adoptAttachment(Attachment(resource: channel, resourceID: "s1"), key: "detach-me", actorID: firstActor)
        client.adoptAttachment(Attachment(resource: other, resourceID: "s2"), key: "keep-me", actorID: firstActor)

        // when
        try await client.detachChannel(channel)

        // then
        XCTAssertFalse(client.has("detach-me"))
        XCTAssertEqual(channel.getStatus(), .detached)
        XCTAssertTrue(client.has("keep-me"))
        XCTAssertEqual(other.getStatus(), .attached)
    }

    /// A detach of an evicted attachment's channel is refused, and a later deactivate still
    /// reaches that attachment.
    func test_deactivate_still_reaches_an_orphan_after_a_refused_stale_detach() async throws {
        // given
        let client = self.makeClient()
        let old = try Channel(key: "orphan")
        let next = try Channel(key: "orphan")
        old.setStatus(.attached)
        next.setStatus(.attached)
        client.adoptAttachment(Attachment(resource: old, resourceID: "s1"), key: "orphan", actorID: firstActor)
        client.adoptAttachment(Attachment(resource: next, resourceID: "s2"), key: "orphan", actorID: firstActor)
        _ = try? await client.detachChannel(old)
        XCTAssertEqual(old.getStatus(), .attached)

        // when
        try await client.handleConnectError(clientNotFound())

        // then
        XCTAssertEqual(old.getStatus(), .detached)
        XCTAssertEqual(next.getStatus(), .detached)
    }

    // MARK: - session capture (#1522)

    func test_captureSession_is_true_while_the_client_stays_in_the_session() {
        // given
        let client = self.makeClient()
        client.adoptAttachment(Attachment(resource: Document(key: "d"), resourceID: "r"), key: "d", actorID: firstActor)

        // when
        let ownsSession = client.captureSession()

        // then
        XCTAssertTrue(ownsSession())
    }

    func test_captureSession_is_false_after_a_deactivate() async throws {
        // given
        let client = self.makeClient()
        client.adoptAttachment(Attachment(resource: Document(key: "d"), resourceID: "r"), key: "d", actorID: firstActor)
        let ownsSession = client.captureSession()

        // when
        try await client.handleConnectError(clientNotFound())

        // then
        XCTAssertFalse(client.isActive)
        XCTAssertFalse(ownsSession())
    }

    func test_captureSession_stays_false_after_re_activation_under_a_new_id() async throws {
        // given - a session that was torn down, then the client activated again as another actor
        let client = self.makeClient()
        client.adoptAttachment(Attachment(resource: Document(key: "d"), resourceID: "r"), key: "d", actorID: firstActor)
        let ownsSession = client.captureSession()
        try await client.handleConnectError(clientNotFound())

        // when
        client.adoptAttachment(Attachment(resource: Document(key: "d2"), resourceID: "r2"), key: "d2", actorID: secondActor)

        // then - the client is active again, but not in the session the request belonged to
        XCTAssertTrue(client.isActive)
        XCTAssertFalse(ownsSession())
        XCTAssertTrue(client.captureSession()())
    }

    func test_captureSession_is_false_when_the_id_changes_without_a_teardown() {
        // given
        let client = self.makeClient()
        client.adoptAttachment(Attachment(resource: Document(key: "d"), resourceID: "r"), key: "d", actorID: firstActor)
        let ownsSession = client.captureSession()

        // when - the same generation, a different client id
        client.adoptAttachment(Attachment(resource: Document(key: "d2"), resourceID: "r2"), key: "d2", actorID: secondActor)

        // then
        XCTAssertTrue(client.isActive)
        XCTAssertFalse(ownsSession())
    }

    // MARK: - handleConnectError session ownership (#1522)

    func test_handleConnectError_leaves_the_client_active_when_it_does_not_own_the_session() async throws {
        // given
        let client = self.makeClient()
        let doc = Document(key: "d")
        client.adoptAttachment(Attachment(resource: doc, resourceID: "r"), key: "d", actorID: firstActor)

        // when - a late errClientNotFound from a session the client has left
        let retry = try await client.handleConnectError(clientNotFound(), ownsSession: { false })

        // then
        XCTAssertFalse(retry)
        XCTAssertTrue(client.isActive)
        XCTAssertTrue(client.has("d"))
        XCTAssertEqual(client.id, firstActor)
    }

    func test_handleConnectError_deactivates_the_client_when_it_owns_the_session() async throws {
        // given
        let client = self.makeClient()
        let doc = Document(key: "d")
        client.adoptAttachment(Attachment(resource: doc, resourceID: "r"), key: "d", actorID: firstActor)

        // when
        let retry = try await client.handleConnectError(clientNotFound(), ownsSession: { true })

        // then
        XCTAssertFalse(retry)
        XCTAssertFalse(client.isActive)
        XCTAssertFalse(client.has("d"))
    }

    func test_handleConnectError_ignores_a_late_client_not_found_after_re_activation() async throws {
        // given - a request captured the first session; the client then re-activated as another actor
        let client = self.makeClient()
        client.adoptAttachment(Attachment(resource: Document(key: "d"), resourceID: "r"), key: "d", actorID: firstActor)
        let ownsSession = client.captureSession()
        client.adoptAttachment(Attachment(resource: Document(key: "d2"), resourceID: "r2"), key: "d2", actorID: secondActor)

        // when
        try await client.handleConnectError(clientNotFound(), ownsSession: ownsSession)

        // then - the new session is left alone
        XCTAssertTrue(client.isActive)
        XCTAssertEqual(client.id, secondActor)
        XCTAssertTrue(client.has("d2"))
    }

    // MARK: - Watch stream of a torn-down attachment

    /// iOS counterpart of JS #1522's "a cancelled stream must not clear or reconnect its successor".
    func test_a_detached_channels_late_stream_end_does_not_reconnect_it_under_a_same_key_successor() async throws {
        // given - `old` is detached, then a new channel of the same key takes the key
        let client = self.makeClient()
        let old = try Channel(key: "same-key")
        let next = try Channel(key: "same-key")
        old.setStatus(.attached)
        let oldAttachment = Attachment(resource: old, resourceID: "s1")
        client.adoptAttachment(oldAttachment, key: "same-key", actorID: firstActor)
        try await client.detachChannel(old)
        next.setStatus(.attached)
        let nextAttachment = Attachment(resource: next, resourceID: "s2")
        client.adoptAttachment(nextAttachment, key: "same-key", actorID: firstActor)

        // when - the old stream's completion lands after the re-attach
        try client.onStreamDisconnect("same-key", with: oldAttachment, error: nil)

        // then - no reconnect is armed for the torn-down attachment
        XCTAssertTrue(oldAttachment.cancelled)
        XCTAssertNil(oldAttachment.watchLoopReconnectTimer)

        // and the successor still reconnects its own stream
        try client.onStreamDisconnect("same-key", with: nextAttachment, error: nil)
        XCTAssertNotNil(nextAttachment.watchLoopReconnectTimer)
        nextAttachment.resetWatchLoopTimer()
    }

    func test_an_evicted_attachments_stream_end_does_not_reconnect_it() throws {
        // given - a same-key attach evicted `evicted` from the map without tearing it down
        let client = self.makeClient()
        let evicted = try Attachment(resource: Channel(key: "same-key"), resourceID: "s1")
        let held = try Attachment(resource: Channel(key: "same-key"), resourceID: "s2")
        client.adoptAttachment(evicted, key: "same-key", actorID: firstActor)
        client.adoptAttachment(held, key: "same-key", actorID: firstActor)

        // when
        try client.onStreamDisconnect("same-key", with: evicted, error: nil)

        // then - the key belongs to `held`, so nothing reconnects `evicted`
        XCTAssertNil(evicted.watchLoopReconnectTimer)
    }

    func test_a_displaced_attachments_watch_message_does_not_reach_the_same_key_successor() async throws {
        // given - a same-key attach displaced `displaced` without tearing it down
        let client = self.makeClient()
        let displaced = try Attachment(resource: Channel(key: "same-key"), resourceID: "s1")
        let held = try Attachment(resource: Channel(key: "same-key"), resourceID: "s2")
        client.adoptAttachment(displaced, key: "same-key", actorID: firstActor)
        client.adoptAttachment(held, key: "same-key", actorID: firstActor)
        var channelInit = Yorkie_V1_ChannelInit()
        channelInit.channelKey = "same-key"
        channelInit.sessionCount = 5
        channelInit.seq = 1
        var resourceInit = Yorkie_V1_ResourceInit()
        resourceInit.channelInit = channelInit
        var response = WatchResponse()
        response.initialization.resourceInits = [resourceInit]

        // when - the displaced attachment's stream delivers a message
        await client.handleChannelWatchResult(.message(response), key: "same-key",
                                              attachment: displaced, generation: displaced.watchGeneration)

        // then - it is dropped instead of being routed by key to `held`
        XCTAssertEqual(held.resource.getSessionCount(), 0)

        // and `held` still receives its own stream's messages
        await client.handleChannelWatchResult(.message(response), key: "same-key",
                                              attachment: held, generation: held.watchGeneration)
        XCTAssertEqual(held.resource.getSessionCount(), 5)
    }

    func test_a_stale_teardown_keeps_the_forwarder_of_the_same_channel_attached_again() throws {
        // given - one Channel detached and attached again: the newer attachment owns its forwarder
        let client = self.makeClient()
        let channel = try Channel(key: "same-key")
        channel.setActor(firstActor)
        channel.setStatus(.attached)
        let stale = Attachment(resource: channel, resourceID: "")
        let current = Attachment(resource: channel, resourceID: "s2")
        client.adoptAttachment(stale, key: "same-key", actorID: firstActor)
        client.adoptAttachment(current, key: "same-key", actorID: firstActor)
        var forwarded = 0
        channel.subscribeLocalBroadcast { _ in forwarded += 1 }

        // when - the stale attempt rolls itself back
        try client.detachInternal("same-key", stale)

        // then - its own stream is cancelled, but the Channel keeps forwarding broadcasts
        XCTAssertTrue(stale.cancelled)
        XCTAssertFalse(current.cancelled)
        try channel.broadcast(topic: "t", payload: Payload(["k": "v"]))
        XCTAssertEqual(forwarded, 1)
    }

    func test_tearing_down_a_replaced_channel_removes_only_its_own_forwarder() throws {
        // given - a different Channel of the same key took the key from `old`
        let client = self.makeClient()
        let old = try Channel(key: "same-key")
        old.setActor(firstActor)
        old.setStatus(.attached)
        let oldAttachment = Attachment(resource: old, resourceID: "s1")
        client.adoptAttachment(oldAttachment, key: "same-key", actorID: firstActor)
        try client.adoptAttachment(Attachment(resource: Channel(key: "same-key"), resourceID: "s2"),
                                   key: "same-key", actorID: firstActor)
        var forwarded = 0
        old.subscribeLocalBroadcast { _ in forwarded += 1 }

        // when
        try client.detachInternal("same-key", oldAttachment)

        // then - `old`'s forwarder goes with it
        try old.broadcast(topic: "t", payload: Payload(["k": "v"]))
        XCTAssertEqual(forwarded, 0)
    }
}
