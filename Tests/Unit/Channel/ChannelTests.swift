/*
 * Copyright 2025 The Yorkie Authors. All rights reserved.
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

final class ChannelTests: XCTestCase {
    // MARK: - Key validation

    @MainActor
    func test_init_accepts_valid_keys() throws {
        XCTAssertNoThrow(try Channel(key: "room"))
        XCTAssertNoThrow(try Channel(key: "team.room"))
        XCTAssertNoThrow(try Channel(key: "team.room.subroom"))
    }

    @MainActor
    func test_init_rejects_empty_key() {
        XCTAssertThrowsError(try Channel(key: "")) { error in
            XCTAssertEqual((error as? YorkieError)?.code, .errInvalidArgument)
        }
    }

    @MainActor
    func test_init_rejects_whitespace_in_key() {
        XCTAssertThrowsError(try Channel(key: "team room")) { error in
            XCTAssertEqual((error as? YorkieError)?.code, .errInvalidArgument)
        }
    }

    @MainActor
    func test_init_rejects_leading_or_trailing_period() {
        XCTAssertThrowsError(try Channel(key: ".room")) { error in
            XCTAssertEqual((error as? YorkieError)?.code, .errInvalidArgument)
        }
        XCTAssertThrowsError(try Channel(key: "room.")) { error in
            XCTAssertEqual((error as? YorkieError)?.code, .errInvalidArgument)
        }
    }

    @MainActor
    func test_init_rejects_consecutive_periods() {
        XCTAssertThrowsError(try Channel(key: "team..room")) { error in
            XCTAssertEqual((error as? YorkieError)?.code, .errInvalidArgument)
        }
    }

    // MARK: - Key paths

    @MainActor
    func test_getKey_returns_full_key() throws {
        let ch = try Channel(key: "team.room.sub")
        XCTAssertEqual(ch.getKey(), "team.room.sub")
    }

    @MainActor
    func test_getFirstKeyPath_returns_first_segment() throws {
        XCTAssertEqual(try Channel(key: "team.room.sub").getFirstKeyPath(), "team")
        XCTAssertEqual(try Channel(key: "single").getFirstKeyPath(), "single")
    }

    // MARK: - Status

    @MainActor
    func test_initial_status_is_detached() throws {
        let ch = try Channel(key: "room")
        XCTAssertEqual(ch.getChannelStatus(), .detached)
        XCTAssertEqual(ch.getStatus(), .detached)
        XCTAssertFalse(ch.isAttached())
    }

    @MainActor
    func test_setStatus_transitions() throws {
        let ch = try Channel(key: "room")
        ch.setStatus(.attached)
        XCTAssertEqual(ch.getChannelStatus(), .attached)
        XCTAssertEqual(ch.getStatus(), .attached)
        XCTAssertTrue(ch.isAttached())

        ch.setStatus(.detached)
        XCTAssertEqual(ch.getStatus(), .detached)
        XCTAssertFalse(ch.isAttached())

        ch.setStatus(.removed)
        XCTAssertEqual(ch.getStatus(), .removed)
    }

    // MARK: - Actor / session

    @MainActor
    func test_setActor_and_getActorID() throws {
        let ch = try Channel(key: "room")
        XCTAssertNil(ch.getActorID())
        ch.setActor("actor-1")
        XCTAssertEqual(ch.getActorID(), "actor-1")
    }

    @MainActor
    func test_setSessionID_and_getSessionID() throws {
        let ch = try Channel(key: "room")
        XCTAssertNil(ch.getSessionID())
        ch.setSessionID("session-xyz")
        XCTAssertEqual(ch.getSessionID(), "session-xyz")
    }

    // MARK: - Session count / seq

    @MainActor
    func test_updateSessionCount_initializes_with_seq_zero() throws {
        let ch = try Channel(key: "room")

        XCTAssertTrue(ch.updateSessionCount(3, 0))
        XCTAssertEqual(ch.getSessionCount(), 3)
    }

    @MainActor
    func test_updateSessionCount_accepts_newer_seq() throws {
        let ch = try Channel(key: "room")
        _ = ch.updateSessionCount(1, 0)

        XCTAssertTrue(ch.updateSessionCount(2, 5))
        XCTAssertEqual(ch.getSessionCount(), 2)
    }

    @MainActor
    func test_updateSessionCount_ignores_older_or_equal_seq() throws {
        let ch = try Channel(key: "room")
        _ = ch.updateSessionCount(2, 5)

        XCTAssertFalse(ch.updateSessionCount(7, 5)) // equal seq → ignored
        XCTAssertFalse(ch.updateSessionCount(8, 3)) // older seq → ignored
        XCTAssertEqual(ch.getSessionCount(), 2)
    }

    // MARK: - isRealtime / hasLocalChanges

    @MainActor
    func test_isRealtime_defaults_to_true() throws {
        XCTAssertTrue(try Channel(key: "room").isRealtime())
    }

    @MainActor
    func test_isRealtime_respects_init_flag() throws {
        XCTAssertFalse(try Channel(key: "room", isRealtime: false).isRealtime())
    }

    @MainActor
    func test_hasLocalChanges_is_always_false() async throws {
        let ch = try Channel(key: "room")
        let has = await ch.hasLocalChanges()
        XCTAssertFalse(has)
    }

    // MARK: - Subscribe / publish dispatch

    @MainActor
    func test_publish_dispatches_to_specific_callback() throws {
        let ch = try Channel(key: "room")
        var broadcast: ChannelBroadcastEvent?
        ch.subscribeBroadcast { broadcast = $0 }

        let event = ChannelBroadcastEvent(
            clientID: "actor-1",
            topic: "chat",
            payload: Payload(["msg": "hi"]),
            options: nil
        )
        ch.publish(event)

        XCTAssertEqual(broadcast?.topic, "chat")
        XCTAssertEqual(broadcast?.clientID, "actor-1")
    }

    @MainActor
    func test_subscribeAll_receives_every_event_type() throws {
        let ch = try Channel(key: "room")
        var received: [ChannelEventType] = []
        ch.subscribeAll { received.append($0.type) }

        ch.publish(ChannelBroadcastEvent(clientID: "a", topic: "t", payload: Payload([:]), options: nil))
        ch.publish(ChannelLocalBroadcastEvent(clientID: "a", topic: "t", payload: Payload([:]), options: nil))
        ch.publish(ChannelPresenceEvent(type: .presenceChanged, count: 2))
        ch.publish(ChannelAuthErrorEvent(reason: "r", method: "m"))
        ch.publish(ChannelSyncErrorEvent(error: YorkieError(code: .errUnexpected, message: "x"), method: "m"))

        XCTAssertEqual(received, [.broadcast, .localBroadcast, .presenceChanged, .authError, .syncError])
    }

    @MainActor
    func test_subscribeTopic_only_receives_matching_topic() throws {
        let ch = try Channel(key: "room")
        var chatCount = 0
        var notifCount = 0
        ch.subscribeTopic("chat") { _ in chatCount += 1 }
        ch.subscribeTopic("notif") { _ in notifCount += 1 }

        ch.publish(ChannelBroadcastEvent(clientID: "a", topic: "chat", payload: Payload([:]), options: nil))
        ch.publish(ChannelBroadcastEvent(clientID: "a", topic: "chat", payload: Payload([:]), options: nil))
        ch.publish(ChannelBroadcastEvent(clientID: "a", topic: "notif", payload: Payload([:]), options: nil))
        ch.publish(ChannelBroadcastEvent(clientID: "a", topic: "other", payload: Payload([:]), options: nil))

        XCTAssertEqual(chatCount, 2)
        XCTAssertEqual(notifCount, 1)
    }

    @MainActor
    func test_unsubscribe_stops_callbacks() throws {
        let ch = try Channel(key: "room")
        var count = 0
        ch.subscribeBroadcast { _ in count += 1 }
        ch.publish(ChannelBroadcastEvent(clientID: "a", topic: "t", payload: Payload([:]), options: nil))

        ch.unsubscribeBroadcast()
        ch.publish(ChannelBroadcastEvent(clientID: "a", topic: "t", payload: Payload([:]), options: nil))

        XCTAssertEqual(count, 1)
    }

    @MainActor
    func test_unsubscribeTopic_removes_only_one_topic() throws {
        let ch = try Channel(key: "room")
        var chatCount = 0
        var notifCount = 0
        ch.subscribeTopic("chat") { _ in chatCount += 1 }
        ch.subscribeTopic("notif") { _ in notifCount += 1 }

        ch.unsubscribeTopic("chat")
        ch.publish(ChannelBroadcastEvent(clientID: "a", topic: "chat", payload: Payload([:]), options: nil))
        ch.publish(ChannelBroadcastEvent(clientID: "a", topic: "notif", payload: Payload([:]), options: nil))

        XCTAssertEqual(chatCount, 0)
        XCTAssertEqual(notifCount, 1)
    }

    // MARK: - broadcast()

    @MainActor
    func test_broadcast_throws_when_not_attached() throws {
        let ch = try Channel(key: "room")
        ch.setActor("actor-1")
        XCTAssertThrowsError(try ch.broadcast(topic: "t", payload: Payload([:]))) { error in
            XCTAssertEqual((error as? YorkieError)?.code, .errNotAttached)
        }
    }

    @MainActor
    func test_broadcast_throws_when_actorID_missing() throws {
        let ch = try Channel(key: "room")
        ch.setStatus(.attached) // attached but actor never set
        XCTAssertThrowsError(try ch.broadcast(topic: "t", payload: Payload([:]))) { error in
            XCTAssertEqual((error as? YorkieError)?.code, .errInvalidArgument)
        }
    }

    @MainActor
    func test_broadcast_publishes_localBroadcast_event() throws {
        let ch = try Channel(key: "room")
        ch.setActor("actor-1")
        ch.setStatus(.attached)

        var received: ChannelLocalBroadcastEvent?
        ch.subscribeLocalBroadcast { received = $0 }

        try ch.broadcast(topic: "chat", payload: Payload(["msg": "hi"]))

        XCTAssertEqual(received?.topic, "chat")
        XCTAssertEqual(received?.clientID, "actor-1")
        XCTAssertEqual(received?.payload, Payload(["msg": "hi"]))
    }

    // MARK: - Attachable conformance

    @MainActor
    func test_publish_DocEvent_is_no_op() throws {
        let ch = try Channel(key: "room")
        var channelEventCount = 0
        ch.subscribeAll { _ in channelEventCount += 1 }

        ch.publish(ConnectionChangedEvent(value: .connected))

        XCTAssertEqual(channelEventCount, 0)
    }
}
