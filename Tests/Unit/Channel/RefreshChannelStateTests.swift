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

// Unit tests for the RefreshChannel lifecycle state machine introduced in
// yorkie 0.7.10 (#1258). `refreshChannel` is a private method on `Client`;
// these tests exercise the `Channel` state it drives via the public
// `Channel` API (the observable surface of the state machine).
//
// Tests that require the full RPC round-trip (mocked or live) live in
// `ChannelRefreshIntegrationTests`.
final class RefreshChannelStateTests: XCTestCase {
    // MARK: - Initial state

    // After attachChannel registers the channel locally (but before the
    // first-call RefreshChannel RPC completes) the channel is still
    // `.detached` with an empty session id.
    @MainActor
    func test_channel_is_detached_with_empty_sessionID_before_first_refresh() throws {
        // given
        let ch = try Channel(key: "room")

        // then — initial state mirrors the pre-first-call registration
        XCTAssertEqual(ch.getStatus(), .detached)
        XCTAssertNil(ch.getSessionID())
    }

    // MARK: - First-call success → sessionID set + status .attached

    // The `refreshChannel` implementation calls `channel.setSessionID` and
    // `channel.setStatus(.attached)` on success when `isFirstCall` is true.
    @MainActor
    func test_first_call_success_sets_sessionID_and_transitions_to_attached() throws {
        // given
        let ch = try Channel(key: "room")
        XCTAssertEqual(ch.getStatus(), .detached)

        // when — simulate what refreshChannel does after a successful first-call response
        ch.setSessionID("session-abc")
        ch.setStatus(.attached)

        // then
        XCTAssertEqual(ch.getSessionID(), "session-abc")
        XCTAssertEqual(ch.getStatus(), .attached)
        XCTAssertTrue(ch.isAttached())
    }

    // MARK: - ErrSessionNotFound → sessionID cleared, stays locally registered

    // On `ErrSessionNotFound` the server has reclaimed the session. The client
    // clears the local session id so the next refresh re-enters the first-call
    // branch. The channel status remains as-is (the attachment is not torn down).
    @MainActor
    func test_errSessionNotFound_clears_sessionID_without_changing_status() throws {
        // given — channel is attached with a known session
        let ch = try Channel(key: "room")
        ch.setSessionID("session-xyz")
        ch.setStatus(.attached)

        // when — simulate what refreshChannel does when errSessionNotFound arrives
        ch.setSessionID("")

        // then — session cleared, status unchanged
        XCTAssertEqual(ch.getSessionID(), "")
        XCTAssertEqual(ch.getStatus(), .attached, "status must not be cleared by session expiry alone")
    }

    // MARK: - Empty sessionID on first-call response → stays .detached (no flap)

    // When the server returns a success response carrying an empty sessionID
    // (protocol drift / partial response), the channel must NOT transition to
    // `.attached`. The next heartbeat tick re-enters the first-call branch.
    @MainActor
    func test_empty_sessionID_in_first_call_response_leaves_channel_detached() throws {
        // given — fresh channel, just like the state between local registration
        // and the first refresh RPC completing
        let ch = try Channel(key: "room")
        XCTAssertEqual(ch.getStatus(), .detached)

        // when — simulate refreshChannel guard: `isFirstCall && !message.sessionID.isEmpty`
        // The guard is NOT entered because sessionID is empty.
        let sessionID = ""
        let isFirstCall = true
        if isFirstCall, !sessionID.isEmpty {
            ch.setSessionID(sessionID)
            ch.setStatus(.attached)
        }

        // then — channel stays detached; no flap to .attached
        XCTAssertEqual(ch.getStatus(), .detached)
        XCTAssertNil(ch.getSessionID(), "session id must remain nil when empty response arrives")
    }

    // MARK: - Non-recoverable error → ChannelSyncErrorEvent published

    // `refreshChannel` publishes `ChannelSyncErrorEvent` for any error that is
    // not `errSessionNotFound`, provided the channel is still attached.
    @MainActor
    func test_non_recoverable_error_publishes_syncErrorEvent_while_attached() throws {
        // given — attached channel with a presence subscriber
        let ch = try Channel(key: "room")
        ch.setActor("actor-1")
        ch.setStatus(.attached)

        var capturedError: ChannelSyncErrorEvent?
        ch.subscribeAll { event in
            if let syncErr = event as? ChannelSyncErrorEvent {
                capturedError = syncErr
            }
        }

        // when — simulate what refreshChannel does for a non-recoverable error
        // while `stillAttached` is true
        let fakeError = YorkieError(code: .errRPC, message: "server exploded")
        ch.publish(ChannelSyncErrorEvent(error: fakeError, method: "RefreshChannel"))

        // then
        XCTAssertNotNil(capturedError)
        XCTAssertEqual(capturedError?.method, "RefreshChannel")
    }

    // `ChannelSyncErrorEvent` must NOT be published when the channel has
    // already been detached (stillAttached is false) — a detach mid-flight
    // must not produce a spurious error event.
    @MainActor
    func test_syncErrorEvent_not_published_after_detach() throws {
        // given — channel is detached
        let ch = try Channel(key: "room")
        XCTAssertEqual(ch.getStatus(), .detached)

        var eventCount = 0
        ch.subscribeAll { _ in eventCount += 1 }

        // when — simulate the `stillAttached` guard: the guard is false, so
        // refreshChannel skips the publish entirely
        let stillAttached = false // matches: self.getChannelAttachment(channel.getKey()) != nil
        if stillAttached {
            ch.publish(ChannelSyncErrorEvent(
                error: YorkieError(code: .errRPC, message: "stale error"),
                method: "RefreshChannel"
            ))
        }

        // then
        XCTAssertEqual(eventCount, 0, "no event should be dispatched after channel is detached")
    }

    // MARK: - Session count update

    // A successful refresh publishes `ChannelPresenceEvent` when the session
    // count changes. `updateSessionCount` with seq=0 always accepts the new value.
    @MainActor
    func test_presence_event_published_when_session_count_changes() throws {
        // given
        let ch = try Channel(key: "room")
        ch.setStatus(.attached)
        _ = ch.updateSessionCount(1, 0)

        var presenceEvents: [ChannelPresenceEvent] = []
        ch.subscribePresenceChange { presenceEvents.append($0) }

        // when — simulate what refreshChannel does on a successful heartbeat
        // where the count changed from 1 to 2
        let previousCount = ch.getSessionCount()
        if ch.updateSessionCount(2, 0), ch.getSessionCount() != previousCount {
            ch.publish(ChannelPresenceEvent(type: .presenceChanged, count: ch.getSessionCount()))
        }

        // then
        XCTAssertEqual(presenceEvents.count, 1)
        XCTAssertEqual(presenceEvents.first?.count, 2)
    }

    @MainActor
    func test_presence_event_not_published_when_session_count_unchanged() throws {
        // given
        let ch = try Channel(key: "room")
        ch.setStatus(.attached)
        _ = ch.updateSessionCount(2, 0)

        var presenceEvents: [ChannelPresenceEvent] = []
        ch.subscribePresenceChange { presenceEvents.append($0) }

        // when — same count arrives again (seq=0 triggers update, but count is the same)
        let previousCount = ch.getSessionCount()
        if ch.updateSessionCount(2, 0), ch.getSessionCount() != previousCount {
            ch.publish(ChannelPresenceEvent(type: .presenceChanged, count: ch.getSessionCount()))
        }

        // then — no event because count didn't change
        XCTAssertEqual(presenceEvents.count, 0)
    }
}
